// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package controllers

import (
	"net/netip"

	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	clusterv1 "sigs.k8s.io/cluster-api/api/core/v1beta2"

	infrav1 "github.com/dsx-ai-factory/nvke/cluster-api-provider-podvm/api/v1alpha1"
)

const (
	testNamespace     = "nvke-system"
	testClusterName   = "test"
	testMachineName   = "test-cp-a1b2"
	testPodNamespace  = "test-pods"
	testRuntimeClass  = "kata-test"
	testNetworkName   = "nodenet"
	testImage         = "registry.example/podvm-node:v1.36.4"
	testStorageClass  = "test-block"
	testBootstrapData = "#cloud-config\nruncmd: [\"true\"]\n"

	// The address range of the tests, inside a /16 node network. The first
	// address the provider gives out is 172.28.1.1.
	testCIDR          = "172.28.1.0/24"
	testPrefixLength  = 16
	testFirstAddress  = "172.28.1.1"
	testSecondAddress = "172.28.1.2"
	testFirstMAC      = "02:00:ac:1c:01:01"
	testProviderID    = "podvm://" + testPodNamespace + "/" + testMachineName
)

func newInfraMachine(name string) *infrav1.PodVMMachine {
	isController := true
	return &infrav1.PodVMMachine{
		TypeMeta: metav1.TypeMeta{APIVersion: infrav1.GroupVersion.String(), Kind: "PodVMMachine"},
		ObjectMeta: metav1.ObjectMeta{
			Name: name, Namespace: testNamespace,
			UID:    types.UID("uid-" + name),
			Labels: map[string]string{clusterv1.ClusterNameLabel: testClusterName},
			OwnerReferences: []metav1.OwnerReference{{
				APIVersion: clusterv1.GroupVersion.String(), Kind: "Machine", Name: name, Controller: &isController,
			}},
		},
		Spec: infrav1.PodVMMachineSpec{
			Image: testImage,
			Resources: infrav1.PodVMResources{
				CPU:    resource.MustParse("2"),
				Memory: resource.MustParse("6Gi"),
			},
			Volumes: infrav1.PodVMVolumes{
				Var:  infrav1.PodVMVolume{StorageClassName: testStorageClass, Size: resource.MustParse("20Gi")},
				Etcd: infrav1.PodVMVolume{StorageClassName: testStorageClass, Size: resource.MustParse("8Gi")},
			},
		},
	}
}

// newAllocatedInfraMachine builds a machine that already holds an address and
// records where its pod is, the state after the first reconcile. It does not
// report the address in status.addresses yet: no node agent answers.
func newAllocatedInfraMachine(name, address string) *infrav1.PodVMMachine {
	machine := newInfraMachine(name)
	machine.Status.Address = address
	machine.Status.HardwareAddress = mustHardwareAddress(address)
	machine.Status.PodNamespace = testPodNamespace
	machine.Status.PodName = name
	return machine
}

func mustHardwareAddress(address string) string {
	return hardwareAddress(netip.MustParseAddr(address))
}
