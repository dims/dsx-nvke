// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package server

import (
	"github.com/dsx-ai-factory/nvke/controller/internal/db"
)

const (
	controlPlaneVIPRequiredMessage = "controlPlaneVIP is required to increase desired control-plane capacity above one; recreate the cluster with controlPlaneVIP configured"
	controlPlaneVIPUpgradeMessage  = "controlPlaneVIP is required to upgrade the control plane; recreate the cluster with controlPlaneVIP configured"
	controlPlaneVIPRolloutMessage  = "controlPlaneVIP is required to replace control-plane nodes; recreate the cluster with controlPlaneVIP configured before changing rollout-triggering control-plane configuration"
)

// validateControlPlaneCapacityChange lets existing clusters without a stable
// endpoint (no VIP and no controlPlaneEndpoint) keep or reduce capacity, but
// rejects growth beyond one control-plane node unless the dev override is enabled.
func (s *clusterService) validateControlPlaneCapacityChange(cluster *db.Cluster, current, desired int) error {
	if !s.allowControlPlaneWithoutVIP && !cluster.HasStableControlPlaneEndpoint() && desired > 1 && desired > current {
		return newBadRequestErrorf("%s", controlPlaneVIPRequiredMessage)
	}
	return nil
}

func (s *clusterService) validateControlPlaneUpgrade(cluster *db.Cluster) error {
	if !s.allowControlPlaneWithoutVIP && !cluster.HasStableControlPlaneEndpoint() {
		return newBadRequestErrorf("%s", controlPlaneVIPUpgradeMessage)
	}
	return nil
}

func (s *clusterService) validateControlPlaneRollout(cluster *db.Cluster, rolloutRequired bool) error {
	if !s.allowControlPlaneWithoutVIP && !cluster.HasStableControlPlaneEndpoint() && rolloutRequired {
		return newBadRequestErrorf("%s", controlPlaneVIPRolloutMessage)
	}
	return nil
}
