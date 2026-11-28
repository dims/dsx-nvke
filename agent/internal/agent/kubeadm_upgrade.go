// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package agent

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"strings"

	"github.com/Masterminds/semver/v3"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	pb "github.com/dsx-ai-factory/nvke/agent/pkg/agent/proto"
	"github.com/dsx-ai-factory/nvke/agent/pkg/utils"
)

const (
	kubeadmPatchesDir     = "/etc/kubernetes/patches"
	kubeadmUpgradeCommand = "upgrade"
	kubeadmPlanCommand    = "plan"
	kubeadmApplyCommand   = "apply"
	kubeadmAssumeYesFlag  = "-y"
)

// KubeadmUpgradeApply upgrades the control plane and its add-ons to the target
// Kubernetes version. kubeadm upgrade apply is idempotent, so retries run the
// command again to finish any incomplete control-plane or add-on convergence.
// With a control plane endpoint gate, the apply runs with this node out of the
// load balancer: see runKubeadmUpgradeApply.
func (s *NodeAgentServer) KubeadmUpgradeApply(
	ctx context.Context,
	req *pb.KubeadmUpgradeApplyRequest,
) (*pb.KubeadmUpgradeApplyResponse, error) {
	defer logRPCSpan(ctx, "KubeadmUpgradeApply")()

	target, err := semver.StrictNewVersion(strings.TrimSpace(req.GetTargetVersion()))
	if err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "target_version must be a semantic version without a leading v: %v", err)
	}
	targetVersion := "v" + target.String()

	if !s.isControlPlaneRole() {
		return nil, status.Errorf(codes.FailedPrecondition, "kubeadm upgrade apply requires a control-plane node")
	}

	if err := os.MkdirAll(s.rootedPath(kubeadmPatchesDir), 0o755); err != nil {
		return nil, status.Errorf(codes.Internal, "create kubeadm patches directory: %v", err)
	}

	response := &pb.KubeadmUpgradeApplyResponse{TargetVersion: targetVersion}
	planOutput, err := s.Runner.Run("kubeadm", []string{kubeadmUpgradeCommand, kubeadmPlanCommand}, &utils.CommandOptions{})
	response.PlanOutput = string(planOutput)
	if err != nil {
		slog.ErrorContext(ctx, "kubeadm upgrade plan failed", "targetVersion", targetVersion, "err", err)
		return nil, status.Errorf(codes.Internal, "kubeadm upgrade plan failed: %v", err)
	}

	applyArgs := []string{kubeadmUpgradeCommand, kubeadmApplyCommand, targetVersion, "--patches=" + kubeadmPatchesDir, kubeadmAssumeYesFlag}
	applyOutput, err := s.runKubeadmUpgradeApply(ctx, applyArgs)
	response.ApplyOutput = string(applyOutput)
	if err != nil {
		slog.ErrorContext(ctx, "kubeadm upgrade apply failed", "targetVersion", targetVersion, "err", err)
		return nil, status.Errorf(codes.Internal, "kubeadm upgrade apply %s failed: %v", targetVersion, err)
	}

	response.Outcome = pb.KubeadmUpgradeApplyResponse_OUTCOME_APPLIED
	return response, nil
}

// runKubeadmUpgradeApply runs kubeadm upgrade apply, which restarts etcd and
// kube-apiserver of this node. With no control plane endpoint gate it only runs
// the command.
//
// With a gate, the node first leaves the load balancer as it does for a
// graceful shutdown, so that the load balancer stops sending calls here before
// the restart and not after the first calls have failed. kubeadm upgrade plan
// stops nothing and runs before this, with the gate open. A node that cannot
// leave the load balancer does not start the apply.
//
// The gate opens when kubeadm returns, whatever it returns. Nothing waits for
// kube-apiserver first: the health check of the load balancer also needs
// /readyz of the local kube-apiserver, so the node is back only when that
// answers. An agent that dies in between opens the gate at its next start, in
// ReconcileInterruptedStaticPodParks.
//
// The gate stays open on a cluster with one control plane node, and when the
// agent cannot tell how many there are. kubeadm reaches the cluster through the
// control plane endpoint, so with the only node out of the load balancer the
// apply could not read the configuration it applies.
//
// staticPodMutationMu is held from the close to the open, as the gate helpers
// require. That also keeps a second call, which a caller sends when the first
// one outlives its deadline, from opening the gate under the first.
func (s *NodeAgentServer) runKubeadmUpgradeApply(ctx context.Context, args []string) ([]byte, error) {
	apply := func() ([]byte, error) { return s.Runner.Run("kubeadm", args, &utils.CommandOptions{}) }
	if s.ControlPlaneEndpointGate.File == "" {
		return apply()
	}
	switch another, err := s.etcdHasAnotherVotingMember(ctx); {
	case err != nil:
		slog.WarnContext(ctx, "cannot tell whether this is the only control plane node; kubeadm upgrade apply runs with the control plane endpoint gate open", "err", err)
		return apply()
	case !another:
		slog.InfoContext(ctx, "this is the only control plane node; kubeadm upgrade apply runs with the control plane endpoint gate open")
		return apply()
	}

	s.staticPodMutationMu.Lock()
	defer s.staticPodMutationMu.Unlock()

	progress := loggingOperationProgress{reason: "kubeadm-upgrade-apply"}
	var output []byte
	err := s.withdrawThroughControlPlaneEndpointGate(ctx, s.Runner, progress, kubeadmUpgradeApplyGateOwner)
	if err != nil {
		err = fmt.Errorf("not started, because this node did not leave the control plane endpoint: %w", err)
	} else {
		output, err = apply()
	}
	// Also after a withdrawal that failed, which can leave the gate closed.
	if openErr := s.openControlPlaneEndpointGate(progress, kubeadmUpgradeApplyGateOwner); openErr != nil {
		err = errors.Join(err, fmt.Errorf("this node did not return to the control plane endpoint: %w", openErr))
	}
	return output, err
}
