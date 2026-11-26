// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

// nvke-lab-client is the lab stand-in for the NVKE controller. It calls nvke-agent on one node
// in the order of the controller (results/nvke-agent-procedure.md, section 3) and starts
// kubeadm init through the agent. In SPIFFE mode it uses the calls of the controller transport
// (controller/internal/agent/transport.go:244-262): it presents its own X.509 SVID, it accepts
// only the expected agent ID, and it prints the ID of the peer.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/spiffe/go-spiffe/v2/spiffegrpc/grpccredentials"
	"github.com/spiffe/go-spiffe/v2/spiffeid"
	"github.com/spiffe/go-spiffe/v2/spiffetls/tlsconfig"
	"github.com/spiffe/go-spiffe/v2/workloadapi"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/peer"

	pb "github.com/dsx-ai-factory/nvke/agent/pkg/agent/proto"
)

// fileFlags collects the repeated -file flag: <path on the node>=<local file>:<octal mode>.
type fileFlags []*pb.File

func (f *fileFlags) String() string { return fmt.Sprint(len(*f), " files") }

func (f *fileFlags) Set(v string) error {
	nodePath, rest, ok := strings.Cut(v, "=")
	local, modeText, ok2 := strings.Cut(rest, ":")
	if !ok || !ok2 {
		return errors.New("want <path on the node>=<local file>:<octal mode>")
	}
	mode, err := strconv.ParseUint(modeText, 8, 32)
	if err != nil {
		return fmt.Errorf("mode %q: %w", modeText, err)
	}
	content, err := os.ReadFile(local)
	if err != nil {
		return fmt.Errorf("reading %s: %w", local, err)
	}
	*f = append(*f, &pb.File{Path: nodePath, Content: content, Mode: uint32(mode), Owner: "root:root"})
	return nil
}

type options struct {
	addr, socket, expectID, steps, initConfig, endpoint, podCIDR, serviceCIDR, kubeconfigOut, sentinel string
	plaintext                                                                                          bool
	wait                                                                                               time.Duration
	files                                                                                              fileFlags
	// Phase 1 CNI test.
	ovsOperationID, cniVersion string
	waitForAgent               time.Duration
	// Phase 1 dry run: the join side.
	joinStringOut, joinStringIn, joinConfig, etcdTarget string
}

func main() {
	var o options
	flag.StringVar(&o.addr, "addr", "", "agent address, host:port")
	flag.BoolVar(&o.plaintext, "plaintext", false, "no TLS, for an agent with --disable-mtls")
	flag.StringVar(&o.socket, "socket", "unix:///tmp/spire-agent/public/api.sock", "SPIFFE workload API socket")
	flag.StringVar(&o.expectID, "expect-id", "", "SPIFFE ID that the agent must present")
	flag.StringVar(&o.steps, "steps", "status,preflight,init,wait,kubeconfig,spire", "calls to make, in this order (also: ovs, cni, joinstrings, etcdremove, reset, join, waitjoin)")
	flag.StringVar(&o.initConfig, "init-config", "", "kubeadm configuration file for ExecuteKubeadmInit")
	flag.Var(&o.files, "file", "file for ExecuteKubeadmInit: <path on the node>=<local file>:<octal mode> (repeat)")
	flag.StringVar(&o.endpoint, "endpoint", "", "control_plane_endpoint")
	flag.StringVar(&o.podCIDR, "pod-cidr", "", "pod_network_cidr")
	flag.StringVar(&o.serviceCIDR, "service-cidr", "", "service_cidr")
	flag.StringVar(&o.kubeconfigOut, "kubeconfig-out", "", "file for the kubeconfig (a secret, mode 0600)")
	flag.StringVar(&o.sentinel, "sentinel", "", "preflight with a file_exists check on this path, not with cloud-init status")
	flag.DurationVar(&o.wait, "wait", 15*time.Minute, "time limit for each wait")
	flag.StringVar(&o.ovsOperationID, "ovs-operation-id", "", "operation ID for StartOpenVSwitchReconciliation (step ovs)")
	flag.StringVar(&o.cniVersion, "cni-version", "", "version for InstallCNI. Empty = the default of the agent, as the controller sends for the default version")
	flag.DurationVar(&o.waitForAgent, "wait-for-agent", 0, "step status: wait up to this time for the connection to the agent (gRPC wait-for-ready). 0 = fail fast")
	flag.StringVar(&o.joinStringOut, "join-string-out", "", "step joinstrings: file for the control plane join string (a secret, mode 0600)")
	flag.StringVar(&o.joinStringIn, "join-string", "", "step join: file with the join string")
	flag.StringVar(&o.joinConfig, "join-config", "", "step join: kubeadm join configuration file")
	flag.StringVar(&o.etcdTarget, "etcd-target", "", "step etcdremove: etcd member name")
	flag.Parse()
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stdout, nil)))
	if err := run(context.Background(), &o); err != nil {
		slog.Error("client failed", "err", err)
		os.Exit(1)
	}
}

// dialOptions returns plaintext credentials, or SPIFFE mTLS that accepts only the expected agent ID.
func dialOptions(ctx context.Context, o *options) (grpc.DialOption, func(), error) {
	if o.plaintext {
		slog.Warn("plaintext mode: the call has no authentication")
		return grpc.WithTransportCredentials(insecure.NewCredentials()), func() {}, nil
	}
	expected, err := spiffeid.FromString(o.expectID)
	if err != nil {
		return nil, nil, fmt.Errorf("parsing -expect-id: %w", err)
	}
	// NewX509Source waits for the first SVID. The limit turns "no identity" into an error.
	ctx, cancel := context.WithTimeout(ctx, time.Minute)
	defer cancel()
	source, err := workloadapi.NewX509Source(ctx, workloadapi.WithClientOptions(workloadapi.WithAddr(o.socket)))
	if err != nil {
		return nil, nil, fmt.Errorf("creating the X.509 source from %s: %w", o.socket, err)
	}
	svid, err := source.GetX509SVID()
	if err != nil {
		_ = source.Close()
		return nil, nil, fmt.Errorf("reading the client SVID: %w", err)
	}
	slog.Info("client identity", "client_id", svid.ID.String(), "expected_agent_id", expected.String())
	creds := grpccredentials.MTLSClientCredentials(source, source, tlsconfig.AuthorizeID(expected))
	return grpc.WithTransportCredentials(creds), func() { _ = source.Close() }, nil
}

func run(ctx context.Context, o *options) error {
	dial, closeSource, err := dialOptions(ctx, o)
	if err != nil {
		return err
	}
	defer closeSource()
	conn, err := grpc.NewClient(o.addr, dial)
	if err != nil {
		return fmt.Errorf("creating the gRPC client: %w", err)
	}
	defer conn.Close() //nolint:errcheck // the process ends after this
	agent := pb.NewNodeAgentClient(conn)

	for _, step := range strings.Split(o.steps, ",") {
		var p peer.Peer
		callCtx, cancel := context.WithTimeout(ctx, o.wait)
		err := runStep(callCtx, agent, o, step, grpc.Peer(&p))
		cancel()
		// The peer ID comes from the certificate that the agent presented in the handshake.
		if id, ok := grpccredentials.PeerIDFromPeer(&p); ok {
			slog.Info("authenticated peer", "step", step, "peer_id", id.String(), "peer_addr", p.Addr.String())
		}
		if err != nil {
			return fmt.Errorf("step %s: %w", step, err)
		}
	}
	return nil
}

func runStep(ctx context.Context, agent pb.NodeAgentClient, o *options, step string, opt grpc.CallOption) error {
	switch step {
	case "status":
		if o.waitForAgent > 0 {
			// Block until the channel is ready. This replaces a port check loop outside the client.
			waitCtx, cancel := context.WithTimeout(ctx, o.waitForAgent)
			defer cancel()
			_, err := kubeadmStatus(waitCtx, agent, opt, grpc.WaitForReady(true))
			return err
		}
		_, err := kubeadmStatus(ctx, agent, opt)
		return err
	case "ovs":
		return openVSwitch(ctx, agent, o, opt)
	case "joinstrings":
		return joinStrings(ctx, agent, o, opt)
	case "etcdremove":
		return etcdRemove(ctx, agent, o, opt)
	case "reset":
		return kubeadmReset(ctx, agent, opt)
	case "join":
		return kubeadmJoin(ctx, agent, o, opt)
	case "waitjoin":
		return waitForJoin(ctx, agent, opt)
	case "cni":
		return installCNI(ctx, agent, o, opt)
	case "preflight":
		return preflight(ctx, agent, o, opt)
	case "init":
		return kubeadmInit(ctx, agent, o, opt)
	case "wait":
		return waitForInit(ctx, agent, opt)
	case "kubeconfig":
		resp, err := agent.GetKubeconfig(ctx, &pb.KubeconfigRequest{}, opt)
		if err != nil {
			return err
		}
		if resp.GetErrorMessage() != "" || resp.GetKubeconfig() == "" {
			return fmt.Errorf("no kubeconfig: %s", resp.GetErrorMessage())
		}
		slog.Info("GetKubeconfig", "bytes", len(resp.GetKubeconfig()), "file", o.kubeconfigOut)
		if o.kubeconfigOut == "" {
			return nil
		}
		return os.WriteFile(o.kubeconfigOut, []byte(resp.GetKubeconfig()), 0o600)
	case "spire":
		resp, err := agent.GetSpireAgentStatus(ctx, &pb.GetSpireAgentStatusRequest{}, opt)
		if err != nil {
			return err
		}
		slog.Info("GetSpireAgentStatus", "server", fmt.Sprintf("%s:%d", resp.GetServerAddress(), resp.GetServerPort()),
			"config_applied", resp.GetConfigApplied(), "has_valid_svid", resp.GetHasValidSvid(),
			"svid_spiffe_id", resp.GetSvidSpiffeId(), "svid_expires_at", time.Unix(resp.GetSvidExpiresAtUnixSeconds(), 0).UTC())
		return nil
	}
	return fmt.Errorf("unknown step %q", step)
}

func kubeadmStatus(ctx context.Context, agent pb.NodeAgentClient, opts ...grpc.CallOption) (*pb.KubeadmStatusResponse, error) {
	resp, err := agent.GetKubeadmStatus(ctx, &pb.KubeadmStatusRequest{}, opts...)
	if err != nil {
		return nil, err
	}
	slog.Info("GetKubeadmStatus", "status", resp.GetKubeadmStatus(), "phase", resp.GetKubeadmPhase(),
		"message", resp.GetKubeadmCurrentMessage(), "agent_version", resp.GetAgentVersion(),
		"cni_install_status", resp.GetCniInstallStatus())
	return resp, nil
}

// openVSwitch does what the activity ConfigureOpenVSwitch of the controller does
// (controller/internal/temporal/activities/configure_open_vswitch.go:71-127): one
// StartOpenVSwitchReconciliation call, then a status poll each 2 seconds until the operation ends.
func openVSwitch(ctx context.Context, agent pb.NodeAgentClient, o *options, opt grpc.CallOption) error {
	if o.ovsOperationID == "" {
		return errors.New("step ovs needs -ovs-operation-id")
	}
	start, err := agent.StartOpenVSwitchReconciliation(ctx, &pb.StartOpenVSwitchReconciliationRequest{OperationId: o.ovsOperationID}, opt)
	if err != nil {
		return fmt.Errorf("StartOpenVSwitchReconciliation: %w", err)
	}
	operation := start.GetOperation()
	for {
		st := operation.GetOperation()
		slog.Info("OpenVSwitchReconciliation", "operation_id", st.GetOperationId(), "phase", st.GetPhase().String(),
			"step", st.GetStep(), "error", st.GetErrorMessage())
		switch st.GetPhase() {
		case pb.NodeAgentOperationPhase_NODE_AGENT_OPERATION_PHASE_SUCCEEDED:
			r := operation.GetResult()
			slog.Info("OpenVSwitchReconciliation result", "outcome", r.GetOutcome().String(), "bridge", r.GetBridgeName(),
				"uplink", r.GetUplinkInterface(), "network_backend", r.GetNetworkBackend().String())
			return nil
		case pb.NodeAgentOperationPhase_NODE_AGENT_OPERATION_PHASE_RUNNING:
		default:
			return fmt.Errorf("Open vSwitch operation ended with phase %s at step %q: %s", st.GetPhase(), st.GetStep(), st.GetErrorMessage())
		}
		if err := sleep(ctx, 2*time.Second); err != nil {
			return err
		}
		status, err := agent.GetOpenVSwitchReconciliationStatus(ctx, &pb.GetOpenVSwitchReconciliationStatusRequest{OperationId: o.ovsOperationID}, opt)
		if err != nil {
			return fmt.Errorf("GetOpenVSwitchReconciliationStatus: %w", err)
		}
		operation = status.GetOperation()
	}
}

// installCNI sends the request of the activity InstallCNI of the controller
// (controller/internal/temporal/activities/install_cni.go:148-170): variant OVN, the two CIDR
// values, no cni_config (no registry override) and an empty version for the default version.
func installCNI(ctx context.Context, agent pb.NodeAgentClient, o *options, opt grpc.CallOption) error {
	begin := time.Now()
	resp, err := agent.InstallCNI(ctx, &pb.InstallCNIRequest{
		CniVariant:     pb.CniVariant_CNI_VARIANT_OVN,
		Version:        o.cniVersion,
		PodNetworkCidr: o.podCIDR,
		ServiceCidr:    o.serviceCIDR,
	}, opt)
	if err != nil {
		return fmt.Errorf("InstallCNI: %w (error_message %q)", err, resp.GetErrorMessage())
	}
	slog.Info("InstallCNI", "status", resp.GetStatus(), "error_message", resp.GetErrorMessage(),
		"resolved_apt_package", resp.GetResolvedAptPackage(), "seconds", fmt.Sprintf("%.1f", time.Since(begin).Seconds()))
	return nil
}

// preflight repeats ExecuteNodePreflight until the node is ready, as the provision workflow does.
func preflight(ctx context.Context, agent pb.NodeAgentClient, o *options, opt grpc.CallOption) error {
	req := &pb.ExecuteNodePreflightRequest{CheckCloudInitStatus: &pb.CheckCloudInitStatus{}}
	if o.sentinel != "" {
		check := &pb.NodePreflightCheck_FileExists{FileExists: &pb.FileExistsPreflightCheck{Path: o.sentinel}}
		req = &pb.ExecuteNodePreflightRequest{Checks: []*pb.NodePreflightCheck{{Name: "cluster-api-bootstrap-success", Check: check}}}
	}
	for {
		resp, err := agent.ExecuteNodePreflight(ctx, req, opt)
		if err != nil {
			return err
		}
		slog.Info("ExecuteNodePreflight", "status", resp.GetStatus(), "message", resp.GetErrorMessage(), "results", fmt.Sprint(resp.GetResults()))
		switch resp.GetStatus() {
		case "ready":
			return nil
		case "error":
			return fmt.Errorf("preflight error: %s", resp.GetErrorMessage())
		}
		if err := sleep(ctx, 5*time.Second); err != nil {
			return err
		}
	}
}

// kubeadmInit sends the request of the controller (temporal/activities/kubeadm_init.go:135-184)
// with no_cni_install, as the controller does with the setting cni.installAfterInit. It sends nothing when init already runs or is complete.
func kubeadmInit(ctx context.Context, agent pb.NodeAgentClient, o *options, opt grpc.CallOption) error {
	status, err := kubeadmStatus(ctx, agent, opt)
	if err != nil {
		return err
	}
	state := strings.ToLower(status.GetKubeadmStatus())
	if strings.ToLower(status.GetKubeadmPhase()) == "initialize" && (state == "ready" || state == "pending") {
		slog.Info("init already started, no ExecuteKubeadmInit call")
		return nil
	}
	config, err := os.ReadFile(o.initConfig)
	if err != nil {
		return fmt.Errorf("reading -init-config: %w", err)
	}
	resp, err := agent.ExecuteKubeadmInit(ctx, &pb.KubeadmInitRequest{
		InitConfig:           string(config),
		ControlPlaneEndpoint: o.endpoint,
		PodNetworkCidr:       o.podCIDR,
		ServiceCidr:          o.serviceCIDR,
		ObjectsToEncrypt:     []string{"secrets"},
		Files:                o.files,
		NoCniInstall:         true,
		// The controller fills these old fields for an OVN cluster in each case, and the agent
		// ignores them with no_cni_install (activities/kubeadm_init.go:156-175).
		UseOvnK8SCni:  true,    //nolint:staticcheck // same as the controller
		CniPluginName: "ovn",   //nolint:staticcheck // same as the controller
		OvnVersion:    "2.4.2", //nolint:staticcheck // db.DefaultOvnKubernetesCNIVersion
	}, opt)
	if err != nil {
		return err
	}
	slog.Info("ExecuteKubeadmInit", "status", resp.GetStatus(), "phase", resp.GetPhase(), "role", resp.GetRole(), "files", len(o.files))
	return nil
}

// waitForInit polls each 10 seconds until the status is ready in the phase initialize.
func waitForInit(ctx context.Context, agent pb.NodeAgentClient, opt grpc.CallOption) error {
	for {
		status, err := kubeadmStatus(ctx, agent, opt)
		if err != nil {
			return err
		}
		switch state := strings.ToLower(status.GetKubeadmStatus()); {
		case state == "error":
			return fmt.Errorf("kubeadm init failed: %s", status.GetKubeadmCurrentMessage())
		case state == "ready" && strings.ToLower(status.GetKubeadmPhase()) == "initialize":
			return nil
		}
		if err := sleep(ctx, 10*time.Second); err != nil {
			return err
		}
	}
}

// joinStrings asks a joined control plane node for new join strings, as the activity KubeadmJoin does
// (controller/internal/temporal/activities/kubeadm_join.go:322-354). The agent runs
// "kubeadm init phase upload-certs --upload-certs" and "kubeadm token create --print-join-command".
// The strings are secrets: the client writes the control plane string to a file and prints no part of it.
func joinStrings(ctx context.Context, agent pb.NodeAgentClient, o *options, opt grpc.CallOption) error {
	begin := time.Now()
	resp, err := agent.UpdateAndFetchKubeAdmJoinStrings(ctx, &pb.KubeadmJoinStringRequest{}, opt)
	if err != nil {
		return fmt.Errorf("UpdateAndFetchKubeAdmJoinStrings: %w", err)
	}
	cp, worker := stripJoinString(resp.GetControlplaneJoinString()), stripJoinString(resp.GetWorkerJoinString())
	if cp == "" || worker == "" {
		return errors.New("missing join strings from agent response")
	}
	fields := strings.Fields(cp)
	endpoint := ""
	if len(fields) > 2 {
		endpoint = fields[2]
	}
	slog.Info("UpdateAndFetchKubeAdmJoinStrings", "endpoint", endpoint, "control_plane_fields", len(fields),
		"has_certificate_key", strings.Contains(cp, "--certificate-key"), "seconds", fmt.Sprintf("%.1f", time.Since(begin).Seconds()))
	if o.joinStringOut == "" {
		return nil
	}
	return os.WriteFile(o.joinStringOut, []byte(cp+"\n"), 0o600)
}

// stripJoinString is the function of the same name in the controller (kubeadm_join.go:356-361).
func stripJoinString(s string) string {
	s = strings.ReplaceAll(s, "\n", "")
	s = strings.ReplaceAll(s, "\t", "")
	s = strings.ReplaceAll(s, "\\", "")
	return s
}

// etcdRemove is the first half of cleanBeforeControlPlaneRejoin (workflows/provision_node.go:576-626):
// a joined control plane node removes the etcd member with the name of the node that joins.
// On a new node the name is not a member, and the agent returns success.
func etcdRemove(ctx context.Context, agent pb.NodeAgentClient, o *options, opt grpc.CallOption) error {
	if o.etcdTarget == "" {
		return errors.New("step etcdremove needs -etcd-target")
	}
	if _, err := agent.RemoveEtcdMember(ctx, &pb.RemoveEtcdMemberRequest{Target: o.etcdTarget}, opt); err != nil {
		return fmt.Errorf("RemoveEtcdMember: %w", err)
	}
	slog.Info("RemoveEtcdMember", "target", o.etcdTarget, "result", "ok")
	return nil
}

// kubeadmReset is the second half of cleanBeforeControlPlaneRejoin: kubeadm reset on the node that
// joins, with no etcd member removal (provision_node.go:628-647).
func kubeadmReset(ctx context.Context, agent pb.NodeAgentClient, opt grpc.CallOption) error {
	begin := time.Now()
	resp, err := agent.ExecuteKubeadmReset(ctx, &pb.KubeadmResetRequest{SkipPhases: []string{"remove-etcd-member"}}, opt)
	if err != nil {
		return fmt.Errorf("ExecuteKubeadmReset: %w", err)
	}
	slog.Info("ExecuteKubeadmReset", "status", resp.GetStatus(), "seconds", fmt.Sprintf("%.1f", time.Since(begin).Seconds()))
	_, err = kubeadmStatus(ctx, agent, opt)
	return err
}

// kubeadmJoin sends the request of the activity KubeadmJoin (kubeadm_join.go:137-176): the rendered
// join configuration, the join string and the files. The agent starts the join and returns.
func kubeadmJoin(ctx context.Context, agent pb.NodeAgentClient, o *options, opt grpc.CallOption) error {
	config, err := os.ReadFile(o.joinConfig)
	if err != nil {
		return fmt.Errorf("reading -join-config: %w", err)
	}
	joinString, err := os.ReadFile(o.joinStringIn)
	if err != nil {
		return fmt.Errorf("reading -join-string: %w", err)
	}
	resp, err := agent.ExecuteKubeadmJoin(ctx, &pb.KubeadmJoinRequest{
		JoinConfig:        string(config),
		KubeadmJoinString: strings.TrimSpace(string(joinString)),
		Files:             o.files,
	}, opt)
	if err != nil {
		return fmt.Errorf("ExecuteKubeadmJoin: %w", err)
	}
	slog.Info("ExecuteKubeadmJoin", "status", resp.GetStatus(), "phase", resp.GetPhase(), "role", resp.GetRole(),
		"error_message", resp.GetErrorMessage(), "files", len(o.files))
	return nil
}

// waitForJoin polls each 10 seconds until the status is ready in the phase join, as the controller
// does (kubeadm_join.go:189-213).
func waitForJoin(ctx context.Context, agent pb.NodeAgentClient, opt grpc.CallOption) error {
	for {
		status, err := kubeadmStatus(ctx, agent, opt)
		if err != nil {
			return err
		}
		switch state := strings.ToLower(status.GetKubeadmStatus()); {
		case state == "error":
			return fmt.Errorf("kubeadm join failed: %s", status.GetKubeadmCurrentMessage())
		case state == "ready" && strings.ToLower(status.GetKubeadmPhase()) == "join":
			return nil
		}
		if err := sleep(ctx, 10*time.Second); err != nil {
			return err
		}
	}
}

func sleep(ctx context.Context, d time.Duration) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(d):
		return nil
	}
}
