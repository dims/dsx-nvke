// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package controllers

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"time"

	corev1 "k8s.io/api/core/v1"
	apiequality "k8s.io/apimachinery/pkg/api/equality"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	utilnet "k8s.io/apimachinery/pkg/util/net"
	"k8s.io/utils/ptr"
	clusterv1 "sigs.k8s.io/cluster-api/api/core/v1beta2"
	capiutil "sigs.k8s.io/cluster-api/util"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

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
	// deleteRetry is the wait between two looks at the objects of a machine
	// that is being deleted. A volume claim goes away shortly after its pod,
	// and no event of the claim reaches this controller.
	deleteRetry = 2 * time.Second

	podVMClusterKind = "PodVMCluster"
	podVMMachineKind = "PodVMMachine"

	// machineFinalizer holds a PodVMMachine until its objects are gone. The
	// name has a domain and a path. The API server warns at every write of an
	// object whose finalizer has a domain and no path.
	machineFinalizer = "podvm.infrastructure.cluster.x-k8s.io/machine-cleanup"

	// rebootAnnotation is the annotation on the Machine with which the NVKE
	// controller asks for a hard reboot. Its value is the time of the request.
	// The NVKE controller writes it under this key only, and it removes the
	// annotation itself when the Node reports a new boot ID.
	rebootAnnotation = "nvke.nvidia.com/reboot"
)

// machineProblem is a state that the provider reports in the Ready condition
// and then waits on. It is not a failure of the reconcile.
type machineProblem struct {
	reason  string
	message string
}

func (p *machineProblem) Error() string { return p.message }

// MachineReconciler makes one pod, two volume claims and one copy of the
// bootstrap Secret for each PodVMMachine, and it deletes them with the machine.
//
// The pod is the node. It runs in a virtual machine through the runtime class
// of the PodVMCluster, and it holds one fixed address of the address range of
// the cluster for the whole life of the machine.
type MachineReconciler struct {
	client        client.Client
	apiReader     client.Reader
	tenantClients tenantClientFactory
	logger        *slog.Logger
}

// NewMachineReconciler builds a MachineReconciler. The API reader reads
// directly from the API server: the provider uses it for every read that must
// not be stale, and for Secrets and volume claims, which it does not cache.
func NewMachineReconciler(k8sClient client.Client, apiReader client.Reader, logger *slog.Logger) *MachineReconciler {
	return &MachineReconciler{
		client:        k8sClient,
		apiReader:     apiReader,
		tenantClients: newKubeconfigTenantClientFactory(apiReader, k8sClient.Scheme()),
		logger:        logger,
	}
}

// SetupWithManager registers the reconciler with a manager.
//
// The reconciler also watches the Machines, because the bootstrap data and a
// reboot request arrive there, and the pods it made, because a lost pod must
// come back.
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
		Watches(
			&corev1.Pod{},
			handler.EnqueueRequestsFromMapFunc(podToMachine),
		).
		// Keep this at 1. Two workers can both read the used addresses before
		// either one writes, and both then give the same address to their
		// machines. No write fails, because each one goes to another object.
		WithOptions(controller.Options{MaxConcurrentReconciles: 1}).
		Named("podvm-machine").
		Complete(r)
}

// podToMachine maps a pod to the PodVMMachine that its owner labels name. The
// pod is in another namespace than the machine, so no owner reference exists.
func podToMachine(_ context.Context, obj client.Object) []reconcile.Request {
	labels := obj.GetLabels()
	namespace, name := labels[infrav1.OwnerNamespaceLabel], labels[infrav1.OwnerNameLabel]
	if namespace == "" || name == "" {
		return nil
	}
	return []reconcile.Request{{
		NamespacedName: client.ObjectKey{Namespace: namespace, Name: name},
	}}
}

// Reconcile brings the pod of a machine to the state that the machine asks
// for, or reports why it cannot.
//
// A finalizer holds the PodVMMachine until its pod, its volume claims and its
// copy of the bootstrap Secret are gone. Only then is its address free.
func (r *MachineReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := r.logger.With("namespace", req.Namespace, "podVMMachine", req.Name)

	machine := &infrav1.PodVMMachine{}
	if err := r.client.Get(ctx, req.NamespacedName, machine); err != nil {
		if apierrors.IsNotFound(err) {
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, fmt.Errorf("failed to get PodVMMachine: %w", err)
	}

	if !machine.DeletionTimestamp.IsZero() {
		return r.reconcileDelete(ctx, machine, logger)
	}

	if !controllerutil.ContainsFinalizer(machine, machineFinalizer) {
		// A merge patch replaces the whole list of finalizers. The lock keeps
		// it from dropping a finalizer that another controller added since
		// the read.
		patch := client.MergeFromWithOptions(machine.DeepCopy(), client.MergeFromWithOptimisticLock{})
		controllerutil.AddFinalizer(machine, machineFinalizer)
		if err := r.client.Patch(ctx, machine, patch); err != nil && !apierrors.IsConflict(err) {
			return ctrl.Result{}, fmt.Errorf("failed to add the PodVMMachine finalizer: %w", err)
		}
		return ctrl.Result{RequeueAfter: retryNow}, nil
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

	pod, result, err := r.reconcilePod(ctx, machine, ownerMachine, infraCluster, logger)
	if err != nil || pod == nil {
		return result, err
	}
	return r.reconcileRunningPod(ctx, machine, ownerMachine, pod, logger)
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
// answers. See reconcileRunningPod.
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

// reconcilePod makes the pod of the machine when it does not exist and answers
// a reboot request. It returns the pod when the pod runs and the node agent in
// it answers, and nil while the machine waits for that.
//
// The same rule serves the first pod and every later one. A pod that is gone,
// for any reason, is made again with the same name, claims, address and
// hardware address, so the node comes back with its state.
//
// While a later pod starts, status.addresses, the provider ID and the
// provisioned flag stay as they are. The NVKE controller already knows the
// node by them, and it reads a removed address or provider ID as a lost
// machine, not as a node that restarts. Only the Ready condition says that
// the node is not there yet.
func (r *MachineReconciler) reconcilePod(
	ctx context.Context,
	machine *infrav1.PodVMMachine,
	ownerMachine *clusterv1.Machine,
	infraCluster *infrav1.PodVMCluster,
	logger *slog.Logger,
) (*corev1.Pod, ctrl.Result, error) {
	pod, err := r.ownedPod(ctx, machine)
	if err != nil {
		return r.reportProblem(ctx, machine, err, logger)
	}

	if request := ownerMachine.Annotations[rebootAnnotation]; request != "" && request != machine.Status.LastRebootRequest {
		answered, err := r.answerRebootRequest(ctx, machine, pod, request, logger)
		if err != nil {
			return nil, ctrl.Result{}, err
		}
		if answered && pod != nil {
			// The event of the pod delete starts the reconcile that makes the
			// new pod.
			return nil, ctrl.Result{}, r.setNotReady(ctx, machine, infrav1.WaitingForPodReason,
				fmt.Sprintf("Pod %s/%s is being deleted for the reboot request %q", pod.Namespace, pod.Name, request))
		}
	}

	switch {
	case pod == nil:
		if err := r.createPodResources(ctx, machine, ownerMachine, infraCluster, logger); err != nil {
			return r.reportProblem(ctx, machine, err, logger)
		}
		return nil, ctrl.Result{}, r.setNotReady(ctx, machine, infrav1.WaitingForPodReason,
			fmt.Sprintf("Pod %s/%s is made and does not run yet", machine.Status.PodNamespace, machine.Status.PodName))

	case !pod.DeletionTimestamp.IsZero():
		return nil, ctrl.Result{}, r.setNotReady(ctx, machine, infrav1.WaitingForPodReason,
			fmt.Sprintf("Pod %s/%s is being deleted, a new pod follows", pod.Namespace, pod.Name))

	case pod.Status.Phase == corev1.PodFailed || pod.Status.Phase == corev1.PodSucceeded:
		// The pod ended and never runs again, for example after an eviction.
		// It counts as lost: delete it, and the next reconcile makes it again.
		logger.Warn("Pod ended, deleting it so that a new pod can take its place", "pod", pod.Name, "phase", pod.Status.Phase)
		if err := r.deletePod(ctx, pod); err != nil {
			return nil, ctrl.Result{}, err
		}
		return nil, ctrl.Result{}, r.setNotReady(ctx, machine, infrav1.WaitingForPodReason,
			fmt.Sprintf("Pod %s/%s ended in the phase %s and is replaced", pod.Namespace, pod.Name, pod.Status.Phase))

	case pod.Status.Phase != corev1.PodRunning:
		return nil, ctrl.Result{}, r.setNotReady(ctx, machine, infrav1.WaitingForPodReason,
			fmt.Sprintf("Pod %s/%s does not run yet", pod.Namespace, pod.Name))

	case !nodeAgentAnswers(pod):
		// The virtual machine boots, or the node agent waits for its
		// identity. The event of the pod status starts the next reconcile.
		return nil, ctrl.Result{}, r.setNotReady(ctx, machine, infrav1.WaitingForNodeAgentReason,
			fmt.Sprintf("Pod %s/%s runs, the node agent in it does not answer yet", pod.Namespace, pod.Name))
	}

	return pod, ctrl.Result{}, nil
}

// answerRebootRequest answers one value of the reboot annotation one time: it
// deletes the pod and records the value. The bool reports whether this call
// answered the request.
//
// The provider makes no new pod before the record is written, so a pod that
// exists while the value is not recorded is the pod from before the request.
// The cache can lag behind that record, and then the pod it shows could be
// the new one. So the provider asks the API server for the record before it
// deletes a pod.
func (r *MachineReconciler) answerRebootRequest(
	ctx context.Context,
	machine *infrav1.PodVMMachine,
	pod *corev1.Pod,
	request string,
	logger *slog.Logger,
) (bool, error) {
	current := &infrav1.PodVMMachine{}
	if err := r.apiReader.Get(ctx, client.ObjectKeyFromObject(machine), current); err != nil {
		return false, fmt.Errorf("failed to read the reboot record of PodVMMachine %s: %w", machine.Name, err)
	}
	if current.Status.LastRebootRequest == request {
		logger.Info("Reboot request is already answered, waiting for the cache", "request", request)
		return false, nil
	}

	if pod != nil && pod.DeletionTimestamp.IsZero() {
		logger.Info("Deleting the pod for a reboot request", "pod", pod.Name, "request", request)
		if err := r.deletePod(ctx, pod); err != nil {
			return false, err
		}
	}

	before := machine.DeepCopy()
	machine.Status.LastRebootRequest = request
	return true, r.patchStatus(ctx, machine, before)
}

// reconcileRunningPod reports a machine whose node agent answers: it writes
// status.addresses, then the provider ID, then the provisioned flag, and it
// gives the Node of the new cluster its provider ID.
//
// The NVKE controller waits for an address, stores it one time, and calls the
// node agent at that address a moment later. A failed call costs it a retry
// wait that starts at 30 seconds and grows to 2 minutes. So the address is
// reported here, when the agent answers, and not at the allocation. It is
// written before the provider ID, so no reader ever sees a machine that has a
// provider ID and no address.
//
// A reconcile of a machine in a steady state writes nothing.
func (r *MachineReconciler) reconcileRunningPod(
	ctx context.Context,
	machine *infrav1.PodVMMachine,
	ownerMachine *clusterv1.Machine,
	pod *corev1.Pod,
	logger *slog.Logger,
) (ctrl.Result, error) {
	if len(machine.Status.Addresses) == 0 {
		before := machine.DeepCopy()
		machine.Status.Addresses = []clusterv1.MachineAddress{
			{Type: clusterv1.MachineInternalIP, Address: machine.Status.Address},
		}
		if err := r.patchStatus(ctx, machine, before); err != nil {
			return ctrl.Result{}, err
		}
		logger.Info("Node agent answers, reported the address", "address", machine.Status.Address)
	}

	if machine.Spec.ProviderID == "" {
		patch := client.MergeFromWithOptions(machine.DeepCopy(), client.MergeFromWithOptimisticLock{})
		machine.Spec.ProviderID = infrav1.FormatProviderID(pod.Namespace, pod.Name)
		if err := r.client.Patch(ctx, machine, patch); err != nil {
			if apierrors.IsConflict(err) {
				logger.Info("Conflict while setting the provider ID, retrying")
				return ctrl.Result{RequeueAfter: retryNow}, nil
			}
			return ctrl.Result{}, fmt.Errorf("failed to set the provider ID of PodVMMachine %s: %w", machine.Name, err)
		}
		logger.Info("Node agent answers, set the provider ID", "providerID", machine.Spec.ProviderID)
	}

	// A new cluster has no API server before its first node is initialized,
	// and the pod of this machine may be that node. So the look at the Node
	// never holds back the provisioned flag.
	//
	// A machine that is on its way out gets no look at all. The NVKE
	// controller stops the API servers of a cluster before it deletes the
	// Machines, so the look would only find a closed port.
	//
	// A Machine with a node reference gets no look either. Cluster API sets
	// the reference when it finds the Node by this provider ID, so the work
	// is done. A look in each later run would call the new cluster for
	// nothing, and a cluster that does not answer would hold the one worker
	// of this controller each time.
	var look nodeLook
	var nodeErr error
	switch {
	case !ownerMachine.DeletionTimestamp.IsZero():
		logger.Debug("Owner Machine is being deleted, not looking at the tenant Node")
	case ownerMachine.Status.NodeRef.IsDefined():
		logger.Debug("Owner Machine has a node reference, not looking at the tenant Node")
	default:
		look, nodeErr = r.reconcileNodeProviderID(ctx, machine, ownerMachine, logger)
	}

	before := machine.DeepCopy()
	machine.Status.Initialization.Provisioned = ptr.To(true)
	running := fmt.Sprintf("Pod %s/%s runs and its node agent answers", pod.Namespace, pod.Name)
	switch {
	case look.conflict != nil:
		setCondition(machine, metav1.ConditionFalse, look.conflict.reason, look.conflict.message)
	case look.noAnswer:
		// The machine itself is ready: its pod runs and its node agent
		// answers. The message is the same for every kind of silence, so a
		// second look that fails in another way writes nothing.
		setCondition(machine, metav1.ConditionTrue, infrav1.PodRunningReason,
			running+". The API server of the new cluster does not answer, so the provider ID of the Node is not checked")
	default:
		setCondition(machine, metav1.ConditionTrue, infrav1.PodRunningReason, running)
	}
	if err := r.patchStatus(ctx, machine, before); err != nil {
		return ctrl.Result{}, errors.Join(err, nodeErr)
	}
	return look.result, nodeErr
}

// reconcileDelete deletes the pod, the two volume claims and the copy of the
// bootstrap Secret of a machine, in whatever state the machine is, and removes
// the finalizer when all of them are gone.
//
// It waits for the objects to be gone, not only for the delete calls. The
// address is free the moment the PodVMMachine is gone, and a pod that still
// runs with that address would then share it with a new machine.
func (r *MachineReconciler) reconcileDelete(
	ctx context.Context,
	machine *infrav1.PodVMMachine,
	logger *slog.Logger,
) (ctrl.Result, error) {
	if !controllerutil.ContainsFinalizer(machine, machineFinalizer) {
		return ctrl.Result{}, nil
	}

	// The provider records the pod namespace before it makes the first object.
	// A machine with no record has nothing to delete.
	if machine.Status.PodNamespace != "" && machine.Status.PodName != "" {
		remaining, err := r.deleteMachineResources(ctx, machine, logger)
		if err != nil {
			return ctrl.Result{}, err
		}
		if len(remaining) > 0 {
			logger.Info("Waiting for the objects of the machine to be gone", "remaining", remaining)
			return ctrl.Result{RequeueAfter: deleteRetry}, r.setNotReady(ctx, machine, infrav1.DeletingReason,
				fmt.Sprintf("Waiting for the delete of %v", remaining))
		}
	}

	patch := client.MergeFromWithOptions(machine.DeepCopy(), client.MergeFromWithOptimisticLock{})
	controllerutil.RemoveFinalizer(machine, machineFinalizer)
	if err := r.client.Patch(ctx, machine, patch); err != nil {
		if apierrors.IsConflict(err) {
			return ctrl.Result{RequeueAfter: retryNow}, nil
		}
		return ctrl.Result{}, fmt.Errorf("failed to remove the finalizer from PodVMMachine %s: %w", machine.Name, err)
	}
	logger.Info("Deleted the objects of the machine and released its address", "address", machine.Status.Address)
	return ctrl.Result{}, nil
}

// nodeLook is what one look at the Node of the new cluster found.
type nodeLook struct {
	// result holds the requeue for a state that clears with no help: the Node
	// does not exist yet, or no API server answers.
	result ctrl.Result
	// conflict is set when the Node holds another provider ID. The provider
	// never overwrites it, and the machine is not ready.
	conflict *machineProblem
	// noAnswer is true when no API server of the new cluster answered. The
	// machine stays ready, and the Ready condition says what is not checked.
	noAnswer bool
}

// reconcileNodeProviderID copies the infrastructure identity to the Node of
// the new cluster. The Node can appear long after the pod runs, so missing
// prerequisites cause a timed requeue.
//
// An API server that does not answer is one of those prerequisites, not a
// failed reconcile. It is the normal state of a cluster before its first node
// is initialized and after the NVKE controller reset its control plane nodes
// for a delete. An error stays an error when an API server answered and
// refused the call, for example for missing rights.
func (r *MachineReconciler) reconcileNodeProviderID(
	ctx context.Context,
	machine *infrav1.PodVMMachine,
	ownerMachine *clusterv1.Machine,
	logger *slog.Logger,
) (nodeLook, error) {
	waitFor := nodeLook{result: ctrl.Result{RequeueAfter: retryAfter}}

	cluster := &clusterv1.Cluster{}
	clusterKey := client.ObjectKey{Namespace: ownerMachine.Namespace, Name: ownerMachine.Spec.ClusterName}
	if err := r.client.Get(ctx, clusterKey, cluster); err != nil {
		if apierrors.IsNotFound(err) {
			logger.Info("Waiting for the CAPI Cluster", "cluster", ownerMachine.Spec.ClusterName)
			return waitFor, nil
		}
		return nodeLook{}, fmt.Errorf("failed to get Cluster for tenant Node: %w", err)
	}

	tenantCtx, cancel := context.WithTimeout(ctx, tenantAPITimeout)
	defer cancel()

	noAnswer := func(action string, err error) (nodeLook, error) {
		logger.Info("API server of the new cluster does not answer, the provider ID of the Node waits",
			"cluster", cluster.Name, "node", ownerMachine.Name, "action", action, "error", err)
		return nodeLook{result: ctrl.Result{RequeueAfter: retryAfter}, noAnswer: true}, nil
	}

	tenantClient, err := r.tenantClients.ClientForCluster(tenantCtx, cluster)
	if err != nil {
		if apierrors.IsNotFound(err) {
			logger.Info("Waiting for the tenant kubeconfig Secret", "cluster", cluster.Name)
			return waitFor, nil
		}
		if tenantAPIServerGaveNoAnswer(err) {
			return noAnswer("create tenant client", err)
		}
		return nodeLook{}, fmt.Errorf("failed to create tenant client: %w", err)
	}

	node := &corev1.Node{}
	if err := tenantClient.Get(tenantCtx, client.ObjectKey{Name: ownerMachine.Name}, node); err != nil {
		if apierrors.IsNotFound(err) {
			logger.Info("Waiting for the tenant Node", "node", ownerMachine.Name)
			return waitFor, nil
		}
		if tenantAPIServerGaveNoAnswer(err) {
			return noAnswer("get tenant Node", err)
		}
		return nodeLook{}, fmt.Errorf("failed to get tenant Node: %w", err)
	}
	if node.Spec.ProviderID == machine.Spec.ProviderID {
		return nodeLook{}, nil
	}
	if node.Spec.ProviderID != "" {
		logger.Error("Tenant Node holds a different provider ID", "node", node.Name,
			"providerID", node.Spec.ProviderID, "expectedProviderID", machine.Spec.ProviderID)
		return nodeLook{conflict: &machineProblem{
			reason: infrav1.NodeProviderIDConflictReason,
			message: fmt.Sprintf("Tenant Node %s has provider ID %q, expected %q",
				node.Name, node.Spec.ProviderID, machine.Spec.ProviderID),
		}}, nil
	}

	patch := client.MergeFromWithOptions(node.DeepCopy(), client.MergeFromWithOptimisticLock{})
	node.Spec.ProviderID = machine.Spec.ProviderID
	if err := tenantClient.Patch(tenantCtx, node, patch); err != nil {
		if apierrors.IsConflict(err) {
			logger.Info("Tenant Node changed while setting its provider ID; retrying", "node", node.Name)
			return nodeLook{result: ctrl.Result{RequeueAfter: retryNow}}, nil
		}
		if tenantAPIServerGaveNoAnswer(err) {
			return noAnswer("patch tenant Node", err)
		}
		return nodeLook{}, fmt.Errorf("failed to patch tenant Node provider ID: %w", err)
	}

	logger.Info("Set tenant Node provider ID", "node", node.Name, "providerID", node.Spec.ProviderID)
	return nodeLook{}, nil
}

// tenantAPIServerGaveNoAnswer reports whether a call to the new cluster failed
// because no API server answered it: the connection was refused or reset, the
// call ran into its time limit, or the server said that it cannot serve now.
//
// An answer of an API server that rejects the call is not in this set. A
// forbidden or an invalid call does not get better by waiting.
func tenantAPIServerGaveNoAnswer(err error) bool {
	var networkErr net.Error
	return errors.As(err, &networkErr) ||
		errors.Is(err, context.DeadlineExceeded) ||
		utilnet.IsConnectionRefused(err) ||
		utilnet.IsConnectionReset(err) ||
		utilnet.IsProbableEOF(err) ||
		apierrors.IsServiceUnavailable(err) ||
		apierrors.IsTimeout(err) ||
		apierrors.IsServerTimeout(err)
}

// reportProblem turns a machineProblem into the Ready condition and a timed
// requeue. Any other error goes back to the caller as a failed reconcile. It
// has the result form of reconcilePod, which is its only caller.
func (r *MachineReconciler) reportProblem(
	ctx context.Context,
	machine *infrav1.PodVMMachine,
	err error,
	logger *slog.Logger,
) (*corev1.Pod, ctrl.Result, error) {
	var problem *machineProblem
	if !errors.As(err, &problem) {
		return nil, ctrl.Result{}, err
	}
	logger.Warn("Machine cannot make progress", "reason", problem.reason, "message", problem.message)
	return nil, ctrl.Result{RequeueAfter: retryAfter}, r.setNotReady(ctx, machine, problem.reason, problem.message)
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
