// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package controllers

import (
	"context"
	"testing"

	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"

	infrav1 "github.com/dsx-ai-factory/nvke/cluster-api-provider-podvm/api/v1alpha1"
)

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

// Two writers must never record two addresses for one machine. The record is
// written with the version of the machine that the provider read. So a write
// that comes second fails, and the provider looks again.
func TestMachineReconcilerDoesNotOverwriteAnAddressThatAnotherWriterRecorded(t *testing.T) {
	reconciler, k8sClient := newMachineReconcilerForTest(t, machineObjects(newInfraMachine(testMachineName))...)
	// Another writer records its address after the provider read the machine
	// and before the provider writes.
	reconciler.client = &racingStatusClient{Client: k8sClient, before: func() {
		machine := getInfraMachine(t, k8sClient, testMachineName)
		machine.Status.Address = "172.28.1.9"
		require.NoError(t, k8sClient.Status().Update(context.Background(), machine))
	}}

	result := reconcileMachine(t, reconciler, testMachineName)

	require.Equal(t, ctrl.Result{RequeueAfter: retryNow}, result)
	require.Equal(t, "172.28.1.9", getInfraMachine(t, k8sClient, testMachineName).Status.Address)
}

// racingStatusClient runs a step of a test just before the first status
// write.
type racingStatusClient struct {
	client.Client
	before func()
}

func (c *racingStatusClient) Status() client.SubResourceWriter {
	return &racingStatusWriter{SubResourceWriter: c.Client.Status(), owner: c}
}

type racingStatusWriter struct {
	client.SubResourceWriter
	owner *racingStatusClient
}

func (w *racingStatusWriter) Patch(ctx context.Context, obj client.Object, patch client.Patch, opts ...client.SubResourcePatchOption) error {
	if w.owner.before != nil {
		w.owner.before()
		w.owner.before = nil
	}
	return w.SubResourceWriter.Patch(ctx, obj, patch, opts...)
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
