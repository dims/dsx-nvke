// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package controllers

import (
	"context"
	"testing"

	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	clusterv1 "sigs.k8s.io/cluster-api/api/core/v1beta2"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"

	infrav1 "github.com/dsx-ai-factory/nvke/cluster-api-provider-podvm/api/v1alpha1"
)

func TestMachineReconcilerAddsFinalizerBeforeAnythingElse(t *testing.T) {
	machine := newInfraMachine(testMachineName)
	machine.Finalizers = nil
	reconciler, k8sClient := newMachineReconcilerForTest(t, machineObjects(machine)...)

	result := reconcileMachine(t, reconciler, testMachineName)
	require.Equal(t, ctrl.Result{RequeueAfter: retryNow}, result)

	machine = getInfraMachine(t, k8sClient, testMachineName)
	require.Contains(t, machine.Finalizers, machineFinalizer)
	require.Empty(t, machine.Status.Address)
	requireGone(t, k8sClient, &corev1.Pod{}, testMachineName)
}

// Each of these states is a wait, not a failure. The machine takes no address
// and the provider makes no object until the wait is over.
func TestMachineReconcilerWaitsBeforeItTakesAnAddress(t *testing.T) {
	tests := []struct {
		name        string
		objects     func() []client.Object
		wantReason  string
		wantRequeue bool
	}{
		{
			name: "the owner Machine is not set yet",
			objects: func() []client.Object {
				machine := newInfraMachine(testMachineName)
				machine.OwnerReferences = nil
				return machineObjects(machine)
			},
			wantReason: infrav1.WaitingForOwnerReason,
		},
		{
			name: "the PodVMCluster does not exist yet",
			objects: func() []client.Object {
				return []client.Object{
					newPodNamespace(), newCAPICluster(), newOwnerMachine(),
					newBootstrapDataSecret(testMachineName), newInfraMachine(testMachineName),
				}
			},
			wantReason:  infrav1.WaitingForClusterReason,
			wantRequeue: true,
		},
		{
			name: "the Cluster does not exist yet",
			objects: func() []client.Object {
				return []client.Object{
					newPodNamespace(), newInfraCluster(), newOwnerMachine(),
					newBootstrapDataSecret(testMachineName), newInfraMachine(testMachineName),
				}
			},
			wantReason:  infrav1.WaitingForClusterReason,
			wantRequeue: true,
		},
		{
			name: "the owner Machine names no bootstrap data Secret yet",
			objects: func() []client.Object {
				owner := newOwnerMachine()
				owner.Spec.Bootstrap.DataSecretName = nil
				return []client.Object{
					newPodNamespace(), newInfraCluster(), newCAPICluster(), owner, newInfraMachine(testMachineName),
				}
			},
			wantReason: infrav1.WaitingForBootstrapDataReason,
		},
		{
			name: "the pod namespace does not exist",
			objects: func() []client.Object {
				return []client.Object{
					newInfraCluster(), newCAPICluster(), newOwnerMachine(),
					newBootstrapDataSecret(testMachineName), newInfraMachine(testMachineName),
				}
			},
			wantReason:  infrav1.PodNamespaceNotFoundReason,
			wantRequeue: true,
		},
		{
			name: "the address range is not usable",
			objects: func() []client.Object {
				infraCluster := newInfraCluster()
				infraCluster.Spec.AddressRange.CIDR = "2001:db8::/64"
				return []client.Object{
					newPodNamespace(), infraCluster, newCAPICluster(), newOwnerMachine(),
					newBootstrapDataSecret(testMachineName), newInfraMachine(testMachineName),
				}
			},
			wantReason:  infrav1.AddressRangeInvalidReason,
			wantRequeue: true,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			reconciler, k8sClient := newMachineReconcilerForTest(t, test.objects()...)

			result := reconcileMachine(t, reconciler, testMachineName)
			if test.wantRequeue {
				require.Equal(t, retryAfter, result.RequeueAfter)
			} else {
				require.Equal(t, ctrl.Result{}, result)
			}

			machine := getInfraMachine(t, k8sClient, testMachineName)
			require.Empty(t, machine.Status.Address)
			require.Empty(t, machine.Status.Addresses)
			require.Empty(t, machine.Spec.ProviderID)
			require.Nil(t, machine.Status.Initialization.Provisioned)
			requireReadyCondition(t, machine.Status.Conditions, metav1.ConditionFalse, test.wantReason)

			pods := &corev1.PodList{}
			require.NoError(t, k8sClient.List(context.Background(), pods))
			require.Empty(t, pods.Items)
		})
	}
}

func TestMachineReconcilerRejectsAnInfraClusterOfAnotherProvider(t *testing.T) {
	capiCluster := newCAPICluster()
	capiCluster.Spec.InfrastructureRef.Kind = "NicoCluster"

	reconciler, _ := newMachineReconcilerForTest(t,
		capiCluster, newOwnerMachine(), newInfraMachine(testMachineName),
	)

	_, err := reconciler.Reconcile(context.Background(), machineRequest(testMachineName))
	require.ErrorContains(t, err, "not PodVMCluster")
}

// The first reconcile of a new machine: the address, then the Secret copy, the
// claims and the pod. The NVKE controller reads the address from the status,
// so the address must be there while the provider ID is still empty.
func TestMachineReconcilerRecordsTheAddressBeforeTheProviderID(t *testing.T) {
	reconciler, k8sClient := newMachineReconcilerForTest(t, machineObjects(newInfraMachine(testMachineName))...)

	result := reconcileMachine(t, reconciler, testMachineName)
	require.Equal(t, ctrl.Result{}, result)

	machine := getInfraMachine(t, k8sClient, testMachineName)
	require.Equal(t, testFirstAddress, machine.Status.Address)
	require.Equal(t, testFirstMAC, machine.Status.HardwareAddress)
	require.Equal(t, []clusterv1.MachineAddress{
		{Type: clusterv1.MachineInternalIP, Address: testFirstAddress},
	}, machine.Status.Addresses)
	require.Equal(t, testPodNamespace, machine.Status.PodNamespace)
	require.Equal(t, testMachineName, machine.Status.PodName)

	// The pod exists and does not run yet.
	require.Empty(t, machine.Spec.ProviderID)
	require.Nil(t, machine.Status.Initialization.Provisioned)
	requireReadyCondition(t, machine.Status.Conditions, metav1.ConditionFalse, infrav1.WaitingForPodReason)
	require.Equal(t, corev1.PodPhase(""), getPod(t, k8sClient, testMachineName).Status.Phase)
}

func TestMachineReconcilerReportsProvisionedWhenThePodRuns(t *testing.T) {
	reconciler, k8sClient := newMachineReconcilerForTest(t, machineObjects(newInfraMachine(testMachineName))...)

	reconcileMachine(t, reconciler, testMachineName)

	// A pod that is scheduled and pulls its image is not a node yet.
	setPodPhase(t, k8sClient, testMachineName, corev1.PodPending)
	reconcileMachine(t, reconciler, testMachineName)
	machine := getInfraMachine(t, k8sClient, testMachineName)
	require.Empty(t, machine.Spec.ProviderID)
	require.Nil(t, machine.Status.Initialization.Provisioned)

	setPodPhase(t, k8sClient, testMachineName, corev1.PodRunning)
	result := reconcileMachine(t, reconciler, testMachineName)
	// The new cluster has no kubeconfig yet, so the look at the Node waits.
	require.Equal(t, retryAfter, result.RequeueAfter)

	machine = getInfraMachine(t, k8sClient, testMachineName)
	require.Equal(t, testProviderID, machine.Spec.ProviderID)
	require.NotNil(t, machine.Status.Initialization.Provisioned)
	require.True(t, *machine.Status.Initialization.Provisioned)
	require.Equal(t, testFirstAddress, machine.Status.Address)
	requireReadyCondition(t, machine.Status.Conditions, metav1.ConditionTrue, infrav1.PodRunningReason)
}

// A reconcile of a machine in a steady state must write nothing. A write would
// start the next reconcile, and the controller would never rest.
func TestMachineReconcilerWritesNothingInASteadyState(t *testing.T) {
	reconciler, k8sClient := newMachineReconcilerForTest(t, machineObjects(newInfraMachine(testMachineName))...)
	reconcileUntilPodRuns(t, reconciler, k8sClient, testMachineName)
	before := getInfraMachine(t, k8sClient, testMachineName)

	reconcileMachine(t, reconciler, testMachineName)
	reconcileMachine(t, reconciler, testMachineName)

	after := getInfraMachine(t, k8sClient, testMachineName)
	require.Equal(t, before.ResourceVersion, after.ResourceVersion)
}

// Two machines must never hold one address. The second machine sees the
// address of the first because the used set comes from the machines that
// exist.
func TestMachineReconcilerNeverGivesOneAddressToTwoMachines(t *testing.T) {
	objects := machineObjects(newInfraMachine(testMachineName))
	objects = append(objects,
		newOwnerMachineNamed("second"), newBootstrapDataSecret("second"), newInfraMachine("second"),
		newOwnerMachineNamed("third"), newBootstrapDataSecret("third"), newInfraMachine("third"),
	)
	reconciler, k8sClient := newMachineReconcilerForTest(t, objects...)

	for _, name := range []string{testMachineName, "second", "third", testMachineName, "second"} {
		reconcileMachine(t, reconciler, name)
	}

	addresses := map[string]string{}
	for _, name := range []string{testMachineName, "second", "third"} {
		machine := getInfraMachine(t, k8sClient, name)
		require.NotEmpty(t, machine.Status.Address)
		holder, taken := addresses[machine.Status.Address]
		require.False(t, taken, "address %s is held by %s and %s", machine.Status.Address, holder, name)
		addresses[machine.Status.Address] = name
	}
	require.Equal(t, map[string]string{
		"172.28.1.1": testMachineName,
		"172.28.1.2": "second",
		"172.28.1.3": "third",
	}, addresses)
}

// The cache can lag behind the write of the reconcile before. The used set
// comes from the API server, so a lagging cache cannot give the address of
// another machine a second time.
func TestMachineReconcilerReadsUsedAddressesFromTheAPIServer(t *testing.T) {
	// What the API server holds: the other machine has the first address.
	live := newFakeClient(t, append(machineObjects(newInfraMachine(testMachineName)),
		newAllocatedInfraMachine("other", testFirstAddress))...)
	// What the cache shows: the address of the other machine is not there yet.
	cached := newFakeClient(t, append(machineObjects(newInfraMachine(testMachineName)),
		newInfraMachine("other"))...)

	reconciler, _ := newMachineReconcilerForTest(t)
	reconciler.client = cached
	reconciler.apiReader = live

	reconcileMachine(t, reconciler, testMachineName)

	require.Equal(t, testSecondAddress, getInfraMachine(t, cached, testMachineName).Status.Address)
}

// The same lag, for the machine itself: the API server already holds its
// address. A second allocation could pick another address, so the provider
// waits for the cache.
func TestMachineReconcilerDoesNotTakeASecondAddress(t *testing.T) {
	live := newFakeClient(t, machineObjects(newAllocatedInfraMachine(testMachineName, "172.28.1.9"))...)
	cached := newFakeClient(t, machineObjects(newInfraMachine(testMachineName))...)

	reconciler, _ := newMachineReconcilerForTest(t)
	reconciler.client = cached
	reconciler.apiReader = live

	result := reconcileMachine(t, reconciler, testMachineName)
	require.Equal(t, ctrl.Result{RequeueAfter: retryNow}, result)
	require.Empty(t, getInfraMachine(t, cached, testMachineName).Status.Address)
}

// The used set covers every namespace. A machine of another namespace that
// holds an address of this range, which a correct setup never has, still
// keeps the address away from a second machine.
func TestMachineReconcilerSkipsAnAddressHeldInAnotherNamespace(t *testing.T) {
	stray := newAllocatedInfraMachine("stray", testFirstAddress)
	stray.Namespace = "another-namespace"
	reconciler, k8sClient := newMachineReconcilerForTest(t,
		append(machineObjects(newInfraMachine(testMachineName)), stray)...)

	reconcileMachine(t, reconciler, testMachineName)

	require.Equal(t, testSecondAddress, getInfraMachine(t, k8sClient, testMachineName).Status.Address)
}

// A machine that is being deleted keeps its address until it is gone: its pod
// may still run. The address is free for the next machine after that.
func TestMachineReconcilerFreesTheAddressWhenTheMachineIsGone(t *testing.T) {
	objects := machineObjects(newInfraMachine(testMachineName))
	objects = append(objects,
		newOwnerMachineNamed("second"), newBootstrapDataSecret("second"), newInfraMachine("second"),
		newOwnerMachineNamed("third"), newBootstrapDataSecret("third"), newInfraMachine("third"),
	)
	reconciler, k8sClient := newMachineReconcilerForTest(t, objects...)

	reconcileMachine(t, reconciler, testMachineName)
	require.Equal(t, testFirstAddress, getInfraMachine(t, k8sClient, testMachineName).Status.Address)

	// The first machine is being deleted and its pod is not gone yet.
	require.NoError(t, k8sClient.Delete(context.Background(), getInfraMachine(t, k8sClient, testMachineName)))
	reconcileMachine(t, reconciler, "second")
	require.Equal(t, testSecondAddress, getInfraMachine(t, k8sClient, "second").Status.Address)

	// The first machine is gone.
	reconcileMachine(t, reconciler, testMachineName)
	reconcileMachine(t, reconciler, testMachineName)
	machines := &infrav1.PodVMMachineList{}
	require.NoError(t, k8sClient.List(context.Background(), machines))
	require.Len(t, machines.Items, 2)

	reconcileMachine(t, reconciler, "third")
	require.Equal(t, testFirstAddress, getInfraMachine(t, k8sClient, "third").Status.Address)
}

func TestMachineReconcilerReportsAFullAddressRange(t *testing.T) {
	infraCluster := newInfraCluster()
	infraCluster.Spec.AddressRange = infrav1.AddressRange{CIDR: "172.28.1.4/31", PrefixLength: testPrefixLength}

	reconciler, k8sClient := newMachineReconcilerForTest(t,
		newPodNamespace(), infraCluster, newCAPICluster(),
		newOwnerMachine(), newBootstrapDataSecret(testMachineName), newInfraMachine(testMachineName),
		newAllocatedInfraMachine("first", "172.28.1.4"),
		newAllocatedInfraMachine("second", "172.28.1.5"),
	)

	result := reconcileMachine(t, reconciler, testMachineName)
	require.Equal(t, retryAfter, result.RequeueAfter)

	machine := getInfraMachine(t, k8sClient, testMachineName)
	require.Empty(t, machine.Status.Address)
	require.Empty(t, machine.Status.PodName)
	requireReadyCondition(t, machine.Status.Conditions, metav1.ConditionFalse, infrav1.NoAddressAvailableReason)
	requireGone(t, k8sClient, &corev1.Pod{}, testMachineName)
}

// The bootstrap data must be in the pod when the pod starts. With no data the
// provider makes no claim and no pod, and it makes them when the data is there.
func TestMachineReconcilerWaitsForTheBootstrapData(t *testing.T) {
	tests := []struct {
		name   string
		source *corev1.Secret
	}{
		{name: "the Secret does not exist"},
		{name: "the Secret has no value", source: &corev1.Secret{
			ObjectMeta: metav1.ObjectMeta{Name: bootstrapDataSecretName(testMachineName), Namespace: testNamespace},
			Data:       map[string][]byte{"other": []byte("x")},
		}},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			objects := []client.Object{
				newPodNamespace(), newInfraCluster(), newCAPICluster(), newOwnerMachine(), newInfraMachine(testMachineName),
			}
			if test.source != nil {
				objects = append(objects, test.source)
			}
			reconciler, k8sClient := newMachineReconcilerForTest(t, objects...)

			result := reconcileMachine(t, reconciler, testMachineName)
			require.Equal(t, retryAfter, result.RequeueAfter)
			requireReadyCondition(t, getInfraMachine(t, k8sClient, testMachineName).Status.Conditions,
				metav1.ConditionFalse, infrav1.BootstrapDataNotFoundReason)
			requireGone(t, k8sClient, &corev1.Pod{}, testMachineName)
			requireGone(t, k8sClient, &corev1.PersistentVolumeClaim{}, varClaimName(testMachineName))
			requireGone(t, k8sClient, &corev1.Secret{}, bootstrapSecretName(testMachineName))

			// The NVKE controller writes the Secret.
			if test.source != nil {
				require.NoError(t, k8sClient.Delete(context.Background(), test.source))
			}
			require.NoError(t, k8sClient.Create(context.Background(), newBootstrapDataSecret(testMachineName)))

			reconcileMachine(t, reconciler, testMachineName)
			require.Equal(t, testMachineName, getPod(t, k8sClient, testMachineName).Name)
		})
	}
}

// An object with the name that the provider needs and with another owner is
// never changed, never mounted and never deleted.
func TestMachineReconcilerReportsAnObjectOfAnotherOwner(t *testing.T) {
	foreignLabels := map[string]string{infrav1.OwnerUIDLabel: "uid-of-another-machine"}

	tests := []struct {
		name    string
		foreign client.Object
	}{
		{name: "a pod", foreign: &corev1.Pod{ObjectMeta: metav1.ObjectMeta{
			Name: testMachineName, Namespace: testPodNamespace,
		}}},
		{name: "a pod of an earlier machine with the same name", foreign: &corev1.Pod{ObjectMeta: metav1.ObjectMeta{
			Name: testMachineName, Namespace: testPodNamespace, Labels: foreignLabels,
		}}},
		{name: "a volume claim", foreign: &corev1.PersistentVolumeClaim{ObjectMeta: metav1.ObjectMeta{
			Name: etcdClaimName(testMachineName), Namespace: testPodNamespace, Labels: foreignLabels,
		}}},
		{name: "a Secret", foreign: &corev1.Secret{ObjectMeta: metav1.ObjectMeta{
			Name: bootstrapSecretName(testMachineName), Namespace: testPodNamespace,
		}}},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			reconciler, k8sClient := newMachineReconcilerForTest(t,
				append(machineObjects(newInfraMachine(testMachineName)), test.foreign)...)

			result := reconcileMachine(t, reconciler, testMachineName)
			require.Equal(t, retryAfter, result.RequeueAfter)

			machine := getInfraMachine(t, k8sClient, testMachineName)
			requireReadyCondition(t, machine.Status.Conditions, metav1.ConditionFalse, infrav1.ResourceConflictReason)
			require.Empty(t, machine.Spec.ProviderID)

			// The foreign object is as it was, and no pod of the provider exists.
			require.NoError(t, k8sClient.Get(context.Background(), client.ObjectKeyFromObject(test.foreign), test.foreign))
			require.NotEqual(t, string(machine.UID), test.foreign.GetLabels()[infrav1.OwnerUIDLabel])
			pods := &corev1.PodList{}
			require.NoError(t, k8sClient.List(context.Background(), pods,
				client.MatchingLabels{infrav1.OwnerUIDLabel: string(machine.UID)}))
			require.Empty(t, pods.Items)
		})
	}
}

func TestPodToMachine(t *testing.T) {
	tests := []struct {
		name   string
		labels map[string]string
		want   []ctrl.Request
	}{
		{
			name: "a pod of the provider",
			labels: map[string]string{
				infrav1.OwnerNamespaceLabel: testNamespace,
				infrav1.OwnerNameLabel:      testMachineName,
			},
			want: []ctrl.Request{{NamespacedName: types.NamespacedName{Namespace: testNamespace, Name: testMachineName}}},
		},
		{name: "a pod of something else", labels: map[string]string{"app": "other"}},
		{name: "a pod with half of the owner", labels: map[string]string{infrav1.OwnerNameLabel: testMachineName}},
		{name: "a pod with no label"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			pod := &corev1.Pod{ObjectMeta: metav1.ObjectMeta{Name: "pod", Namespace: testPodNamespace, Labels: test.labels}}
			require.Equal(t, test.want, podToMachine(context.Background(), pod))
		})
	}
}
