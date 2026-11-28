# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# shellcheck shell=bash
# Settings of the Konnectivity prototype of phase 3 on the second machine. Source this file
# after /root/kata-cp/bin/env.sh and /root/kata-cp/p3/env-p3.sh. It runs nothing.
export KONN=$W/p3-konn
# The two images of the upstream project apiserver-network-proxy. v0.34.0 is the version that
# Kubernetes 1.36.4 pins for the client inside the API server (go.mod:215 at the tag v1.36.4)
# and names for both images in its own manifests (cluster/gce/manifests/konnectivity-server.yaml:23,
# cluster/gce/addons/konnectivity-agent/konnectivity-agent-ds.yaml:30).
export KONN_SERVER_IMAGE=registry.k8s.io/kas-network-proxy/proxy-server:v0.34.0
export KONN_AGENT_IMAGE=registry.k8s.io/kas-network-proxy/proxy-agent:v0.34.0
# The archives, made on the workstation with docker save --platform linux/amd64.
export KONN_SERVER_ARCHIVE=registry.k8s.io_kas-network-proxy_proxy-server_v0.34.0.tar
export KONN_SERVER_ARCHIVE_SHA256=7a0092fa8023d06d28ae9b94f97d698a7596b9af461b69f37bead67dbfe6f209
export KONN_AGENT_ARCHIVE=registry.k8s.io_kas-network-proxy_proxy-agent_v0.34.0.tar
export KONN_AGENT_ARCHIVE_SHA256=220fea15192dd846b32eacc0cfbd1a2128a52f723905b6ab163b74e2e3df54d2
# The two new image tags, and the tags that they come from.
export KONN_POD_BASE=nvke-node-podvm:bcc4376f-p10
export KONN_POD_IMAGE=nvke-node-podvm:bcc4376f-p11
export KONN_WORKER_BASE=nvke-node-nico:bcc4376f-w1
export KONN_WORKER_IMAGE=nvke-node-nico:bcc4376f-w2
# The agent port on each control plane node and on the shared address.
export KONN_AGENT_PORT=8132
# The workers of this test have ONE network, kata-bb, with a fixed address from this block.
# The simulator has 172.29.2.5 in the same block. No control plane pod calls the simulator.
export KONN_WORKER_PREFIX=172.29.2
export KONN_WORKER_BLOCK=172.29.2.0/24
# The lab objects of the host cluster.
export KONN_NS=d                               # the namespace of the control plane pods
export KONN_SERVICE=cp-api                     # the Service of the shared address
export KONN_POLICY=p3-konn-no-way-to-workers   # the NetworkPolicy of the design
# The paths on a control plane node (also in files/ and in requests/render.sh).
export KONN_EGRESS_FILE=/etc/kubernetes/policies/egress-selector-configuration.yaml
export KONN_MANIFEST=/etc/kubernetes/manifests/konnectivity-server.yaml
export KONN_SOCKET=/etc/kubernetes/policies/konnectivity/konnectivity-server.socket
