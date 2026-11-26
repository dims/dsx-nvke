#!/bin/sh
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Lab: the bridge br-node of a kind node for the node network. The interface nodenet0 (the second
# Docker network) becomes a port of the bridge, and the bridge takes its hardware address and its
# IP address. The bridge CNI plugin adds one port for each pod that asks for the network "nodenet".
# With the address on the bridge, the node itself and the pods of this node reach each address on
# the node network (macvlan and ipvlan on nodenet0 do not permit that).
# The unit lab-node-bridge.service runs this script at each start of the node, before the kubelet.
set -e
IF=nodenet0
BR=br-node
[ -d "/sys/class/net/$IF" ] || { echo "no interface $IF"; exit 1; }
ip link show "$BR" >/dev/null 2>&1 || ip link add "$BR" type bridge
if [ "$(cat /sys/class/net/$IF/master/ifindex 2>/dev/null)" != "$(cat /sys/class/net/$BR/ifindex)" ]; then
  ip link set "$BR" address "$(cat /sys/class/net/$IF/address)"
  ip link set "$IF" master "$BR"
fi
ip link set "$IF" up
ip link set "$BR" up
addr=$(ip -o -4 addr show dev "$IF" | awk '{print $4}' | head -1)
if [ -n "$addr" ]; then
  ip addr del "$addr" dev "$IF"
  ip addr replace "$addr" dev "$BR"
fi
echo "$BR: address $(ip -o -4 addr show dev "$BR" | awk '{print $4}'), mac $(cat /sys/class/net/$BR/address), ports $(ls /sys/class/net/$BR/brif | tr '\n' ' ')"
