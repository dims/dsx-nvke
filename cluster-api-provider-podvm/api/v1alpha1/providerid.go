// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package v1alpha1

import (
	"fmt"
	"strings"
)

const (
	// ProviderIDScheme is the scheme of every provider ID that this provider
	// writes.
	ProviderIDScheme = "podvm"

	providerIDPrefix = ProviderIDScheme + "://"
)

// FormatProviderID builds the provider ID of a machine from the namespace and
// the name of its pod.
func FormatProviderID(podNamespace, podName string) string {
	return providerIDPrefix + podNamespace + "/" + podName
}

// ParseProviderID returns the pod namespace and the pod name of a provider ID
// that this provider wrote. It returns an error for any other provider ID, so
// a caller never reads a pod out of the value of another provider.
func ParseProviderID(providerID string) (string, string, error) {
	rest, found := strings.CutPrefix(providerID, providerIDPrefix)
	if !found {
		return "", "", fmt.Errorf("provider ID %q does not start with %q", providerID, providerIDPrefix)
	}

	podNamespace, podName, found := strings.Cut(rest, "/")
	if !found || podNamespace == "" || podName == "" || strings.Contains(podName, "/") {
		return "", "", fmt.Errorf("provider ID %q must have the form %s<pod-namespace>/<pod-name>", providerID, providerIDPrefix)
	}

	return podNamespace, podName, nil
}
