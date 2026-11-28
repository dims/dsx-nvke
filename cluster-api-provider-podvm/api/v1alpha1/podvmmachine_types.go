// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package v1alpha1

import (
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	clusterv1 "sigs.k8s.io/cluster-api/api/core/v1beta2"
)

// PodVMResources is the size of the virtual machine of one pod.
type PodVMResources struct {
	// CPU is the CPU count of the virtual machine. The provider writes it as
	// the limit and as the request of the container, because the Kata runtime
	// sizes the virtual machine from the limits.
	CPU resource.Quantity `json:"cpu"`

	// Memory is the memory of the virtual machine. The provider writes it as
	// the limit and as the request of the container.
	Memory resource.Quantity `json:"memory"`
}

// PodVMVolume describes one block volume of a pod.
type PodVMVolume struct {
	// StorageClassName is the storage class of the volume claim. When it is
	// empty, the claim names no class and the host cluster uses its default
	// class.
	// +optional
	// +kubebuilder:validation:MaxLength=253
	StorageClassName string `json:"storageClassName,omitempty"`

	// Size is the size that the volume claim requests.
	Size resource.Quantity `json:"size"`
}

// PodVMVolumes holds the two block volumes of a pod. The provider makes one
// volume claim with the volume mode Block for each of them. The node image
// makes the filesystems.
type PodVMVolumes struct {
	// Var is the volume that the node image mounts at /var. It keeps the
	// state of the node through a new pod, with the SPIRE agent data.
	Var PodVMVolume `json:"var"`

	// Etcd is the volume that the node image mounts at /var/lib/etcd.
	Etcd PodVMVolume `json:"etcd"`
}

// PodVMMachineSpec defines the desired state of PodVMMachine.
// +kubebuilder:validation:XValidation:rule="!has(oldSelf.providerID) || (has(self.providerID) && self.providerID == oldSelf.providerID)",message="providerID is immutable once set"
type PodVMMachineSpec struct {
	// ProviderID names the pod of this machine, in the form
	// podvm://<pod-namespace>/<pod-name>. The provider sets it once, when the
	// node agent in the pod answers for the first time. The provider never
	// changes it and never clears it: a new pod for the same machine has the
	// same name.
	// +optional
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:MaxLength=512
	ProviderID string `json:"providerID,omitempty"`

	// Image is the node image for pods. The entry point of the image runs:
	// the provider sets no command and no arguments. The image carries the
	// Kubernetes version of the node, so a new version is a new image.
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:MaxLength=1024
	Image string `json:"image"`

	// ImagePullPolicy is the pull policy of the node image. When it is empty,
	// the host cluster applies its default.
	// +optional
	// +kubebuilder:validation:Enum=Always;IfNotPresent;Never
	ImagePullPolicy corev1.PullPolicy `json:"imagePullPolicy,omitempty"`

	// Resources is the size of the virtual machine.
	Resources PodVMResources `json:"resources"`

	// Volumes describes the two block volumes of the pod.
	Volumes PodVMVolumes `json:"volumes"`
}

// PodVMMachineInitializationStatus reports the initialization state that the
// Cluster API contract requires.
// +kubebuilder:validation:MinProperties=1
type PodVMMachineInitializationStatus struct {
	// Provisioned is true when the node agent in the pod of the machine
	// answered for the first time. The provider never clears it: a pod that
	// is lost later is made again for the same machine.
	// +optional
	Provisioned *bool `json:"provisioned,omitempty"`
}

// PodVMMachineStatus defines the observed state of PodVMMachine.
type PodVMMachineStatus struct {
	// Initialization reports the state that the Cluster API contract requires.
	// +optional
	Initialization PodVMMachineInitializationStatus `json:"initialization,omitempty,omitzero"`

	// Addresses holds the fixed address of the machine as its internal IP
	// address. Cluster API copies it to the Machine, and the NVKE controller
	// reads it to find the node agent and calls the agent at once. So the
	// provider writes it when the node agent in the pod answers, just before
	// the provider ID, and never clears it. The address itself is in
	// status.address from the allocation on.
	// +optional
	Addresses []clusterv1.MachineAddress `json:"addresses,omitempty"`

	// PodNamespace is the namespace of the pod, of the volume claims and of
	// the copy of the bootstrap Secret. The provider records it before it
	// makes the first of them, so a delete finds them without the
	// PodVMCluster.
	// +optional
	PodNamespace string `json:"podNamespace,omitempty"`

	// PodName is the name of the pod. It is the name of the owner Machine.
	// +optional
	PodName string `json:"podName,omitempty"`

	// Address is the fixed address that this machine holds, with no prefix
	// length. This field is the record of the allocation: the provider
	// derives the set of used addresses from this field of every machine of
	// the cluster. The address is free again when the PodVMMachine is gone.
	// +optional
	Address string `json:"address,omitempty"`

	// HardwareAddress is the fixed hardware address of the pod interface on
	// the node network. The provider derives it from the address.
	// +optional
	HardwareAddress string `json:"hardwareAddress,omitempty"`

	// LastRebootRequest is the value of the reboot annotation of the owner
	// Machine that the provider answered last. The provider answers a new
	// value one time: it deletes the pod, and then makes the pod again.
	// +optional
	LastRebootRequest string `json:"lastRebootRequest,omitempty"`

	// Conditions describes the current state.
	// +optional
	Conditions []metav1.Condition `json:"conditions,omitempty"`
}

// +kubebuilder:metadata:labels=cluster.x-k8s.io/provider=infrastructure-podvm
// +kubebuilder:metadata:labels=cluster.x-k8s.io/v1beta2=v1alpha1
// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:scope=Namespaced,categories=cluster-api,shortName=pvmm
// +kubebuilder:printcolumn:name="Provisioned",type="boolean",JSONPath=".status.initialization.provisioned"
// +kubebuilder:printcolumn:name="Pod",type="string",JSONPath=".status.podName"
// +kubebuilder:printcolumn:name="Address",type="string",JSONPath=".status.address"
// +kubebuilder:printcolumn:name="ProviderID",type="string",JSONPath=".spec.providerID"
// +kubebuilder:printcolumn:name="Age",type="date",JSONPath=".metadata.creationTimestamp"

// PodVMMachine is the Schema for the podvmmachines API.
type PodVMMachine struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	// The three rules below are on this field and not on PodVMMachineSpec,
	// because PodVMMachineTemplate has the same spec type. A template can
	// change.

	// Spec is what the machine is: its node image, its size and its volumes.
	// These three do not change after the machine is made. The provider
	// changes no pod in place, so a new value would only reach the next pod of
	// the machine, on the volumes of the old one. A new image, a new size or
	// new volumes is a new machine, which is what a rollout makes.
	// +kubebuilder:validation:XValidation:rule="self.image == oldSelf.image",message="image is immutable, a new image is a new machine"
	// +kubebuilder:validation:XValidation:rule="self.resources == oldSelf.resources",message="resources is immutable, a new size is a new machine"
	// +kubebuilder:validation:XValidation:rule="self.volumes == oldSelf.volumes",message="volumes is immutable, new volumes are a new machine"
	Spec   PodVMMachineSpec   `json:"spec,omitempty"`
	Status PodVMMachineStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// PodVMMachineList contains a list of PodVMMachine.
type PodVMMachineList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []PodVMMachine `json:"items"`
}

func init() {
	objectTypes = append(objectTypes, &PodVMMachine{}, &PodVMMachineList{})
}

// GetConditions returns the set of conditions for this object.
func (m *PodVMMachine) GetConditions() []metav1.Condition {
	return m.Status.Conditions
}

// SetConditions sets conditions for this object.
func (m *PodVMMachine) SetConditions(conditions []metav1.Condition) {
	m.Status.Conditions = conditions
}

var (
	_ runtime.Object = &PodVMMachine{}
	_ runtime.Object = &PodVMMachineList{}
)
