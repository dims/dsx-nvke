// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package v1alpha1

import (
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	clusterv1 "sigs.k8s.io/cluster-api/api/core/v1beta2"
)

const (
	// DefaultFailureDomainLabelKey is the node label that names a failure
	// domain when spec.failureDomainLabelKey is empty.
	DefaultFailureDomainLabelKey = "topology.kubernetes.io/zone"

	// HostNameLabelKey is the node label that names one host node. The provider
	// uses it as the failure domain when no node carries the label of
	// spec.failureDomainLabelKey.
	HostNameLabelKey = "kubernetes.io/hostname"
)

// NetworkAttachmentReference names the NetworkAttachmentDefinition that puts a
// pod on the node network.
type NetworkAttachmentReference struct {
	// Name is the name of the NetworkAttachmentDefinition.
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:MaxLength=253
	Name string `json:"name"`

	// Namespace is the namespace of the NetworkAttachmentDefinition. When it is
	// empty, the provider uses spec.podNamespace.
	// +optional
	// +kubebuilder:validation:MaxLength=63
	Namespace string `json:"namespace,omitempty"`
}

// AddressRange is the block of addresses that the provider gives to the pods
// of one cluster. The provider is the only owner of the block: nothing else
// on the node network may use an address of it.
type AddressRange struct {
	// CIDR is the block of IPv4 addresses, for example 172.28.1.0/24. The
	// provider gives each machine the lowest free address of the block. It
	// does not use the first and the last address of the block, and it does
	// not use the network address and the broadcast address of the node
	// network.
	// +kubebuilder:validation:MinLength=9
	// +kubebuilder:validation:MaxLength=18
	CIDR string `json:"cidr"`

	// PrefixLength is the prefix length of the node network. The provider
	// writes it with each address, for example 172.28.1.21/16. The node
	// network must contain the block of cidr, so the prefix length cannot be
	// larger than the prefix length of cidr.
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=32
	PrefixLength int32 `json:"prefixLength"`
}

// ControlPlaneServiceSpec holds what the load balancer of the host cluster
// needs from the caller for the Service of the control plane.
type ControlPlaneServiceSpec struct {
	// Annotations are the annotations of the Service. An implementation of a
	// load balancer reads its settings from them, for example the fixed
	// address that the Service must get.
	// +optional
	Annotations map[string]string `json:"annotations,omitempty"`

	// LoadBalancerClass names the implementation of the load balancer. When
	// it is empty, the default implementation of the host cluster takes the
	// Service.
	// +optional
	// +kubebuilder:validation:MaxLength=253
	LoadBalancerClass string `json:"loadBalancerClass,omitempty"`

	// ExternalTrafficPolicy is the external traffic policy of the Service.
	// When it is empty, the default of the host cluster applies.
	// +optional
	// +kubebuilder:validation:Enum=Cluster;Local
	ExternalTrafficPolicy corev1.ServiceExternalTrafficPolicy `json:"externalTrafficPolicy,omitempty"`
}

// PodVMClusterSpec defines the desired state of PodVMCluster.
//
// The spec holds no control plane endpoint. The NVKE controller takes the
// endpoint from the controlPlaneEndpoint field of its own cluster API and
// ignores an endpoint on the infrastructure cluster.
// +kubebuilder:validation:XValidation:rule="has(self.controlPlaneService) == has(oldSelf.controlPlaneService)",message="controlPlaneService cannot be added or removed"
type PodVMClusterSpec struct {
	// PodNamespace is the namespace of the host cluster in which the provider
	// makes the pods, the volume claims and the copies of the bootstrap
	// Secrets. The namespace must exist. The provider does not make it and
	// does not delete it.
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:MaxLength=63
	// +kubebuilder:validation:Pattern=`^[a-z0-9]([-a-z0-9]*[a-z0-9])?$`
	// +kubebuilder:validation:XValidation:rule="self == oldSelf",message="podNamespace is immutable"
	PodNamespace string `json:"podNamespace"`

	// RuntimeClassName is the RuntimeClass of each pod. It must name a Kata
	// runtime whose guest kernel has what a Kubernetes node needs.
	//
	// It cannot change. The provider makes the pod of a machine again after a
	// lost pod and after a reboot request, from the cluster as it is then. So
	// a new value would move each machine that exists to another runtime at
	// its next pod, in no order and on the volumes of its old pod. What the
	// RuntimeClass names can change in the host cluster, for example with a
	// new version of the runtime.
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:MaxLength=253
	// +kubebuilder:validation:XValidation:rule="self == oldSelf",message="runtimeClassName is immutable"
	RuntimeClassName string `json:"runtimeClassName"`

	// NetworkAttachment names the NetworkAttachmentDefinition of the node
	// network. Each pod gets one more interface on that network, with a fixed
	// address and a fixed hardware address.
	//
	// It cannot change. The address range is a block of this network, and
	// the machines that exist are on it. With a new value the next pod of
	// each machine would be on another network than the pods that still run,
	// with an address of the same block.
	// +kubebuilder:validation:XValidation:rule="self == oldSelf",message="networkAttachment is immutable"
	NetworkAttachment NetworkAttachmentReference `json:"networkAttachment"`

	// AddressRange is the block of fixed addresses for the pods of this
	// cluster. It must not overlap the block of another PodVMCluster.
	// +kubebuilder:validation:XValidation:rule="self == oldSelf",message="addressRange is immutable"
	AddressRange AddressRange `json:"addressRange"`

	// FailureDomainLabelKey is the node label of the host cluster that names
	// a failure domain. The provider publishes one failure domain for each
	// value of this label. When no node carries the label, the provider
	// publishes one failure domain for each host node, from the label
	// kubernetes.io/hostname.
	// +optional
	// +kubebuilder:default="topology.kubernetes.io/zone"
	// +kubebuilder:validation:MaxLength=317
	FailureDomainLabelKey string `json:"failureDomainLabelKey,omitempty"`

	// ControlPlaneService asks the provider to make the Service of the
	// control plane endpoint: one Service of the type LoadBalancer in
	// spec.podNamespace, with port 6443, that selects the control plane pods
	// of the cluster. The caller gives the address of that Service to the
	// NVKE controller as the controlPlaneEndpoint of the cluster request, so
	// the address must be known before the request. The annotations are the
	// place to ask the load balancer for a fixed address.
	//
	// When the field is not set, the provider makes no Service, and the
	// caller brings the endpoint.
	// +optional
	// +kubebuilder:validation:XValidation:rule="self == oldSelf",message="controlPlaneService is immutable"
	ControlPlaneService *ControlPlaneServiceSpec `json:"controlPlaneService,omitempty"`
}

// PodVMClusterInitializationStatus reports the initialization state that the
// Cluster API contract requires.
// +kubebuilder:validation:MinProperties=1
type PodVMClusterInitializationStatus struct {
	// Provisioned is true when the spec is valid and, with
	// spec.controlPlaneService, when the Service of the control plane has an
	// address. The core Cluster API machine controller waits for this field
	// before it acts on any machine of the cluster.
	// +optional
	Provisioned *bool `json:"provisioned,omitempty"`
}

// PodVMClusterStatus defines the observed state of PodVMCluster.
type PodVMClusterStatus struct {
	// Initialization reports the state that the Cluster API contract requires.
	// +optional
	Initialization PodVMClusterInitializationStatus `json:"initialization,omitempty,omitzero"`

	// FailureDomains lists the failure domains of the host cluster. Each one
	// can hold a control plane machine. Cluster API copies the list to the
	// Cluster, and the NVKE controller picks one domain for each control plane
	// machine.
	// +optional
	// +listType=map
	// +listMapKey=name
	FailureDomains []clusterv1.FailureDomain `json:"failureDomains,omitempty"`

	// Conditions describes the current state.
	// +optional
	Conditions []metav1.Condition `json:"conditions,omitempty"`
}

// +kubebuilder:metadata:labels=cluster.x-k8s.io/provider=infrastructure-podvm
// +kubebuilder:metadata:labels=cluster.x-k8s.io/v1beta2=v1alpha1
// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:scope=Namespaced,categories=cluster-api,shortName=pvmc
// +kubebuilder:printcolumn:name="Provisioned",type="boolean",JSONPath=".status.initialization.provisioned"
// +kubebuilder:printcolumn:name="PodNamespace",type="string",JSONPath=".spec.podNamespace"
// +kubebuilder:printcolumn:name="Addresses",type="string",JSONPath=".spec.addressRange.cidr"
// +kubebuilder:printcolumn:name="Age",type="date",JSONPath=".metadata.creationTimestamp"

// PodVMCluster is the Schema for the podvmclusters API.
type PodVMCluster struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   PodVMClusterSpec   `json:"spec,omitempty"`
	Status PodVMClusterStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// PodVMClusterList contains a list of PodVMCluster.
type PodVMClusterList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []PodVMCluster `json:"items"`
}

func init() {
	objectTypes = append(objectTypes, &PodVMCluster{}, &PodVMClusterList{})
}

// GetConditions returns the set of conditions for this object.
func (c *PodVMCluster) GetConditions() []metav1.Condition {
	return c.Status.Conditions
}

// SetConditions sets conditions for this object.
func (c *PodVMCluster) SetConditions(conditions []metav1.Condition) {
	c.Status.Conditions = conditions
}

// NetworkAttachmentNamespace returns the namespace of the
// NetworkAttachmentDefinition: the one the spec names, or the pod namespace.
func (c *PodVMCluster) NetworkAttachmentNamespace() string {
	if c.Spec.NetworkAttachment.Namespace != "" {
		return c.Spec.NetworkAttachment.Namespace
	}
	return c.Spec.PodNamespace
}

// FailureDomainLabelKey returns the node label that names a failure domain:
// the one the spec names, or the default.
func (c *PodVMCluster) FailureDomainLabelKey() string {
	if c.Spec.FailureDomainLabelKey != "" {
		return c.Spec.FailureDomainLabelKey
	}
	return DefaultFailureDomainLabelKey
}

var (
	_ runtime.Object = &PodVMCluster{}
	_ runtime.Object = &PodVMClusterList{}
)
