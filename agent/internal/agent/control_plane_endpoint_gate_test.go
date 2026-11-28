// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package agent

import (
	"cmp"
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	nvkeutils "github.com/dsx-ai-factory/nvke/agent/pkg/utils"
)

// The addresses are from the documentation ranges, so no listing can match an
// address of the machine that runs the test: the production code skips a peer
// that is local.
const (
	testGateFile       = "/var/lib/nvke/control-plane-endpoint.gate"
	testBackendAddress = "198.51.100.10"
	testBackendOutput  = "2: eth0    inet " + testBackendAddress + "/24 brd 198.51.100.255 scope global eth0\\       valid_lft forever preferred_lft forever\n"
	testBackendPeer    = "0 0 " + testBackendAddress + ":6443 203.0.113.7:41000\n"
	testVipPeer        = "0 0 " + testKubeVipAddress + ":6443 203.0.113.9:42000\n"

	// The owner of a closed gate, as gateState reports it. The first two are also
	// the park directories.
	callerGate = defaultStaticPodBackupDir
	defragGate = defaultEtcdDefragParkDir
	byHandGate = "no owner" // a gate file that the agent did not write

	// The event of a closed socket. The owner of the gate at that moment follows.
	closedBackendPeer = "close " + testBackendAddress + ":6443 -> 203.0.113.7:41000 gate="
	closedVipPeer     = "close " + testKubeVipAddress + ":6443 -> 203.0.113.9:42000 gate="
)

var (
	gateWithdrawalSteps = []string{
		stepResolvingEndpointBackendAddress,
		stepClosingEndpointGate,
		stepWaitingEndpointGateSettle,
		stepClosingEndpointBackendSockets,
		stepWaitingEndpointBackendSocketQuietWindow,
	}
	kubeVipWithdrawalSteps = []string{
		stepResolvingKubeVip,
		stepStoppingKubeVip,
		stepWaitingKubeVipExit,
		stepClosingVipSockets,
		stepRemovingLoopbackVip,
		stepWaitingVipSocketQuietWindow,
	}
)

// endpointGateNode adds to controlPlaneNodeFake what a node behind a load
// balancer has: a backend interface, and sockets that are told apart by the
// local address they arrived on. It records the owner of the gate when a socket
// is closed and when etcd stops, because the property under test is an order.
type endpointGateNode struct {
	*controlPlaneNodeFake
	gatePath string

	backendOutput  string // what `ip` answers for the backend interface
	backendQueries int
	// peers is what `ss` lists for a local address, one answer for each listing.
	// The last answer repeats.
	peers    map[string][]string
	listings map[string]int
	closeErr error // fails `ss -K`
	events   []string
}

// gateState is the owner of the closed gate, or nothing when the gate is open.
func (n *endpointGateNode) gateState() string {
	data, err := os.ReadFile(n.gatePath)
	if err != nil {
		return ""
	}
	return cmp.Or(strings.TrimSpace(string(data)), byHandGate)
}

func (n *endpointGateNode) Run(name string, args []string, opts *nvkeutils.CommandOptions) ([]byte, error) {
	switch {
	case name == "ip" && slices.Equal(args, []string{"-o", "-4", "addr", "show", "dev", "eth0", "scope", "global"}):
		n.backendQueries++
		return []byte(n.backendOutput), nil
	case name == "ss" && len(args) == 8 && args[0] == "-Htan":
		// ss -Htan state established src <local> sport = :6443
		answers, call := n.peers[args[4]], n.listings[args[4]]
		n.listings[args[4]]++
		if len(answers) == 0 {
			return nil, nil
		}
		return []byte(answers[min(call, len(answers)-1)]), nil
	case name == "ss" && len(args) == 13 && args[0] == "-Ktan":
		// ss -Ktan state established src <local> sport = :6443 dst <peer> dport = :<port>
		n.events = append(n.events, fmt.Sprintf("close %s%s -> %s%s gate=%s", args[4], args[7], args[9], args[12], n.gateState()))
		return nil, n.closeErr
	case name == "crictl" && len(args) > 0 && args[0] == "stop":
		n.events = append(n.events, "stop-etcd gate="+n.gateState())
	}
	return n.controlPlaneNodeFake.Run(name, args, opts)
}

// gateSetup changes the node that a case starts from.
type gateSetup func(*testing.T, *NodeAgentServer, *endpointGateNode)

// endpointGateTestServer builds a control-plane node with or without kube-vip
// and with or without a gate. The defragmentation of its etcd member succeeds
// and reclaims space unless a setup changes the etcd client.
func endpointGateTestServer(t *testing.T, kubeVip, gate bool, setup ...gateSetup) (*NodeAgentServer, *endpointGateNode) {
	t.Helper()
	const mib = int64(1024 * 1024)
	s, fake := etcdRestartTestServer(t, &fakeEtcdMemberClient{
		members:  testEtcdMembersThree(),
		localID:  2,
		leaderID: 1,
		statusFn: etcdSizingStatus(500*mib, 100*mib, 120*mib, 3),
	})
	if !kubeVip {
		require.NoError(t, os.Remove(filepath.Join(s.RootPath, defaultStaticPodManifestDir, defaultKubeVipManifestName)))
		fake.pods[kubeVipContainerName].runningID = ""
		fake.loopbackVIPs = nil
	}
	if gate {
		s.ControlPlaneEndpointGate = ControlPlaneEndpointGate{File: testGateFile, BackendInterface: "eth0", Settle: time.Millisecond}
	}
	node := &endpointGateNode{
		controlPlaneNodeFake: fake,
		gatePath:             filepath.Join(s.RootPath, testGateFile),
		backendOutput:        testBackendOutput,
		peers:                map[string][]string{},
		listings:             map[string]int{},
	}
	s.Runner = node
	s.FileWriter = &nvkeutils.OSFileWriter{}
	for _, apply := range setup {
		apply(t, s, node)
	}
	return s, node
}

// peersOn sets what `ss` lists for a local address, one answer for each listing.
func peersOn(address string, listings ...string) gateSetup {
	return func(_ *testing.T, _ *NodeAgentServer, n *endpointGateNode) { n.peers[address] = listings }
}

// gateClosedBy leaves the gate the way an earlier flow would have.
func gateClosedBy(owner string) gateSetup {
	return func(t *testing.T, _ *NodeAgentServer, n *endpointGateNode) {
		t.Helper()
		content := owner + "\n"
		if owner == byHandGate {
			content = ""
		}
		require.NoError(t, os.MkdirAll(filepath.Dir(n.gatePath), 0o755))
		require.NoError(t, os.WriteFile(n.gatePath, []byte(content), 0o644))
	}
}

// parkedIn leaves manifests the way the flow that owns parkDir leaves them. A
// parked kube-vip has no container and no address on lo.
func parkedIn(parkDir string, manifestNames ...string) gateSetup {
	return func(t *testing.T, s *NodeAgentServer, n *endpointGateNode) {
		t.Helper()
		for _, manifestName := range manifestNames {
			parkManifestIn(t, s, parkDir, manifestName)
		}
		if slices.Contains(manifestNames, defaultKubeVipManifestName) {
			n.pods[kubeVipContainerName].runningID = ""
			n.loopbackVIPs = nil
		}
	}
}

// gateWriteFails makes each write fail the way a full disk does: the file is
// there and empty. A gate file in that state is closed and names no owner.
func gateWriteFails(_ *testing.T, s *NodeAgentServer, _ *endpointGateNode) {
	s.FileWriter = fullDiskWriter{}
}

type fullDiskWriter struct{}

func (fullDiskWriter) WriteFile(filename string, _ []byte, perm os.FileMode) error {
	return errors.Join(os.WriteFile(filename, nil, perm), errors.New("disk full"))
}

// gateCase is a node, and what a flow must leave of it.
type gateCase struct {
	name    string
	kubeVip bool
	noGate  bool // the agent runs with no gate flag
	setup   []gateSetup
	timeout time.Duration // bounds the call, for the case that cancels it

	wantErr    []string
	wantSteps  []string
	wantEvents []string
	wantGate   string   // the owner of the closed gate, or nothing when the gate must be open
	wantParked []string // the manifests left in the shared park directory, for a caller to restore
}

// runGateCases runs flow on the node of each case and checks what it left. A
// manifest of the node that is not parked for a caller must be active.
func runGateCases(t *testing.T, tests []gateCase, flow func(context.Context, *NodeAgentServer, nodeAgentOperationProgress) error) {
	t.Helper()
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			s, node := endpointGateTestServer(t, tc.kubeVip, !tc.noGate, tc.setup...)
			ctx, cancel := context.WithTimeout(context.Background(), cmp.Or(tc.timeout, time.Minute))
			defer cancel()
			progress := &fakeOperationProgress{}

			err := flow(ctx, s, progress)

			if len(tc.wantErr) == 0 {
				require.NoError(t, err)
			}
			for _, want := range tc.wantErr {
				require.ErrorContains(t, err, want)
			}
			assert.Equal(t, tc.wantSteps, progress.steps)
			assert.Equal(t, tc.wantEvents, node.events)
			assert.Equal(t, tc.wantGate, node.gateState())
			for manifestName, onNode := range map[string]bool{defaultKubeAPIServerManifestName: true, defaultKubeVipManifestName: tc.kubeVip} {
				parked := slices.Contains(tc.wantParked, manifestName)
				assert.Equal(t, parked, manifestIsParkedIn(t, s, defaultStaticPodBackupDir, manifestName), manifestName)
				assert.Equal(t, onNode && !parked, staticPodManifestIsActive(t, s, manifestName), manifestName)
			}
			if tc.noGate {
				assert.Zero(t, node.backendQueries, "with no gate flag the backend interface is never read")
			}
		})
	}
}

// The withdrawal behind StartK8SControlPlaneNodeGracefulShutdown, for each
// combination of kube-vip and the gate. The caller owns the restore here, so a
// gate that closes names the shared park directory.
func TestGracefulShutdownWithdrawsThroughTheControlPlaneEndpointGate(t *testing.T) {
	// Nothing to close, and then a new socket in the quiet window.
	loadBalancerStillSends := peersOn(testBackendAddress, "", testBackendPeer)

	runGateCases(t, []gateCase{
		{
			name: "gate only: the gate closes, the settle time passes, the backend sockets close and the quiet window passes",
			setup: []gateSetup{peersOn(testBackendAddress,
				testBackendPeer+"0 0 [::ffff:"+testBackendAddress+"]:6443 [::ffff:203.0.113.8]:41001\n", "")},
			wantSteps: append(slices.Clone(gateWithdrawalSteps), stepResolvingKubeVip),
			wantEvents: []string{
				closedBackendPeer + callerGate,
				"close " + testBackendAddress + ":6443 -> 203.0.113.8:41001 gate=" + callerGate,
			},
			wantGate: callerGate,
		},
		{
			name:       "kube-vip only: with no gate flag the withdrawal is the kube-vip withdrawal and nothing else",
			kubeVip:    true,
			noGate:     true,
			setup:      []gateSetup{peersOn(testKubeVipAddress, testVipPeer, "")},
			wantSteps:  kubeVipWithdrawalSteps,
			wantEvents: []string{closedVipPeer},
			wantParked: []string{defaultKubeVipManifestName},
		},
		{name: "neither: with no gate flag and no kube-vip the withdrawal does nothing", noGate: true, wantSteps: []string{stepResolvingKubeVip}},
		{
			name:       "both: the node leaves the load balancer first and the VIP second",
			kubeVip:    true,
			setup:      []gateSetup{peersOn(testBackendAddress, testBackendPeer, ""), peersOn(testKubeVipAddress, testVipPeer, "")},
			wantSteps:  slices.Concat(gateWithdrawalSteps, kubeVipWithdrawalSteps),
			wantEvents: []string{closedBackendPeer + callerGate, closedVipPeer + callerGate},
			wantGate:   callerGate,
			wantParked: []string{defaultKubeVipManifestName},
		},
		{
			name:  "gate only: a load balancer that still sends connections fails the withdrawal and leaves the gate closed",
			setup: []gateSetup{loadBalancerStillSends},
			wantErr: []string{
				"control plane endpoint backend socket quiet window failed on " + testBackendAddress,
				testBackendAddress + ":6443 -> 203.0.113.7:41000",
			},
			wantSteps: gateWithdrawalSteps,
			wantGate:  callerGate,
		},
		{
			name:      "both: a failed quiet window on the backend address stops before kube-vip is touched",
			kubeVip:   true,
			setup:     []gateSetup{loadBalancerStillSends},
			wantErr:   []string{"control plane endpoint backend socket quiet window failed"},
			wantSteps: gateWithdrawalSteps,
			wantGate:  callerGate,
		},
		{
			name:      "gate only: a failed gate write fails the withdrawal with the gate open and no socket closed",
			setup:     []gateSetup{gateWriteFails, peersOn(testBackendAddress, testBackendPeer)},
			wantErr:   []string{"close control plane endpoint gate", "disk full"},
			wantSteps: gateWithdrawalSteps[:2],
		},
		{
			name:      "gate only: a backend interface with no IPv4 address, such as one with IPv6 only, fails before the gate closes",
			setup:     []gateSetup{func(_ *testing.T, _ *NodeAgentServer, n *endpointGateNode) { n.backendOutput = "" }},
			wantErr:   []string{"resolve control plane endpoint backend address", "no global IPv4 address on eth0"},
			wantSteps: gateWithdrawalSteps[:1],
		},
		{
			name: "gate only: a socket that cannot be closed fails the withdrawal and leaves the gate closed",
			setup: []gateSetup{peersOn(testBackendAddress, testBackendPeer), func(_ *testing.T, _ *NodeAgentServer, n *endpointGateNode) {
				n.closeErr = errors.New("ss failed")
			}},
			wantErr:    []string{"close remote sockets on control plane endpoint backend address " + testBackendAddress, "ss failed"},
			wantSteps:  gateWithdrawalSteps[:4],
			wantEvents: []string{closedBackendPeer + callerGate},
			wantGate:   callerGate,
		},
		{
			name: "gate only: a call that is canceled in the settle time fails the withdrawal and leaves the gate closed",
			setup: []gateSetup{func(_ *testing.T, s *NodeAgentServer, _ *endpointGateNode) {
				s.ControlPlaneEndpointGate.Settle = time.Hour
			}},
			timeout:   20 * time.Millisecond,
			wantErr:   []string{"wait for control plane endpoint gate settle", "context deadline exceeded"},
			wantSteps: gateWithdrawalSteps[:3],
			wantGate:  callerGate,
		},
	}, func(ctx context.Context, s *NodeAgentServer, progress nodeAgentOperationProgress) error {
		return s.runK8sControlPlaneNodeGracefulShutdown(ctx, progress, false)
	})
}

// The restore behind StartKubeVipRestore. A caller that asks for the node back
// gets the gate opened whoever closed it.
func TestKubeVipRestoreOpensTheControlPlaneEndpointGate(t *testing.T) {
	noKubeVip := []string{stepWaitingKubeAPIServerReady, stepResolvingKubeVip}
	kubeVipBack := append(slices.Clone(noKubeVip), stepRestoringKubeVip, stepWaitingKubeVipStart, stepWaitingLoopbackVip)
	andOpened := func(steps []string) []string { return append(slices.Clone(steps), stepOpeningEndpointGate) }
	kubeVipWithdrawn := parkedIn(callerGate, defaultKubeVipManifestName)

	runGateCases(t, []gateCase{
		{
			name:      "gate only: restore opens a gate that a graceful shutdown closed",
			setup:     []gateSetup{gateClosedBy(callerGate)},
			wantSteps: andOpened(noKubeVip),
		},
		{name: "gate only: restore with no gate file succeeds and opens nothing", wantSteps: noKubeVip},
		{
			name:      "both: restore puts kube-vip back and then opens the gate",
			kubeVip:   true,
			setup:     []gateSetup{kubeVipWithdrawn, gateClosedBy(callerGate)},
			wantSteps: andOpened(kubeVipBack),
		},
		{
			name:    "both: restore opens the gate even when kube-vip does not come back",
			kubeVip: true,
			setup: []gateSetup{kubeVipWithdrawn, gateClosedBy(callerGate), func(_ *testing.T, _ *NodeAgentServer, n *endpointGateNode) {
				n.pods[kubeVipContainerName].startDelay = 1_000_000
			}},
			wantErr:   []string{"wait for kube-vip start"},
			wantSteps: andOpened(kubeVipBack[:4]),
		},
		{
			name:      "gate only: restore opens a gate that the etcd defragmentation left closed",
			setup:     []gateSetup{gateClosedBy(defragGate)},
			wantSteps: andOpened(noKubeVip),
		},
		{
			name:      "gate only: restore opens a gate that an operator closed by hand",
			setup:     []gateSetup{gateClosedBy(byHandGate)},
			wantSteps: andOpened(noKubeVip),
		},
		{
			// A directory is not a gate file, and gateState reads it as an open gate.
			name: "gate only: restore reports a gate file that cannot be read",
			setup: []gateSetup{func(t *testing.T, _ *NodeAgentServer, n *endpointGateNode) {
				require.NoError(t, os.MkdirAll(n.gatePath, 0o755))
			}},
			wantErr:   []string{"open control plane endpoint gate"},
			wantSteps: noKubeVip,
		},
		{
			name:      "kube-vip only: with no gate flag restore leaves a file at the gate path alone",
			kubeVip:   true,
			noGate:    true,
			setup:     []gateSetup{kubeVipWithdrawn, gateClosedBy(callerGate)},
			wantSteps: kubeVipBack,
			wantGate:  callerGate,
		},
	}, func(ctx context.Context, s *NodeAgentServer, progress nodeAgentOperationProgress) error {
		return s.runKubeVipRestore(ctx, progress)
	})
}

// Who may take a closed gate over. The caller's hold is the stronger one: it
// keeps the node out of service until a caller asks for it back.
func TestCloseControlPlaneEndpointGateOwnership(t *testing.T) {
	tests := []struct {
		name       string
		existing   string // the owner of a gate that is closed already
		parkDir    string
		wantClosed bool
		wantGate   string
	}{
		{name: "a caller closes an open gate", parkDir: callerGate, wantClosed: true, wantGate: callerGate},
		{name: "a caller closes its own gate again", existing: callerGate, parkDir: callerGate, wantClosed: true, wantGate: callerGate},
		{name: "a caller takes over a gate that the defragmentation left closed", existing: defragGate, parkDir: callerGate, wantClosed: true, wantGate: callerGate},
		{name: "the defragmentation closes an open gate", parkDir: defragGate, wantClosed: true, wantGate: defragGate},
		{name: "the defragmentation closes its own gate again", existing: defragGate, parkDir: defragGate, wantClosed: true, wantGate: defragGate},
		{name: "the defragmentation leaves a gate that a caller closed", existing: callerGate, parkDir: defragGate, wantGate: callerGate},
		{name: "the defragmentation leaves a gate that an operator closed by hand", existing: byHandGate, parkDir: defragGate, wantGate: byHandGate},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			s, node := endpointGateTestServer(t, false, true)
			if tc.existing != "" {
				gateClosedBy(tc.existing)(t, s, node)
			}

			closed, err := s.closeControlPlaneEndpointGate(tc.parkDir)

			require.NoError(t, err)
			assert.Equal(t, tc.wantClosed, closed)
			assert.Equal(t, tc.wantGate, node.gateState())
			assert.NoFileExists(t, node.gatePath+".tmp", "the staged file must not stay behind")
			if tc.wantClosed {
				assertPathMode(t, node.gatePath, 0o644)
			}
		})
	}
}

func TestResolveEndpointBackendAddress(t *testing.T) {
	tests := []struct {
		name      string
		output    string
		runErr    error
		want      string
		wantError string
	}{
		{name: "one address with a prefix length", output: testBackendOutput, want: testBackendAddress},
		{
			name:   "one address of a point-to-point interface, printed with no prefix length",
			output: "3: eth0    inet 198.51.100.10 peer 198.51.100.1/32 scope global eth0\n",
			want:   testBackendAddress,
		},
		{name: "no address", output: "\n", wantError: "no global IPv4 address on eth0"},
		{
			name:      "two addresses",
			output:    testBackendOutput + "2: eth0    inet 198.51.100.11/24 scope global secondary eth0\n",
			wantError: "multiple global IPv4 addresses on eth0: 198.51.100.10, 198.51.100.11",
		},
		{
			name:      "an IPv6 address is not a backend address",
			output:    "2: eth0    inet6 2001:db8::10/64 scope global \n",
			wantError: "no global IPv4 address on eth0",
		},
		{
			name:      "a command that fails",
			output:    `Device "eth0" does not exist.`,
			runErr:    errors.New("exit status 1"),
			wantError: `ip addr show dev eth0: exit status 1: Device "eth0" does not exist.`,
		},
		{
			name:      "an address that does not parse",
			output:    "2: eth0    inet not-an-address scope global eth0\n",
			wantError: `parse interface address "not-an-address"`,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := resolveEndpointBackendAddress(&MockRunner{Output: []byte(tc.output), Err: tc.runErr}, "eth0")

			if tc.wantError != "" {
				require.ErrorContains(t, err, tc.wantError)
				return
			}
			require.NoError(t, err)
			assert.Equal(t, tc.want, got)
		})
	}
}
