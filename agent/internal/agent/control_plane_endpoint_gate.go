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
	stepResolvingEndpointBackendAddress         = "resolving_endpoint_backend_address"
	stepClosingEndpointGate                     = "closing_endpoint_gate"
	stepWaitingEndpointGateSettle               = "waiting_for_endpoint_gate_settle"
	stepClosingEndpointBackendSockets           = "closing_endpoint_backend_sockets"
	stepWaitingEndpointBackendSocketQuietWindow = "waiting_for_endpoint_backend_socket_quiet_window"
	stepOpeningEndpointGate                     = "opening_endpoint_gate"
)

// kubeadmUpgradeApplyGateOwner is what KubeadmUpgradeApply writes into the gate
// file. The RPC parks no manifest, so it has no park directory to name. The name
// only says who opens the gate: the agent, as for defaultEtcdDefragParkDir.
const kubeadmUpgradeApplyGateOwner = "kubeadm-upgrade-apply"

// ControlPlaneEndpointGate configures the health gate that takes this node out
// of a control-plane load balancer the node does not run. The gate is a file,
// and the load balancer's health check has to fail for this node while the file
// exists. The agent cannot see the load balancer, so the quiet window after the
// gate closes is its only proof that the health check reads the gate.
type ControlPlaneEndpointGate struct {
	// File is the path of the gate file. Empty means no gate.
	File string
	// BackendInterface is the interface the load balancer's connections arrive
	// on. Its address is read at each withdrawal, because the agent starts
	// before the node's addresses are final.
	BackendInterface string
	// Settle is how long the load balancer gets to stop sending new connections
	// after the gate closes, before the established ones are closed.
	Settle time.Duration
}

// withdrawThroughControlPlaneEndpointGate takes this node out of the load
// balancer that reads the gate. Callers must already hold staticPodMutationMu.
//
// It mirrors withdrawKubeVip where it can. Closing the gate stands in for
// parking kube-vip. Nothing stands in for removing the address from lo, because
// the backend address is the node's own and has to stay.
//
// A failure after the gate closed leaves it closed, as a failed kube-vip
// withdrawal leaves the manifest parked. The restore that follows opens it.
func (s *NodeAgentServer) withdrawThroughControlPlaneEndpointGate(
	ctx context.Context,
	runner nvkeutils.CommandRunner,
	progress nodeAgentOperationProgress,
	parkDir string,
) error {
	gate := s.ControlPlaneEndpointGate
	// Before the gate closes, so an interface that does not resolve fails the
	// withdrawal with the node untouched.
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

	// The load balancer acts on the gate only at its next health checks. Closing
	// the sockets before that would send the clients straight back here.
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

	// A health check that does not read the gate, or a settle time shorter than
	// the health check needs, shows up here as new sockets. The wrapped error is
	// the kube-vip check's own, so it calls the backend address a VIP.
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
// The file names the park directory of the flow that closed it, and that
// decides who opens the gate as it decides who restores a parked manifest: see
// defaultEtcdDefragParkDir. So a defragmentation leaves a gate that a caller
// closed. Taking it over would open it underneath that caller when the
// defragmentation finishes. A caller does take over a gate the defragmentation
// left closed, because the caller's hold is the stronger one.
//
// KubeadmUpgradeApply parks nothing and passes kubeadmUpgradeApplyGateOwner. It
// is held to the rule of the defragmentation: see
// agentOpensControlPlaneEndpointGate.
//
// The file is staged and renamed into place. The health check only asks whether
// the file exists, so a write that failed halfway would leave a closed gate
// with no owner, which nothing but a caller would open.
func (s *NodeAgentServer) closeControlPlaneEndpointGate(parkDir string) (bool, error) {
	path := s.rootedPath(s.ControlPlaneEndpointGate.File)
	if agentOpensControlPlaneEndpointGate(parkDir) {
		owner, closed, err := readControlPlaneEndpointGate(path)
		if err != nil {
			return false, err
		}
		if closed && !agentOpensControlPlaneEndpointGate(owner) {
			slog.Info("control plane endpoint gate is already closed and a caller owns it; leaving it as it is",
				"gateFile", path, "owner", owner)
			return false, nil
		}
	}

	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return false, err
	}
	staged := path + ".tmp"
	if err := s.FileWriter.WriteFile(staged, []byte(parkDir+"\n"), 0o644); err != nil {
		return false, fmt.Errorf("write %s: %w", staged, err)
	}
	if err := os.Rename(staged, path); err != nil {
		return false, err
	}
	slog.Info("closed the control plane endpoint gate", "gateFile", path, "owner", parkDir)
	return true, nil
}

// openControlPlaneEndpointGate removes the gate file. Callers must already hold
// staticPodMutationMu. It does not wait for the load balancer, which takes the
// node back once its health check also finds the local apiserver ready.
//
// With an owner that agentOpensControlPlaneEndpointGate accepts, it opens only a
// gate that such a flow closed. A caller's restore opens the gate whoever closed
// it. No gate configured and a gate that is already open are both success.
func (s *NodeAgentServer) openControlPlaneEndpointGate(progress nodeAgentOperationProgress, parkDir string) error {
	if s.ControlPlaneEndpointGate.File == "" {
		return nil
	}
	path := s.rootedPath(s.ControlPlaneEndpointGate.File)
	owner, closed, err := readControlPlaneEndpointGate(path)
	if err != nil {
		return fmt.Errorf("open control plane endpoint gate: %w", err)
	}
	if !closed {
		return nil
	}
	if agentOpensControlPlaneEndpointGate(parkDir) && !agentOpensControlPlaneEndpointGate(owner) {
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

// handOffControlPlaneEndpointGateToCaller is the gate's half of
// handOffParkedManifestsToCaller. It names the shared park directory as the
// owner of a gate the defragmentation closed, so the startup reconciler leaves
// the gate closed.
func (s *NodeAgentServer) handOffControlPlaneEndpointGateToCaller() error {
	if s.ControlPlaneEndpointGate.File == "" {
		return nil
	}
	path := s.rootedPath(s.ControlPlaneEndpointGate.File)
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

// agentOpensControlPlaneEndpointGate reports whether owner names a flow that
// closes the gate and opens it again in one call: the etcd defragmentation and
// KubeadmUpgradeApply. The agent owes the open of such a gate, at the end of the
// flow or at its next start. Any other owner is a caller.
//
// Each of these flows holds staticPodMutationMu from the close to the open. So
// a gate of this kind that one of them finds closed is what an interrupted flow
// left behind, and it takes that gate over.
func agentOpensControlPlaneEndpointGate(owner string) bool {
	return owner == defaultEtcdDefragParkDir || owner == kubeadmUpgradeApplyGateOwner
}

// etcdHasAnotherVotingMember reports whether etcd has a voting member besides
// the local one. With the stacked etcd of kubeadm that is another control plane
// node, and so another node behind the load balancer. The agent cannot see the
// load balancer, and this is the nearest thing to it that it can read.
func (s *NodeAgentServer) etcdHasAnotherVotingMember(ctx context.Context) (bool, error) {
	client, err := s.newEtcdMemberClient()
	if err != nil {
		return false, fmt.Errorf("connect to local kubeadm etcd: %w", err)
	}
	defer client.Close()

	listCtx, cancel := s.etcdCallContext(ctx)
	defer cancel()
	members, err := client.MemberList(listCtx)
	if err != nil {
		return false, fmt.Errorf("list etcd members: %w", err)
	}
	return votingMemberCount(members) > 1, nil
}

// readControlPlaneEndpointGate reports whether the gate is closed and, if so,
// which owner it names: a park directory, or kubeadmUpgradeApplyGateOwner. A
// gate file the agent did not write names none, and counts as a caller's.
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

// resolveEndpointBackendAddress returns the one global IPv4 address of the
// backend interface. IPv4 only, as the kube-vip withdrawal is: the ss calls
// that both use are written for IPv4 addresses. More than one address is an
// error for the reason more than one VIP on lo is: nothing says which of them
// the load balancer uses.
func resolveEndpointBackendAddress(runner nvkeutils.CommandRunner, iface string) (string, error) {
	output, err := runner.Run("ip", []string{"-o", "-4", "addr", "show", "dev", iface, "scope", "global"}, nil) //nolint:goconst // ip(8) argv fragment; naming each CLI flag reads worse than the literal
	if err != nil {
		return "", fmt.Errorf("ip addr show dev %s: %w: %s", iface, err, strings.TrimSpace(string(output)))
	}
	var addresses []string
	for _, line := range strings.Split(string(output), "\n") {
		fields := strings.Fields(line)
		for i := 0; i+1 < len(fields); i++ {
			if fields[i] != "inet" {
				continue
			}
			// A point-to-point address is printed with no prefix length.
			addr, err := netip.ParseAddr(fields[i+1])
			if prefix, prefixErr := netip.ParsePrefix(fields[i+1]); prefixErr == nil {
				addr, err = prefix.Addr(), nil
			}
			if err != nil {
				return "", fmt.Errorf("parse interface address %q: %w", fields[i+1], err)
			}
			if addr.Is4() {
				addresses = append(addresses, addr.String())
			}
			break
		}
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
