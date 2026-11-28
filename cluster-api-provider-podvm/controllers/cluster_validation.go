// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package controllers

import (
	"context"
	"fmt"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"sigs.k8s.io/controller-runtime/pkg/client"

	infrav1 "github.com/dsx-ai-factory/nvke/cluster-api-provider-podvm/api/v1alpha1"
)

// specProblem says why the spec of a PodVMCluster is not usable. The reason is
// a reason of the Ready condition.
type specProblem struct {
	reason  string
	message string
}

// validateClusterSpec checks the spec of a PodVMCluster. It returns the
// checked address range, or the problem that an operator must correct. An
// error means the check itself failed, and the caller tries again.
//
// The cluster controller and the machine controller both call it. The machine
// controller does not trust the status of the cluster: it checks the spec
// again before it takes an address.
func validateClusterSpec(
	ctx context.Context,
	apiReader client.Reader,
	k8sClient client.Reader,
	infraCluster *infrav1.PodVMCluster,
) (addressRange, *specProblem, error) {
	checked, err := parseAddressRange(infraCluster.Spec.AddressRange)
	if err != nil {
		return addressRange{}, &specProblem{reason: infrav1.AddressRangeInvalidReason, message: err.Error()}, nil
	}

	// A direct read: the provider keeps no cache of namespaces, and it needs
	// only the get right for this.
	namespace := &corev1.Namespace{}
	if err := apiReader.Get(ctx, client.ObjectKey{Name: infraCluster.Spec.PodNamespace}, namespace); err != nil {
		if apierrors.IsNotFound(err) {
			return addressRange{}, &specProblem{
				reason:  infrav1.PodNamespaceNotFoundReason,
				message: fmt.Sprintf("Namespace %q does not exist. The provider does not make it", infraCluster.Spec.PodNamespace),
			}, nil
		}
		return addressRange{}, nil, fmt.Errorf("failed to get the pod namespace %s: %w", infraCluster.Spec.PodNamespace, err)
	}

	clusters := &infrav1.PodVMClusterList{}
	if err := k8sClient.List(ctx, clusters); err != nil {
		return addressRange{}, nil, fmt.Errorf("failed to list PodVMClusters: %w", err)
	}
	for i := range clusters.Items {
		other := &clusters.Items[i]
		if other.Namespace == infraCluster.Namespace && other.Name == infraCluster.Name {
			continue
		}
		otherRange, err := parseAddressRange(other.Spec.AddressRange)
		if err != nil {
			// A cluster with an unusable range gives out no address.
			continue
		}
		if !checked.overlaps(otherRange) || !isOlder(other, infraCluster) {
			continue
		}
		return addressRange{}, &specProblem{
			reason: infrav1.AddressRangeOverlapReason,
			message: fmt.Sprintf("Address range %s overlaps the range %s of the older PodVMCluster %s/%s",
				infraCluster.Spec.AddressRange.CIDR, other.Spec.AddressRange.CIDR, other.Namespace, other.Name),
		}, nil
	}

	return checked, nil, nil
}

// isOlder reports whether a was created before b. The older cluster keeps its
// range when two ranges overlap, so a new cluster can never take addresses
// from a cluster that already has machines. Two clusters of the same second
// are ordered by namespace and name, so exactly one of them keeps the range.
func isOlder(a, b *infrav1.PodVMCluster) bool {
	if !a.CreationTimestamp.Equal(&b.CreationTimestamp) {
		return a.CreationTimestamp.Before(&b.CreationTimestamp)
	}
	if a.Namespace != b.Namespace {
		return a.Namespace < b.Namespace
	}
	return a.Name < b.Name
}
