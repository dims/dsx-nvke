// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package server

import (
	"net/netip"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/dsx-ai-factory/nvke/controller/api"
	"github.com/dsx-ai-factory/nvke/controller/internal/db"
)

func TestResolveClusterNetwork(t *testing.T) {
	tests := []struct {
		name        string
		config      *api.ClusterNetworkCreateConfig
		wantPod     string
		wantService string
		wantError   string
	}{
		{
			name:        "defaults",
			wantPod:     defaultClusterPodCIDR,
			wantService: defaultClusterServiceCIDR,
		},
		{
			name: "canonicalizes host bits",
			config: &api.ClusterNetworkCreateConfig{
				PodCIDR:     "10.233.65.7/18",
				ServiceCIDR: "10.233.1.5/18",
			},
			wantPod:     "10.233.64.0/18",
			wantService: "10.233.0.0/18",
		},
		{
			name: "canonicalizes multiple pod CIDRs",
			config: &api.ClusterNetworkCreateConfig{
				PodCIDR:     "10.240.1.1/16, 10.241.1.1/16",
				ServiceCIDR: "10.120.0.0/16",
			},
			wantPod:     "10.240.0.0/16,10.241.0.0/16",
			wantService: "10.120.0.0/16",
		},
		{
			name: "defaults an omitted field",
			config: &api.ClusterNetworkCreateConfig{
				ServiceCIDR: "172.20.0.0/16",
			},
			wantPod:     defaultClusterPodCIDR,
			wantService: "172.20.0.0/16",
		},
		{
			name:      "rejects malformed CIDR",
			config:    &api.ClusterNetworkCreateConfig{PodCIDR: "not-a-cidr"},
			wantError: "not a valid CIDR",
		},
		{
			name:      "rejects empty pod CIDR list entries",
			config:    &api.ClusterNetworkCreateConfig{PodCIDR: "10.240.0.0/16,"},
			wantError: "empty CIDR entry",
		},
		{
			name:      "rejects IPv6",
			config:    &api.ClusterNetworkCreateConfig{PodCIDR: "fd00::/64"},
			wantError: "must be an IPv4 CIDR",
		},
		{
			name:      "rejects public address space",
			config:    &api.ClusterNetworkCreateConfig{PodCIDR: "8.8.0.0/16"},
			wantError: "RFC 1918 private address space",
		},
		{
			name:      "rejects prefix not fully contained in private address space",
			config:    &api.ClusterNetworkCreateConfig{PodCIDR: "192.168.0.0/15"},
			wantError: "RFC 1918 private address space",
		},
		{
			name:      "rejects range larger than supported",
			config:    &api.ClusterNetworkCreateConfig{PodCIDR: "10.0.0.0/8"},
			wantError: "prefix length between /12 and /23",
		},
		{
			name:      "rejects node-sized pod CIDR",
			config:    &api.ClusterNetworkCreateConfig{PodCIDR: "10.240.0.0/24"},
			wantError: "prefix length between /12 and /23",
		},
		{
			name:      "rejects range smaller than supported",
			config:    &api.ClusterNetworkCreateConfig{PodCIDR: "10.0.0.0/25"},
			wantError: "prefix length between /12 and /23",
		},
		{
			name:      "rejects OVN host subnet suffix",
			config:    &api.ClusterNetworkCreateConfig{PodCIDR: "10.240.0.0/16/24"},
			wantError: "not a valid CIDR",
		},
		{
			name:      "rejects overlapping pod CIDRs",
			config:    &api.ClusterNetworkCreateConfig{PodCIDR: "10.240.0.0/16,10.240.128.0/17"},
			wantError: "overlaps",
		},
		{
			name: "accepts a /24 service CIDR",
			config: &api.ClusterNetworkCreateConfig{
				PodCIDR:     "10.240.0.0/23",
				ServiceCIDR: "10.120.0.0/24",
			},
			wantPod:     "10.240.0.0/23",
			wantService: "10.120.0.0/24",
		},
		{
			name: "rejects overlapping pod and service ranges",
			config: &api.ClusterNetworkCreateConfig{
				PodCIDR:     "10.233.0.0/16",
				ServiceCIDR: "10.233.0.0/18",
			},
			wantError: "must not overlap",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			network, err := resolveClusterNetwork(tt.config)
			if tt.wantError != "" {
				require.Error(t, err)
				assert.Contains(t, err.Error(), tt.wantError)
				return
			}
			require.NoError(t, err)
			assert.Equal(t, tt.wantPod, network.podCIDR)
			assert.Equal(t, tt.wantService, network.serviceCIDR.String())
		})
	}
}

func TestResolvedClusterNetworkValidateCNI(t *testing.T) {
	defaultNetwork, err := resolveClusterNetwork(nil)
	require.NoError(t, err)
	assert.NoError(t, defaultNetwork.validateCNI(db.CNICalico))

	customNetwork, err := resolveClusterNetwork(&api.ClusterNetworkCreateConfig{
		PodCIDR:     "10.240.0.0/16,10.241.0.0/16",
		ServiceCIDR: "10.120.0.0/16",
	})
	require.NoError(t, err)
	assert.NoError(t, customNetwork.validateCNI(db.CNIOvnKubernetes))
	require.ErrorContains(t, customNetwork.validateCNI(db.CNICalico), "custom pod or service CIDRs require")
}

func TestValidatePodCIDRCapacity(t *testing.T) {
	tests := []struct {
		name            string
		podCIDR         string
		desiredNodes    int
		configuredSurge int
		wantError       string
	}{
		{
			name:         "/24 has no scaling headroom",
			podCIDR:      "10.240.0.0/24",
			desiredNodes: 1,
			wantError:    "provides 1 /24 node blocks, but 2 are required",
		},
		{
			name:         "/23 supports one node and one spare",
			podCIDR:      "10.240.0.0/23",
			desiredNodes: 1,
		},
		{
			name:         "/22 supports three nodes and one spare",
			podCIDR:      "10.240.0.0/22",
			desiredNodes: 3,
		},
		{
			name:         "/22 rejects four nodes without headroom",
			podCIDR:      "10.240.0.0/22",
			desiredNodes: 4,
			wantError:    "provides 4 /24 node blocks, but 5 are required",
		},
		{
			name:            "/21 supports configured surge greater than minimum headroom",
			podCIDR:         "10.240.0.0/21",
			desiredNodes:    4,
			configuredSurge: 2,
		},
		{
			name:         "multiple ranges contribute to capacity",
			podCIDR:      "10.240.0.0/23,10.242.0.0/23",
			desiredNodes: 3,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			parts := strings.Split(tt.podCIDR, ",")
			prefixes := make([]netip.Prefix, 0, len(parts))
			for _, part := range parts {
				prefixes = append(prefixes, netip.MustParsePrefix(part))
			}
			err := validatePodCIDRCapacity(
				prefixes,
				tt.desiredNodes,
				tt.configuredSurge,
			)
			if tt.wantError == "" {
				require.NoError(t, err)
				return
			}
			require.ErrorContains(t, err, tt.wantError)
		})
	}
}

func TestRequiredPodCIDRNodeBlocks(t *testing.T) {
	nodePools := []db.NodePool{
		{DesiredCount: 3, MaxSurge: 1},
		{DesiredCount: 1, MaxSurge: 0},
	}

	assert.Equal(t, 6, requiredPodCIDRNodeBlocks(nodePools, 1))
}

func TestPodCIDRNodePoolsWithClusterCP(t *testing.T) {
	nodePools := []db.NodePool{{DesiredCount: 3, MaxSurge: 1}}
	cluster := db.Cluster{ControlPlaneConfig: db.ControlPlaneConfig{DesiredCount: 3, MaxSurge: 1}}

	// A synthetic control-plane pool carries the cluster-level desired count
	// (MaxSurge stays zero because CP surge is supplied via clusterMaxSurge).
	augmented := podCIDRNodePoolsWithClusterCP(cluster, nodePools)
	assert.Len(t, augmented, len(nodePools)+1)
	cp := augmented[len(augmented)-1]
	assert.True(t, cp.ControlPlane)
	assert.Equal(t, 3, cp.DesiredCount)
	assert.Equal(t, 0, cp.MaxSurge)

	// 3 worker + 3 CP desired = 6 nodes; headroom = max(1, clusterMaxSurge=1 +
	// worker surge=1 + CP surge=0) = 2, so 8 blocks.
	assert.Equal(t, 8, requiredPodCIDRNodeBlocks(augmented, cluster.ControlPlaneConfig.MaxSurge))
}

func TestResolvedClusterNetworkValidateControlPlaneVIP(t *testing.T) {
	network, err := resolveClusterNetwork(&api.ClusterNetworkCreateConfig{
		PodCIDR:     "10.232.64.0/18,10.233.64.0/18",
		ServiceCIDR: "10.233.0.0/18",
	})
	require.NoError(t, err)

	require.ErrorContains(t, network.validateControlPlaneVIP("2001:db8::1"), "IPv4")
	require.ErrorContains(t, network.validateControlPlaneVIP("10.233.64.10"), "controlPlaneVIP")
	require.ErrorContains(t, network.validateControlPlaneVIP("10.233.64.10"), "network.podCIDR")
	require.ErrorContains(t, network.validateControlPlaneVIP("10.233.0.10"), "controlPlaneVIP")
	require.ErrorContains(t, network.validateControlPlaneVIP("10.233.0.10"), "network.serviceCIDR")
	assert.NoError(t, network.validateControlPlaneVIP("172.31.0.10"))
}

func TestResolvedClusterNetworkValidateControlPlaneEndpoint(t *testing.T) {
	network, err := resolveClusterNetwork(&api.ClusterNetworkCreateConfig{
		PodCIDR:     "10.232.64.0/18,10.233.64.0/18",
		ServiceCIDR: "10.233.0.0/18",
	})
	require.NoError(t, err)

	tests := []struct {
		name     string
		endpoint string
		// wantErr lists the parts the error must contain. Empty means valid.
		wantErr []string
	}{
		{name: "an IPv4 address", endpoint: "172.31.0.10"},
		{name: "an IPv4 address with a port", endpoint: "172.31.0.10:6443"},
		{name: "a DNS name", endpoint: "lb.example.com"},
		{name: "a DNS name with a port", endpoint: "lb.example.com:8443"},
		{name: "a single-label DNS name with the highest port", endpoint: "api-1:65535"},
		{name: "a DNS name is not checked against the CIDRs", endpoint: "10-233-64-10.example.com:6443"},

		{name: "an IPv4 host inside a pod CIDR", endpoint: "10.233.64.10:6443", wantErr: []string{"controlPlaneEndpoint", "network.podCIDR"}},
		{name: "an IPv4 host inside the second pod CIDR", endpoint: "10.232.64.10", wantErr: []string{"controlPlaneEndpoint", "network.podCIDR"}},
		{name: "an IPv4 host inside the service CIDR", endpoint: "10.233.0.10:6443", wantErr: []string{"controlPlaneEndpoint", "network.serviceCIDR"}},

		{name: "an empty value", endpoint: "", wantErr: []string{"the host is empty"}},
		{name: "a port without a host", endpoint: ":6443", wantErr: []string{"the host is empty"}},
		{name: "a colon without a port", endpoint: "lb.example.com:", wantErr: []string{"port"}},
		{name: "port zero", endpoint: "lb.example.com:0", wantErr: []string{"port"}},
		{name: "a port above the range", endpoint: "lb.example.com:65536", wantErr: []string{"port"}},
		{name: "a port name", endpoint: "lb.example.com:https", wantErr: []string{"port"}},
		{name: "a signed port", endpoint: "lb.example.com:+6443", wantErr: []string{"port"}},
		{name: "a space after the port", endpoint: "lb.example.com:6443 ", wantErr: []string{"port"}},
		{name: "an IPv6 address", endpoint: "2001:db8::1", wantErr: []string{"IPv4 address or a DNS name"}},
		{name: "an IPv6 address in brackets with a port", endpoint: "[2001:db8::1]:6443", wantErr: []string{"IPv4 address or a DNS name"}},
		{name: "a URL", endpoint: "https://lb.example.com:6443", wantErr: []string{"IPv4 address or a DNS name"}},
		{name: "an IPv4 address with an octet out of range", endpoint: "10.233.0.300:6443", wantErr: []string{"not a valid IPv4 address"}},
		{name: "an IPv4 address with too few octets", endpoint: "10.233", wantErr: []string{"not a valid IPv4 address"}},
		{name: "an upper-case DNS name", endpoint: "LB.example.com", wantErr: []string{"IPv4 address or a DNS name"}},
		{name: "a DNS name with an underscore", endpoint: "lb_1.example.com:6443", wantErr: []string{"IPv4 address or a DNS name"}},
		{name: "a space before the host", endpoint: " lb.example.com", wantErr: []string{"IPv4 address or a DNS name"}},
		{name: "a blank value", endpoint: " ", wantErr: []string{"IPv4 address or a DNS name"}},
		{name: "a path after the host", endpoint: "lb.example.com/api", wantErr: []string{"IPv4 address or a DNS name"}},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := network.validateControlPlaneEndpoint(tt.endpoint)
			if len(tt.wantErr) == 0 {
				require.NoError(t, err)
				return
			}
			require.Error(t, err)
			for _, part := range tt.wantErr {
				assert.ErrorContains(t, err, part)
			}
		})
	}
}

func TestResolvedClusterNetworkValidateAPIServerEndpointFields(t *testing.T) {
	network, err := resolveClusterNetwork(&api.ClusterNetworkCreateConfig{
		PodCIDR:     "10.232.64.0/18,10.233.64.0/18",
		ServiceCIDR: "10.233.0.0/18",
	})
	require.NoError(t, err)

	tests := []struct {
		name                 string
		controlPlaneVIP      string
		controlPlaneEndpoint string
		wantErr              string
	}{
		{name: "neither field"},
		{name: "a valid VIP", controlPlaneVIP: "172.31.0.10"},
		{name: "a valid endpoint", controlPlaneEndpoint: "lb.example.com:6443"},
		{name: "both fields", controlPlaneVIP: "172.31.0.10", controlPlaneEndpoint: "lb.example.com:6443", wantErr: "mutually exclusive"},
		{name: "both fields with the same address", controlPlaneVIP: "172.31.0.10", controlPlaneEndpoint: "172.31.0.10", wantErr: "mutually exclusive"},
		{name: "an invalid VIP", controlPlaneVIP: "10.233.0.10", wantErr: "controlPlaneVIP"},
		{name: "an invalid endpoint", controlPlaneEndpoint: "10.233.0.10:6443", wantErr: "controlPlaneEndpoint"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := network.validateAPIServerEndpointFields(tt.controlPlaneVIP, tt.controlPlaneEndpoint)
			if tt.wantErr == "" {
				require.NoError(t, err)
				return
			}
			require.ErrorContains(t, err, tt.wantErr)
		})
	}
}
