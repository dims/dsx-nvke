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

// unavailableMessage is the free text of a provider. It becomes the pending
// message of the node.
const unavailableMessage = `no capacity in the failure domain "A"`

func TestClient_FailureDomainUnavailable(t *testing.T) {
	t.Parallel()

	condition := func(conditionType string, status metav1.ConditionStatus, reason string, observedGeneration int64) metav1.Condition {
		return metav1.Condition{
			Type:               conditionType,
			Status:             status,
			Reason:             reason,
			Message:            unavailableMessage,
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
			name:       "not ready for another reason",
			conditions: []metav1.Condition{infrastructureReady(metav1.ConditionFalse, clusterv1.MachineInfrastructureNotReadyReason, 2)},
			want:       false,
		},
		{
			name:       "reason on a ready machine",
			conditions: []metav1.Condition{infrastructureReady(metav1.ConditionTrue, "FailureDomainUnavailable", 2)},
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
				ObjectMeta: metav1.ObjectMeta{Generation: 2},
				Status:     clusterv1.MachineStatus{Conditions: tt.conditions},
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
// The table above builds the condition by hand, so it cannot see a change of
// the mirror.
func TestClient_FailureDomainUnavailable_ReadsTheClusterAPIMirror(t *testing.T) {
	t.Parallel()

	infraMachine := &unstructured.Unstructured{Object: map[string]any{
		"metadata": map[string]any{"generation": int64(1)},
		"status": map[string]any{"conditions": []any{map[string]any{
			"type":               "Ready",
			"status":             "False",
			"reason":             "FailureDomainUnavailable",
			"message":            unavailableMessage,
			"observedGeneration": int64(1),
			"lastTransitionTime": "2026-11-27T05:33:41Z",
		}}},
	}}
	machine := &clusterv1.Machine{ObjectMeta: metav1.ObjectMeta{Generation: 3}}

	mirror, err := capiconditions.NewMirrorConditionFromUnstructured(infraMachine, "Ready",
		capiconditions.TargetConditionType(clusterv1.MachineInfrastructureReadyCondition))
	require.NoError(t, err)
	capiconditions.Set(machine, *mirror)

	got, err := New().FailureDomainUnavailable(context.Background(), shared.MachineAdvanceDeps{}, machine)
	require.NoError(t, err)
	assert.True(t, got)
	assert.Equal(t, unavailableMessage, capiconditions.Get(machine, clusterv1.MachineInfrastructureReadyCondition).Message)
}
