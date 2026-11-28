# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# shellcheck shell=bash
# Settings of phase 3 on the second machine. Source this file after /root/kata-cp/bin/env.sh.
# It runs nothing. Each script of this folder reads its names and addresses from here.
export P3=$W/p3
export P3_LOGS=$W/logs/p3
export API_NET=kata-bb                 # the kind nodes, the shared API address, SPIRE (172.29.0.0/16)
export NODE_NET=kata-bb-node           # the node addresses (172.28.0.0/16, internal)

# The simulator: one container on the network of the kind nodes.
export SIM_NAME=p3-nico-sim
# The image of the CI deploy path (controller/hack/ci/backend-e2e.sh:34), by its digest.
export SIM_IMAGE=docker:29.1.3-cli
export SIM_IMAGE_DIGEST=sha256:4fa0ee1f3a7e4354c4ea34558b6d4ee32859baf4973d4c8ccc8e7fe3dd730c04
# A fixed address. It is in the subnet of kata-bb, outside the range that Docker gives out
# (172.29.0.0/24) and outside the MetalLB pool (172.29.255.200 to .250).
export SIM_IP=172.29.2.5
export SIM_PORT=18080
export SIM_STATE=$P3/state             # database, the log of docker-two-nets, its lock

# The workers. The last number is the same on both networks. 172.28.0.0/24 is the range of
# Docker, and 172.28.1.0/24 is the range of the pod provider.
export WORKER_NODE_PREFIX=172.28.2
export WORKER_API_PREFIX=172.29.2
export WORKER_IP_FIRST=11 WORKER_IP_LAST=250
# The interface names inside a worker: the node network is eth0, the network of the kind nodes
# is eth1. docker-two-nets sets them, and it adds the hosts line of the host name (2026-11-27).
export WORKER_NODE_IFNAME=eth0 WORKER_API_IFNAME=eth1
export WORKER_IMAGE=nvke-node-nico:bcc4376f-w1

# CAPNICo, as NVKE deploys it (deploy/nico/capnico/capnico.yaml and release.yaml at 5c08484c).
export CAPNICO_IMAGE=ghcr.io/dsx-ai-factory/cluster-api-provider-nico/controller:v0.3.0-rc.1
export CAPNICO_NS=capnico-system
# The fake credential of the simulator. The simulator accepts each token that is not empty.
# The organization is the one of the seed file (default-seed.yaml:6).
export NICO_ORG_ID=novxwn552ssc
export NICO_API_NAME=forge
