// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package v1alpha1

const (
	// ReadyCondition is the condition type that the Cluster API contract reads
	// on an infrastructure object.
	ReadyCondition = "Ready"
)

// Reasons of the Ready condition of a PodVMCluster.
const (
	// ClusterSpecValidReason means the spec passed every check.
	ClusterSpecValidReason = "SpecValid"

	// PodNamespaceNotFoundReason means the namespace of spec.podNamespace does
	// not exist. The provider does not make it.
	PodNamespaceNotFoundReason = "PodNamespaceNotFound"

	// AddressRangeInvalidReason means spec.addressRange is not usable. The
	// message names the problem.
	AddressRangeInvalidReason = "AddressRangeInvalid"

	// AddressRangeOverlapReason means spec.addressRange overlaps the range of
	// a PodVMCluster that is older. The older cluster keeps its range.
	AddressRangeOverlapReason = "AddressRangeOverlap"
)

// Reasons of the Ready condition of a PodVMMachine.
const (
	// WaitingForOwnerReason means the Cluster API machine controller has not
	// yet set the owner reference on this object.
	WaitingForOwnerReason = "WaitingForOwner"

	// WaitingForClusterReason means the PodVMCluster of this machine does not
	// exist yet.
	WaitingForClusterReason = "WaitingForCluster"

	// WaitingForBootstrapDataReason means the owner Machine names no bootstrap
	// data Secret yet.
	WaitingForBootstrapDataReason = "WaitingForBootstrapData"

	// NoAddressAvailableReason means every address of the range of the
	// cluster is in use.
	NoAddressAvailableReason = "NoAddressAvailable"

	// WaitingForPodReason means the pod exists and does not run yet, or the
	// pod of a provisioned machine was lost and its new pod does not run yet.
	WaitingForPodReason = "WaitingForPod"
)
