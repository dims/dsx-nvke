// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package controllers

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/utils/ptr"
	clusterv1 "sigs.k8s.io/cluster-api/api/core/v1beta2"
	"sigs.k8s.io/controller-runtime/pkg/client"

	infrav1 "github.com/dsx-ai-factory/nvke/cluster-api-provider-podvm/api/v1alpha1"
)

// The pod is the contract with the node image. Each assertion is one point of
// that contract, so a change here is a change that the image must follow.
func TestMachineReconcilerMakesThePodOfTheContract(t *testing.T) {
	reconciler, k8sClient := newMachineReconcilerForTest(t, machineObjects(newInfraMachine(testMachineName))...)
	reconcileMachine(t, reconciler, testMachineName)

	pod := getPod(t, k8sClient, testMachineName)

	// Name, hostname and namespace. An empty spec.hostname means the pod name.
	require.Equal(t, testMachineName, pod.Name)
	require.Equal(t, testPodNamespace, pod.Namespace)
	require.Empty(t, pod.Spec.Hostname)

	// Runtime class, and no link to the host cluster.
	require.Equal(t, ptr.To(testRuntimeClass), pod.Spec.RuntimeClassName)
	require.Equal(t, ptr.To(false), pod.Spec.AutomountServiceAccountToken)
	require.Equal(t, ptr.To(false), pod.Spec.EnableServiceLinks)
	require.Equal(t, corev1.RestartPolicyAlways, pod.Spec.RestartPolicy)

	// A pod that is deleted gets 20 seconds to stop. A control plane node does
	// not stop by itself in the default of 30 seconds, so the default only
	// makes each new pod wait longer.
	require.Equal(t, ptr.To(int64(20)), pod.Spec.TerminationGracePeriodSeconds)

	// One privileged container named node, with the entry point of the image.
	require.Len(t, pod.Spec.Containers, 1)
	require.Empty(t, pod.Spec.InitContainers)
	container := pod.Spec.Containers[0]
	require.Equal(t, "node", container.Name)
	require.Equal(t, testImage, container.Image)
	require.Empty(t, container.Command)
	require.Empty(t, container.Args)
	require.Equal(t, ptr.To(true), container.SecurityContext.Privileged)
	require.Empty(t, container.ImagePullPolicy)

	// Requests are equal to limits.
	wantResources := corev1.ResourceList{
		corev1.ResourceCPU:    resource.MustParse("2"),
		corev1.ResourceMemory: resource.MustParse("6Gi"),
	}
	require.True(t, wantResources.Cpu().Equal(*container.Resources.Limits.Cpu()))
	require.True(t, wantResources.Memory().Equal(*container.Resources.Limits.Memory()))
	require.True(t, wantResources.Cpu().Equal(*container.Resources.Requests.Cpu()))
	require.True(t, wantResources.Memory().Equal(*container.Resources.Requests.Memory()))
	require.Len(t, container.Resources.Limits, 2)
	require.Len(t, container.Resources.Requests, 2)

	// The two block devices.
	require.Equal(t, []corev1.VolumeDevice{
		{Name: "var", DevicePath: "/dev/podvm-var"},
		{Name: "etcd", DevicePath: "/dev/podvm-etcd"},
	}, container.VolumeDevices)

	// The bootstrap data: read only, the file "value".
	require.Equal(t, []corev1.VolumeMount{
		{Name: "bootstrap", MountPath: "/etc/podvm/bootstrap", ReadOnly: true},
	}, container.VolumeMounts)
	require.Equal(t, []corev1.Volume{
		{Name: "var", VolumeSource: corev1.VolumeSource{
			PersistentVolumeClaim: &corev1.PersistentVolumeClaimVolumeSource{ClaimName: testMachineName + "-var"},
		}},
		{Name: "etcd", VolumeSource: corev1.VolumeSource{
			PersistentVolumeClaim: &corev1.PersistentVolumeClaimVolumeSource{ClaimName: testMachineName + "-etcd"},
		}},
		{Name: "bootstrap", VolumeSource: corev1.VolumeSource{
			Secret: &corev1.SecretVolumeSource{
				SecretName: testMachineName + "-bootstrap",
				Items:      []corev1.KeyToPath{{Key: "value", Path: "value"}},
			},
		}},
	}, pod.Spec.Volumes)

	// The environment.
	require.Equal(t, []corev1.EnvVar{
		{Name: "PODVM_MACHINE_NAME", Value: testMachineName},
		{Name: "PODVM_NODE_ADDRESS", Value: "172.28.1.1/16"},
		{Name: "PODVM_NODE_INTERFACE", Value: "net1"},
	}, container.Env)

	// The network annotation: one entry, with the name and the namespace of
	// the network attachment, the address and the hardware address.
	require.Equal(t, map[string]string{
		"k8s.v1.cni.cncf.io/networks": `[{"name":"nodenet","namespace":"test-pods","ips":["172.28.1.1/16"],"mac":"02:00:ac:1c:01:01"}]`,
	}, pod.Annotations)

	// The labels. A Service of the caller selects the first two.
	require.Equal(t, map[string]string{
		"cluster.x-k8s.io/cluster-name":                         testClusterName,
		"cluster.x-k8s.io/control-plane":                        "",
		"podvm.infrastructure.cluster.x-k8s.io/machine-name":    testMachineName,
		"podvm.infrastructure.cluster.x-k8s.io/owner-namespace": testNamespace,
		"podvm.infrastructure.cluster.x-k8s.io/owner-name":      testMachineName,
		"podvm.infrastructure.cluster.x-k8s.io/owner-uid":       "uid-" + testMachineName,
	}, pod.Labels)

	// The readiness probe of a control plane machine runs a program of the
	// node image in the container. The program reads the endpoint gate of
	// the node and /readyz of the local API server, so a call from outside
	// the guest cannot take its place. One slow answer must not take the pod
	// out of the shared Service: the probe waits 3 seconds for an answer, and
	// the pod is out after 3 failures in a row.
	require.Equal(t, &corev1.Probe{
		ProbeHandler: corev1.ProbeHandler{Exec: &corev1.ExecAction{
			Command: []string{"/usr/local/bin/podvm-endpoint-ready"},
		}},
		PeriodSeconds:    2,
		TimeoutSeconds:   3,
		FailureThreshold: 3,
	}, container.ReadinessProbe)
	// A pod is out after about 6 seconds of failed answers.
	require.Equal(t, int32(6), container.ReadinessProbe.PeriodSeconds*container.ReadinessProbe.FailureThreshold)
	require.Nil(t, container.LivenessProbe)

	// The startup probe: a TCP connection to the secure port of the node
	// agent, each 2 seconds. The container counts as started when the agent
	// accepts it, and the machine reports its address at that moment.
	require.Equal(t, &corev1.Probe{
		ProbeHandler: corev1.ProbeHandler{TCPSocket: &corev1.TCPSocketAction{
			Port: intstr.FromInt32(15005),
		}},
		PeriodSeconds:    2,
		FailureThreshold: 600,
	}, container.StartupProbe)
	// The node has 20 minutes to come up before the kubelet starts the
	// container again.
	budget := time.Duration(container.StartupProbe.PeriodSeconds*container.StartupProbe.FailureThreshold) * time.Second
	require.Equal(t, 20*time.Minute, budget)
}

func TestMachineReconcilerMakesTheVolumeClaimsAndTheSecretCopy(t *testing.T) {
	reconciler, k8sClient := newMachineReconcilerForTest(t, machineObjects(newInfraMachine(testMachineName))...)
	reconcileMachine(t, reconciler, testMachineName)

	wantLabels := map[string]string{
		clusterv1.ClusterNameLabel:  testClusterName,
		infrav1.MachineNameLabel:    testMachineName,
		infrav1.OwnerNamespaceLabel: testNamespace,
		infrav1.OwnerNameLabel:      testMachineName,
		infrav1.OwnerUIDLabel:       "uid-" + testMachineName,
	}

	for name, size := range map[string]string{
		testMachineName + "-var":  "20Gi",
		testMachineName + "-etcd": "8Gi",
	} {
		claim := &corev1.PersistentVolumeClaim{}
		require.NoError(t, k8sClient.Get(context.Background(),
			client.ObjectKey{Namespace: testPodNamespace, Name: name}, claim))
		require.Equal(t, wantLabels, claim.Labels)
		require.Equal(t, ptr.To(corev1.PersistentVolumeBlock), claim.Spec.VolumeMode)
		require.Equal(t, []corev1.PersistentVolumeAccessMode{corev1.ReadWriteOnce}, claim.Spec.AccessModes)
		require.Equal(t, ptr.To(testStorageClass), claim.Spec.StorageClassName)
		request := claim.Spec.Resources.Requests[corev1.ResourceStorage]
		require.True(t, request.Equal(resource.MustParse(size)), "claim %s asks for %s", name, request.String())
	}

	secretCopy := &corev1.Secret{}
	require.NoError(t, k8sClient.Get(context.Background(),
		client.ObjectKey{Namespace: testPodNamespace, Name: testMachineName + "-bootstrap"}, secretCopy))
	require.Equal(t, wantLabels, secretCopy.Labels)
	require.Equal(t, corev1.SecretTypeOpaque, secretCopy.Type)
	require.Equal(t, map[string][]byte{"value": []byte(testBootstrapData)}, secretCopy.Data)
}

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

// The same rule, through the reconciler: the failure domain of the Machine
// reaches the pod that the provider makes.
func TestMachineReconcilerPlacesThePodInTheFailureDomainOfTheMachine(t *testing.T) {
	owner := newOwnerMachine()
	owner.Spec.FailureDomain = "host-2"
	reconciler, k8sClient := newMachineReconcilerForTest(t,
		newPodNamespace(), newInfraCluster(), newCAPICluster(), owner,
		newBootstrapDataSecret(testMachineName), newInfraMachine(testMachineName),
	)

	reconcileMachine(t, reconciler, testMachineName)

	pod := getPod(t, k8sClient, testMachineName)
	require.Equal(t, []corev1.NodeSelectorTerm{
		nodeTerm("topology.kubernetes.io/zone", "host-2"),
		nodeTerm("kubernetes.io/hostname", "host-2"),
	}, pod.Spec.Affinity.NodeAffinity.RequiredDuringSchedulingIgnoredDuringExecution.NodeSelectorTerms)
}

func nodeTerm(key, value string) corev1.NodeSelectorTerm {
	return corev1.NodeSelectorTerm{MatchExpressions: []corev1.NodeSelectorRequirement{{
		Key: key, Operator: corev1.NodeSelectorOpIn, Values: []string{value},
	}}}
}
