// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package agent

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"time"

	nvkeutils "github.com/dsx-ai-factory/nvke/agent/pkg/utils"
)

const (
	// DefaultControlPlaneEndpointGateSettle is how long a withdrawal waits
	// between closing the gate and closing the sockets, unless the agent is
	// started with another value.
	DefaultControlPlaneEndpointGateSettle = 10 * time.Second

	controlPlaneEndpointGateFileMode = 0o644
	controlPlaneEndpointGateDirMode  = 0o755

	stepResolvingEndpointBackendAddress         = "resolving_endpoint_backend_address"
	stepClosingEndpointGate                     = "closing_endpoint_gate"
	stepWaitingEndpointGateSettle               = "waiting_for_endpoint_gate_settle"
	stepClosingEndpointBackendSockets           = "closing_endpoint_backend_sockets"
	stepWaitingEndpointBackendSocketQuietWindow = "waiting_for_endpoint_backend_socket_quiet_window"
	stepOpeningEndpointGate                     = "opening_endpoint_gate"
)

// ControlPlaneEndpointGate configures the health gate that takes this node out
// of a control-plane load balancer the node does not run. The zero value means
// there is no gate, and the agent then withdraws only kube-vip.
//
// The gate is a file. The load balancer's health check has to fail for this
// node while the file exists, which is the one thing the agent cannot verify
// directly: it cannot see the load balancer. What it can see is whether
// connections keep arriving, and that is what the quiet window after the gate
// closes is for.
type ControlPlaneEndpointGate struct {
	// File is the path of the gate file. Empty means no gate.
	File string
	// BackendInterface is the interface the load balancer's connections arrive
	// on. Its address is read at each withdrawal rather than once at startup,
	// because the agent starts before the node's addresses are final.
	BackendInterface string
	// Settle is how long the load balancer is given to stop sending new
	// connections here after the gate closes, before the established ones are
	// closed.
	Settle time.Duration
}

// configured reports whether this node has a gate.
func (g ControlPlaneEndpointGate) configured() bool {
	return g.File != ""
}

// withdrawThroughControlPlaneEndpointGate takes this node out of the load
// balancer in front of the control plane. Callers must already hold
// staticPodMutationMu and must have checked that a gate is configured.
//
// The steps mirror withdrawKubeVip where they can. Closing the gate stands in
// for parking kube-vip: it is what tells the network to stop steering traffic
// here. Nothing stands in for removing the address from lo, because the backend
// address is the node's own and has to stay. So the settle time is all that
// separates closing the gate from closing the sockets, and the quiet window is
// the only proof that the load balancer stopped. Closing the established
// sockets and the quiet window are the kube-vip code on a different address.
//
// The backend address is resolved before the gate closes, so an interface that
// cannot be resolved fails the withdrawal with the node untouched.
//
// A failure after the gate closed leaves it closed, as a failed kube-vip
// withdrawal leaves the manifest parked. The restore that follows a failed
// withdrawal opens it.
func (s *NodeAgentServer) withdrawThroughControlPlaneEndpointGate(
	ctx context.Context,
	runner nvkeutils.CommandRunner,
	progress nodeAgentOperationProgress,
	parkDir string,
) error {
	gate := s.ControlPlaneEndpointGate
	progress.SetStep(stepResolvingEndpointBackendAddress)
	backend, err := resolveEndpointBackendAddress(runner, gate.BackendInterface)
	if err != nil {
		return fmt.Errorf("resolve control plane endpoint backend address: %w", err)
	}

	progress.SetStep(stepClosingEndpointGate)
	closed, err := s.closeControlPlaneEndpointGate(parkDir)
	if err != nil {
		return fmt.Errorf("close control plane endpoint gate: %w", err)
	}
	if !closed {
		return nil
	}

	// The load balancer acts on the gate only at its next health checks, so the
	// established sockets are left alone until it has had time to. Closing them
	// earlier would send the clients straight back here.
	progress.SetStep(stepWaitingEndpointGateSettle)
	slog.Info("waiting for the load balancer to act on the closed control plane endpoint gate",
		"settle", gate.Settle, "backendInterface", gate.BackendInterface, "backendAddress", backend)
	if err := sleepOrDone(ctx, gate.Settle); err != nil {
		return fmt.Errorf("wait for control plane endpoint gate settle: %w", err)
	}

	progress.SetStep(stepClosingEndpointBackendSockets)
	if _, err := s.closeRemoteVipPeers(runner, backend, defaultKubeVipApiserverPort); err != nil {
		return fmt.Errorf("close remote sockets on control plane endpoint backend address %s: %w", backend, err)
	}

	// The proof that the load balancer stopped. A health check that does not
	// read the gate, or a settle time shorter than the health check needs, shows
	// up here as new sockets, and the operation must not start in either case.
	//
	// The wrapped error is the kube-vip check's own, so it calls the address a
	// VIP and dates the sockets from kube-vip's exit. Here the address is the
	// backend address and the sockets are new since the gate closed.
	progress.SetStep(stepWaitingEndpointBackendSocketQuietWindow)
	if err := s.waitForVipSocketQuietWindow(ctx, runner, backend, defaultKubeVipApiserverPort, s.kubeVipSocketQuietWindowOrDefault()); err != nil {
		return fmt.Errorf("control plane endpoint backend socket quiet window failed on %s: %w", backend, err)
	}
	slog.Info("withdrew this node from the control plane endpoint through the gate",
		"gateFile", gate.File, "backendInterface", gate.BackendInterface, "backendAddress", backend)
	return nil
}

// closeControlPlaneEndpointGate writes the gate file, and reports whether this
// call is the one that holds the gate closed.
//
// The file's content is the park directory of the flow that closed it, which
// makes the gate one more member of that park family. See
// defaultEtcdDefragParkDir: a gate that names it is a debt the agent owes and
// settles itself, at the end of the defragmentation or at the next startup,
// and a gate that names anything else stays closed until a caller asks for the
// node back.
//
// A defragmentation therefore leaves alone a gate somebody else closed. The
// node is already out of service on that caller's terms, and taking the gate
// over would have the defragmentation open it underneath them when it finishes.
// The reverse is allowed: a caller that withdraws the node takes over a gate
// the defragmentation left behind, because the caller's hold is the stronger
// one.
//
// The file is written beside its final path and renamed into place. The load
// balancer's health check only asks whether the file exists, so a write that
// failed halfway would otherwise leave a closed gate with no readable owner,
// which nothing but a caller would ever open.
func (s *NodeAgentServer) closeControlPlaneEndpointGate(parkDir string) (bool, error) {
	path := s.controlPlaneEndpointGatePath()
	if parkDir == defaultEtcdDefragParkDir {
		owner, closed, err := readControlPlaneEndpointGate(path)
		if err != nil {
			return false, err
		}
		if closed && owner != parkDir {
			slog.Info("control plane endpoint gate is already closed and a caller owns it; leaving it as it is",
				"gateFile", path, "owner", owner)
			return false, nil
		}
	}

	if err := os.MkdirAll(filepath.Dir(path), controlPlaneEndpointGateDirMode); err != nil {
		return false, err
	}
	writer := s.FileWriter
	if writer == nil {
		writer = &nvkeutils.OSFileWriter{}
	}
	staged := path + ".tmp"
	if err := writer.WriteFile(staged, []byte(parkDir+"\n"), controlPlaneEndpointGateFileMode); err != nil {
		return false, fmt.Errorf("write %s: %w", staged, err)
	}
	if err := os.Rename(staged, path); err != nil {
		return false, err
	}
	slog.Info("closed the control plane endpoint gate", "gateFile", path, "owner", parkDir)
	return true, nil
}

// openControlPlaneEndpointGate removes the gate file, which is the whole of
// returning this node to the load balancer: the health check passes again once
// the file is gone and the local apiserver is ready, and the load balancer does
// the rest. Callers must already hold staticPodMutationMu.
//
// Nothing here waits for the load balancer to take the node back, for the same
// reason nothing closes the gate on its say-so: the agent cannot see it.
//
// parkDir decides which gates this may open, by the same rule that decides
// which parked manifests a restore puts back. The defragmentation and the
// startup reconciler pass defaultEtcdDefragParkDir and open only a gate the
// defragmentation closed. A caller's restore opens the gate whoever closed it,
// since asking for the node back is exactly what a closed gate waits for.
//
// A node with no gate configured, and a gate that is already open, are both
// success.
func (s *NodeAgentServer) openControlPlaneEndpointGate(progress nodeAgentOperationProgress, parkDir string) error {
	if !s.ControlPlaneEndpointGate.configured() {
		return nil
	}
	path := s.controlPlaneEndpointGatePath()
	owner, closed, err := readControlPlaneEndpointGate(path)
	if err != nil {
		return fmt.Errorf("open control plane endpoint gate: %w", err)
	}
	if !closed {
		return nil
	}
	if parkDir == defaultEtcdDefragParkDir && owner != parkDir {
		slog.Info("control plane endpoint gate is closed and a caller owns it; leaving it closed",
			"gateFile", path, "owner", owner)
		return nil
	}

	progress.SetStep(stepOpeningEndpointGate)
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("open control plane endpoint gate: %w", err)
	}
	slog.Info("opened the control plane endpoint gate", "gateFile", path, "owner", owner)
	return nil
}

// handOffControlPlaneEndpointGateToCaller makes a gate the defragmentation
// closed stay closed across a restart, by naming the shared park directory as
// its owner. It is the gate's half of handOffParkedManifestsToCaller and exists
// for the same branches.
func (s *NodeAgentServer) handOffControlPlaneEndpointGateToCaller() error {
	if !s.ControlPlaneEndpointGate.configured() {
		return nil
	}
	path := s.controlPlaneEndpointGatePath()
	owner, closed, err := readControlPlaneEndpointGate(path)
	if err != nil {
		return err
	}
	if !closed || owner != defaultEtcdDefragParkDir {
		return nil
	}
	if _, err := s.closeControlPlaneEndpointGate(defaultStaticPodBackupDir); err != nil {
		return fmt.Errorf("hand the control plane endpoint gate to the caller: %w", err)
	}
	slog.Warn("handed the closed control plane endpoint gate to the caller; this node stays out of the load balancer until a caller restores it",
		"gateFile", path)
	return nil
}

func (s *NodeAgentServer) controlPlaneEndpointGatePath() string {
	return s.rootedPath(s.ControlPlaneEndpointGate.File)
}

// readControlPlaneEndpointGate reports whether the gate is closed and, if so,
// which park directory it names as its owner. A gate file the agent did not
// write, such as one an operator created by hand, has no such owner and is
// treated as a caller's.
func readControlPlaneEndpointGate(path string) (string, bool, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return "", false, nil
		}
		return "", false, err
	}
	return strings.TrimSpace(string(data)), true, nil
}

// resolveEndpointBackendAddress returns the address the load balancer's
// connections arrive on, which is the one global IPv4 address of the backend
// interface.
//
// IPv4 only, as the kube-vip withdrawal is: the socket listing and `ss -K`
// below it are written for IPv4 addresses. An interface with no IPv4 address is
// an error rather than a skip, because the withdrawal could then neither close
// the established sockets nor verify the quiet window.
//
// More than one address is an error for the reason more than one VIP on lo is:
// nothing says which of them the load balancer uses, and guessing would close
// and watch the wrong sockets.
func resolveEndpointBackendAddress(runner nvkeutils.CommandRunner, iface string) (string, error) {
	output, err := runner.Run("ip", []string{"-o", "-4", "addr", "show", "dev", iface, "scope", "global"}, nil) //nolint:goconst // ip(8) argv fragment; naming each CLI flag reads worse than the literal
	if err != nil {
		return "", fmt.Errorf("ip addr show dev %s: %w: %s", iface, err, strings.TrimSpace(string(output)))
	}
	addresses, err := parseInterfaceIPv4Addresses(string(output))
	if err != nil {
		return "", err
	}
	switch len(addresses) {
	case 0:
		return "", fmt.Errorf("no global IPv4 address on %s", iface)
	case 1:
		return addresses[0], nil
	default:
		return "", fmt.Errorf("multiple global IPv4 addresses on %s: %s", iface, strings.Join(addresses, ", "))
	}
}

// parseInterfaceIPv4Addresses reads the addresses out of `ip -o -4 addr show`.
// The address follows "inet" and usually carries a prefix length; a
// point-to-point address is printed without one.
func parseInterfaceIPv4Addresses(output string) ([]string, error) {
	var addresses []string
	for _, line := range strings.Split(output, "\n") {
		fields := strings.Fields(line)
		for i := 0; i+1 < len(fields); i++ {
			if fields[i] != "inet" {
				continue
			}
			addr, err := parseInterfaceAddress(fields[i+1])
			if err != nil {
				return nil, fmt.Errorf("parse interface address %q: %w", fields[i+1], err)
			}
			if addr.Is4() {
				addresses = append(addresses, addr.String())
			}
			break
		}
	}
	return addresses, nil
}

func parseInterfaceAddress(field string) (netip.Addr, error) {
	if prefix, err := netip.ParsePrefix(field); err == nil {
		return prefix.Addr(), nil
	}
	return netip.ParseAddr(field)
}
