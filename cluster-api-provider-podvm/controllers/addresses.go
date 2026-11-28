// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package controllers

import (
	"fmt"
	"net/netip"

	infrav1 "github.com/dsx-ai-factory/nvke/cluster-api-provider-podvm/api/v1alpha1"
)

// addressRange is the checked form of spec.addressRange of a PodVMCluster.
type addressRange struct {
	// block holds the addresses that the provider gives out.
	block netip.Prefix
	// network is the node network: the block address with the prefix length
	// of the node network.
	network netip.Prefix
}

// parseAddressRange checks spec.addressRange and returns its checked form.
//
// The hardware address of a pod comes from the four bytes of its address, so
// the block must be IPv4.
func parseAddressRange(spec infrav1.AddressRange) (addressRange, error) {
	block, err := netip.ParsePrefix(spec.CIDR)
	if err != nil {
		return addressRange{}, fmt.Errorf("cidr %q is not a CIDR block: %w", spec.CIDR, err)
	}
	if !block.Addr().Is4() {
		return addressRange{}, fmt.Errorf("cidr %q is not an IPv4 block", spec.CIDR)
	}
	if block.Masked() != block {
		return addressRange{}, fmt.Errorf("cidr %q has host bits set, use %s", spec.CIDR, block.Masked())
	}

	prefixLength := int(spec.PrefixLength)
	if prefixLength < 1 || prefixLength > block.Addr().BitLen() {
		return addressRange{}, fmt.Errorf("prefixLength %d is not between 1 and %d", prefixLength, block.Addr().BitLen())
	}
	if prefixLength > block.Bits() {
		return addressRange{}, fmt.Errorf(
			"prefixLength %d is larger than the prefix length of cidr %q, so the node network does not contain the block",
			prefixLength, spec.CIDR,
		)
	}

	network, err := block.Addr().Prefix(prefixLength)
	if err != nil {
		return addressRange{}, fmt.Errorf("prefixLength %d does not fit cidr %q: %w", prefixLength, spec.CIDR, err)
	}

	checked := addressRange{block: block, network: network}
	if _, found := checked.firstFree(nil); !found {
		return addressRange{}, fmt.Errorf("cidr %q with prefixLength %d holds no usable address", spec.CIDR, prefixLength)
	}
	return checked, nil
}

// overlaps reports whether two ranges share an address.
func (r addressRange) overlaps(other addressRange) bool {
	return r.block.Overlaps(other.block)
}

// usable reports whether the provider can give the address to a pod.
//
// The first and the last address of the block stay free, the way the network
// address and the broadcast address of a subnet do. The network address and
// the broadcast address of the node network are never usable. A block of one
// or two addresses has no first and last address to leave out.
func (r addressRange) usable(address netip.Addr) bool {
	if !r.block.Contains(address) {
		return false
	}
	if r.block.Bits() < 31 && (address == r.block.Addr() || address == lastAddress(r.block)) {
		return false
	}
	if r.network.Bits() < 31 && (address == r.network.Addr() || address == lastAddress(r.network)) {
		return false
	}
	return true
}

// firstFree returns the lowest usable address that no machine holds.
//
// The order is fixed, so two reconciles of the same state give the same
// answer.
func (r addressRange) firstFree(used addressAllocations) (netip.Addr, bool) {
	for address := r.block.Addr(); address.IsValid() && r.block.Contains(address); address = address.Next() {
		if !r.usable(address) {
			continue
		}
		if _, held := used[address]; held {
			continue
		}
		return address, true
	}
	return netip.Addr{}, false
}

// lastAddress returns the highest address of an IPv4 prefix.
func lastAddress(prefix netip.Prefix) netip.Addr {
	bytes := prefix.Masked().Addr().As4()
	hostBits := 32 - prefix.Bits()
	for i := 3; i >= 0 && hostBits > 0; i-- {
		bits := min(hostBits, 8)
		bytes[i] |= byte(0xff >> (8 - bits))
		hostBits -= bits
	}
	return netip.AddrFrom4(bytes)
}

// hardwareAddress derives the fixed hardware address of a pod from its
// address: 02:00 and the four bytes of the IPv4 address. The first byte marks
// the address as locally administered.
func hardwareAddress(address netip.Addr) string {
	bytes := address.As4()
	return fmt.Sprintf("02:00:%02x:%02x:%02x:%02x", bytes[0], bytes[1], bytes[2], bytes[3])
}

// addressAllocations maps an address to the PodVMMachine that holds it, as
// <namespace>/<name>.
type addressAllocations map[netip.Addr]string

// allocationsFromMachines reads the address of every machine.
//
// The provider derives this set on every allocation instead of keeping it in
// a second object. status.address of a machine is the only record, so the set
// is as current as the API server and it survives a restart of the provider.
// A machine that is being deleted still holds its address: the address is free
// when the object is gone.
func allocationsFromMachines(machines []infrav1.PodVMMachine) addressAllocations {
	allocations := make(addressAllocations, len(machines))
	for i := range machines {
		machine := &machines[i]
		if machine.Status.Address == "" {
			continue
		}
		address, err := netip.ParseAddr(machine.Status.Address)
		if err != nil {
			continue
		}
		allocations[address] = machine.Namespace + "/" + machine.Name
	}
	return allocations
}
