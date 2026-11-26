#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# The images that a node of the inner cluster pulls in the dry run flow and that the NVKE node image does
# not have: the node-local DNS cache, and the pause image of kubeadm v1.36.4 (the node image has pause:3.10,
# kubeadm asks for pause:3.10.2 in its preflight). A node cannot pull here (firewall of the machine), so the
# machine pulls each one with ctr (namespace kata-lab) and exports a file. cmd_preload of c3/dry/run.sh
# imports the files into each node pod.
# Removal: ctr -n kata-lab images rm <each image>; rm -rf /root/kata-cp/dl/img/inner
set -euo pipefail
. /root/kata-cp/bin/env.sh
D=$W/dl/img/inner
mkdir -p "$D"
get() { # get <reference to pull> <name:tag in the file> <file>
  ctr -n kata-lab images pull --platform linux/amd64 "$1" >/dev/null
  [ "$1" = "$2" ] || ctr -n kata-lab images tag --force "$1" "$2" >/dev/null 2>&1 || true
  ctr -n kata-lab images export --platform linux/amd64 "$D/$3" "$2"
  ls -la "$D/$3"
}
get registry.k8s.io/dns/k8s-dns-node-cache:1.26.8@sha256:bc6e64e2c85956af2fcc0aa720086410d41b4f31f378c9a92646fecc85cd4739 registry.k8s.io/dns/k8s-dns-node-cache:1.26.8 k8s-dns-node-cache.tar
get registry.k8s.io/pause:3.10.2 registry.k8s.io/pause:3.10.2 pause-3.10.2.tar
echo "INNER IMAGES DONE"
