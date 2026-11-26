// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
)

// PodVMMachineTemplateResource holds the machine that Cluster API renders
// from this template.
type PodVMMachineTemplateResource struct {
	// ObjectMeta is copied to the rendered machine. Only labels and annotations
	// are used.
	// +optional
	ObjectMeta metav1.ObjectMeta `json:"metadata,omitempty"`

	// Spec is the spec of the rendered PodVMMachine.
	Spec PodVMMachineSpec `json:"spec"`
}

// PodVMMachineTemplateSpec defines the desired state of PodVMMachineTemplate.
type PodVMMachineTemplateSpec struct {
	// Template is the machine to render.
	Template PodVMMachineTemplateResource `json:"template"`
}

// +kubebuilder:metadata:labels=cluster.x-k8s.io/provider=infrastructure-podvm
// +kubebuilder:metadata:labels=cluster.x-k8s.io/v1beta2=v1alpha1
// +kubebuilder:object:root=true
// +kubebuilder:resource:scope=Namespaced,categories=cluster-api,shortName=pvmmt
// +kubebuilder:printcolumn:name="Age",type="date",JSONPath=".metadata.creationTimestamp"

// PodVMMachineTemplate is the Schema for the podvmmachinetemplates API.
//
// A caller sends this kind as the infra.machineTemplate of the cluster control
// plane configuration or of a node pool. The template carries the node image,
// the size of the virtual machine and the two volumes. The address of each
// machine comes from the PodVMCluster.
type PodVMMachineTemplate struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec PodVMMachineTemplateSpec `json:"spec,omitempty"`
}

// +kubebuilder:object:root=true

// PodVMMachineTemplateList contains a list of PodVMMachineTemplate.
type PodVMMachineTemplateList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []PodVMMachineTemplate `json:"items"`
}

func init() {
	objectTypes = append(objectTypes, &PodVMMachineTemplate{}, &PodVMMachineTemplateList{})
}

var (
	_ runtime.Object = &PodVMMachineTemplate{}
	_ runtime.Object = &PodVMMachineTemplateList{}
)
