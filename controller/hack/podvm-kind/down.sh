#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Remove what up.sh made: the simulator, the kind cluster, the loop devices with
# their files, and the Docker network of the node network. Delete each tenant
# cluster through the NVKE API first: a worker container of the simulator goes
# only that way.
#
# The kernel modules and the inotify limit of the step host stay.

set -euo pipefail

KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-podvm}"
STATE_DIR="${PODVM_KIND_STATE_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/podvm-kind}"
NODE_NETWORK=podvm-nodenet

log() { printf '\n=== %s\n' "$*" >&2; }
as_root() { if [[ "$(id -u)" -eq 0 ]]; then "$@"; else sudo "$@"; fi; }

pid_file="${STATE_DIR}/nico-sim/nico-sim.pid"
if [[ -s "${pid_file}" ]] && kill -0 "$(cat "${pid_file}")" 2>/dev/null; then
  log "stopping nico-sim"
  kill "$(cat "${pid_file}")"
fi
rm -f "${pid_file}"

log "deleting the kind cluster ${KIND_CLUSTER_NAME}"
kind delete cluster --name "${KIND_CLUSTER_NAME}"

log "detaching the loop devices of ${STATE_DIR}/disks"
for file in "${STATE_DIR}"/disks/*.img; do
  [[ -e "${file}" ]] || continue
  for dev in $(as_root losetup --noheadings --output NAME --associated "${file}"); do
    as_root losetup --detach "${dev}"
  done
  rm -f "${file}"
done

if docker network inspect "${NODE_NETWORK}" >/dev/null 2>&1; then
  log "removing the Docker network ${NODE_NETWORK}"
  docker network rm "${NODE_NETWORK}" >/dev/null
fi
