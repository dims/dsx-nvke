// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package controllers

import (
	"testing"

	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/utils/ptr"
	clusterv1 "sigs.k8s.io/cluster-api/api/core/v1beta2"

	infrav1 "github.com/dsx-ai-factory/nvke/cluster-api-provider-podvm/api/v1alpha1"
)

func TestBuildPodFollowsTheMachineAndTheCluster(t *testing.T) {
	tests := []struct {
		name   string
		mutate func(machine *infrav1.PodVMMachine, owner *clusterv1.Machine, infraCluster *infrav1.PodVMCluster)
		check  func(t *testing.T, pod *corev1.Pod)
	}{
		{
			name: "a worker machine has no control plane label and no readiness probe",
			mutate: func(_ *infrav1.PodVMMachine, owner *clusterv1.Machine, _ *infrav1.PodVMCluster) {
				delete(owner.Labels, clusterv1.MachineControlPlaneLabel)
			},
			check: func(t *testing.T, pod *corev1.Pod) {
				require.NotContains(t, pod.Labels, clusterv1.MachineControlPlaneLabel)
				require.Nil(t, pod.Spec.Containers[0].ReadinessProbe)
				// The node agent runs on every node, so a worker has the
				// startup probe too.
				require.Equal(t, int32(15005), pod.Spec.Containers[0].StartupProbe.TCPSocket.Port.IntVal)
			},
		},
		{
			name: "the pull policy of the machine",
			mutate: func(machine *infrav1.PodVMMachine, _ *clusterv1.Machine, _ *infrav1.PodVMCluster) {
				machine.Spec.ImagePullPolicy = corev1.PullNever
			},
			check: func(t *testing.T, pod *corev1.Pod) {
				require.Equal(t, corev1.PullNever, pod.Spec.Containers[0].ImagePullPolicy)
			},
		},
		{
			name: "a network attachment of another namespace",
			mutate: func(_ *infrav1.PodVMMachine, _ *clusterv1.Machine, infraCluster *infrav1.PodVMCluster) {
				infraCluster.Spec.NetworkAttachment.Namespace = "networks"
			},
			check: func(t *testing.T, pod *corev1.Pod) {
				require.Equal(t,
					`[{"name":"nodenet","namespace":"networks","ips":["172.28.1.21/16"],"mac":"02:00:ac:1c:01:15"}]`,
					pod.Annotations[networksAnnotation])
			},
		},
		{
			name: "the prefix length of the node network",
			mutate: func(_ *infrav1.PodVMMachine, _ *clusterv1.Machine, infraCluster *infrav1.PodVMCluster) {
				infraCluster.Spec.AddressRange.PrefixLength = 20
			},
			check: func(t *testing.T, pod *corev1.Pod) {
				require.Equal(t, "172.28.1.21/20", pod.Spec.Containers[0].Env[1].Value)
				require.Contains(t, pod.Annotations[networksAnnotation], `"ips":["172.28.1.21/20"]`)
			},
		},
		{
			name: "the pod name is the name of the Machine, not of the PodVMMachine",
			mutate: func(machine *infrav1.PodVMMachine, owner *clusterv1.Machine, _ *infrav1.PodVMCluster) {
				owner.Name = "machine-name"
				machine.Status.PodName = owner.Name
			},
			check: func(t *testing.T, pod *corev1.Pod) {
				require.Equal(t, "machine-name", pod.Name)
				require.Equal(t, "machine-name", pod.Labels[infrav1.MachineNameLabel])
				require.Equal(t, testMachineName, pod.Labels[infrav1.OwnerNameLabel])
				require.Equal(t, "machine-name", pod.Spec.Containers[0].Env[0].Value)
				require.Equal(t, "machine-name-var", pod.Spec.Volumes[0].PersistentVolumeClaim.ClaimName)
			},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			machine := newAllocatedInfraMachine(testMachineName, "172.28.1.21")
			owner := newOwnerMachine()
			infraCluster := newInfraCluster()
			test.mutate(machine, owner, infraCluster)

			pod, err := buildPod(machine, owner, infraCluster, resourceLabels(machine, owner))
			require.NoError(t, err)
			test.check(t, pod)
		})
	}
}

func TestBuildClaimWithNoStorageClassLeavesTheClassToTheHostCluster(t *testing.T) {
	machine := newAllocatedInfraMachine(testMachineName, testFirstAddress)

	claim := buildClaim(machine, varClaimName(testMachineName),
		infrav1.PodVMVolume{Size: resource.MustParse("20Gi")}, nil)

	require.Nil(t, claim.Spec.StorageClassName)
	require.Equal(t, ptr.To(corev1.PersistentVolumeBlock), claim.Spec.VolumeMode)
}

// The failure domain that the NVKE controller writes on the Machine becomes a
// node rule of the pod. The rule is required: the NVKE controller counts on it
// when it spreads the control plane.
func TestPodAffinityTurnsTheFailureDomainIntoANodeRule(t *testing.T) {
	tests := []struct {
		name          string
		failureDomain string
		labelKey      string
		wantTerms     []corev1.NodeSelectorTerm
	}{
		{
			name:          "no failure domain, no node rule",
			failureDomain: "",
			wantTerms:     nil,
		},
		{
			name:          "the default key: the zone, or the host node with that name",
			failureDomain: "zone-a",
			wantTerms: []corev1.NodeSelectorTerm{
				nodeTerm("topology.kubernetes.io/zone", "zone-a"),
				nodeTerm("kubernetes.io/hostname", "zone-a"),
			},
		},
		{
			name:          "a host node as the failure domain of a cluster with no zone label",
			failureDomain: "host-2",
			wantTerms: []corev1.NodeSelectorTerm{
				nodeTerm("topology.kubernetes.io/zone", "host-2"),
				nodeTerm("kubernetes.io/hostname", "host-2"),
			},
		},
		{
			name:          "a label key of the operator",
			failureDomain: "rack-7",
			labelKey:      "example.com/rack",
			wantTerms: []corev1.NodeSelectorTerm{
				nodeTerm("example.com/rack", "rack-7"),
				nodeTerm("kubernetes.io/hostname", "rack-7"),
			},
		},
		{
			name:          "the host name label as the key gives one term",
			failureDomain: "host-2",
			labelKey:      "kubernetes.io/hostname",
			wantTerms: []corev1.NodeSelectorTerm{
				nodeTerm("kubernetes.io/hostname", "host-2"),
			},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			owner := newOwnerMachine()
			owner.Spec.FailureDomain = test.failureDomain
			infraCluster := newInfraCluster()
			infraCluster.Spec.FailureDomainLabelKey = test.labelKey

			affinity := podAffinity(owner, infraCluster)

			if test.wantTerms == nil {
				require.Nil(t, affinity.NodeAffinity)
			} else {
				require.Equal(t, test.wantTerms,
					affinity.NodeAffinity.RequiredDuringSchedulingIgnoredDuringExecution.NodeSelectorTerms)
				require.Empty(t, affinity.NodeAffinity.PreferredDuringSchedulingIgnoredDuringExecution)
			}

			// The pods of one cluster prefer different host nodes. A strict
			// rule would stop the extra pod of a rollout.
			require.Empty(t, affinity.PodAntiAffinity.RequiredDuringSchedulingIgnoredDuringExecution)
			require.Equal(t, []corev1.WeightedPodAffinityTerm{{
				Weight: 100,
				PodAffinityTerm: corev1.PodAffinityTerm{
					LabelSelector: &metav1.LabelSelector{
						MatchLabels: map[string]string{clusterv1.ClusterNameLabel: testClusterName},
					},
					TopologyKey: "kubernetes.io/hostname",
				},
			}}, affinity.PodAntiAffinity.PreferredDuringSchedulingIgnoredDuringExecution)
		})
	}
}

func nodeTerm(key, value string) corev1.NodeSelectorTerm {
	return corev1.NodeSelectorTerm{MatchExpressions: []corev1.NodeSelectorRequirement{{
		Key: key, Operator: corev1.NodeSelectorOpIn, Values: []string{value},
	}}}
}
