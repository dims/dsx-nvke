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
