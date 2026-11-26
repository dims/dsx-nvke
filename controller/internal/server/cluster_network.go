// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package server

import (
	"errors"
	"fmt"
	"net/netip"
	"strconv"
	"strings"

	"k8s.io/apimachinery/pkg/util/validation"

	"github.com/dsx-ai-factory/nvke/controller/api"
	"github.com/dsx-ai-factory/nvke/controller/internal/db"
)

const (
	defaultClusterPodCIDR     = "192.168.0.0/16"
	defaultClusterServiceCIDR = "10.96.0.0/12"
	minClusterCIDRPrefixBits  = 12
	maxClusterCIDRPrefixBits  = 24
	maxPodCIDRPrefixBits      = 23
	podCIDRNodePrefixBits     = 24
	minimumPodCIDRHeadroom    = 1
)

type resolvedClusterNetwork struct {
	podCIDR         string
	podCIDRPrefixes []netip.Prefix
	serviceCIDR     netip.Prefix
}

func (n resolvedClusterNetwork) validateCNI(cni db.CniPlugin) error {
	usesDefaults := n.podCIDR == defaultClusterPodCIDR &&
		n.serviceCIDR.String() == defaultClusterServiceCIDR
	if cni != db.CNIOvnKubernetes && !usesDefaults {
		return fmt.Errorf("custom pod or service CIDRs require CNI plugin %q", db.CNIOvnKubernetes)
	}
	return nil
}

func validatePodCIDRCapacity(podCIDRs []netip.Prefix, desiredNodes, configuredSurge int) error {
	headroom := max(minimumPodCIDRHeadroom, configuredSurge)
	requiredNodeBlocks := desiredNodes + headroom
	availableNodeBlocks := 0
	podCIDRParts := make([]string, 0, len(podCIDRs))
	for _, podCIDR := range podCIDRs {
		availableNodeBlocks += 1 << (podCIDRNodePrefixBits - podCIDR.Bits())
		podCIDRParts = append(podCIDRParts, podCIDR.String())
	}
	if availableNodeBlocks < requiredNodeBlocks {
		return fmt.Errorf(
			"network.podCIDR %q provides %d /%d node blocks, but %d are required for %d desired nodes plus %d surge/headroom; choose a larger pod CIDR",
			strings.Join(podCIDRParts, ","),
			availableNodeBlocks,
			podCIDRNodePrefixBits,
			requiredNodeBlocks,
			desiredNodes,
			headroom,
		)
	}
	return nil
}

func podCIDRCapacityRequirement(nodePools []db.NodePool, clusterMaxSurge int) (int, int) {
	desiredNodes := 0
	configuredSurge := clusterMaxSurge
	for _, nodePool := range nodePools {
		desiredNodes += nodePool.DesiredCount
		configuredSurge += nodePool.MaxSurge
	}
	return desiredNodes, configuredSurge
}

func requiredPodCIDRNodeBlocks(nodePools []db.NodePool, clusterMaxSurge int) int {
	desiredNodes, configuredSurge := podCIDRCapacityRequirement(nodePools, clusterMaxSurge)
	return desiredNodes + max(minimumPodCIDRHeadroom, configuredSurge)
}

func validateStoredPodCIDRCapacity(cluster db.Cluster, nodePools []db.NodePool) error {
	network, err := resolveStoredClusterNetwork(cluster)
	if err != nil {
		return fmt.Errorf("invalid stored cluster network: %w", err)
	}
	desiredNodes, configuredSurge := podCIDRCapacityRequirement(nodePools, cluster.ControlPlaneConfig.MaxSurge)
	return validatePodCIDRCapacity(network.podCIDRPrefixes, desiredNodes, configuredSurge)
}

func resolveClusterNetwork(config *api.ClusterNetworkCreateConfig) (resolvedClusterNetwork, error) {
	podCIDR := defaultClusterPodCIDR
	serviceCIDR := defaultClusterServiceCIDR
	if config != nil {
		if config.PodCIDR != "" {
			podCIDR = config.PodCIDR
		}
		if config.ServiceCIDR != "" {
			serviceCIDR = config.ServiceCIDR
		}
	}

	podCIDRPrefixes, canonicalPodCIDR, err := parseClusterPodCIDRs("network.podCIDR", podCIDR)
	if err != nil {
		return resolvedClusterNetwork{}, err
	}
	servicePrefix, err := parseClusterCIDR("network.serviceCIDR", serviceCIDR, maxClusterCIDRPrefixBits)
	if err != nil {
		return resolvedClusterNetwork{}, err
	}
	for _, podPrefix := range podCIDRPrefixes {
		if podPrefix.Overlaps(servicePrefix) {
			return resolvedClusterNetwork{}, fmt.Errorf(
				"network.podCIDR %q and network.serviceCIDR %q must not overlap",
				podPrefix,
				servicePrefix,
			)
		}
	}

	return resolvedClusterNetwork{
		podCIDR:         canonicalPodCIDR,
		podCIDRPrefixes: podCIDRPrefixes,
		serviceCIDR:     servicePrefix,
	}, nil
}

func resolveStoredClusterNetwork(cluster db.Cluster) (resolvedClusterNetwork, error) {
	if cluster.PodCIDR == "" || cluster.ServiceCIDR == "" {
		return resolvedClusterNetwork{}, fmt.Errorf("stored pod and service CIDRs must both be set")
	}
	podCIDRPrefixes, canonicalPodCIDR, err := parseClusterPodCIDRs("cluster pod CIDR", cluster.PodCIDR)
	if err != nil {
		return resolvedClusterNetwork{}, err
	}
	serviceCIDR, err := parseClusterCIDR("cluster service CIDR", cluster.ServiceCIDR, maxClusterCIDRPrefixBits)
	if err != nil {
		return resolvedClusterNetwork{}, err
	}
	for _, podPrefix := range podCIDRPrefixes {
		if podPrefix.Overlaps(serviceCIDR) {
			return resolvedClusterNetwork{}, fmt.Errorf(
				"stored pod CIDR %q and service CIDR %q overlap",
				podPrefix,
				serviceCIDR,
			)
		}
	}
	return resolvedClusterNetwork{podCIDR: canonicalPodCIDR, podCIDRPrefixes: podCIDRPrefixes, serviceCIDR: serviceCIDR}, nil
}

func parseClusterPodCIDRs(field, value string) ([]netip.Prefix, string, error) {
	parts := strings.Split(value, ",")
	prefixes := make([]netip.Prefix, 0, len(parts))
	canonicalParts := make([]string, 0, len(parts))

	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part == "" {
			return nil, "", fmt.Errorf("%s %q contains an empty CIDR entry", field, value)
		}

		prefix, err := parseClusterCIDR(field, part, maxPodCIDRPrefixBits)
		if err != nil {
			return nil, "", err
		}
		for _, existing := range prefixes {
			if existing.Overlaps(prefix) {
				return nil, "", fmt.Errorf("%s %q overlaps %q", field, prefix, existing)
			}
		}

		prefixes = append(prefixes, prefix)
		canonicalParts = append(canonicalParts, prefix.String())
	}

	return prefixes, strings.Join(canonicalParts, ","), nil
}

func parseClusterCIDR(field, value string, maxPrefixBits int) (netip.Prefix, error) {
	prefix, err := netip.ParsePrefix(value)
	if err != nil {
		return netip.Prefix{}, fmt.Errorf("%s %q is not a valid CIDR: %w", field, value, err)
	}
	if !prefix.Addr().Is4() {
		return netip.Prefix{}, fmt.Errorf("%s %q must be an IPv4 CIDR", field, value)
	}

	prefix = prefix.Masked()
	if prefix.Bits() < minClusterCIDRPrefixBits || prefix.Bits() > maxPrefixBits {
		return netip.Prefix{}, fmt.Errorf(
			"%s %q must have a prefix length between /%d and /%d",
			field,
			value,
			minClusterCIDRPrefixBits,
			maxPrefixBits,
		)
	}
	if !isContainedInPrivateAddressSpace(prefix) {
		return netip.Prefix{}, fmt.Errorf("%s %q must be contained in RFC 1918 private address space", field, value)
	}
	return prefix, nil
}

// isContainedInPrivateAddressSpace reports whether the entire prefix is contained in RFC 1918 private address space.
func isContainedInPrivateAddressSpace(prefix netip.Prefix) bool {
	privateAddressSpaces := [...]netip.Prefix{
		netip.MustParsePrefix("10.0.0.0/8"),
		netip.MustParsePrefix("172.16.0.0/12"),
		netip.MustParsePrefix("192.168.0.0/16"),
	}
	for _, privateAddressSpace := range privateAddressSpaces {
		if prefix.Bits() >= privateAddressSpace.Bits() && privateAddressSpace.Contains(prefix.Addr()) {
			return true
		}
	}
	return false
}

func (n resolvedClusterNetwork) validateControlPlaneVIP(vip string) error {
	addr, err := netip.ParseAddr(vip)
	if err != nil {
		return fmt.Errorf("invalid controlPlaneVIP %q: %w", vip, err)
	}
	if !addr.Is4() {
		return fmt.Errorf("invalid controlPlaneVIP %q: must be an IPv4 address", vip)
	}
	return n.validateOutsideClusterCIDRs("controlPlaneVIP", vip, addr)
}

// validateAPIServerEndpointFields checks the two fields of a create request
// that name the API server endpoint. At most one of them is set, and the one
// that is set must be valid for this network.
func (n resolvedClusterNetwork) validateAPIServerEndpointFields(controlPlaneVIP, controlPlaneEndpoint string) error {
	switch {
	case controlPlaneVIP != "" && controlPlaneEndpoint != "":
		return newBadRequestErrorf("controlPlaneEndpoint and controlPlaneVIP are mutually exclusive; set only one of them")
	case controlPlaneVIP != "":
		return n.validateControlPlaneVIP(controlPlaneVIP)
	case controlPlaneEndpoint != "":
		return n.validateControlPlaneEndpoint(controlPlaneEndpoint)
	default:
		return nil
	}
}

// validateControlPlaneEndpoint checks a controlPlaneEndpoint value. The form is
// host or host:port, which is what kubeadm accepts for its field of the same
// name, with an IPv4 address or a DNS name as the host. An IPv4 host must be
// outside the pod and service CIDRs, the same rule as for controlPlaneVIP.
func (n resolvedClusterNetwork) validateControlPlaneEndpoint(endpoint string) error {
	addr, isAddr, err := parseControlPlaneEndpoint(endpoint)
	if err != nil {
		return fmt.Errorf("invalid controlPlaneEndpoint %q: %w", endpoint, err)
	}
	if !isAddr {
		// NVKE cannot tell which addresses a DNS name resolves to, so the CIDR
		// rule applies to an address host only.
		return nil
	}
	return n.validateOutsideClusterCIDRs("controlPlaneEndpoint", endpoint, addr)
}

// validateOutsideClusterCIDRs rejects an API server address that lies inside
// the pod or service CIDR. field and value name the request field in the error.
func (n resolvedClusterNetwork) validateOutsideClusterCIDRs(field, value string, addr netip.Addr) error {
	for _, podPrefix := range n.podCIDRPrefixes {
		if podPrefix.Contains(addr) {
			return newBadRequestErrorf(
				"%s %q overlaps %s %q",
				field,
				value,
				"network.podCIDR",
				podPrefix,
			)
		}
	}
	if n.serviceCIDR.Contains(addr) {
		return newBadRequestErrorf(
			"%s %q overlaps %s %q",
			field,
			value,
			"network.serviceCIDR",
			n.serviceCIDR,
		)
	}
	return nil
}

// parseControlPlaneEndpoint checks a host or host:port endpoint. The host is an
// IPv4 address or an RFC 1123 DNS subdomain, and the port, when present, is a
// number from 1 to 65535. It returns the address of an IPv4 host and true, or
// false when the host is a DNS name.
func parseControlPlaneEndpoint(endpoint string) (netip.Addr, bool, error) {
	host := endpoint
	if i := strings.LastIndex(endpoint, ":"); i >= 0 {
		host = endpoint[:i]
		port, err := strconv.ParseUint(endpoint[i+1:], 10, 16)
		if err != nil || port == 0 {
			return netip.Addr{}, false, fmt.Errorf("port %q must be a number from 1 to 65535", endpoint[i+1:])
		}
	}
	if host == "" {
		return netip.Addr{}, false, errors.New("the host is empty")
	}
	// A colon or a bracket left in the host means an IPv6 literal. Without
	// them, the only address that parses below is an IPv4 one.
	if strings.ContainsAny(host, ":[]") {
		return netip.Addr{}, false, fmt.Errorf("host %q must be an IPv4 address or a DNS name", host)
	}
	if addr, err := netip.ParseAddr(host); err == nil {
		return addr, true, nil
	}
	// Digits and dots alone are a mistyped address, not a name. As a name it
	// would pass the DNS check below and skip the CIDR rule.
	if strings.Trim(host, "0123456789.") == "" {
		return netip.Addr{}, false, fmt.Errorf("host %q is not a valid IPv4 address", host)
	}
	if problems := validation.IsDNS1123Subdomain(host); len(problems) > 0 {
		return netip.Addr{}, false, fmt.Errorf("host %q must be an IPv4 address or a DNS name: %s", host, strings.Join(problems, "; "))
	}
	return netip.Addr{}, false, nil
}
