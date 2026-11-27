// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package controllers

import (
	"context"
	"testing"

	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	clusterv1 "sigs.k8s.io/cluster-api/api/core/v1beta2"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"

	infrav1 "github.com/dsx-ai-factory/nvke/cluster-api-provider-podvm/api/v1alpha1"
)

const (
	testFailureDomain = "host-3"
	// testSchedulerText is the text of the scheduler from the lab: the host
	// node of the failure domain had no free volume.
	testSchedulerText = "0/4 nodes are available: 1 node(s) didn't find available persistent volumes to bind, " +
		"1 node(s) had untolerated taint(s), 2 node(s) didn't match Pod's node affinity/selector."
)

// newMachineReconcilerInFailureDomain makes the reconciler for one machine
// whose owner Machine names the given failure domain. An empty value means
// that the Machine names none.
func newMachineReconcilerInFailureDomain(t *testing.T, failureDomain string) (*MachineReconciler, client.Client) {
	t.Helper()
	owner := newOwnerMachine()
	owner.Spec.FailureDomain = failureDomain
	return newMachineReconcilerForTest(t,
		newPodNamespace(), newInfraCluster(), newCAPICluster(), owner,
		newBootstrapDataSecret(testMachineName), newInfraMachine(testMachineName),
	)
}

func readyCondition(t *testing.T, machine *infrav1.PodVMMachine) metav1.Condition {
	t.Helper()
	condition := meta.FindStatusCondition(machine.Status.Conditions, infrav1.ReadyCondition)
	require.NotNil(t, condition, "no %s condition in %v", infrav1.ReadyCondition, machine.Status.Conditions)
	return *condition
}

// The NVKE controller matches the type, the status and the reason of this
// condition by their text. A change of one of them is a change of the contract
// with the NVKE controller.
func TestFailureDomainUnavailableIsTheTextThatTheNVKEControllerReads(t *testing.T) {
	require.Equal(t, "Ready", infrav1.ReadyCondition)
	require.Equal(t, "FailureDomainUnavailable", infrav1.FailureDomainUnavailableReason)
	require.Equal(t, "PodUnschedulable", infrav1.PodUnschedulableReason)
}

// A pod that the scheduler cannot place stays pending with no end. The machine
// reports it, so that the NVKE controller can show why a node waits and can
// place a control plane node in another failure domain.
func TestMachineReconcilerReportsAPodThatTheSchedulerCannotPlace(t *testing.T) {
	tests := []struct {
		name            string
		failureDomain   string
		scheduled       corev1.ConditionStatus
		schedulerReason string
		schedulerText   string
		wantReason      string
		wantMessage     string
	}{
		{
			name:            "the failure domain of the Machine has no room",
			failureDomain:   testFailureDomain,
			scheduled:       corev1.ConditionFalse,
			schedulerReason: corev1.PodReasonUnschedulable,
			schedulerText:   testSchedulerText,
			wantReason:      infrav1.FailureDomainUnavailableReason,
			wantMessage: `Pod test-pods/test-cp-a1b2 cannot be scheduled in the failure domain "host-3": ` +
				testSchedulerText,
		},
		{
			name:            "the Machine names no failure domain",
			scheduled:       corev1.ConditionFalse,
			schedulerReason: corev1.PodReasonUnschedulable,
			schedulerText:   "0/4 nodes are available: 4 Insufficient memory.",
			wantReason:      infrav1.PodUnschedulableReason,
			wantMessage:     "Pod test-pods/test-cp-a1b2 cannot be scheduled: 0/4 nodes are available: 4 Insufficient memory.",
		},
		{
			name:            "the scheduler gives no text",
			failureDomain:   testFailureDomain,
			scheduled:       corev1.ConditionFalse,
			schedulerReason: corev1.PodReasonUnschedulable,
			wantReason:      infrav1.FailureDomainUnavailableReason,
			wantMessage: `Pod test-pods/test-cp-a1b2 cannot be scheduled in the failure domain "host-3": ` +
				"the scheduler gave no message",
		},
		{
			name:            "the scheduler itself failed, which says nothing about room",
			failureDomain:   testFailureDomain,
			scheduled:       corev1.ConditionFalse,
			schedulerReason: corev1.PodReasonSchedulerError,
			schedulerText:   "running Bind plugin: the server is not reachable",
			wantReason:      infrav1.WaitingForPodReason,
			wantMessage:     "Pod test-pods/test-cp-a1b2 does not run yet",
		},
		{
			name:          "the pod has a node and does not run yet",
			failureDomain: testFailureDomain,
			scheduled:     corev1.ConditionTrue,
			wantReason:    infrav1.WaitingForPodReason,
			wantMessage:   "Pod test-pods/test-cp-a1b2 does not run yet",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			reconciler, k8sClient := newMachineReconcilerInFailureDomain(t, test.failureDomain)
			reconcileMachine(t, reconciler, testMachineName)

			setPodScheduled(t, k8sClient, testMachineName, test.scheduled, test.schedulerReason, test.schedulerText)
			result := reconcileMachine(t, reconciler, testMachineName)

			// The event of the pod status starts the next reconcile.
			require.Equal(t, ctrl.Result{}, result)

			machine := getInfraMachine(t, k8sClient, testMachineName)
			condition := readyCondition(t, machine)
			require.Equal(t, metav1.ConditionFalse, condition.Status)
			require.Equal(t, test.wantReason, condition.Reason)
			require.Equal(t, test.wantMessage, condition.Message)
			require.Equal(t, machine.Generation, condition.ObservedGeneration)

			// The machine is not a node: nothing tells the NVKE controller
			// where to call it. The address stays held for it.
			require.Empty(t, machine.Status.Addresses)
			require.Empty(t, machine.Spec.ProviderID)
			require.Nil(t, machine.Status.Initialization.Provisioned)
			require.Equal(t, testFirstAddress, machine.Status.Address)

			// The provider leaves the pod to the scheduler.
			require.True(t, getPod(t, k8sClient, testMachineName).DeletionTimestamp.IsZero())
		})
	}
}

// A pod that the scheduler has not looked at yet has no PodScheduled
// condition. It is not reported as a pod with no place.
func TestMachineReconcilerWaitsForAPodThatTheSchedulerHasNotLookedAt(t *testing.T) {
	reconciler, k8sClient := newMachineReconcilerInFailureDomain(t, testFailureDomain)
	reconcileMachine(t, reconciler, testMachineName)

	setPodPhase(t, k8sClient, testMachineName, corev1.PodPending)
	reconcileMachine(t, reconciler, testMachineName)

	requireReadyCondition(t, getInfraMachine(t, k8sClient, testMachineName).Status.Conditions,
		metav1.ConditionFalse, infrav1.WaitingForPodReason)
}

// When a place gets free the scheduler gives the pod a node. The reason goes
// away at once, and the machine comes up the usual way.
func TestMachineReconcilerDropsTheReasonWhenThePodGetsANode(t *testing.T) {
	reconciler, k8sClient := newMachineReconcilerInFailureDomain(t, testFailureDomain)
	reconcileMachine(t, reconciler, testMachineName)

	setPodScheduled(t, k8sClient, testMachineName, corev1.ConditionFalse, corev1.PodReasonUnschedulable, testSchedulerText)
	reconcileMachine(t, reconciler, testMachineName)
	requireReadyCondition(t, getInfraMachine(t, k8sClient, testMachineName).Status.Conditions,
		metav1.ConditionFalse, infrav1.FailureDomainUnavailableReason)
	firstPod := getPod(t, k8sClient, testMachineName)

	// The pod has a node and pulls its image.
	setPodScheduled(t, k8sClient, testMachineName, corev1.ConditionTrue, "", "")
	reconcileMachine(t, reconciler, testMachineName)
	condition := readyCondition(t, getInfraMachine(t, k8sClient, testMachineName))
	require.Equal(t, metav1.ConditionFalse, condition.Status)
	require.Equal(t, infrav1.WaitingForPodReason, condition.Reason)
	require.NotContains(t, condition.Message, testFailureDomain)

	// The virtual machine boots.
	setPodPhase(t, k8sClient, testMachineName, corev1.PodRunning)
	reconcileMachine(t, reconciler, testMachineName)
	requireReadyCondition(t, getInfraMachine(t, k8sClient, testMachineName).Status.Conditions,
		metav1.ConditionFalse, infrav1.WaitingForNodeAgentReason)

	// The node agent answers.
	startNodeAgent(t, k8sClient, testMachineName)
	reconcileMachine(t, reconciler, testMachineName)
	machine := getInfraMachine(t, k8sClient, testMachineName)
	requireReadyCondition(t, machine.Status.Conditions, metav1.ConditionTrue, infrav1.PodRunningReason)
	require.Equal(t, testProviderID, machine.Spec.ProviderID)
	require.True(t, *machine.Status.Initialization.Provisioned)

	// It is the pod from before. The provider made no new one.
	require.Equal(t, firstPod.UID, getPod(t, k8sClient, testMachineName).UID)
}

// The scheduler changes its text when the host cluster changes. The condition
// follows the text, and a reconcile with the same text writes nothing.
func TestMachineReconcilerFollowsTheTextOfTheScheduler(t *testing.T) {
	reconciler, k8sClient := newMachineReconcilerInFailureDomain(t, testFailureDomain)
	reconcileMachine(t, reconciler, testMachineName)

	setPodScheduled(t, k8sClient, testMachineName, corev1.ConditionFalse, corev1.PodReasonUnschedulable, testSchedulerText)
	reconcileMachine(t, reconciler, testMachineName)
	first := getInfraMachine(t, k8sClient, testMachineName)

	reconcileMachine(t, reconciler, testMachineName)
	second := getInfraMachine(t, k8sClient, testMachineName)
	require.Equal(t, first.ResourceVersion, second.ResourceVersion)

	laterText := "0/4 nodes are available: 1 Insufficient cpu, 3 node(s) didn't match Pod's node affinity/selector."
	setPodScheduled(t, k8sClient, testMachineName, corev1.ConditionFalse, corev1.PodReasonUnschedulable, laterText)
	reconcileMachine(t, reconciler, testMachineName)

	third := getInfraMachine(t, k8sClient, testMachineName)
	condition := readyCondition(t, third)
	require.Equal(t, infrav1.FailureDomainUnavailableReason, condition.Reason)
	require.Contains(t, condition.Message, laterText)
	require.NotContains(t, condition.Message, testSchedulerText)
	// The status did not change, so the time of the last change stays. The
	// NVKE controller counts from its own record how long a node waits.
	require.Equal(t, readyCondition(t, first).LastTransitionTime, condition.LastTransitionTime)
}

// The pod of a provisioned machine was lost, and the new pod finds no place.
// The machine reports it and keeps what the NVKE controller knows the node by.
func TestMachineReconcilerReportsALostPodWithNoPlaceAndKeepsTheNode(t *testing.T) {
	reconciler, k8sClient := newMachineReconcilerInFailureDomain(t, testFailureDomain)
	reconcileUntilNodeAgentAnswers(t, reconciler, k8sClient, testMachineName)

	require.NoError(t, k8sClient.Delete(context.Background(), getPod(t, k8sClient, testMachineName)))
	reconcileMachine(t, reconciler, testMachineName)
	setPodScheduled(t, k8sClient, testMachineName, corev1.ConditionFalse, corev1.PodReasonUnschedulable, testSchedulerText)
	reconcileMachine(t, reconciler, testMachineName)

	machine := getInfraMachine(t, k8sClient, testMachineName)
	requireReadyCondition(t, machine.Status.Conditions, metav1.ConditionFalse, infrav1.FailureDomainUnavailableReason)
	require.Equal(t, []clusterv1.MachineAddress{
		{Type: clusterv1.MachineInternalIP, Address: testFirstAddress},
	}, machine.Status.Addresses)
	require.Equal(t, testProviderID, machine.Spec.ProviderID)
	require.True(t, *machine.Status.Initialization.Provisioned)
}

func TestPodUnschedulable(t *testing.T) {
	scheduled := func(status corev1.ConditionStatus, reason, message string) corev1.PodCondition {
		return corev1.PodCondition{Type: corev1.PodScheduled, Status: status, Reason: reason, Message: message}
	}

	tests := []struct {
		name       string
		conditions []corev1.PodCondition
		wantText   string
		want       bool
	}{
		{name: "no condition", want: false},
		{
			name:       "the scheduler found no node",
			conditions: []corev1.PodCondition{scheduled(corev1.ConditionFalse, corev1.PodReasonUnschedulable, "no node")},
			wantText:   "no node",
			want:       true,
		},
		{
			name: "the condition is not the first one",
			conditions: []corev1.PodCondition{
				{Type: corev1.PodReady, Status: corev1.ConditionFalse, Reason: corev1.PodReasonUnschedulable},
				scheduled(corev1.ConditionFalse, corev1.PodReasonUnschedulable, "no node"),
			},
			wantText: "no node",
			want:     true,
		},
		{
			name:       "the scheduler failed",
			conditions: []corev1.PodCondition{scheduled(corev1.ConditionFalse, corev1.PodReasonSchedulerError, "bind failed")},
			wantText:   "bind failed",
			want:       false,
		},
		{
			name:       "the pod has a node",
			conditions: []corev1.PodCondition{scheduled(corev1.ConditionTrue, "", "")},
			want:       false,
		},
		{
			name:       "the reason on a pod that has a node",
			conditions: []corev1.PodCondition{scheduled(corev1.ConditionTrue, corev1.PodReasonUnschedulable, "")},
			want:       false,
		},
		{
			name: "the reason on another condition",
			conditions: []corev1.PodCondition{
				{Type: corev1.PodReady, Status: corev1.ConditionFalse, Reason: corev1.PodReasonUnschedulable},
			},
			want: false,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			pod := &corev1.Pod{Status: corev1.PodStatus{Phase: corev1.PodPending, Conditions: test.conditions}}

			text, unschedulable := podUnschedulable(pod)

			require.Equal(t, test.want, unschedulable)
			require.Equal(t, test.wantText, text)
		})
	}
}
