// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package controllers

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	apiequality "k8s.io/apimachinery/pkg/api/equality"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/utils/ptr"
	clusterv1 "sigs.k8s.io/cluster-api/api/core/v1beta2"
	capiutil "sigs.k8s.io/cluster-api/util"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller"
	"sigs.k8s.io/controller-runtime/pkg/handler"

	infrav1 "github.com/dsx-ai-factory/nvke/cluster-api-provider-podvm/api/v1alpha1"
)

// +kubebuilder:rbac:groups=cluster.x-k8s.io,resources=clusters,verbs=get;list;watch
// +kubebuilder:rbac:groups=cluster.x-k8s.io,resources=machines,verbs=get;list;watch
// +kubebuilder:rbac:groups=infrastructure.cluster.x-k8s.io,resources=podvmclusters,verbs=get;list;watch
// +kubebuilder:rbac:groups=infrastructure.cluster.x-k8s.io,resources=podvmmachines,verbs=get;list;patch;watch
// +kubebuilder:rbac:groups=infrastructure.cluster.x-k8s.io,resources=podvmmachines/status,verbs=patch
// +kubebuilder:rbac:groups="",resources=pods,verbs=create;delete;get;list;watch
// +kubebuilder:rbac:groups="",resources=persistentvolumeclaims,verbs=create;delete;get
// +kubebuilder:rbac:groups="",resources=secrets,verbs=create;delete;get

const (
	// retryAfter is the wait before the provider looks again at a state that
	// only an operator or another controller can change, for example a
	// missing PodVMCluster or a full address range.
	retryAfter = 30 * time.Second
	// retryNow retries after a conflict or a stale read, which should clear at once.
	retryNow = time.Second

	podVMClusterKind = "PodVMCluster"
	podVMMachineKind = "PodVMMachine"
)

// MachineReconciler makes one pod, two volume claims and one copy of the
// bootstrap Secret for each PodVMMachine, and it deletes them with the machine.
//
// The pod is the node. It runs in a virtual machine through the runtime class
// of the PodVMCluster, and it holds one fixed address of the address range of
// the cluster for the whole life of the machine.
type MachineReconciler struct {
	client    client.Client
	apiReader client.Reader
	logger    *slog.Logger
}

// NewMachineReconciler builds a MachineReconciler. The API reader reads
// directly from the API server: the provider uses it for every read that must
// not be stale, and for Secrets and volume claims, which it does not cache.
func NewMachineReconciler(k8sClient client.Client, apiReader client.Reader, logger *slog.Logger) *MachineReconciler {
	return &MachineReconciler{
		client:    k8sClient,
		apiReader: apiReader,
		logger:    logger,
	}
}

// SetupWithManager registers the reconciler with a manager.
//
// The reconciler also watches the Machines, because the bootstrap data
// arrives there.
//
// One reconcile runs at a time. An address is safe from a second machine only
// because one writer reads the used addresses and then takes a free one.
func (r *MachineReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&infrav1.PodVMMachine{}).
		Watches(
			&clusterv1.Machine{},
			handler.EnqueueRequestsFromMapFunc(
				capiutil.MachineToInfrastructureMapFunc(infrav1.GroupVersion.WithKind(podVMMachineKind)),
			),
		).
		// Keep this at 1. Two workers can both read the used addresses before
		// either one writes, and both then give the same address to their
		// machines. No write fails, because each one goes to another object.
		WithOptions(controller.Options{MaxConcurrentReconciles: 1}).
		Named("podvm-machine").
		Complete(r)
}

// Reconcile brings the pod of a machine to the state that the machine asks
// for, or reports why it cannot.
func (r *MachineReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := r.logger.With("namespace", req.Namespace, "podVMMachine", req.Name)

	machine := &infrav1.PodVMMachine{}
	if err := r.client.Get(ctx, req.NamespacedName, machine); err != nil {
		if apierrors.IsNotFound(err) {
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, fmt.Errorf("failed to get PodVMMachine: %w", err)
	}

	ownerMachine, err := capiutil.GetOwnerMachine(ctx, r.client, machine.ObjectMeta)
	if err != nil {
		return ctrl.Result{}, fmt.Errorf("failed to get owner Machine: %w", err)
	}
	if ownerMachine == nil {
		// Cluster API sets the owner reference shortly after the Machine
		// exists. Until then the cluster, the pod name and the bootstrap data
		// are all unknown.
		logger.Info("Waiting for Machine controller to set the owner reference")
		return ctrl.Result{}, r.setNotReady(ctx, machine, infrav1.WaitingForOwnerReason, "Waiting for the owner Machine")
	}

	infraCluster, found, err := r.infraClusterFor(ctx, machine, ownerMachine)
	if err != nil {
		return ctrl.Result{}, err
	}
	if !found {
		logger.Info("Waiting for the PodVMCluster")
		return ctrl.Result{RequeueAfter: retryAfter},
			r.setNotReady(ctx, machine, infrav1.WaitingForClusterReason, "Waiting for the PodVMCluster")
	}

	if machine.Status.Address == "" {
		if ptr.Deref(ownerMachine.Spec.Bootstrap.DataSecretName, "") == "" {
			// The Machine watch starts the next reconcile when the name is set.
			logger.Info("Waiting for the bootstrap data Secret name on the owner Machine")
			return ctrl.Result{}, r.setNotReady(ctx, machine, infrav1.WaitingForBootstrapDataReason,
				"Waiting for spec.bootstrap.dataSecretName of the owner Machine")
		}

		result, err := r.allocateAddress(ctx, machine, ownerMachine, infraCluster, logger)
		if err != nil || !result.IsZero() {
			return result, err
		}
	}

	return ctrl.Result{}, nil
}

// infraClusterFor finds the PodVMCluster of a machine through the Cluster that
// owns it. The bool reports whether the object exists yet; while it is false
// the caller waits rather than fails.
func (r *MachineReconciler) infraClusterFor(
	ctx context.Context,
	machine *infrav1.PodVMMachine,
	ownerMachine *clusterv1.Machine,
) (*infrav1.PodVMCluster, bool, error) {
	if ownerMachine.Spec.ClusterName == "" {
		return nil, false, fmt.Errorf(
			"machine %s/%s has an empty spec.clusterName",
			ownerMachine.Namespace, ownerMachine.Name,
		)
	}

	cluster := &clusterv1.Cluster{}
	if err := r.client.Get(ctx, client.ObjectKey{
		Namespace: ownerMachine.Namespace,
		Name:      ownerMachine.Spec.ClusterName,
	}, cluster); err != nil {
		if apierrors.IsNotFound(err) {
			return nil, false, nil
		}
		return nil, false, fmt.Errorf("failed to get Cluster %s: %w", ownerMachine.Spec.ClusterName, err)
	}

	// Read the name from the Cluster rather than assume it matches the cluster
	// name. Cluster API treats the infrastructure reference as the only link.
	infraRef := cluster.Spec.InfrastructureRef
	if infraRef.Name == "" {
		return nil, false, nil
	}
	if infraRef.Kind != podVMClusterKind || infraRef.APIGroup != infrav1.GroupName {
		return nil, false, fmt.Errorf(
			"cluster %s/%s has infrastructure %s.%s, not %s.%s",
			cluster.Namespace, cluster.Name, infraRef.Kind, infraRef.APIGroup,
			podVMClusterKind, infrav1.GroupName,
		)
	}

	infraCluster := &infrav1.PodVMCluster{}
	if err := r.client.Get(ctx, client.ObjectKey{
		Namespace: machine.Namespace,
		Name:      infraRef.Name,
	}, infraCluster); err != nil {
		if apierrors.IsNotFound(err) {
			return nil, false, nil
		}
		return nil, false, fmt.Errorf("failed to get PodVMCluster %s: %w", infraRef.Name, err)
	}

	return infraCluster, true, nil
}

// allocateAddress takes a free address of the range of the cluster and records
// it, with the place of the pod, in the status of the machine.
//
// The record is written before any object exists. A delete then always knows
// where to look, and no second machine can take the address.
//
// It does not write status.addresses. That field tells Cluster API and the
// NVKE controller where to call the node, so it follows when the node agent
// answers.
//
// The set of used addresses is read directly from the API server, from every
// PodVMMachine of every namespace. The cache can lag behind a write of the
// reconcile before this one, and a lagging view would give one address to two
// machines.
func (r *MachineReconciler) allocateAddress(
	ctx context.Context,
	machine *infrav1.PodVMMachine,
	ownerMachine *clusterv1.Machine,
	infraCluster *infrav1.PodVMCluster,
	logger *slog.Logger,
) (ctrl.Result, error) {
	checkedRange, problem, err := validateClusterSpec(ctx, r.apiReader, r.client, infraCluster)
	if err != nil {
		return ctrl.Result{}, err
	}
	if problem != nil {
		logger.Error("Cannot take an address from an unusable PodVMCluster", "reason", problem.reason, "message", problem.message)
		return ctrl.Result{RequeueAfter: retryAfter}, r.setNotReady(ctx, machine, problem.reason, problem.message)
	}

	machines := &infrav1.PodVMMachineList{}
	if err := r.apiReader.List(ctx, machines); err != nil {
		return ctrl.Result{}, fmt.Errorf("failed to list PodVMMachines: %w", err)
	}
	for i := range machines.Items {
		current := &machines.Items[i]
		if current.UID == machine.UID && current.Status.Address != "" {
			// The API server already holds an address for this machine, and
			// the cache does not show it yet. Wait for the cache.
			logger.Info("Address is already recorded, waiting for the cache", "address", current.Status.Address)
			return ctrl.Result{RequeueAfter: retryNow}, nil
		}
	}
	allocations := allocationsFromMachines(machines.Items)

	address, found := checkedRange.firstFree(allocations)
	if !found {
		logger.Info("No free address in the range", "range", infraCluster.Spec.AddressRange.CIDR)
		message := fmt.Sprintf("No free address for this machine: every address of %s is in use",
			infraCluster.Spec.AddressRange.CIDR)
		return ctrl.Result{RequeueAfter: retryAfter},
			r.setNotReady(ctx, machine, infrav1.NoAddressAvailableReason, message)
	}

	patch := client.MergeFromWithOptions(machine.DeepCopy(), client.MergeFromWithOptimisticLock{})
	machine.Status.Address = address.String()
	machine.Status.HardwareAddress = hardwareAddress(address)
	machine.Status.PodNamespace = infraCluster.Spec.PodNamespace
	machine.Status.PodName = ownerMachine.Name
	setCondition(machine, metav1.ConditionFalse, infrav1.WaitingForPodReason,
		fmt.Sprintf("Machine holds address %s, the pod is not made yet", address))
	if err := r.client.Status().Patch(ctx, machine, patch); err != nil {
		if apierrors.IsConflict(err) {
			// Another write reached the object first. Look again with a fresh
			// view rather than force this address.
			logger.Info("Conflict while recording an address, retrying", "address", address.String())
			return ctrl.Result{RequeueAfter: retryNow}, nil
		}
		return ctrl.Result{}, fmt.Errorf("failed to record address %s on PodVMMachine %s: %w", address, machine.Name, err)
	}

	logger.Info("Gave an address to the machine",
		"address", machine.Status.Address,
		"hardwareAddress", machine.Status.HardwareAddress,
		"podNamespace", machine.Status.PodNamespace,
		"podName", machine.Status.PodName,
	)
	return ctrl.Result{}, nil
}

// setNotReady reports why the machine is not ready. It never clears
// status.addresses, the provider ID or the provisioned flag: each describes a
// node that the NVKE controller may already know.
func (r *MachineReconciler) setNotReady(
	ctx context.Context,
	machine *infrav1.PodVMMachine,
	reason, message string,
) error {
	before := machine.DeepCopy()
	setCondition(machine, metav1.ConditionFalse, reason, message)
	return r.patchStatus(ctx, machine, before)
}

// patchStatus writes the status when it differs from the given earlier state.
// Most reconciles of a machine that runs change nothing.
func (r *MachineReconciler) patchStatus(ctx context.Context, machine, before *infrav1.PodVMMachine) error {
	if apiequality.Semantic.DeepEqual(before.Status, machine.Status) {
		return nil
	}
	if err := r.client.Status().Patch(ctx, machine, client.MergeFrom(before)); err != nil {
		return fmt.Errorf("failed to update the status of PodVMMachine %s: %w", machine.Name, err)
	}
	return nil
}
