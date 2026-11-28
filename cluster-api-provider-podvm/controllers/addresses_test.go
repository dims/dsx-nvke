// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package controllers

import (
	"net/netip"
	"testing"

	"github.com/stretchr/testify/require"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	infrav1 "github.com/dsx-ai-factory/nvke/cluster-api-provider-podvm/api/v1alpha1"
)

func TestParseAddressRange(t *testing.T) {
	tests := []struct {
		name         string
		cidr         string
		prefixLength int32
		wantNetwork  string
		wantError    string
	}{
		{name: "a /24 range inside a /16 node network", cidr: "172.28.1.0/24", prefixLength: 16, wantNetwork: "172.28.0.0/16"},
		{name: "a range that is the whole node network", cidr: "10.0.0.0/24", prefixLength: 24, wantNetwork: "10.0.0.0/24"},
		{name: "a single address", cidr: "10.0.0.7/32", prefixLength: 24, wantNetwork: "10.0.0.0/24"},
		{name: "not a CIDR block", cidr: "172.28.1.0", prefixLength: 16, wantError: "is not a CIDR block"},
		{name: "an IPv6 block", cidr: "2001:db8::/64", prefixLength: 64, wantError: "is not an IPv4 block"},
		{name: "an IPv4 block in IPv6 form", cidr: "::ffff:10.0.0.0/120", prefixLength: 24, wantError: "is not an IPv4 block"},
		{name: "host bits set", cidr: "172.28.1.5/24", prefixLength: 16, wantError: "has host bits set, use 172.28.1.0/24"},
		{name: "prefix length zero", cidr: "172.28.1.0/24", prefixLength: 0, wantError: "is not between 1 and 32"},
		{name: "prefix length above 32", cidr: "172.28.1.0/24", prefixLength: 33, wantError: "is not between 1 and 32"},
		{name: "node network smaller than the block", cidr: "172.28.0.0/16", prefixLength: 24, wantError: "does not contain the block"},
		{name: "only the network address of the node network", cidr: "10.0.0.0/32", prefixLength: 24, wantError: "holds no usable address"},
		{name: "only the broadcast address of the node network", cidr: "10.0.0.255/32", prefixLength: 24, wantError: "holds no usable address"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			checked, err := parseAddressRange(infrav1.AddressRange{CIDR: test.cidr, PrefixLength: test.prefixLength})
			if test.wantError != "" {
				require.ErrorContains(t, err, test.wantError)
				return
			}
			require.NoError(t, err)
			require.Equal(t, test.cidr, checked.block.String())
			require.Equal(t, test.wantNetwork, checked.network.String())
		})
	}
}

func TestAddressRangeFirstFree(t *testing.T) {
	tests := []struct {
		name         string
		cidr         string
		prefixLength int32
		used         []string
		want         string
		wantNone     bool
	}{
		{name: "skips the first address of the block", cidr: "172.28.1.0/24", prefixLength: 16, want: "172.28.1.1"},
		{name: "takes the lowest free address", cidr: "172.28.1.0/24", prefixLength: 16,
			used: []string{"172.28.1.1", "172.28.1.2", "172.28.1.4"}, want: "172.28.1.3"},
		{name: "ignores an address of another range", cidr: "172.28.1.0/24", prefixLength: 16,
			used: []string{"172.28.2.1"}, want: "172.28.1.1"},
		{name: "never gives the last address of the block", cidr: "10.0.0.0/30", prefixLength: 24,
			used: []string{"10.0.0.1", "10.0.0.2"}, wantNone: true},
		{name: "a block of two addresses has no first and last to leave out", cidr: "10.0.0.4/31", prefixLength: 24,
			want: "10.0.0.4"},
		{name: "a block of two addresses at the start of the node network", cidr: "10.0.0.0/31", prefixLength: 24,
			want: "10.0.0.1"},
		{name: "a full range", cidr: "10.0.0.4/31", prefixLength: 24,
			used: []string{"10.0.0.4", "10.0.0.5"}, wantNone: true},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			checked, err := parseAddressRange(infrav1.AddressRange{CIDR: test.cidr, PrefixLength: test.prefixLength})
			require.NoError(t, err)

			used := addressAllocations{}
			for _, address := range test.used {
				used[netip.MustParseAddr(address)] = "holder"
			}

			address, found := checked.firstFree(used)
			if test.wantNone {
				require.False(t, found, "got %s", address)
				return
			}
			require.True(t, found)
			require.Equal(t, test.want, address.String())
		})
	}
}

// A /24 range inside a /16 node network gives out 254 addresses: .1 to .254.
func TestAddressRangeGivesEveryUsableAddressOnce(t *testing.T) {
	checked, err := parseAddressRange(infrav1.AddressRange{CIDR: testCIDR, PrefixLength: testPrefixLength})
	require.NoError(t, err)

	used := addressAllocations{}
	for {
		address, found := checked.firstFree(used)
		if !found {
			break
		}
		_, twice := used[address]
		require.False(t, twice, "address %s was given twice", address)
		used[address] = "holder"
	}

	require.Len(t, used, 254)
	require.NotContains(t, used, netip.MustParseAddr("172.28.1.0"))
	require.NotContains(t, used, netip.MustParseAddr("172.28.1.255"))
	require.Contains(t, used, netip.MustParseAddr("172.28.1.1"))
	require.Contains(t, used, netip.MustParseAddr("172.28.1.254"))
}

func TestAddressRangeOverlaps(t *testing.T) {
	tests := []struct {
		name  string
		other string
		want  bool
	}{
		{name: "the same block", other: "172.28.1.0/24", want: true},
		{name: "a block inside it", other: "172.28.1.128/25", want: true},
		{name: "a block around it", other: "172.28.0.0/22", want: true},
		{name: "the next block", other: "172.28.2.0/24", want: false},
	}

	base, err := parseAddressRange(infrav1.AddressRange{CIDR: testCIDR, PrefixLength: testPrefixLength})
	require.NoError(t, err)

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			other, err := parseAddressRange(infrav1.AddressRange{CIDR: test.other, PrefixLength: testPrefixLength})
			require.NoError(t, err)
			require.Equal(t, test.want, base.overlaps(other))
			require.Equal(t, test.want, other.overlaps(base))
		})
	}
}

// The node image and the network attachment both rely on this form: 02:00 and
// the four bytes of the address.
func TestHardwareAddress(t *testing.T) {
	tests := []struct {
		address string
		want    string
	}{
		{address: "172.28.1.21", want: "02:00:ac:1c:01:15"},
		{address: "172.28.1.1", want: "02:00:ac:1c:01:01"},
		{address: "10.0.0.255", want: "02:00:0a:00:00:ff"},
		{address: "192.168.200.7", want: "02:00:c0:a8:c8:07"},
	}

	for _, test := range tests {
		t.Run(test.address, func(t *testing.T) {
			require.Equal(t, test.want, hardwareAddress(netip.MustParseAddr(test.address)))
		})
	}
}

func TestLastAddress(t *testing.T) {
	tests := []struct {
		prefix string
		want   string
	}{
		{prefix: "172.28.1.0/24", want: "172.28.1.255"},
		{prefix: "172.28.0.0/16", want: "172.28.255.255"},
		{prefix: "10.0.0.4/31", want: "10.0.0.5"},
		{prefix: "10.0.0.7/32", want: "10.0.0.7"},
		{prefix: "10.0.0.0/20", want: "10.0.15.255"},
	}

	for _, test := range tests {
		t.Run(test.prefix, func(t *testing.T) {
			require.Equal(t, test.want, lastAddress(netip.MustParsePrefix(test.prefix)).String())
		})
	}
}

// A machine that is being deleted still holds its address: its pod may still
// run. A machine with no address, or with an unreadable one, holds nothing.
func TestAllocationsFromMachines(t *testing.T) {
	deleting := newAllocatedInfraMachine("deleting", "172.28.1.2")
	now := metav1.Now()
	deleting.DeletionTimestamp = &now

	unreadable := newInfraMachine("unreadable")
	unreadable.Status.Address = "not-an-address"

	allocations := allocationsFromMachines([]infrav1.PodVMMachine{
		*newAllocatedInfraMachine("first", "172.28.1.1"),
		*deleting,
		*newInfraMachine("pending"),
		*unreadable,
	})

	require.Equal(t, addressAllocations{
		netip.MustParseAddr("172.28.1.1"): testNamespace + "/first",
		netip.MustParseAddr("172.28.1.2"): testNamespace + "/deleting",
	}, allocations)
}
