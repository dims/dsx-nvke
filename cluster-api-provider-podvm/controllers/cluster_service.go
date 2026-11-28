// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package controllers

import (
	"context"
	"fmt"
	"log/slog"
	"strings"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/apimachinery/pkg/util/validation"
	clusterv1 "sigs.k8s.io/cluster-api/api/core/v1beta2"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	infrav1 "github.com/dsx-ai-factory/nvke/cluster-api-provider-podvm/api/v1alpha1"
)

const (
	// clusterFinalizer holds a PodVMCluster that has a control plane Service
	// until that Service is gone. A cluster with no such Service gets no
	// finalizer.
	clusterFinalizer = "podvm.infrastructure.cluster.x-k8s.io/cluster-cleanup"

	// controlPlaneServiceSuffix follows the name of the Cluster in the name of
	// the control plane Service.
	controlPlaneServiceSuffix = "-control-plane"

	// apiServerPort is the port of the API server in a control plane pod. The
	// Service has the same port, which is the port that kubeadm writes into
	// every kubeconfig when the endpoint names no port.
	apiServerPort     = 6443
	apiServerPortName = "kube-apiserver"

	clusterKind = "Cluster"
)

// serviceToCluster maps a control plane Service to the PodVMCluster that its
// owner labels name. The Service is in another namespace than the cluster, so
// no owner reference exists.
func serviceToCluster(_ context.Context, obj client.Object) []reconcile.Request {
	labels := obj.GetLabels()
	namespace, name := labels[infrav1.OwnerNamespaceLabel], labels[infrav1.OwnerNameLabel]
	if namespace == "" || name == "" {
		return nil
	}
	return []reconcile.Request{{
		NamespacedName: client.ObjectKey{Namespace: namespace, Name: name},
	}}
}

// ownerClusterName returns the name of the Cluster API Cluster that owns the
// PodVMCluster, or "" while Cluster API has not set the owner reference. The
// control plane pods carry that name in a label, and the Service selects it.
func ownerClusterName(infraCluster *infrav1.PodVMCluster) string {
	for _, ref := range infraCluster.OwnerReferences {
		group, _, _ := strings.Cut(ref.APIVersion, "/")
		if ref.Kind == clusterKind && group == clusterv1.GroupVersion.Group {
			return ref.Name
		}
	}
	return ""
}

// ensureClusterFinalizer adds the finalizer to a cluster that asks for a
// control plane Service. The bool reports whether this call wrote it, in
// which case the caller ends the run and reads the object again.
func (r *ClusterReconciler) ensureClusterFinalizer(ctx context.Context, infraCluster *infrav1.PodVMCluster) (bool, error) {
	if infraCluster.Spec.ControlPlaneService == nil || controllerutil.ContainsFinalizer(infraCluster, clusterFinalizer) {
		return false, nil
	}
	// A merge patch replaces the whole list of finalizers. The lock keeps it
	// from dropping a finalizer that another controller added since the read.
	patch := client.MergeFromWithOptions(infraCluster.DeepCopy(), client.MergeFromWithOptimisticLock{})
	controllerutil.AddFinalizer(infraCluster, clusterFinalizer)
	if err := r.client.Patch(ctx, infraCluster, patch); err != nil && !apierrors.IsConflict(err) {
		if objectIsGone(ctx, r.apiReader, infraCluster, &infrav1.PodVMCluster{}, err) {
			return true, nil
		}
		return false, fmt.Errorf("failed to add the PodVMCluster finalizer: %w", err)
	}
	return true, nil
}

// reconcileControlPlaneService makes the Service of the control plane endpoint
// and returns the address that the load balancer gave it. A specProblem is a
// state that the Ready condition reports and that the cluster waits on.
//
// The Service is read directly from the API server. The cache holds only the
// Services that carry the owner labels of the provider, so it cannot show a
// Service of another owner that has the same name.
func (r *ClusterReconciler) reconcileControlPlaneService(
	ctx context.Context,
	infraCluster *infrav1.PodVMCluster,
	logger *slog.Logger,
) (string, *specProblem, error) {
	clusterName := ownerClusterName(infraCluster)
	if clusterName == "" {
		// Cluster API sets the owner reference shortly after the Cluster
		// exists. That write starts the next reconcile.
		return "", &specProblem{
			reason:  infrav1.WaitingForOwnerClusterReason,
			message: "Waiting for the owner Cluster, whose name the control plane Service selects",
		}, nil
	}

	key := client.ObjectKey{Namespace: infraCluster.Spec.PodNamespace, Name: clusterName + controlPlaneServiceSuffix}
	if problems := validation.IsDNS1035Label(key.Name); len(problems) > 0 {
		return "", &specProblem{
			reason: infrav1.ControlPlaneServiceNameInvalidReason,
			message: fmt.Sprintf("%q is not a valid Service name: %s. The name of the Cluster must start with a letter, "+
				"have no dot, and have at most %d characters",
				key.Name, strings.Join(problems, "; "), validation.DNS1035LabelMaxLength-len(controlPlaneServiceSuffix)),
		}, nil
	}

	service := &corev1.Service{}
	err := r.apiReader.Get(ctx, key, service)
	switch {
	case apierrors.IsNotFound(err):
		service = buildControlPlaneService(infraCluster, clusterName, key)
		if err := r.client.Create(ctx, service); err != nil {
			// Also for "already exists": the next reconcile reads the Service
			// and checks whose it is.
			return "", nil, fmt.Errorf("failed to create Service %s: %w", key, err)
		}
		logger.Info("Made the control plane Service", "service", key.Name, "podNamespace", key.Namespace)
	case err != nil:
		return "", nil, fmt.Errorf("failed to get Service %s: %w", key, err)
	case service.Labels[infrav1.OwnerUIDLabel] != string(infraCluster.UID):
		return "", &specProblem{
			reason:  infrav1.ControlPlaneServiceConflictReason,
			message: fmt.Sprintf("Service %s exists and does not belong to this PodVMCluster", key),
		}, nil
	}

	address := loadBalancerAddress(service)
	if address == "" {
		// The event of the Service status starts the next reconcile.
		return "", &specProblem{
			reason:  infrav1.WaitingForLoadBalancerAddressReason,
			message: fmt.Sprintf("Service %s has no address from the load balancer yet", key),
		}, nil
	}
	return address, nil, nil
}

// buildControlPlaneService builds the Service of the control plane endpoint.
// It selects the two labels that the machine controller puts on a control
// plane pod, so only a control plane pod whose readiness probe passes is
// behind it.
func buildControlPlaneService(infraCluster *infrav1.PodVMCluster, clusterName string, key client.ObjectKey) *corev1.Service {
	spec := infraCluster.Spec.ControlPlaneService

	annotations := make(map[string]string, len(spec.Annotations))
	for name, value := range spec.Annotations {
		annotations[name] = value
	}

	service := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{
			Namespace: key.Namespace,
			Name:      key.Name,
			Labels: map[string]string{
				clusterv1.ClusterNameLabel:  clusterName,
				infrav1.OwnerNamespaceLabel: infraCluster.Namespace,
				infrav1.OwnerNameLabel:      infraCluster.Name,
				infrav1.OwnerUIDLabel:       string(infraCluster.UID),
			},
			Annotations: annotations,
		},
		Spec: corev1.ServiceSpec{
			Type: corev1.ServiceTypeLoadBalancer,
			Selector: map[string]string{
				clusterv1.ClusterNameLabel:         clusterName,
				clusterv1.MachineControlPlaneLabel: "",
			},
			Ports: []corev1.ServicePort{{
				Name:       apiServerPortName,
				Protocol:   corev1.ProtocolTCP,
				Port:       apiServerPort,
				TargetPort: intstr.FromInt32(apiServerPort),
			}},
			ExternalTrafficPolicy: spec.ExternalTrafficPolicy,
		},
	}
	if spec.LoadBalancerClass != "" {
		service.Spec.LoadBalancerClass = &spec.LoadBalancerClass
	}
	return service
}

// loadBalancerAddress returns the first address or host name that the load
// balancer reports for the Service, or "" while it reports none.
func loadBalancerAddress(service *corev1.Service) string {
	for _, ingress := range service.Status.LoadBalancer.Ingress {
		if ingress.IP != "" {
			return ingress.IP
		}
		if ingress.Hostname != "" {
			return ingress.Hostname
		}
	}
	return ""
}

// reconcileDelete deletes the control plane Service of a cluster that is being
// deleted, and removes the finalizer when the Service is gone.
//
// It finds the Service by its owner labels and not by its name, so it deletes
// exactly what this PodVMCluster made, also when the owner reference of the
// cluster is gone by then.
func (r *ClusterReconciler) reconcileDelete(
	ctx context.Context,
	infraCluster *infrav1.PodVMCluster,
	logger *slog.Logger,
) (ctrl.Result, error) {
	if !controllerutil.ContainsFinalizer(infraCluster, clusterFinalizer) {
		return ctrl.Result{}, nil
	}

	services := &corev1.ServiceList{}
	if err := r.apiReader.List(ctx, services,
		client.InNamespace(infraCluster.Spec.PodNamespace),
		client.MatchingLabels{infrav1.OwnerUIDLabel: string(infraCluster.UID)},
	); err != nil {
		return ctrl.Result{}, fmt.Errorf("failed to list the Services of PodVMCluster %s: %w", infraCluster.Name, err)
	}
	for i := range services.Items {
		service := &services.Items[i]
		if !service.DeletionTimestamp.IsZero() {
			continue
		}
		err := r.client.Delete(ctx, service, client.Preconditions{UID: &service.UID})
		if err != nil && !apierrors.IsNotFound(err) && !apierrors.IsConflict(err) {
			return ctrl.Result{}, fmt.Errorf("failed to delete Service %s/%s: %w", service.Namespace, service.Name, err)
		}
		logger.Info("Deleted the control plane Service", "service", service.Name, "podNamespace", service.Namespace)
	}
	if len(services.Items) > 0 {
		// A load balancer can hold the Service for a moment with a finalizer
		// of its own.
		return ctrl.Result{RequeueAfter: deleteRetry}, nil
	}

	patch := client.MergeFromWithOptions(infraCluster.DeepCopy(), client.MergeFromWithOptimisticLock{})
	controllerutil.RemoveFinalizer(infraCluster, clusterFinalizer)
	if err := r.client.Patch(ctx, infraCluster, patch); err != nil {
		if apierrors.IsConflict(err) {
			return ctrl.Result{RequeueAfter: retryNow}, nil
		}
		if objectIsGone(ctx, r.apiReader, infraCluster, &infrav1.PodVMCluster{}, err) {
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, fmt.Errorf("failed to remove the finalizer from PodVMCluster %s: %w", infraCluster.Name, err)
	}
	return ctrl.Result{}, nil
}
