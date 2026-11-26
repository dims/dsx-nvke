# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# kind node image for the lab: the stock node image plus a D-Bus system bus.
# The Rust runtime of Kata asks systemd over D-Bus for the cgroup of each sandbox,
# and the stock kind node has no D-Bus daemon. A site node has one.
# Build: docker build -t kata-cp-node:v1.36.4 lab/kind-node
# Use:   set NODE_IMAGE=kata-cp-node:v1.36.4 in lab/00-host-setup.sh
FROM kindest/node:v1.36.4
RUN apt-get update \
 && apt-get install -y --no-install-recommends dbus \
 && rm -rf /var/lib/apt/lists/*
