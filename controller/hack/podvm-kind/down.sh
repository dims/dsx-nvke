#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Remove what up.sh made: the kind cluster and the Docker network of the node
# network. Delete each tenant cluster through the NVKE API first.
#
# The kernel modules and the inotify limit of the step host stay.

set -euo pipefail

KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-podvm}"
NODE_NETWORK=podvm-nodenet

log() { printf '\n=== %s\n' "$*" >&2; }

log "deleting the kind cluster ${KIND_CLUSTER_NAME}"
kind delete cluster --name "${KIND_CLUSTER_NAME}"

if docker network inspect "${NODE_NETWORK}" >/dev/null 2>&1; then
  log "removing the Docker network ${NODE_NETWORK}"
  docker network rm "${NODE_NETWORK}" >/dev/null
fi
