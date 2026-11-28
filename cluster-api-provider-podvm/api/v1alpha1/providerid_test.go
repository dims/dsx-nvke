// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package v1alpha1

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestFormatAndParseProviderID(t *testing.T) {
	providerID := FormatProviderID("cluster-pods", "test-cp-a1b2")
	require.Equal(t, "podvm://cluster-pods/test-cp-a1b2", providerID)

	podNamespace, podName, err := ParseProviderID(providerID)
	require.NoError(t, err)
	require.Equal(t, "cluster-pods", podNamespace)
	require.Equal(t, "test-cp-a1b2", podName)
}

// A provider ID of another provider, or one that names no pod, must never
// yield a pod that this provider then deletes.
func TestParseProviderIDRejectsOtherForms(t *testing.T) {
	tests := []struct {
		name       string
		providerID string
	}{
		{name: "empty", providerID: ""},
		{name: "another provider", providerID: "nico://instance-1"},
		{name: "provisioned provider", providerID: "provisioned://cluster/10.0.0.11"},
		{name: "scheme only", providerID: "podvm://"},
		{name: "no pod name", providerID: "podvm://only-namespace"},
		{name: "empty pod name", providerID: "podvm://namespace/"},
		{name: "empty namespace", providerID: "podvm:///pod"},
		{name: "one part too many", providerID: "podvm://namespace/pod/extra"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, _, err := ParseProviderID(test.providerID)
			require.Error(t, err)
		})
	}
}
