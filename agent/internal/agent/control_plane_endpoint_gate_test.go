// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package agent

import (
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
	clientv3 "go.etcd.io/etcd/client/v3"

	pb "github.com/dsx-ai-factory/nvke/agent/pkg/agent/proto"
	nvkeutils "github.com/dsx-ai-factory/nvke/agent/pkg/utils"
)

// The gate file and the interface are the ones the pod node image uses. The
// addresses are from the documentation ranges, so no listing can match an
// address of the machine that runs the test: a peer that is local is not a
// remote client, and the production code skips it.
const (
	testEndpointGateFile         = "/var/lib/nvke/control-plane-endpoint.gate"
	testEndpointBackendInterface = "eth0"
	testEndpointBackendAddress   = "198.51.100.10"

	testEndpointGateOpen = "open"

	testBackendInterfaceOutput = "2: eth0    inet " + testEndpointBackendAddress +
		"/24 brd 198.51.100.255 scope global eth0\\       valid_lft forever preferred_lft forever\n"
	testBackendPeer = "0 0 " + testEndpointBackendAddress + ":6443 203.0.113.7:41000\n"
	testVipPeer     = "0 0 " + testKubeVipAddress + ":6443 203.0.113.9:42000\n"
)

// endpointGateNode adds to controlPlaneNodeFake what a node behind a load
// balancer has and that fake does not model: a backend interface, and sockets
// that are told apart by the local address they arrived on.
//
// It records the state of the gate at each moment that matters, because the
// property under test is an order: the gate is closed before a socket is
// closed, and it is still closed while etcd is down.
type endpointGateNode struct {
	*controlPlaneNodeFake
	gatePath string

	// backendOutput and backendErr are what `ip` answers for the backend
	// interface.
	backendOutput  string
	backendErr     error
	backendQueries int

	// peers is what `ss` lists for a local address, one answer for each
	// listing. The last answer repeats.
	peers    map[string][]string
	listings map[string]int
	// closeErr fails `ss -K`.
	closeErr error

	events []string
}

// gateState is "open", or the owner that the gate file names.
func (n *endpointGateNode) gateState() string {
	data, err := os.ReadFile(n.gatePath)
	if err != nil {
		return testEndpointGateOpen
	}
	return strings.TrimSpace(string(data))
}

func (n *endpointGateNode) Run(name string, args []string, opts *nvkeutils.CommandOptions) ([]byte, error) {
	switch {
	case name == "ip" && slices.Equal(args, []string{"-o", "-4", "addr", "show", "dev", testEndpointBackendInterface, "scope", "global"}):
		n.backendQueries++
		return []byte(n.backendOutput), n.backendErr
	case name == "ss" && len(args) == 8 && args[0] == "-Htan":
		// ss -Htan state established src <local> sport = :6443
		local := args[4]
		answers := n.peers[local]
		call := n.listings[local]
		n.listings[local]++
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

func (n *endpointGateNode) RunSplitOutput(name string, args []string, opts *nvkeutils.CommandOptions) (nvkeutils.CommandOutput, error) {
	out, err := n.Run(name, args, opts)
	return nvkeutils.CommandOutput{Stdout: out}, err
}

// endpointGateTestServer builds a control-plane node with or without kube-vip,
// and with or without a gate. The defragmentation of the member it carries
// succeeds and reclaims space unless a test replaces the etcd client.
func endpointGateTestServer(t *testing.T, kubeVip, gate bool) (*NodeAgentServer, *endpointGateNode) {
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
		s.ControlPlaneEndpointGate = ControlPlaneEndpointGate{
			File:             testEndpointGateFile,
			BackendInterface: testEndpointBackendInterface,
			Settle:           time.Millisecond,
		}
	}
	node := &endpointGateNode{
		controlPlaneNodeFake: fake,
		gatePath:             filepath.Join(s.RootPath, testEndpointGateFile),
		backendOutput:        testBackendInterfaceOutput,
		peers:                map[string][]string{},
		listings:             map[string]int{},
	}
	s.Runner = node
	return s, node
}

// writeEndpointGate closes the gate the way an earlier flow would have left it.
func writeEndpointGate(t *testing.T, node *endpointGateNode, owner string) {
	t.Helper()
	require.NoError(t, os.MkdirAll(filepath.Dir(node.gatePath), 0o755))
	content := ""
	if owner != "" {
		content = owner + "\n"
	}
	require.NoError(t, os.WriteFile(node.gatePath, []byte(content), 0o644))
}

// withdrawKubeVipByHand leaves kube-vip the way a graceful shutdown leaves it:
// the manifest parked for the caller, no container, no address on lo.
func withdrawKubeVipByHand(t *testing.T, s *NodeAgentServer, node *endpointGateNode) {
	t.Helper()
	parkManifestIn(t, s, defaultStaticPodBackupDir, defaultKubeVipManifestName)
	node.pods[kubeVipContainerName].runningID = ""
	node.loopbackVIPs = nil
}

var endpointGateWithdrawalSteps = []string{
	stepResolvingEndpointBackendAddress,
	stepClosingEndpointGate,
	stepWaitingEndpointGateSettle,
	stepClosingEndpointBackendSockets,
	stepWaitingEndpointBackendSocketQuietWindow,
}

var kubeVipWithdrawalSteps = []string{
	stepResolvingKubeVip,
	stepStoppingKubeVip,
	stepWaitingKubeVipExit,
	stepClosingVipSockets,
	stepRemovingLoopbackVip,
	stepWaitingVipSocketQuietWindow,
}

// The withdrawal behind StartK8SControlPlaneNodeGracefulShutdown, for each
// combination of kube-vip and the gate. The caller owns the restore here, so a
// gate that closes names the shared park directory.
func TestGracefulShutdownWithdrawsThroughTheControlPlaneEndpointGate(t *testing.T) {
	const callerGate = defaultStaticPodBackupDir

	tests := []struct {
		name    string
		kubeVip bool
		gate    bool
		arrange func(*NodeAgentServer, *endpointGateNode)
		// timeout bounds the call, for the case that cancels it.
		timeout time.Duration

		wantErrorContains []string
		wantSteps         []string
		wantEvents        []string
		wantGate          string
		wantKubeVipParked bool
	}{
		{
			name: "gate only: the gate closes, the settle time passes, the backend sockets close and the quiet window passes",
			gate: true,
			arrange: func(_ *NodeAgentServer, node *endpointGateNode) {
				node.peers[testEndpointBackendAddress] = []string{
					testBackendPeer + "0 0 [::ffff:" + testEndpointBackendAddress + "]:6443 [::ffff:203.0.113.8]:41001\n",
					"",
				}
			},
			wantSteps: append(slices.Clone(endpointGateWithdrawalSteps), stepResolvingKubeVip),
			wantEvents: []string{
				"close " + testEndpointBackendAddress + ":6443 -> 203.0.113.7:41000 gate=" + callerGate,
				"close " + testEndpointBackendAddress + ":6443 -> 203.0.113.8:41001 gate=" + callerGate,
			},
			wantGate: callerGate,
		},
		{
			name:    "kube-vip only: with no gate flag the withdrawal is the kube-vip withdrawal and nothing else",
			kubeVip: true,
			arrange: func(_ *NodeAgentServer, node *endpointGateNode) {
				node.peers[testKubeVipAddress] = []string{testVipPeer, ""}
			},
			wantSteps:         kubeVipWithdrawalSteps,
			wantEvents:        []string{"close " + testKubeVipAddress + ":6443 -> 203.0.113.9:42000 gate=" + testEndpointGateOpen},
			wantGate:          testEndpointGateOpen,
			wantKubeVipParked: true,
		},
		{
			name:      "neither: with no gate flag and no kube-vip the withdrawal does nothing",
			wantSteps: []string{stepResolvingKubeVip},
			wantGate:  testEndpointGateOpen,
		},
		{
			name:    "both: the node leaves the load balancer first and the VIP second",
			kubeVip: true,
			gate:    true,
			arrange: func(_ *NodeAgentServer, node *endpointGateNode) {
				node.peers[testEndpointBackendAddress] = []string{testBackendPeer, ""}
				node.peers[testKubeVipAddress] = []string{testVipPeer, ""}
			},
			wantSteps: append(slices.Clone(endpointGateWithdrawalSteps), kubeVipWithdrawalSteps...),
			wantEvents: []string{
				"close " + testEndpointBackendAddress + ":6443 -> 203.0.113.7:41000 gate=" + callerGate,
				"close " + testKubeVipAddress + ":6443 -> 203.0.113.9:42000 gate=" + callerGate,
			},
			wantGate:          callerGate,
			wantKubeVipParked: true,
		},
		{
			name: "gate only: a load balancer that still sends connections fails the withdrawal and leaves the gate closed",
			gate: true,
			arrange: func(_ *NodeAgentServer, node *endpointGateNode) {
				// Nothing to close, and then a new socket in the quiet window.
				node.peers[testEndpointBackendAddress] = []string{"", testBackendPeer}
			},
			wantErrorContains: []string{
				"control plane endpoint backend socket quiet window failed on " + testEndpointBackendAddress,
				testEndpointBackendAddress + ":6443 -> 203.0.113.7:41000",
			},
			wantSteps: endpointGateWithdrawalSteps,
			wantGate:  callerGate,
		},
		{
			name:    "both: a failed quiet window on the backend address stops before kube-vip is touched",
			kubeVip: true,
			gate:    true,
			arrange: func(_ *NodeAgentServer, node *endpointGateNode) {
				node.peers[testEndpointBackendAddress] = []string{"", testBackendPeer}
			},
			wantErrorContains: []string{"control plane endpoint backend socket quiet window failed"},
			wantSteps:         endpointGateWithdrawalSteps,
			wantGate:          callerGate,
		},
		{
			name: "gate only: a failed gate write fails the withdrawal with the gate open and no socket closed",
			gate: true,
			arrange: func(s *NodeAgentServer, node *endpointGateNode) {
				s.FileWriter = &MockFileWriter{Err: errors.New("disk full")}
				node.peers[testEndpointBackendAddress] = []string{testBackendPeer}
			},
			wantErrorContains: []string{"close control plane endpoint gate", "disk full"},
			wantSteps:         []string{stepResolvingEndpointBackendAddress, stepClosingEndpointGate},
			wantGate:          testEndpointGateOpen,
		},
		{
			name: "gate only: a backend interface with no IPv4 address, such as one with IPv6 only, fails before the gate closes",
			gate: true,
			arrange: func(_ *NodeAgentServer, node *endpointGateNode) {
				node.backendOutput = ""
			},
			wantErrorContains: []string{"resolve control plane endpoint backend address", "no global IPv4 address on eth0"},
			wantSteps:         []string{stepResolvingEndpointBackendAddress},
			wantGate:          testEndpointGateOpen,
		},
		{
			name: "gate only: a backend interface with two addresses fails before the gate closes",
			gate: true,
			arrange: func(_ *NodeAgentServer, node *endpointGateNode) {
				node.backendOutput = testBackendInterfaceOutput + "2: eth0    inet 198.51.100.11/24 scope global secondary eth0\n"
			},
			wantErrorContains: []string{"multiple global IPv4 addresses on eth0: 198.51.100.10, 198.51.100.11"},
			wantSteps:         []string{stepResolvingEndpointBackendAddress},
			wantGate:          testEndpointGateOpen,
		},
		{
			name: "gate only: a backend interface that does not exist fails before the gate closes",
			gate: true,
			arrange: func(_ *NodeAgentServer, node *endpointGateNode) {
				node.backendOutput = `Device "eth0" does not exist.`
				node.backendErr = errors.New("exit status 1")
			},
			wantErrorContains: []string{"ip addr show dev eth0", `Device "eth0" does not exist.`},
			wantSteps:         []string{stepResolvingEndpointBackendAddress},
			wantGate:          testEndpointGateOpen,
		},
		{
			name: "gate only: a socket that cannot be closed fails the withdrawal and leaves the gate closed",
			gate: true,
			arrange: func(_ *NodeAgentServer, node *endpointGateNode) {
				node.peers[testEndpointBackendAddress] = []string{testBackendPeer}
				node.closeErr = errors.New("ss failed")
			},
			wantErrorContains: []string{"close remote sockets on control plane endpoint backend address " + testEndpointBackendAddress, "ss failed"},
			wantSteps:         endpointGateWithdrawalSteps[:4],
			wantEvents:        []string{"close " + testEndpointBackendAddress + ":6443 -> 203.0.113.7:41000 gate=" + callerGate},
			wantGate:          callerGate,
		},
		{
			name: "gate only: a call that is canceled in the settle time fails the withdrawal and leaves the gate closed",
			gate: true,
			arrange: func(s *NodeAgentServer, _ *endpointGateNode) {
				s.ControlPlaneEndpointGate.Settle = time.Hour
			},
			timeout:           20 * time.Millisecond,
			wantErrorContains: []string{"wait for control plane endpoint gate settle", "context deadline exceeded"},
			wantSteps:         endpointGateWithdrawalSteps[:3],
			wantGate:          callerGate,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			s, node := endpointGateTestServer(t, tc.kubeVip, tc.gate)
			if tc.arrange != nil {
				tc.arrange(s, node)
			}
			ctx := context.Background()
			if tc.timeout > 0 {
				var cancel context.CancelFunc
				ctx, cancel = context.WithTimeout(ctx, tc.timeout)
				defer cancel()
			}
			progress := &fakeOperationProgress{}

			err := s.runK8sControlPlaneNodeGracefulShutdown(ctx, progress, false)

			if len(tc.wantErrorContains) == 0 {
				require.NoError(t, err)
			} else {
				require.Error(t, err)
				for _, want := range tc.wantErrorContains {
					assert.Contains(t, err.Error(), want)
				}
			}
			assert.Equal(t, tc.wantSteps, progress.steps)
			assert.Equal(t, tc.wantEvents, node.events)
			assert.Equal(t, tc.wantGate, node.gateState())
			assert.Equal(t, tc.wantKubeVipParked, manifestIsParkedIn(t, s, defaultStaticPodBackupDir, defaultKubeVipManifestName))
			assert.Equal(t, tc.kubeVip && !tc.wantKubeVipParked, staticPodManifestIsActive(t, s, defaultKubeVipManifestName))
			assert.True(t, staticPodManifestIsActive(t, s, defaultKubeAPIServerManifestName), "the apiserver was not asked to stop")
			if !tc.gate {
				assert.Zero(t, node.backendQueries, "with no gate flag the backend interface is never read")
			}
		})
	}
}

// The restore behind StartKubeVipRestore. A caller that asks for the node back
// gets the gate opened whoever closed it.
func TestKubeVipRestoreOpensTheControlPlaneEndpointGate(t *testing.T) {
	tests := []struct {
		name    string
		kubeVip bool
		gate    bool
		arrange func(*testing.T, *NodeAgentServer, *endpointGateNode)

		wantErrorContains []string
		wantSteps         []string
		wantGate          string
		wantKubeVipActive bool
	}{
		{
			name: "gate only: restore opens a gate that a graceful shutdown closed",
			gate: true,
			arrange: func(t *testing.T, _ *NodeAgentServer, node *endpointGateNode) {
				writeEndpointGate(t, node, defaultStaticPodBackupDir)
			},
			wantSteps: []string{stepWaitingKubeAPIServerReady, stepResolvingKubeVip, stepOpeningEndpointGate},
			wantGate:  testEndpointGateOpen,
		},
		{
			name:      "gate only: restore with no gate file succeeds and opens nothing",
			gate:      true,
			wantSteps: []string{stepWaitingKubeAPIServerReady, stepResolvingKubeVip},
			wantGate:  testEndpointGateOpen,
		},
		{
			name:    "both: restore puts kube-vip back and then opens the gate",
			kubeVip: true,
			gate:    true,
			arrange: func(t *testing.T, s *NodeAgentServer, node *endpointGateNode) {
				withdrawKubeVipByHand(t, s, node)
				writeEndpointGate(t, node, defaultStaticPodBackupDir)
			},
			wantSteps: []string{
				stepWaitingKubeAPIServerReady,
				stepResolvingKubeVip,
				stepRestoringKubeVip,
				stepWaitingKubeVipStart,
				stepWaitingLoopbackVip,
				stepOpeningEndpointGate,
			},
			wantGate:          testEndpointGateOpen,
			wantKubeVipActive: true,
		},
		{
			name:    "both: restore opens the gate even when kube-vip does not come back",
			kubeVip: true,
			gate:    true,
			arrange: func(t *testing.T, s *NodeAgentServer, node *endpointGateNode) {
				withdrawKubeVipByHand(t, s, node)
				node.pods[kubeVipContainerName].startDelay = 1_000_000
				writeEndpointGate(t, node, defaultStaticPodBackupDir)
			},
			wantErrorContains: []string{"wait for kube-vip start"},
			wantSteps: []string{
				stepWaitingKubeAPIServerReady,
				stepResolvingKubeVip,
				stepRestoringKubeVip,
				stepWaitingKubeVipStart,
				stepOpeningEndpointGate,
			},
			wantGate:          testEndpointGateOpen,
			wantKubeVipActive: true,
		},
		{
			name: "gate only: restore opens a gate that the etcd defragmentation left closed",
			gate: true,
			arrange: func(t *testing.T, _ *NodeAgentServer, node *endpointGateNode) {
				writeEndpointGate(t, node, defaultEtcdDefragParkDir)
			},
			wantSteps: []string{stepWaitingKubeAPIServerReady, stepResolvingKubeVip, stepOpeningEndpointGate},
			wantGate:  testEndpointGateOpen,
		},
		{
			name: "gate only: restore opens a gate that an operator closed by hand",
			gate: true,
			arrange: func(t *testing.T, _ *NodeAgentServer, node *endpointGateNode) {
				writeEndpointGate(t, node, "")
			},
			wantSteps: []string{stepWaitingKubeAPIServerReady, stepResolvingKubeVip, stepOpeningEndpointGate},
			wantGate:  testEndpointGateOpen,
		},
		{
			name: "gate only: restore reports a gate file that cannot be read",
			gate: true,
			arrange: func(t *testing.T, _ *NodeAgentServer, node *endpointGateNode) {
				require.NoError(t, os.MkdirAll(node.gatePath, 0o755))
			},
			wantErrorContains: []string{"open control plane endpoint gate"},
			wantSteps:         []string{stepWaitingKubeAPIServerReady, stepResolvingKubeVip},
			// A directory is not a gate file, and the fake reads it as no gate.
			wantGate: testEndpointGateOpen,
		},
		{
			name:    "kube-vip only: with no gate flag restore leaves a file at the gate path alone",
			kubeVip: true,
			arrange: func(t *testing.T, s *NodeAgentServer, node *endpointGateNode) {
				withdrawKubeVipByHand(t, s, node)
				writeEndpointGate(t, node, defaultStaticPodBackupDir)
			},
			wantSteps: []string{
				stepWaitingKubeAPIServerReady,
				stepResolvingKubeVip,
				stepRestoringKubeVip,
				stepWaitingKubeVipStart,
				stepWaitingLoopbackVip,
			},
			wantGate:          defaultStaticPodBackupDir,
			wantKubeVipActive: true,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			s, node := endpointGateTestServer(t, tc.kubeVip, tc.gate)
			if tc.arrange != nil {
				tc.arrange(t, s, node)
			}
			progress := &fakeOperationProgress{}

			err := s.runKubeVipRestore(context.Background(), progress)

			if len(tc.wantErrorContains) == 0 {
				require.NoError(t, err)
			} else {
				require.Error(t, err)
				for _, want := range tc.wantErrorContains {
					assert.Contains(t, err.Error(), want)
				}
			}
			assert.Equal(t, tc.wantSteps, progress.steps)
			assert.Equal(t, tc.wantGate, node.gateState())
			assert.Equal(t, tc.wantKubeVipActive, staticPodManifestIsActive(t, s, defaultKubeVipManifestName))
		})
	}
}

// The etcd defragmentation withdraws and restores in one call, so it gets the
// gate through the calls it already makes. A gate it closes names its own park
// directory, which is what lets the agent open it again without a caller.
func TestRunEtcdDefragUsesTheControlPlaneEndpointGate(t *testing.T) {
	const (
		callerGate = defaultStaticPodBackupDir
		defragGate = defaultEtcdDefragParkDir
	)
	const mib = int64(1024 * 1024)
	etcdNeverHealthyAfterRestart := func(ctx context.Context, call int) (*clientv3.StatusResponse, error) {
		// Calls 1 and 2 are the preflight and the leadership check. Everything
		// from 3 on is the health wait after the restart.
		if call >= 3 {
			return nil, errors.New("connection refused")
		}
		return etcdSizingStatus(500*mib, 100*mib, 500*mib, 3)(ctx, call)
	}

	tests := []struct {
		name    string
		kubeVip bool
		arrange func(*testing.T, *NodeAgentServer, *endpointGateNode)

		wantErr             bool
		wantOutcome         pb.GetEtcdDefragStatusResponse_Outcome
		wantMessageContains []string
		// wantSteps is checked when it is set. The other cases check only the
		// steps that must or must not be there.
		wantSteps            []string
		wantStepsContain     []string
		wantStepsNotContain  []string
		wantEvents           []string
		wantGate             string
		wantGateAfterRestart string
	}{
		{
			name: "gate only: the gate is closed while etcd restarts and open when the node is back",
			arrange: func(_ *testing.T, _ *NodeAgentServer, node *endpointGateNode) {
				node.peers[testEndpointBackendAddress] = []string{testBackendPeer, ""}
			},
			wantOutcome: pb.GetEtcdDefragStatusResponse_OUTCOME_RECLAIMED,
			wantSteps: slices.Concat(
				[]string{stepEtcdDefragPreflight, stepEtcdDefragTransferLeader},
				endpointGateWithdrawalSteps,
				[]string{
					stepResolvingKubeVip,
					stepStoppingKubeAPIServer,
					stepWaitingKubeAPIServerExit,
					stepEtcdDefragStoppingEtcd,
					stepEtcdDefragWaitingRestart,
					stepEtcdDefragWaitingHealthy,
					stepEtcdDefragReturningToService,
					stepRestoringKubeAPIServer,
					stepWaitingKubeAPIServerStart,
					stepWaitingKubeAPIServerReady,
					stepResolvingKubeVip,
					// The gate opens last, after the apiserver is ready.
					stepOpeningEndpointGate,
					stepEtcdDefragMeasuring,
				},
			),
			wantEvents: []string{
				"close " + testEndpointBackendAddress + ":6443 -> 203.0.113.7:41000 gate=" + defragGate,
				"stop-etcd gate=" + defragGate,
			},
			wantGate:             testEndpointGateOpen,
			wantGateAfterRestart: testEndpointGateOpen,
		},
		{
			name:    "both: kube-vip and the gate are withdrawn for the restart and both are returned",
			kubeVip: true,
			arrange: func(_ *testing.T, _ *NodeAgentServer, node *endpointGateNode) {
				node.peers[testEndpointBackendAddress] = []string{testBackendPeer, ""}
			},
			wantOutcome: pb.GetEtcdDefragStatusResponse_OUTCOME_RECLAIMED,
			wantStepsContain: []string{
				stepClosingEndpointGate,
				stepStoppingKubeVip,
				stepRestoringKubeVip,
				stepOpeningEndpointGate,
			},
			wantEvents: []string{
				"close " + testEndpointBackendAddress + ":6443 -> 203.0.113.7:41000 gate=" + defragGate,
				"stop-etcd gate=" + defragGate,
			},
			wantGate:             testEndpointGateOpen,
			wantGateAfterRestart: testEndpointGateOpen,
		},
		{
			name: "gate only: a load balancer that still sends connections returns the node to service and opens the gate",
			arrange: func(_ *testing.T, _ *NodeAgentServer, node *endpointGateNode) {
				node.peers[testEndpointBackendAddress] = []string{"", testBackendPeer}
			},
			wantOutcome:          pb.GetEtcdDefragStatusResponse_OUTCOME_FAILED_RESTORED,
			wantMessageContains:  []string{"control plane endpoint backend socket quiet window failed"},
			wantStepsContain:     []string{stepOpeningEndpointGate},
			wantStepsNotContain:  []string{stepStoppingKubeAPIServer, stepEtcdDefragStoppingEtcd},
			wantGate:             testEndpointGateOpen,
			wantGateAfterRestart: testEndpointGateOpen,
		},
		{
			name: "gate only: a failed gate write returns the node to service with the gate open",
			arrange: func(_ *testing.T, s *NodeAgentServer, _ *endpointGateNode) {
				s.FileWriter = &MockFileWriter{Err: errors.New("disk full")}
			},
			wantOutcome:          pb.GetEtcdDefragStatusResponse_OUTCOME_FAILED_RESTORED,
			wantMessageContains:  []string{"close control plane endpoint gate", "disk full"},
			wantStepsNotContain:  []string{stepStoppingKubeAPIServer, stepEtcdDefragStoppingEtcd, stepOpeningEndpointGate},
			wantGate:             testEndpointGateOpen,
			wantGateAfterRestart: testEndpointGateOpen,
		},
		{
			name: "gate only: a member that never returns healthy leaves the gate closed and hands it to the caller",
			arrange: func(_ *testing.T, s *NodeAgentServer, _ *endpointGateNode) {
				s.etcdClient.(*fakeEtcdMemberClient).statusFn = etcdNeverHealthyAfterRestart
			},
			wantErr:             true,
			wantOutcome:         pb.GetEtcdDefragStatusResponse_OUTCOME_FAILED_NOT_RESTORED,
			wantMessageContains: []string{"did not return healthy", "left out of service"},
			wantStepsNotContain: []string{stepOpeningEndpointGate},
			wantEvents:          []string{"stop-etcd gate=" + defragGate},
			wantGate:            callerGate,
			// A restart must not return a node whose etcd cannot answer.
			wantGateAfterRestart: callerGate,
		},
		{
			name: "gate only: a gate that a caller closed stays closed and stays the caller's",
			arrange: func(t *testing.T, _ *NodeAgentServer, node *endpointGateNode) {
				writeEndpointGate(t, node, callerGate)
				node.peers[testEndpointBackendAddress] = []string{testBackendPeer}
			},
			wantOutcome:         pb.GetEtcdDefragStatusResponse_OUTCOME_RECLAIMED,
			wantStepsNotContain: []string{stepWaitingEndpointGateSettle, stepClosingEndpointBackendSockets, stepOpeningEndpointGate},
			wantEvents:          []string{"stop-etcd gate=" + callerGate},
			wantGate:            callerGate,
			// The caller still owns it after a restart.
			wantGateAfterRestart: callerGate,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			s, node := endpointGateTestServer(t, tc.kubeVip, true)
			if tc.arrange != nil {
				tc.arrange(t, s, node)
			}
			progress := &fakeOperationProgress{}

			err := s.runEtcdDefrag(context.Background(), progress)

			if tc.wantErr {
				require.Error(t, err)
			} else {
				require.NoError(t, err)
			}
			result := decodeDefragResult(t, progress)
			assert.Equal(t, int32(tc.wantOutcome), result.Outcome)
			for _, want := range tc.wantMessageContains {
				assert.Contains(t, result.ErrorMessage, want)
			}
			if tc.wantSteps != nil {
				assert.Equal(t, tc.wantSteps, progress.steps)
			}
			for _, want := range tc.wantStepsContain {
				assert.Contains(t, progress.steps, want)
			}
			for _, unwanted := range tc.wantStepsNotContain {
				assert.NotContains(t, progress.steps, unwanted)
			}
			assert.Equal(t, tc.wantEvents, node.events)
			assert.Equal(t, tc.wantGate, node.gateState())
			if tc.kubeVip {
				assert.True(t, staticPodManifestIsActive(t, s, defaultKubeVipManifestName), "kube-vip must be restored")
				assert.Contains(t, node.loopbackVIPs, testKubeVipAddress)
			}

			require.NoError(t, s.ReconcileInterruptedStaticPodParks(context.Background()))
			assert.Equal(t, tc.wantGateAfterRestart, node.gateState())
		})
	}
}

// The repair of stale state at startup. It opens a gate under the rule that
// decides which parked manifests it puts back: only what the defragmentation
// owes.
func TestReconcileInterruptedStaticPodParksOpensAStaleControlPlaneEndpointGate(t *testing.T) {
	tests := []struct {
		name    string
		kubeVip bool
		gate    bool
		arrange func(*testing.T, *NodeAgentServer, *endpointGateNode)

		wantGate            string
		wantAPIServerActive bool
		wantKubeVipActive   bool
	}{
		{
			name: "a gate closed by an interrupted defragmentation is opened and kube-apiserver is put back",
			gate: true,
			arrange: func(t *testing.T, s *NodeAgentServer, node *endpointGateNode) {
				s.NodeStatus.NodeAgentOperations = runningEtcdDefragRecord()
				parkManifest(t, s, defaultKubeAPIServerManifestName)
				writeEndpointGate(t, node, defaultEtcdDefragParkDir)
			},
			wantGate:            testEndpointGateOpen,
			wantAPIServerActive: true,
		},
		{
			name: "a gate closed by an interrupted defragmentation is opened when no manifest is parked",
			gate: true,
			arrange: func(t *testing.T, _ *NodeAgentServer, node *endpointGateNode) {
				writeEndpointGate(t, node, defaultEtcdDefragParkDir)
			},
			wantGate:            testEndpointGateOpen,
			wantAPIServerActive: true,
		},
		{
			name:    "both: kube-vip parked by an interrupted defragmentation is put back and the gate is opened",
			kubeVip: true,
			gate:    true,
			arrange: func(t *testing.T, s *NodeAgentServer, node *endpointGateNode) {
				parkManifest(t, s, defaultKubeAPIServerManifestName)
				parkManifest(t, s, defaultKubeVipManifestName)
				node.loopbackVIPs = nil
				writeEndpointGate(t, node, defaultEtcdDefragParkDir)
			},
			wantGate:            testEndpointGateOpen,
			wantAPIServerActive: true,
			wantKubeVipActive:   true,
		},
		{
			name: "a gate closed by a graceful shutdown stays closed",
			gate: true,
			arrange: func(t *testing.T, _ *NodeAgentServer, node *endpointGateNode) {
				writeEndpointGate(t, node, defaultStaticPodBackupDir)
			},
			wantGate:            defaultStaticPodBackupDir,
			wantAPIServerActive: true,
		},
		{
			name: "a gate handed to the caller by a defragmentation that gave up on the member stays closed",
			gate: true,
			arrange: func(t *testing.T, s *NodeAgentServer, node *endpointGateNode) {
				parkManifest(t, s, defaultKubeAPIServerManifestName)
				writeEndpointGate(t, node, defaultEtcdDefragParkDir)
				require.NoError(t, s.handOffParkedManifestsToCaller())
			},
			wantGate: defaultStaticPodBackupDir,
		},
		{
			name: "a gate that an operator closed by hand stays closed",
			gate: true,
			arrange: func(t *testing.T, _ *NodeAgentServer, node *endpointGateNode) {
				writeEndpointGate(t, node, "")
			},
			wantGate:            "",
			wantAPIServerActive: true,
		},
		{
			name:                "no gate file is a clean start",
			gate:                true,
			wantGate:            testEndpointGateOpen,
			wantAPIServerActive: true,
		},
		{
			name:    "kube-vip only: with no gate flag a file at the gate path is left alone",
			kubeVip: true,
			arrange: func(t *testing.T, s *NodeAgentServer, node *endpointGateNode) {
				parkManifest(t, s, defaultKubeVipManifestName)
				node.loopbackVIPs = nil
				writeEndpointGate(t, node, defaultEtcdDefragParkDir)
			},
			wantGate:            defaultEtcdDefragParkDir,
			wantAPIServerActive: true,
			wantKubeVipActive:   true,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			s, node := endpointGateTestServer(t, tc.kubeVip, tc.gate)
			if tc.arrange != nil {
				tc.arrange(t, s, node)
			}

			require.NoError(t, s.ReconcileInterruptedStaticPodParks(context.Background()))

			assert.Equal(t, tc.wantGate, node.gateState())
			assert.Equal(t, tc.wantAPIServerActive, staticPodManifestIsActive(t, s, defaultKubeAPIServerManifestName))
			assert.Equal(t, tc.wantKubeVipActive, staticPodManifestIsActive(t, s, defaultKubeVipManifestName))
			assert.Empty(t, node.events, "the repair closes no socket")
		})
	}
}

// Who may take a closed gate over. The caller's hold is the stronger one: it
// keeps the node out of service until a caller asks for it back.
func TestCloseControlPlaneEndpointGateOwnership(t *testing.T) {
	const noGate = "none"

	tests := []struct {
		name       string
		existing   string
		parkDir    string
		wantClosed bool
		wantGate   string
	}{
		{
			name:       "a caller closes an open gate",
			existing:   noGate,
			parkDir:    defaultStaticPodBackupDir,
			wantClosed: true,
			wantGate:   defaultStaticPodBackupDir,
		},
		{
			name:       "a caller closes its own gate again",
			existing:   defaultStaticPodBackupDir,
			parkDir:    defaultStaticPodBackupDir,
			wantClosed: true,
			wantGate:   defaultStaticPodBackupDir,
		},
		{
			name:       "a caller takes over a gate that the defragmentation left closed",
			existing:   defaultEtcdDefragParkDir,
			parkDir:    defaultStaticPodBackupDir,
			wantClosed: true,
			wantGate:   defaultStaticPodBackupDir,
		},
		{
			name:       "the defragmentation closes an open gate",
			existing:   noGate,
			parkDir:    defaultEtcdDefragParkDir,
			wantClosed: true,
			wantGate:   defaultEtcdDefragParkDir,
		},
		{
			name:       "the defragmentation closes its own gate again",
			existing:   defaultEtcdDefragParkDir,
			parkDir:    defaultEtcdDefragParkDir,
			wantClosed: true,
			wantGate:   defaultEtcdDefragParkDir,
		},
		{
			name:     "the defragmentation leaves a gate that a caller closed",
			existing: defaultStaticPodBackupDir,
			parkDir:  defaultEtcdDefragParkDir,
			wantGate: defaultStaticPodBackupDir,
		},
		{
			name:     "the defragmentation leaves a gate that an operator closed by hand",
			existing: "",
			parkDir:  defaultEtcdDefragParkDir,
			wantGate: "",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			s, node := endpointGateTestServer(t, false, true)
			if tc.existing != noGate {
				writeEndpointGate(t, node, tc.existing)
			}

			closed, err := s.closeControlPlaneEndpointGate(tc.parkDir)

			require.NoError(t, err)
			assert.Equal(t, tc.wantClosed, closed)
			assert.Equal(t, tc.wantGate, node.gateState())
			assert.NoFileExists(t, node.gatePath+".tmp", "the staged file must not stay behind")
			if tc.wantClosed {
				assertPathMode(t, node.gatePath, controlPlaneEndpointGateFileMode)
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
		{
			name:   "one address with a prefix length",
			output: testBackendInterfaceOutput,
			want:   testEndpointBackendAddress,
		},
		{
			name:   "one address of a point-to-point interface, printed with no prefix length",
			output: "3: eth0    inet 198.51.100.10 peer 198.51.100.1/32 scope global eth0\\       valid_lft forever preferred_lft forever\n",
			want:   testEndpointBackendAddress,
		},
		{
			name:      "no address",
			output:    "\n",
			wantError: "no global IPv4 address on eth0",
		},
		{
			name: "two addresses",
			output: testBackendInterfaceOutput +
				"2: eth0    inet 198.51.100.11/24 scope global secondary eth0\\       valid_lft forever preferred_lft forever\n",
			wantError: "multiple global IPv4 addresses on eth0: 198.51.100.10, 198.51.100.11",
		},
		{
			name:      "an IPv6 address is not a backend address",
			output:    "2: eth0    inet6 2001:db8::10/64 scope global \\       valid_lft forever preferred_lft forever\n",
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
			runner := &MockRunner{Runners: []runner{
				runForCommand("ip", []string{"-o", "-4", "addr", "show", "dev", "eth0", "scope", "global"}, func(string, []string, *nvkeutils.CommandOptions) ([]byte, error) {
					return []byte(tc.output), tc.runErr
				}),
			}, Err: errors.New("unexpected command")}

			got, err := resolveEndpointBackendAddress(runner, "eth0")

			if tc.wantError != "" {
				require.Error(t, err)
				assert.Contains(t, err.Error(), tc.wantError)
				return
			}
			require.NoError(t, err)
			assert.Equal(t, tc.want, got)
		})
	}
}
