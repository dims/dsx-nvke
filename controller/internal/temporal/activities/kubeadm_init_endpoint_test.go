// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package activities

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/dsx-ai-factory/nvke/controller/internal/agent/agenttest"
	"github.com/dsx-ai-factory/nvke/controller/internal/db"
)

func TestKubeadmControlPlaneEndpoint(t *testing.T) {
	const nodeIP = "192.0.2.10"

	tests := []struct {
		name    string
		cluster db.Cluster
		want    string
	}{
		{
			name:    "an endpoint that NVKE does not manage, with a port",
			cluster: db.Cluster{ControlPlaneEndpoint: "172.18.255.200:6443"},
			want:    "172.18.255.200:6443",
		},
		{
			name:    "an endpoint that NVKE does not manage, as a DNS name without a port",
			cluster: db.Cluster{ControlPlaneEndpoint: "lb.example.com"},
			want:    "lb.example.com",
		},
		{
			name:    "a VIP",
			cluster: db.Cluster{ControlPlaneVIP: "172.31.0.10"},
			want:    "172.31.0.10",
		},
		{
			name:    "no endpoint and no VIP falls back to the node IP",
			cluster: db.Cluster{},
			want:    nodeIP,
		},
		{
			// The API rejects this pair. The order still has to be defined.
			name:    "the endpoint comes before the VIP",
			cluster: db.Cluster{ControlPlaneEndpoint: "lb.example.com:6443", ControlPlaneVIP: "172.31.0.10"},
			want:    "lb.example.com:6443",
		},
		{
			name:    "a blank endpoint falls through to the VIP",
			cluster: db.Cluster{ControlPlaneEndpoint: " ", ControlPlaneVIP: "172.31.0.10"},
			want:    "172.31.0.10",
		},
		{
			name:    "a blank endpoint and a blank VIP fall back to the node IP",
			cluster: db.Cluster{ControlPlaneEndpoint: " ", ControlPlaneVIP: "\t"},
			want:    nodeIP,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			assert.Equal(t, tt.want, kubeadmControlPlaneEndpoint(tt.cluster, nodeIP))
		})
	}
}

// The choice has to reach both places the agent reads: the request field and
// the ClusterConfiguration that kubeadm init runs with.
func TestKubeadmInitSendsControlPlaneEndpoint(t *testing.T) {
	tests := []struct {
		name                 string
		controlPlaneEndpoint string
		controlPlaneVIP      string
		// want is empty when the node IP of the fixture is expected.
		want string
	}{
		{
			name:                 "an endpoint that NVKE does not manage",
			controlPlaneEndpoint: "172.18.255.200:6443",
			want:                 "172.18.255.200:6443",
		},
		{
			name:            "a VIP",
			controlPlaneVIP: "172.31.0.10",
			want:            "172.31.0.10",
		},
		{
			name: "the node IP",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cluster, initialNode, nodeSet, nodePool := snapshotInitRecords()
			cluster.ControlPlaneEndpoint = tt.controlPlaneEndpoint
			cluster.ControlPlaneVIP = tt.controlPlaneVIP
			want := tt.want
			if want == "" {
				want = initialNode.IP
			}
			database := snapshotInitDatabase(cluster, initialNode, nodeSet, nodePool)
			agent := &snapshotWiringAgent{FakeClient: &agenttest.FakeClient{}, initStatus: true}
			a := snapshotActivities(database, agent, snapshotSharedConfig())

			require.NoError(t, executeSnapshotInit(t, a, KubeadmInitInput{ClusterID: cluster.ID, InitialNodeID: initialNode.ID}))

			request := requireSingleInitRequest(t, agent)
			assert.Equal(t, want, request.GetControlPlaneEndpoint())
			assert.Contains(t, request.GetInitConfig(), "controlPlaneEndpoint: "+want+"\n")
			database.AssertExpectations(t)
		})
	}
}
