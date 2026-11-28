// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package controllers

import (
	"context"
	"testing"

	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"

	infrav1 "github.com/dsx-ai-factory/nvke/cluster-api-provider-podvm/api/v1alpha1"
)

const (
	// podFinalizer keeps a deleted pod in the API server, the way a pod stays
	// while its virtual machine shuts down.
	podFinalizer = "test.example/still-running"
)

// The NVKE controller asks for the Machine delete and does not wait, then
// waits with no end for zero Machines. So the delete of a PodVMMachine must
// finish by itself in every state of the machine.
func TestMachineReconcilerDeletesAMachineInEachState(t *testing.T) {
	tests := []struct {
		name string
		// prepare brings the machine to the state and returns whether the
		// provider made objects for it.
		prepare func(t *testing.T, reconciler *MachineReconciler, k8sClient client.Client) bool
		objects func() []client.Object
	}{
		{
			name:    "no owner Machine yet",
			objects: func() []client.Object { return []client.Object{newInfraMachine(testMachineName)} },
			prepare: func(*testing.T, *MachineReconciler, client.Client) bool { return false },
		},
		{
			name: "no address yet: the machine waits for its cluster",
			objects: func() []client.Object {
				return []client.Object{newPodNamespace(), newOwnerMachine(), newInfraMachine(testMachineName)}
			},
			prepare: func(t *testing.T, reconciler *MachineReconciler, _ client.Client) bool {
				reconcileMachine(t, reconciler, testMachineName)
				return false
			},
		},
		{
			name: "address recorded, no pod yet",
			objects: func() []client.Object {
				return machineObjects(newAllocatedInfraMachine(testMachineName, testFirstAddress))
			},
			prepare: func(*testing.T, *MachineReconciler, client.Client) bool { return false },
		},
		{
			name: "address recorded, the bootstrap data never came",
			objects: func() []client.Object {
				return []client.Object{
					newPodNamespace(), newInfraCluster(), newCAPICluster(), newOwnerMachine(), newInfraMachine(testMachineName),
				}
			},
			prepare: func(t *testing.T, reconciler *MachineReconciler, _ client.Client) bool {
				reconcileMachine(t, reconciler, testMachineName)
				return false
			},
		},
		{
			name:    "pod made and not running",
			objects: func() []client.Object { return machineObjects(newInfraMachine(testMachineName)) },
			prepare: func(t *testing.T, reconciler *MachineReconciler, _ client.Client) bool {
				reconcileMachine(t, reconciler, testMachineName)
				return true
			},
		},
		{
			name:    "pod runs and the node agent does not answer yet",
			objects: func() []client.Object { return machineObjects(newInfraMachine(testMachineName)) },
			prepare: func(t *testing.T, reconciler *MachineReconciler, k8sClient client.Client) bool {
				reconcileMachine(t, reconciler, testMachineName)
				setPodPhase(t, k8sClient, testMachineName, corev1.PodRunning)
				reconcileMachine(t, reconciler, testMachineName)
				return true
			},
		},
		{
			name:    "pod runs",
			objects: func() []client.Object { return machineObjects(newInfraMachine(testMachineName)) },
			prepare: func(t *testing.T, reconciler *MachineReconciler, k8sClient client.Client) bool {
				reconcileUntilNodeAgentAnswers(t, reconciler, k8sClient, testMachineName)
				return true
			},
		},
		{
			name:    "pod runs and the PodVMCluster is already gone",
			objects: func() []client.Object { return machineObjects(newInfraMachine(testMachineName)) },
			prepare: func(t *testing.T, reconciler *MachineReconciler, k8sClient client.Client) bool {
				reconcileUntilNodeAgentAnswers(t, reconciler, k8sClient, testMachineName)
				require.NoError(t, k8sClient.Delete(context.Background(), newInfraCluster()))
				require.NoError(t, k8sClient.Delete(context.Background(), newCAPICluster()))
				return true
			},
		},
		{
			name:    "pod lost and not made again yet",
			objects: func() []client.Object { return machineObjects(newInfraMachine(testMachineName)) },
			prepare: func(t *testing.T, reconciler *MachineReconciler, k8sClient client.Client) bool {
				reconcileUntilNodeAgentAnswers(t, reconciler, k8sClient, testMachineName)
				require.NoError(t, k8sClient.Delete(context.Background(), getPod(t, k8sClient, testMachineName)))
				return true
			},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			reconciler, k8sClient := newMachineReconcilerForTest(t, test.objects()...)
			madeObjects := test.prepare(t, reconciler, k8sClient)

			require.NoError(t, k8sClient.Delete(context.Background(), getInfraMachine(t, k8sClient, testMachineName)))

			result := reconcileMachine(t, reconciler, testMachineName)
			if madeObjects {
				// The first pass deletes, the second sees that all is gone.
				require.Equal(t, ctrl.Result{RequeueAfter: deleteRetry}, result)
				requireReadyCondition(t, getInfraMachine(t, k8sClient, testMachineName).Status.Conditions,
					metav1.ConditionFalse, infrav1.DeletingReason)
				result = reconcileMachine(t, reconciler, testMachineName)
			}
			require.Equal(t, ctrl.Result{}, result)

			// No object and no volume claim is left, and the machine is gone.
			requireGone(t, k8sClient, &corev1.Pod{}, testMachineName)
			requireGone(t, k8sClient, &corev1.PersistentVolumeClaim{}, varClaimName(testMachineName))
			requireGone(t, k8sClient, &corev1.PersistentVolumeClaim{}, etcdClaimName(testMachineName))
			requireGone(t, k8sClient, &corev1.Secret{}, bootstrapSecretName(testMachineName))
			machine := &infrav1.PodVMMachine{}
			err := k8sClient.Get(context.Background(),
				client.ObjectKey{Namespace: testNamespace, Name: testMachineName}, machine)
			require.True(t, apierrors.IsNotFound(err), "the PodVMMachine still exists: %v", err)

			// A late event for the machine that is gone is not an error.
			require.Equal(t, ctrl.Result{}, reconcileMachine(t, reconciler, testMachineName))
		})
	}
}

// The finalizer stays until the pod is really gone. The address is free the
// moment the machine is gone, and a pod that still runs would share it.
func TestMachineReconcilerKeepsTheFinalizerUntilThePodIsGone(t *testing.T) {
	reconciler, k8sClient := newMachineReconcilerForTest(t, machineObjects(newInfraMachine(testMachineName))...)
	reconcileUntilNodeAgentAnswers(t, reconciler, k8sClient, testMachineName)
	holdPod(t, k8sClient, testMachineName)

	require.NoError(t, k8sClient.Delete(context.Background(), getInfraMachine(t, k8sClient, testMachineName)))

	for range 3 {
		result := reconcileMachine(t, reconciler, testMachineName)
		require.Equal(t, ctrl.Result{RequeueAfter: deleteRetry}, result)

		machine := getInfraMachine(t, k8sClient, testMachineName)
		require.Contains(t, machine.Finalizers, machineFinalizer)
		require.Equal(t, testFirstAddress, machine.Status.Address)
		require.False(t, getPod(t, k8sClient, testMachineName).DeletionTimestamp.IsZero())
	}
	// The claims and the Secret copy are gone at once. Only the pod is left.
	requireGone(t, k8sClient, &corev1.PersistentVolumeClaim{}, varClaimName(testMachineName))
	requireGone(t, k8sClient, &corev1.Secret{}, bootstrapSecretName(testMachineName))

	releasePod(t, k8sClient, testMachineName)
	require.Equal(t, ctrl.Result{}, reconcileMachine(t, reconciler, testMachineName))

	err := k8sClient.Get(context.Background(),
		client.ObjectKey{Namespace: testNamespace, Name: testMachineName}, &infrav1.PodVMMachine{})
	require.True(t, apierrors.IsNotFound(err))
}

// A delete never touches an object of another owner, and such an object does
// not hold the delete.
func TestMachineReconcilerLeavesObjectsOfAnotherOwnerOnDelete(t *testing.T) {
	foreignLabels := map[string]string{infrav1.OwnerUIDLabel: "uid-of-another-machine"}
	foreign := []client.Object{
		&corev1.Pod{ObjectMeta: metav1.ObjectMeta{
			Name: testMachineName, Namespace: testPodNamespace, Labels: foreignLabels,
		}},
		&corev1.PersistentVolumeClaim{ObjectMeta: metav1.ObjectMeta{
			Name: varClaimName(testMachineName), Namespace: testPodNamespace, Labels: foreignLabels,
		}},
		&corev1.PersistentVolumeClaim{ObjectMeta: metav1.ObjectMeta{
			Name: etcdClaimName(testMachineName), Namespace: testPodNamespace,
		}},
		&corev1.Secret{ObjectMeta: metav1.ObjectMeta{
			Name: bootstrapSecretName(testMachineName), Namespace: testPodNamespace,
		}},
	}
	objects := append(machineObjects(newAllocatedInfraMachine(testMachineName, testFirstAddress)), foreign...)
	reconciler, k8sClient := newMachineReconcilerForTest(t, objects...)

	require.NoError(t, k8sClient.Delete(context.Background(), getInfraMachine(t, k8sClient, testMachineName)))
	require.Equal(t, ctrl.Result{}, reconcileMachine(t, reconciler, testMachineName))

	err := k8sClient.Get(context.Background(),
		client.ObjectKey{Namespace: testNamespace, Name: testMachineName}, &infrav1.PodVMMachine{})
	require.True(t, apierrors.IsNotFound(err))
	for _, obj := range foreign {
		require.NoError(t, k8sClient.Get(context.Background(), client.ObjectKeyFromObject(obj), obj),
			"%T %s must stay", obj, obj.GetName())
		require.True(t, obj.GetDeletionTimestamp().IsZero())
	}
}

func holdPod(t *testing.T, k8sClient client.Client, name string) {
	t.Helper()
	pod := getPod(t, k8sClient, name)
	pod.Finalizers = append(pod.Finalizers, podFinalizer)
	require.NoError(t, k8sClient.Update(context.Background(), pod))
}

func releasePod(t *testing.T, k8sClient client.Client, name string) {
	t.Helper()
	pod := getPod(t, k8sClient, name)
	pod.Finalizers = nil
	require.NoError(t, k8sClient.Update(context.Background(), pod))
}
