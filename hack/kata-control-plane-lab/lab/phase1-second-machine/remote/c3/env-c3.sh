# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Settings of block C3 on the-second-machine: the dry run flow (NVKE node image, nvke-agent, lab client) with a
# fixed address for each node and the kernel datapath of Open vSwitch. Source this file.
. /root/kata-cp/bin/env.sh
export NS=${NS:-c3}
export KIND_NODE=$CP_NODE
export RUNTIME_CLASS=${RUNTIME_CLASS-kata-clh-runtime-rs-fix-direct-ovs}   # the class of record with the kernel that has Open vSwitch
export KERNEL_CONFIG=${KERNEL_CONFIG-$W/kbuild/out/opt/kata/share/kata-containers/config-6.18.62-211}
export IMAGE=nvke-node:bcc4376f-amd64
export ADDR_FORM=none            # the node address is on net1 (Multus). The wrapper adds no address.
export ETCD_PATCH=0              # stock etcd settings: no patch file, no skip flag, no listen change
export REPAIR=off
export P1_OVS_DATAPATH=${P1_OVS_DATAPATH-}          # empty = the value of the image: NKE_OVS_DATAPATH_TYPE=system
export P1_OVS_NO_MODPROBE=${P1_OVS_NO_MODPROBE-1}   # the kernel has Open vSwitch built in and no /sys/module/openvswitch
export P1_TUN=${P1_TUN-0}
export CLIENT_BIN=$W/c3/dry/bin/nvke-lab-client
export LOCAL_DNS_MANIFEST=$W/c3/dry/kube_local_dns.yaml
export LOOP_MAP=$W/disks/loop-map.txt
export LABRENDER=$W/c3/labrender
export KEEP=1
