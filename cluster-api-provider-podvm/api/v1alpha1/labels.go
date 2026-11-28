// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package v1alpha1

// Labels that the provider writes on each object it makes in the pod
// namespace: the pod, the two volume claims and the copy of the bootstrap
// Secret.
//
// The pod namespace is not the namespace of the PodVMMachine, so an owner
// reference cannot link the two. These labels are that link. The provider
// changes and deletes an object only when the labels name its PodVMMachine.
const (
	// MachineNameLabel holds the name of the Cluster API Machine. It is also
	// the name of the pod.
	MachineNameLabel = "podvm.infrastructure.cluster.x-k8s.io/machine-name"

	// OwnerNamespaceLabel holds the namespace of the PodVMMachine that owns
	// the object.
	OwnerNamespaceLabel = "podvm.infrastructure.cluster.x-k8s.io/owner-namespace"

	// OwnerNameLabel holds the name of the PodVMMachine that owns the object.
	OwnerNameLabel = "podvm.infrastructure.cluster.x-k8s.io/owner-name"

	// OwnerUIDLabel holds the UID of the PodVMMachine that owns the object. A
	// later PodVMMachine with the same name has another UID, so it never
	// takes over the volumes of an earlier one.
	OwnerUIDLabel = "podvm.infrastructure.cluster.x-k8s.io/owner-uid"
)
