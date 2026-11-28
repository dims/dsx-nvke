// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package controllers

import (
	"context"
	"fmt"
	"log/slog"

	corev1 "k8s.io/api/core/v1"
	apiequality "k8s.io/apimachinery/pkg/api/equality"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/utils/ptr"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/builder"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	infrav1 "github.com/dsx-ai-factory/nvke/cluster-api-provider-podvm/api/v1alpha1"
)

// +kubebuilder:rbac:groups=infrastructure.cluster.x-k8s.io,resources=podvmclusters,verbs=get;list;patch;watch
// +kubebuilder:rbac:groups=infrastructure.cluster.x-k8s.io,resources=podvmclusters/status,verbs=patch
// +kubebuilder:rbac:groups="",resources=namespaces,verbs=get
// +kubebuilder:rbac:groups="",resources=nodes,verbs=list;watch
// +kubebuilder:rbac:groups="",resources=services,verbs=create;delete;get;list;watch

// ClusterReconciler checks the spec of a PodVMCluster, publishes the failure
// domains of the host cluster, makes the Service of the control plane endpoint
// when the spec asks for one, and reports the cluster as provisioned.
//
// Reporting the cluster is not optional. The core Cluster API machine
// controller waits for status.initialization.provisioned on the infrastructure
// cluster before it acts on any machine, so a cluster that never reports it
// stops every node of the cluster.
type ClusterReconciler struct {
	client    client.Client
	apiReader client.Reader
	logger    *slog.Logger
}

// NewClusterReconciler builds a ClusterReconciler. The API reader reads the
// pod namespace directly from the API server.
func NewClusterReconciler(k8sClient client.Client, apiReader client.Reader, logger *slog.Logger) *ClusterReconciler {
	return &ClusterReconciler{
		client:    k8sClient,
		apiReader: apiReader,
		logger:    logger,
	}
}

// SetupWithManager registers the reconciler with a manager.
//
// The reconciler also watches the nodes of the host cluster, because the
// failure domains come from their labels, and the control plane Services it
// made, because the load balancer writes the address to their status.
func (r *ClusterReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&infrav1.PodVMCluster{}).
		Watches(
			&corev1.Node{},
			handler.EnqueueRequestsFromMapFunc(r.nodeToClusters),
			builder.WithPredicates(nodePlacementChanged()),
		).
		Watches(
			&corev1.Service{},
			handler.EnqueueRequestsFromMapFunc(serviceToCluster),
		).
		Named("podvm-cluster").
		Complete(r)
}

// nodeToClusters maps a node of the host cluster to every PodVMCluster. Each
// of them publishes failure domains from the same nodes.
func (r *ClusterReconciler) nodeToClusters(ctx context.Context, _ client.Object) []reconcile.Request {
	clusters := &infrav1.PodVMClusterList{}
	if err := r.client.List(ctx, clusters); err != nil {
		r.logger.Error("Failed to list PodVMClusters for a node event", "error", err)
		return nil
	}

	requests := make([]reconcile.Request, 0, len(clusters.Items))
	for i := range clusters.Items {
		requests = append(requests, reconcile.Request{
			NamespacedName: client.ObjectKeyFromObject(&clusters.Items[i]),
		})
	}
	return requests
}

// Reconcile checks the spec and reports the state of the cluster.
//
// A cluster with no control plane Service gets no finalizer. Every other
// object of the provider belongs to a PodVMMachine, and each machine records
// the namespace of its objects in its own status, so such a cluster needs no
// cleanup and its delete never waits for the provider. Only a cluster that
// asks for a control plane Service gets a finalizer, which holds it until that
// Service is gone.
func (r *ClusterReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := r.logger.With("namespace", req.Namespace, "podVMCluster", req.Name)

	infraCluster := &infrav1.PodVMCluster{}
	if err := r.client.Get(ctx, req.NamespacedName, infraCluster); err != nil {
		if apierrors.IsNotFound(err) {
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, fmt.Errorf("failed to get PodVMCluster: %w", err)
	}

	if !infraCluster.DeletionTimestamp.IsZero() {
		return r.reconcileDelete(ctx, infraCluster, logger)
	}

	if added, err := r.ensureClusterFinalizer(ctx, infraCluster); err != nil || added {
		return ctrl.Result{RequeueAfter: retryNow}, err
	}

	before := infraCluster.DeepCopy()

	_, problem, err := validateClusterSpec(ctx, r.apiReader, r.client, infraCluster)
	if err != nil {
		return ctrl.Result{}, err
	}
	if problem != nil {
		// Do not clear a provisioned flag that was already reported. The
		// machines of the cluster are running, and withdrawing the flag would
		// stop Cluster API from acting on them.
		logger.Error("Spec of the PodVMCluster is not usable", "reason", problem.reason, "message", problem.message)
		setCondition(infraCluster, metav1.ConditionFalse, problem.reason, problem.message)
		// A missing namespace or an overlap can clear with no change to this
		// object, so look again after a while.
		return ctrl.Result{RequeueAfter: retryAfter}, r.patchStatus(ctx, infraCluster, before)
	}

	nodes := &corev1.NodeList{}
	if err := r.client.List(ctx, nodes); err != nil {
		return ctrl.Result{}, fmt.Errorf("failed to list the nodes of the host cluster: %w", err)
	}
	domains := failureDomainsFromNodes(nodes.Items, infraCluster.FailureDomainLabelKey())
	infraCluster.Status.FailureDomains = domains
	ready := fmt.Sprintf("Spec is valid, %d failure domains", len(domains))

	if infraCluster.Spec.ControlPlaneService != nil {
		address, problem, err := r.reconcileControlPlaneService(ctx, infraCluster, logger)
		if err != nil {
			return ctrl.Result{}, err
		}
		if problem != nil {
			// The cluster is not provisioned before its endpoint has an
			// address: the first node of the cluster needs it. A flag that
			// was already reported stays, as for an unusable spec.
			logger.Info("Control plane Service is not ready", "reason", problem.reason, "message", problem.message)
			setCondition(infraCluster, metav1.ConditionFalse, problem.reason, problem.message)
			// A Service of another owner can go away with no event that
			// reaches this controller, so look again after a while.
			return ctrl.Result{RequeueAfter: retryAfter}, r.patchStatus(ctx, infraCluster, before)
		}
		ready += fmt.Sprintf(", the control plane Service has the address %s", address)
	}

	infraCluster.Status.Initialization.Provisioned = ptr.To(true)
	setCondition(infraCluster, metav1.ConditionTrue, infrav1.ClusterSpecValidReason, ready)

	if err := r.patchStatus(ctx, infraCluster, before); err != nil {
		return ctrl.Result{}, err
	}

	logger.Debug("Reconciled PodVMCluster", "failureDomains", len(domains))
	return ctrl.Result{}, nil
}

// patchStatus writes the status when it differs from the status that the
// reconcile started with.
//
// A PodVMCluster with no finalizer is gone the moment it is deleted. A
// reconcile that started from a cache that still showed it has nothing left
// to do, and that is not an error.
func (r *ClusterReconciler) patchStatus(ctx context.Context, infraCluster, before *infrav1.PodVMCluster) error {
	if apiequality.Semantic.DeepEqual(before.Status, infraCluster.Status) {
		return nil
	}
	if err := r.client.Status().Patch(ctx, infraCluster, client.MergeFrom(before)); err != nil {
		if objectIsGone(ctx, r.apiReader, infraCluster, &infrav1.PodVMCluster{}, err) {
			r.logger.Info("PodVMCluster is gone, nothing is left to do",
				"namespace", infraCluster.Namespace, "podVMCluster", infraCluster.Name)
			return nil
		}
		return fmt.Errorf("failed to update the status of PodVMCluster %s: %w", infraCluster.Name, err)
	}
	return nil
}
