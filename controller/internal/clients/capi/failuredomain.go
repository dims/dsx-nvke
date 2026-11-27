// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package capi

import (
	"context"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	clusterv1 "sigs.k8s.io/cluster-api/api/core/v1beta2"
	capiconditions "sigs.k8s.io/cluster-api/util/conditions"

	"github.com/dsx-ai-factory/nvke/controller/internal/clients/shared"
)

const (
	// failureDomainUnavailableReason is the reason a template-backed
	// infrastructure provider sets on its infrastructure machine's Ready
	// condition when it cannot place the machine in the failure domain the
	// Machine requests. CAPNICo uses the same text on its own condition.
	failureDomainUnavailableReason = "FailureDomainUnavailable"
)

// FailureDomainUnavailable reports whether the infrastructure provider reports
// that it cannot place machine in its requested failure domain.
//
// This is the contract for a template-backed provider. The provider sets the
// Ready condition of its infrastructure machine to status False with reason
// FailureDomainUnavailable while Machine.spec.failureDomain has no capacity for
// the machine, and to any other reason once it does or when the cause is
// something else. The condition message is free text; it becomes the node's
// pending message.
//
// The condition is read from the Machine, not from the infrastructure machine.
// Cluster API mirrors the infrastructure machine's Ready condition into the
// Machine's InfrastructureReady condition and keeps the status, reason and
// message as the provider wrote them. Reading the mirror needs no API version
// for the provider's kind and no further API call, so deps is unused.
func (*Client) FailureDomainUnavailable(_ context.Context, _ shared.MachineAdvanceDeps, machine *clusterv1.Machine) (bool, error) {
	return isFailureDomainUnavailable(machine), nil
}

func isFailureDomainUnavailable(machine *clusterv1.Machine) bool {
	infrastructureReady := capiconditions.Get(machine, clusterv1.MachineInfrastructureReadyCondition)
	return infrastructureReady != nil &&
		infrastructureReady.Status == metav1.ConditionFalse &&
		infrastructureReady.Reason == failureDomainUnavailableReason &&
		// Cluster API stamps the mirror with the Machine's generation, not the
		// infrastructure machine's. A condition from an older generation predates
		// a Machine spec change Cluster API has not reconciled yet.
		(infrastructureReady.ObservedGeneration == 0 || infrastructureReady.ObservedGeneration >= machine.Generation)
}
