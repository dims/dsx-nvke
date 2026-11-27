// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package capi

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	clusterv1 "sigs.k8s.io/cluster-api/api/core/v1beta2"
	capiconditions "sigs.k8s.io/cluster-api/util/conditions"

	"github.com/dsx-ai-factory/nvke/controller/internal/clients/shared"
)

func TestClient_FailureDomainUnavailable(t *testing.T) {
	t.Parallel()

	condition := func(conditionType string, status metav1.ConditionStatus, reason string, observedGeneration int64) metav1.Condition {
		return metav1.Condition{
			Type:               conditionType,
			Status:             status,
			Reason:             reason,
			Message:            "Pod pods/cp-a cannot be scheduled in the failure domain \"A\": 0/4 nodes are available",
			ObservedGeneration: observedGeneration,
		}
	}
	infrastructureReady := func(status metav1.ConditionStatus, reason string, observedGeneration int64) metav1.Condition {
		return condition(clusterv1.MachineInfrastructureReadyCondition, status, reason, observedGeneration)
	}

	tests := []struct {
		name       string
		conditions []metav1.Condition
		want       bool
	}{
		{
			name:       "domain out of capacity",
			conditions: []metav1.Condition{infrastructureReady(metav1.ConditionFalse, "FailureDomainUnavailable", 2)},
			want:       true,
		},
		{
			name:       "no observed generation",
			conditions: []metav1.Condition{infrastructureReady(metav1.ConditionFalse, "FailureDomainUnavailable", 0)},
			want:       true,
		},
		{
			name: "among the Machine's other conditions",
			conditions: []metav1.Condition{
				condition(clusterv1.MachineReadyCondition, metav1.ConditionFalse, clusterv1.MachineNotReadyReason, 2),
				condition(clusterv1.MachineBootstrapConfigReadyCondition, metav1.ConditionTrue, clusterv1.MachineBootstrapConfigReadyReason, 2),
				infrastructureReady(metav1.ConditionFalse, "FailureDomainUnavailable", 2),
			},
			want: true,
		},
		{
			name:       "unschedulable without a requested domain",
			conditions: []metav1.Condition{infrastructureReady(metav1.ConditionFalse, "PodUnschedulable", 2)},
			want:       false,
		},
		{
			name:       "provider still creating the machine",
			conditions: []metav1.Condition{infrastructureReady(metav1.ConditionFalse, "WaitingForPod", 2)},
			want:       false,
		},
		{
			name:       "provider reports no Ready condition and Cluster API falls back",
			conditions: []metav1.Condition{infrastructureReady(metav1.ConditionFalse, clusterv1.MachineInfrastructureNotReadyReason, 2)},
			want:       false,
		},
		{
			name:       "infrastructure ready",
			conditions: []metav1.Condition{infrastructureReady(metav1.ConditionTrue, clusterv1.MachineInfrastructureReadyReason, 2)},
			want:       false,
		},
		{
			name:       "reason on a ready machine",
			conditions: []metav1.Condition{infrastructureReady(metav1.ConditionTrue, "FailureDomainUnavailable", 2)},
			want:       false,
		},
		{
			name:       "reason with unknown status",
			conditions: []metav1.Condition{infrastructureReady(metav1.ConditionUnknown, "FailureDomainUnavailable", 2)},
			want:       false,
		},
		{
			name:       "reason on another condition",
			conditions: []metav1.Condition{condition(clusterv1.MachineReadyCondition, metav1.ConditionFalse, "FailureDomainUnavailable", 2)},
			want:       false,
		},
		{
			name:       "condition predates the current Machine spec",
			conditions: []metav1.Condition{infrastructureReady(metav1.ConditionFalse, "FailureDomainUnavailable", 1)},
			want:       false,
		},
		{
			name: "no condition yet",
			want: false,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			machine := &clusterv1.Machine{
				ObjectMeta: metav1.ObjectMeta{Name: "cp-a", Namespace: "nvke-system", Generation: 2},
				Spec: clusterv1.MachineSpec{
					FailureDomain: "A",
					InfrastructureRef: clusterv1.ContractVersionedObjectReference{
						APIGroup: "infrastructure.cluster.x-k8s.io",
						Kind:     "PodVMMachine",
						Name:     "cp-a",
					},
				},
				Status: clusterv1.MachineStatus{Conditions: tt.conditions},
			}

			// No Kubernetes client: the answer comes from the Machine alone.
			got, err := New().FailureDomainUnavailable(context.Background(), shared.MachineAdvanceDeps{}, machine)

			require.NoError(t, err)
			assert.Equal(t, tt.want, got)
		})
	}
}

// Cluster API builds the Machine's InfrastructureReady condition from the
// infrastructure machine with these two calls. The test pins what this client
// relies on: the mirror keeps the provider's status, reason and message, and
// carries the Machine's generation in place of the infrastructure machine's.
func TestClient_FailureDomainUnavailable_ReadsTheClusterAPIMirror(t *testing.T) {
	t.Parallel()

	const message = "Pod pods/cp-a cannot be scheduled in the failure domain \"A\": 0/4 nodes are available"
	infraMachine := &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "infrastructure.cluster.x-k8s.io/v1alpha1",
		"kind":       "PodVMMachine",
		"metadata":   map[string]any{"name": "cp-a", "namespace": "nvke-system", "generation": int64(1)},
		"status": map[string]any{"conditions": []any{map[string]any{
			"type":               "Ready",
			"status":             "False",
			"reason":             "FailureDomainUnavailable",
			"message":            message,
			"observedGeneration": int64(1),
			"lastTransitionTime": "2026-11-27T05:33:41Z",
		}}},
	}}
	machine := &clusterv1.Machine{ObjectMeta: metav1.ObjectMeta{Name: "cp-a", Namespace: "nvke-system", Generation: 3}}

	mirror, err := capiconditions.NewMirrorConditionFromUnstructured(infraMachine, "Ready",
		capiconditions.TargetConditionType(clusterv1.MachineInfrastructureReadyCondition))
	require.NoError(t, err)
	capiconditions.Set(machine, *mirror)

	got, err := New().FailureDomainUnavailable(context.Background(), shared.MachineAdvanceDeps{}, machine)
	require.NoError(t, err)
	assert.True(t, got)

	mirrored := capiconditions.Get(machine, clusterv1.MachineInfrastructureReadyCondition)
	require.NotNil(t, mirrored)
	assert.Equal(t, message, mirrored.Message)
	assert.Equal(t, int64(3), mirrored.ObservedGeneration)
}
