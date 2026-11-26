#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Render the kubeadm init configuration and the prerequisite files with the renderer of the
# NVKE controller at the lab commit (controller/internal/kubeadmconfig, InitConfig.Render).
# The go flag -overlay adds main.go to the controller module in memory. The clone stays unchanged.
#
# Usage: render.sh <output folder> <node IP> <endpoint> <node name>
# Variables: K8S_VERSION, POD_CIDR, SERVICE_CIDR, SKIP_KUBE_PROXY, CONTAINER_MODE,
#            SYSTEM_RESERVED_MEMORY, KUBE_RESERVED_MEMORY, TOKEN (empty = the renderer makes one)
set -euo pipefail
OUT=$1 NODE_IP=$2 ENDPOINT=$3 NODE_NAME=$4
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC=${NVKE_SRC:-/scratch/kata-cp/src/nvke}
PKG=$SRC/controller/internal/labrender   # this folder exists only in the overlay
mkdir -p "$OUT"
OVERLAY=$(mktemp /scratch/kata-cp/tmp/gate1-nvke/overlay.XXXXXX.json)
trap 'rm -f "$OVERLAY"' EXIT
printf '{"Replace": {"%s/main.go": "%s/main.go"}}\n' "$PKG" "$HERE" >"$OVERLAY"

export PATH=$HOME/.local/go/bin:$PATH
export GOCACHE=${GOCACHE:-/scratch/kata-cp/tmp/go-build}   # no write to the build cache of the user
export GOPROXY=${GOPROXY:-off}                              # the module cache has all modules
export LAB_OUT=$OUT LAB_NODE_IP=$NODE_IP LAB_ENDPOINT=$ENDPOINT LAB_NODE_NAME=$NODE_NAME
export LAB_K8S_VERSION=${K8S_VERSION:-v1.36.4}
export LAB_POD_CIDR=${POD_CIDR:-10.113.0.0/16} LAB_SERVICE_CIDR=${SERVICE_CIDR:-10.112.0.0/16}
export LAB_SKIP_KUBE_PROXY=${SKIP_KUBE_PROXY:-true} LAB_CONTAINER_MODE=${CONTAINER_MODE:-false}
export LAB_SYSTEM_RESERVED_MEMORY=${SYSTEM_RESERVED_MEMORY:-1Gi} LAB_KUBE_RESERVED_MEMORY=${KUBE_RESERVED_MEMORY:-512Mi}
export LAB_TOKEN=${TOKEN:-}
cd "$SRC/controller"
go run -overlay "$OVERLAY" ./internal/labrender
