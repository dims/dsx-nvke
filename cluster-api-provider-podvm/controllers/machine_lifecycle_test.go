// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package controllers

import (
	"context"
	"fmt"
	"testing"

	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	clusterv1 "sigs.k8s.io/cluster-api/api/core/v1beta2"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"

	infrav1 "github.com/dsx-ai-factory/nvke/cluster-api-provider-podvm/api/v1alpha1"
)

const (
	// keptAnnotation marks an object in a test. An object that the provider
	// made again would not carry it.
	keptAnnotation = "test.example/kept"
	// podFinalizer keeps a deleted pod in the API server, the way a pod stays
	// while its virtual machine shuts down.
	podFinalizer = "test.example/still-running"
)

// When the pod of a provisioned machine is gone, the provider makes it again:
// same name, same claims, same address, same hardware address. The node comes
// back with its state, and the NVKE controller never learns of it.
func TestMachineReconcilerMakesALostPodAgainWithTheSameIdentity(t *testing.T) {
	tests := []struct {
		name string
		// loseSource removes the bootstrap data Secret of the Machine first.
		// The NVKE controller deletes it with the Machine, and a restore can
		// lose it.
		loseSource bool
	}{
		{name: "the bootstrap data Secret of the Machine still exists"},
		{name: "the bootstrap data Secret of the Machine is gone", loseSource: true},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			reconciler, k8sClient := newMachineReconcilerForTest(t, machineObjects(newInfraMachine(testMachineName))...)
			reconcileUntilPodRuns(t, reconciler, k8sClient, testMachineName)

			firstPod := getPod(t, k8sClient, testMachineName)
			markKept(t, k8sClient, &corev1.PersistentVolumeClaim{}, varClaimName(testMachineName))
			markKept(t, k8sClient, &corev1.PersistentVolumeClaim{}, etcdClaimName(testMachineName))
			markKept(t, k8sClient, &corev1.Secret{}, bootstrapSecretName(testMachineName))

			source := newBootstrapDataSecret(testMachineName)
			if test.loseSource {
				require.NoError(t, k8sClient.Delete(context.Background(), source))
			} else {
				// A later render of the Secret holds a new join token. The node
				// already used the first one, so the copy must not change.
				require.NoError(t, k8sClient.Get(context.Background(), client.ObjectKeyFromObject(source), source))
				source.Data["value"] = []byte("a later render")
				require.NoError(t, k8sClient.Update(context.Background(), source))
			}

			// The pod is lost.
			require.NoError(t, k8sClient.Delete(context.Background(), firstPod))
			requireGone(t, k8sClient, &corev1.Pod{}, testMachineName)

			result := reconcileMachine(t, reconciler, testMachineName)
			require.Equal(t, ctrl.Result{}, result)

			newPod := getPod(t, k8sClient, testMachineName)
			require.Equal(t, firstPod.Name, newPod.Name)
			require.Equal(t, firstPod.Namespace, newPod.Namespace)
			require.Equal(t, firstPod.Annotations[networksAnnotation], newPod.Annotations[networksAnnotation])
			require.Contains(t, newPod.Annotations[networksAnnotation], `"ips":["172.28.1.1/16"]`)
			require.Contains(t, newPod.Annotations[networksAnnotation], `"mac":"02:00:ac:1c:01:01"`)
			require.Equal(t, firstPod.Spec, newPod.Spec)
			require.Equal(t, firstPod.Labels, newPod.Labels)

			// The claims and the Secret copy are the ones from before.
			requireKept(t, k8sClient, &corev1.PersistentVolumeClaim{}, varClaimName(testMachineName))
			requireKept(t, k8sClient, &corev1.PersistentVolumeClaim{}, etcdClaimName(testMachineName))
			requireKept(t, k8sClient, &corev1.Secret{}, bootstrapSecretName(testMachineName))
			secretCopy := &corev1.Secret{}
			require.NoError(t, k8sClient.Get(context.Background(),
				client.ObjectKey{Namespace: testPodNamespace, Name: bootstrapSecretName(testMachineName)}, secretCopy))
			require.Equal(t, []byte(testBootstrapData), secretCopy.Data["value"])

			// The machine keeps what it is known by.
			machine := getInfraMachine(t, k8sClient, testMachineName)
			require.Equal(t, testProviderID, machine.Spec.ProviderID)
			require.Equal(t, testFirstAddress, machine.Status.Address)
			require.Equal(t, testFirstMAC, machine.Status.HardwareAddress)
			require.True(t, *machine.Status.Initialization.Provisioned)
			requireReadyCondition(t, machine.Status.Conditions, metav1.ConditionFalse, infrav1.WaitingForPodReason)

			setPodPhase(t, k8sClient, testMachineName, corev1.PodRunning)
			reconcileMachine(t, reconciler, testMachineName)
			requireReadyCondition(t, getInfraMachine(t, k8sClient, testMachineName).Status.Conditions,
				metav1.ConditionTrue, infrav1.PodRunningReason)
		})
	}
}

// A pod that ended never runs again, for example after an eviction. It holds
// the name, so the provider deletes it and then makes the pod again.
func TestMachineReconcilerReplacesAPodThatEnded(t *testing.T) {
	for _, phase := range []corev1.PodPhase{corev1.PodFailed, corev1.PodSucceeded} {
		t.Run(string(phase), func(t *testing.T) {
			reconciler, k8sClient := newMachineReconcilerForTest(t, machineObjects(newInfraMachine(testMachineName))...)
			reconcileUntilPodRuns(t, reconciler, k8sClient, testMachineName)
			markKept(t, k8sClient, &corev1.Pod{}, testMachineName)

			setPodPhase(t, k8sClient, testMachineName, phase)
			reconcileMachine(t, reconciler, testMachineName)
			requireGone(t, k8sClient, &corev1.Pod{}, testMachineName)
			requireReadyCondition(t, getInfraMachine(t, k8sClient, testMachineName).Status.Conditions,
				metav1.ConditionFalse, infrav1.WaitingForPodReason)

			reconcileMachine(t, reconciler, testMachineName)
			pod := getPod(t, k8sClient, testMachineName)
			require.NotContains(t, pod.Annotations, keptAnnotation)
			require.Contains(t, pod.Annotations[networksAnnotation], `"ips":["172.28.1.1/16"]`)
		})
	}
}

// While the old pod shuts down, its name and its address are in use. The
// provider waits for it to be gone.
func TestMachineReconcilerWaitsForAPodThatIsBeingDeleted(t *testing.T) {
	reconciler, k8sClient := newMachineReconcilerForTest(t, machineObjects(newInfraMachine(testMachineName))...)
	reconcileUntilPodRuns(t, reconciler, k8sClient, testMachineName)
	holdPod(t, k8sClient, testMachineName)

	require.NoError(t, k8sClient.Delete(context.Background(), getPod(t, k8sClient, testMachineName)))
	result := reconcileMachine(t, reconciler, testMachineName)
	require.Equal(t, ctrl.Result{}, result)

	pod := getPod(t, k8sClient, testMachineName)
	require.False(t, pod.DeletionTimestamp.IsZero())
	requireReadyCondition(t, getInfraMachine(t, k8sClient, testMachineName).Status.Conditions,
		metav1.ConditionFalse, infrav1.WaitingForPodReason)

	releasePod(t, k8sClient, testMachineName)
	reconcileMachine(t, reconciler, testMachineName)
	require.True(t, getPod(t, k8sClient, testMachineName).DeletionTimestamp.IsZero())
}

// With no copy and no source the pod cannot get its bootstrap data. The
// provider reports it and makes no pod that would start with nothing.
func TestMachineReconcilerDoesNotMakeALostPodWithNoBootstrapData(t *testing.T) {
	reconciler, k8sClient := newMachineReconcilerForTest(t, machineObjects(newInfraMachine(testMachineName))...)
	reconcileUntilPodRuns(t, reconciler, k8sClient, testMachineName)

	for _, secret := range []*corev1.Secret{
		newBootstrapDataSecret(testMachineName),
		{ObjectMeta: metav1.ObjectMeta{Name: bootstrapSecretName(testMachineName), Namespace: testPodNamespace}},
	} {
		require.NoError(t, k8sClient.Delete(context.Background(), secret))
	}
	require.NoError(t, k8sClient.Delete(context.Background(), getPod(t, k8sClient, testMachineName)))

	result := reconcileMachine(t, reconciler, testMachineName)
	require.Equal(t, retryAfter, result.RequeueAfter)
	requireGone(t, k8sClient, &corev1.Pod{}, testMachineName)
	requireReadyCondition(t, getInfraMachine(t, k8sClient, testMachineName).Status.Conditions,
		metav1.ConditionFalse, infrav1.BootstrapDataNotFoundReason)
}

// The NVKE controller asks for a hard reboot with an annotation on the Machine
// and waits for a new boot ID of the Node. The provider answers each value one
// time: it deletes the pod, and the lost pod rule makes the pod again.
func TestMachineReconcilerAnswersARebootRequestOneTime(t *testing.T) {
	reconciler, k8sClient := newMachineReconcilerForTest(t, machineObjects(newInfraMachine(testMachineName))...)
	reconcileUntilPodRuns(t, reconciler, k8sClient, testMachineName)
	markKept(t, k8sClient, &corev1.Pod{}, testMachineName)
	markKept(t, k8sClient, &corev1.PersistentVolumeClaim{}, varClaimName(testMachineName))

	// No request: the pod stays.
	reconcileMachine(t, reconciler, testMachineName)
	requireKept(t, k8sClient, &corev1.Pod{}, testMachineName)

	const firstRequest = "2026-11-26T22:30:00Z"
	setRebootAnnotation(t, k8sClient, firstRequest)

	// The request deletes the pod and is recorded.
	result := reconcileMachine(t, reconciler, testMachineName)
	require.Equal(t, ctrl.Result{}, result)
	requireGone(t, k8sClient, &corev1.Pod{}, testMachineName)
	machine := getInfraMachine(t, k8sClient, testMachineName)
	require.Equal(t, firstRequest, machine.Status.LastRebootRequest)
	require.Equal(t, testProviderID, machine.Spec.ProviderID)
	requireReadyCondition(t, machine.Status.Conditions, metav1.ConditionFalse, infrav1.WaitingForPodReason)

	// The next reconcile makes the pod again, with the same address and the
	// same claims.
	reconcileMachine(t, reconciler, testMachineName)
	newPod := getPod(t, k8sClient, testMachineName)
	require.NotContains(t, newPod.Annotations, keptAnnotation)
	require.Contains(t, newPod.Annotations[networksAnnotation], `"ips":["172.28.1.1/16"]`)
	requireKept(t, k8sClient, &corev1.PersistentVolumeClaim{}, varClaimName(testMachineName))

	// The annotation stays until the NVKE controller sees the new boot ID.
	// The new pod must survive every reconcile in that time.
	markKept(t, k8sClient, &corev1.Pod{}, testMachineName)
	setPodPhase(t, k8sClient, testMachineName, corev1.PodRunning)
	for range 3 {
		reconcileMachine(t, reconciler, testMachineName)
	}
	requireKept(t, k8sClient, &corev1.Pod{}, testMachineName)
	requireReadyCondition(t, getInfraMachine(t, k8sClient, testMachineName).Status.Conditions,
		metav1.ConditionTrue, infrav1.PodRunningReason)

	// The NVKE controller removes the annotation: nothing happens.
	setRebootAnnotation(t, k8sClient, "")
	reconcileMachine(t, reconciler, testMachineName)
	requireKept(t, k8sClient, &corev1.Pod{}, testMachineName)

	// A new request is a new value, and the pod goes again.
	setRebootAnnotation(t, k8sClient, "2026-11-26T23:45:00Z")
	reconcileMachine(t, reconciler, testMachineName)
	requireGone(t, k8sClient, &corev1.Pod{}, testMachineName)
	require.Equal(t, "2026-11-26T23:45:00Z", getInfraMachine(t, k8sClient, testMachineName).Status.LastRebootRequest)
}

// A reboot request for a pod that is already shutting down is answered by that
// shutdown. The provider records the request and does not delete the next pod.
func TestMachineReconcilerRecordsARebootRequestForAPodThatIsBeingDeleted(t *testing.T) {
	reconciler, k8sClient := newMachineReconcilerForTest(t, machineObjects(newInfraMachine(testMachineName))...)
	reconcileUntilPodRuns(t, reconciler, k8sClient, testMachineName)
	holdPod(t, k8sClient, testMachineName)
	require.NoError(t, k8sClient.Delete(context.Background(), getPod(t, k8sClient, testMachineName)))

	setRebootAnnotation(t, k8sClient, "2026-11-26T22:30:00Z")
	reconcileMachine(t, reconciler, testMachineName)
	require.Equal(t, "2026-11-26T22:30:00Z", getInfraMachine(t, k8sClient, testMachineName).Status.LastRebootRequest)

	releasePod(t, k8sClient, testMachineName)
	reconcileMachine(t, reconciler, testMachineName)
	markKept(t, k8sClient, &corev1.Pod{}, testMachineName)
	reconcileMachine(t, reconciler, testMachineName)
	requireKept(t, k8sClient, &corev1.Pod{}, testMachineName)
}

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
			name:    "pod runs",
			objects: func() []client.Object { return machineObjects(newInfraMachine(testMachineName)) },
			prepare: func(t *testing.T, reconciler *MachineReconciler, k8sClient client.Client) bool {
				reconcileUntilPodRuns(t, reconciler, k8sClient, testMachineName)
				return true
			},
		},
		{
			name:    "pod runs and the PodVMCluster is already gone",
			objects: func() []client.Object { return machineObjects(newInfraMachine(testMachineName)) },
			prepare: func(t *testing.T, reconciler *MachineReconciler, k8sClient client.Client) bool {
				reconcileUntilPodRuns(t, reconciler, k8sClient, testMachineName)
				require.NoError(t, k8sClient.Delete(context.Background(), newInfraCluster()))
				require.NoError(t, k8sClient.Delete(context.Background(), newCAPICluster()))
				return true
			},
		},
		{
			name:    "pod lost and not made again yet",
			objects: func() []client.Object { return machineObjects(newInfraMachine(testMachineName)) },
			prepare: func(t *testing.T, reconciler *MachineReconciler, k8sClient client.Client) bool {
				reconcileUntilPodRuns(t, reconciler, k8sClient, testMachineName)
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
	reconcileUntilPodRuns(t, reconciler, k8sClient, testMachineName)
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

func setRebootAnnotation(t *testing.T, k8sClient client.Client, value string) {
	t.Helper()
	owner := &clusterv1.Machine{}
	require.NoError(t, k8sClient.Get(context.Background(),
		client.ObjectKey{Namespace: testNamespace, Name: testMachineName}, owner))
	if owner.Annotations == nil {
		owner.Annotations = map[string]string{}
	}
	if value == "" {
		delete(owner.Annotations, "nvke.nvidia.com/reboot")
	} else {
		owner.Annotations["nvke.nvidia.com/reboot"] = value
	}
	require.NoError(t, k8sClient.Update(context.Background(), owner))
}

func objectInPodNamespace(t *testing.T, k8sClient client.Client, obj client.Object, name string) client.Object {
	t.Helper()
	require.NoError(t, k8sClient.Get(context.Background(),
		client.ObjectKey{Namespace: testPodNamespace, Name: name}, obj))
	return obj
}

func markKept(t *testing.T, k8sClient client.Client, obj client.Object, name string) {
	t.Helper()
	objectInPodNamespace(t, k8sClient, obj, name)
	annotations := obj.GetAnnotations()
	if annotations == nil {
		annotations = map[string]string{}
	}
	annotations[keptAnnotation] = "true"
	obj.SetAnnotations(annotations)
	require.NoError(t, k8sClient.Update(context.Background(), obj))
}

func requireKept(t *testing.T, k8sClient client.Client, obj client.Object, name string) {
	t.Helper()
	objectInPodNamespace(t, k8sClient, obj, name)
	require.Equal(t, "true", obj.GetAnnotations()[keptAnnotation], "%T %s was made again", obj, name)
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

// The cache can lag behind the record of a reboot request, and the pod it
// shows can already be the new one. The record of the API server decides, so
// the new pod is not deleted a second time.
func TestMachineReconcilerDoesNotAnswerARebootRequestTwiceWithAStaleCache(t *testing.T) {
	const request = "2026-11-26T22:30:00Z"
	reconciler, cached := newMachineReconcilerForTest(t, machineObjects(newInfraMachine(testMachineName))...)
	reconcileUntilPodRuns(t, reconciler, cached, testMachineName)
	setRebootAnnotation(t, cached, request)
	markKept(t, cached, &corev1.Pod{}, testMachineName)

	// What the API server holds: the request is answered.
	answeredMachine := getInfraMachine(t, cached, testMachineName)
	answeredMachine.ResourceVersion = ""
	answeredMachine.Status.LastRebootRequest = request
	reconciler.apiReader = newFakeClient(t, answeredMachine)

	reconcileMachine(t, reconciler, testMachineName)

	requireKept(t, cached, &corev1.Pod{}, testMachineName)
}

// A reboot annotation can stay on the Machine for a long time. Once the cache
// shows the record of the request, a reconcile does not ask the API server for
// it again.
func TestMachineReconcilerReadsTheRebootRecordFromTheCacheWhenItIsThere(t *testing.T) {
	reconciler, k8sClient := newMachineReconcilerForTest(t, machineObjects(newInfraMachine(testMachineName))...)
	reconcileUntilPodRuns(t, reconciler, k8sClient, testMachineName)
	setRebootAnnotation(t, k8sClient, "2026-11-26T22:30:00Z")
	reconcileMachine(t, reconciler, testMachineName)
	reconcileMachine(t, reconciler, testMachineName)
	setPodPhase(t, k8sClient, testMachineName, corev1.PodRunning)

	reconciler.apiReader = &noMachineReader{Reader: k8sClient}

	reconcileMachine(t, reconciler, testMachineName)
	requireReadyCondition(t, getInfraMachine(t, k8sClient, testMachineName).Status.Conditions,
		metav1.ConditionTrue, infrav1.PodRunningReason)
}

// noMachineReader fails every direct read of a PodVMMachine.
type noMachineReader struct {
	client.Reader
}

func (r *noMachineReader) Get(ctx context.Context, key client.ObjectKey, obj client.Object, opts ...client.GetOption) error {
	if _, isMachine := obj.(*infrav1.PodVMMachine); isMachine {
		return apierrors.NewInternalError(fmt.Errorf("unexpected direct read of PodVMMachine %s", key))
	}
	return r.Reader.Get(ctx, key, obj, opts...)
}
