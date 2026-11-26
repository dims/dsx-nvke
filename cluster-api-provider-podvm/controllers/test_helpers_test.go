// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package controllers

import (
	"context"
	"log/slog"
	"net/netip"
	"testing"

	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/utils/ptr"
	clusterv1 "sigs.k8s.io/cluster-api/api/core/v1beta2"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"

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

	// The lab range: the first address the provider gives out is 172.28.1.1.
	testCIDR          = "172.28.1.0/24"
	testPrefixLength  = 16
	testFirstAddress  = "172.28.1.1"
	testSecondAddress = "172.28.1.2"
	testFirstMAC      = "02:00:ac:1c:01:01"
	testProviderID    = "podvm://" + testPodNamespace + "/" + testMachineName
)

func newTestScheme(t *testing.T) *runtime.Scheme {
	t.Helper()
	scheme := runtime.NewScheme()
	require.NoError(t, corev1.AddToScheme(scheme))
	require.NoError(t, clusterv1.AddToScheme(scheme))
	require.NoError(t, infrav1.AddToScheme(scheme))
	return scheme
}

func newPodNamespace() *corev1.Namespace {
	return &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: testPodNamespace}}
}

func newInfraCluster() *infrav1.PodVMCluster {
	return newInfraClusterNamed(testClusterName, testCIDR)
}

func newInfraClusterNamed(name, cidr string) *infrav1.PodVMCluster {
	return &infrav1.PodVMCluster{
		TypeMeta:   metav1.TypeMeta{APIVersion: infrav1.GroupVersion.String(), Kind: "PodVMCluster"},
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: testNamespace},
		Spec: infrav1.PodVMClusterSpec{
			PodNamespace:      testPodNamespace,
			RuntimeClassName:  testRuntimeClass,
			NetworkAttachment: infrav1.NetworkAttachmentReference{Name: testNetworkName},
			AddressRange:      infrav1.AddressRange{CIDR: cidr, PrefixLength: testPrefixLength},
		},
	}
}

func newCAPICluster() *clusterv1.Cluster {
	return &clusterv1.Cluster{
		TypeMeta:   metav1.TypeMeta{APIVersion: clusterv1.GroupVersion.String(), Kind: "Cluster"},
		ObjectMeta: metav1.ObjectMeta{Name: testClusterName, Namespace: testNamespace},
		Spec: clusterv1.ClusterSpec{InfrastructureRef: clusterv1.ContractVersionedObjectReference{
			APIGroup: infrav1.GroupName, Kind: "PodVMCluster", Name: testClusterName,
		}},
	}
}

func bootstrapDataSecretName(machineName string) string { return machineName + "-bootstrap-data" }

func newOwnerMachine() *clusterv1.Machine { return newOwnerMachineNamed(testMachineName) }

// newOwnerMachineNamed builds a control plane Machine the way the NVKE
// controller does: the cluster label, the control plane label, and the name of
// the bootstrap data Secret.
func newOwnerMachineNamed(name string) *clusterv1.Machine {
	return &clusterv1.Machine{
		TypeMeta: metav1.TypeMeta{APIVersion: clusterv1.GroupVersion.String(), Kind: "Machine"},
		ObjectMeta: metav1.ObjectMeta{
			Name: name, Namespace: testNamespace,
			Labels: map[string]string{
				clusterv1.ClusterNameLabel:         testClusterName,
				clusterv1.MachineControlPlaneLabel: "",
			},
		},
		Spec: clusterv1.MachineSpec{
			ClusterName: testClusterName,
			Bootstrap:   clusterv1.Bootstrap{DataSecretName: ptr.To(bootstrapDataSecretName(name))},
			InfrastructureRef: clusterv1.ContractVersionedObjectReference{
				APIGroup: infrav1.GroupName, Kind: "PodVMMachine", Name: name,
			},
		},
	}
}

func newBootstrapDataSecret(machineName string) *corev1.Secret {
	return &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{Name: bootstrapDataSecretName(machineName), Namespace: testNamespace},
		Type:       corev1.SecretTypeOpaque,
		Data:       map[string][]byte{"value": []byte(testBootstrapData)},
	}
}

func newInfraMachine(name string) *infrav1.PodVMMachine {
	isController := true
	return &infrav1.PodVMMachine{
		TypeMeta: metav1.TypeMeta{APIVersion: infrav1.GroupVersion.String(), Kind: "PodVMMachine"},
		ObjectMeta: metav1.ObjectMeta{
			Name: name, Namespace: testNamespace,
			UID:        types.UID("uid-" + name),
			Labels:     map[string]string{clusterv1.ClusterNameLabel: testClusterName},
			Finalizers: []string{machineFinalizer},
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

// machineObjects returns everything one machine needs to be reconciled.
func machineObjects(machine *infrav1.PodVMMachine) []client.Object {
	return []client.Object{
		newPodNamespace(),
		newInfraCluster(),
		newCAPICluster(),
		newOwnerMachineNamed(machine.Name),
		newBootstrapDataSecret(machine.Name),
		machine,
	}
}

func newFakeClient(t *testing.T, objects ...client.Object) client.Client {
	t.Helper()
	return fake.NewClientBuilder().
		WithScheme(newTestScheme(t)).
		WithObjects(objects...).
		WithStatusSubresource(&infrav1.PodVMMachine{}, &infrav1.PodVMCluster{}, &corev1.Pod{}).
		Build()
}

func newMachineReconcilerForTest(t *testing.T, objects ...client.Object) (*MachineReconciler, client.Client) {
	t.Helper()
	k8sClient := newFakeClient(t, objects...)
	return NewMachineReconciler(k8sClient, k8sClient, slog.New(slog.DiscardHandler)), k8sClient
}

func machineRequest(name string) ctrl.Request {
	return ctrl.Request{NamespacedName: types.NamespacedName{Namespace: testNamespace, Name: name}}
}

func reconcileMachine(t *testing.T, reconciler *MachineReconciler, name string) ctrl.Result {
	t.Helper()
	result, err := reconciler.Reconcile(context.Background(), machineRequest(name))
	require.NoError(t, err)
	return result
}

func getInfraMachine(t *testing.T, k8sClient client.Client, name string) *infrav1.PodVMMachine {
	t.Helper()
	machine := &infrav1.PodVMMachine{}
	require.NoError(t, k8sClient.Get(context.Background(),
		client.ObjectKey{Namespace: testNamespace, Name: name}, machine))
	return machine
}

func getPod(t *testing.T, k8sClient client.Client, name string) *corev1.Pod {
	t.Helper()
	pod := &corev1.Pod{}
	require.NoError(t, k8sClient.Get(context.Background(),
		client.ObjectKey{Namespace: testPodNamespace, Name: name}, pod))
	return pod
}

// requireGone asserts that an object of the pod namespace does not exist.
func requireGone(t *testing.T, k8sClient client.Client, obj client.Object, name string) {
	t.Helper()
	err := k8sClient.Get(context.Background(), client.ObjectKey{Namespace: testPodNamespace, Name: name}, obj)
	require.True(t, apierrors.IsNotFound(err), "expected %T %s to be gone, got %v", obj, name, err)
}

// setPodPhase plays the part of the kubelet. A pod in the phase Running has
// its container, and the startup probe of that container has not passed: the
// virtual machine boots and no node agent answers.
func setPodPhase(t *testing.T, k8sClient client.Client, name string, phase corev1.PodPhase) {
	t.Helper()
	pod := getPod(t, k8sClient, name)
	pod.Status.Phase = phase
	pod.Status.ContainerStatuses = nil
	if phase == corev1.PodRunning {
		pod.Status.ContainerStatuses = []corev1.ContainerStatus{{Name: "node", Started: ptr.To(false)}}
	}
	require.NoError(t, k8sClient.Status().Update(context.Background(), pod))
}

// startNodeAgent plays the kubelet at the moment the startup probe passes: the
// pod runs and the node agent in it accepts a connection.
func startNodeAgent(t *testing.T, k8sClient client.Client, name string) {
	t.Helper()
	pod := getPod(t, k8sClient, name)
	pod.Status.Phase = corev1.PodRunning
	pod.Status.ContainerStatuses = []corev1.ContainerStatus{{Name: "node", Started: ptr.To(true)}}
	require.NoError(t, k8sClient.Status().Update(context.Background(), pod))
}

// reconcileUntilNodeAgentAnswers takes a new machine to the state "the node is
// up": the first reconcile makes the pod, the node agent in it starts to
// answer, the second reconcile sees it.
func reconcileUntilNodeAgentAnswers(t *testing.T, reconciler *MachineReconciler, k8sClient client.Client, name string) {
	t.Helper()
	reconcileMachine(t, reconciler, name)
	startNodeAgent(t, k8sClient, name)
	reconcileMachine(t, reconciler, name)
}

func requireReadyCondition(t *testing.T, conditions []metav1.Condition, status metav1.ConditionStatus, reason string) {
	t.Helper()
	for _, condition := range conditions {
		if condition.Type == infrav1.ReadyCondition {
			require.Equal(t, status, condition.Status, condition.Message)
			require.Equal(t, reason, condition.Reason, condition.Message)
			return
		}
	}
	t.Fatalf("no %s condition found in %v", infrav1.ReadyCondition, conditions)
}

func mustHardwareAddress(address string) string {
	return hardwareAddress(netip.MustParseAddr(address))
}
