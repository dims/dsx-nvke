#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# On the workstation: copy the files of phase 3 to the second machine, or fetch the logs. It uses
# the wrapper bb.sh (one multiplexed SSH connection). No address and no credential is in this file.
#   scripts   this folder to /root/kata-cp/p3/ (after a check for the bash network socket device
#             path form)
#   sim       the simulator binary, its seed file and their checksums to /root/kata-cp/p3/sim/
#   agent     the agent binary of the lab build to /root/kata-cp/p3/image/nvke-agent
#   images    the two image archives to /root/kata-cp/dl/img/: CAPNICo (for the kind nodes) and
#             the Docker CLI image of the simulator container
#   logs      /root/kata-cp/logs/p3/ to the workstation
# Usage: ws-sync.sh scripts | sim | agent | images | logs
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BB=${BB:-/scratch/kata-cp/work/bigbox/bb.sh}
OUT=${OUT:-/scratch/kata-cp/work/phase3}
AGENT=${AGENT:-/scratch/kata-cp/work/phase2-gaps/bin-encfix/nvke-agent}
DEST=/root/kata-cp/p3
both() { # <local file> <remote file>: the checksum on both sides
  echo "workstation: $(sha256sum "$1" | cut -d' ' -f1)  $1"
  echo "machine:     $("$BB" sha256sum "$2" | cut -d' ' -f1)  $2"
}
case "${1:-}" in
  scripts)
    if grep -rnE '/dev/(t|u)[cd]p/' "$HERE"; then echo "a file has the bash network socket device path form. Not copied"; exit 1; fi
    "$BB" mkdir -p "$DEST"
    "$BB" --rsync-put "$HERE/" "$DEST/"
    ;;
  sim)
    ( cd "$OUT/sim" && sha256sum -c SHA256SUMS )
    for f in nico-sim default-seed.yaml SHA256SUMS; do
      "$BB" --put "$OUT/sim/$f" "$DEST/sim/$f"
      both "$OUT/sim/$f" "$DEST/sim/$f"
    done
    ;;
  agent)
    [ -s "$AGENT" ] || { echo "no agent binary at $AGENT"; exit 1; }
    "$BB" --put "$AGENT" "$DEST/image/nvke-agent"
    both "$AGENT" "$DEST/image/nvke-agent"
    echo "give the sha256 above to the build: AGENT_SHA256=... $DEST/image/build-worker.sh"
    ;;
  images)
    ( cd "$OUT/images" && sha256sum -c SHA256SUMS )
    for f in ghcr.io_dsx-ai-factory_cluster-api-provider-nico_controller_v0.3.0-rc.1.tar docker_29.1.3-cli.tar; do
      "$BB" --put "$OUT/images/$f" "/root/kata-cp/dl/img/$f"
      both "$OUT/images/$f" "/root/kata-cp/dl/img/$f"
    done
    ;;
  logs)
    mkdir -p /scratch/kata-cp/logs/bigbox/remote-logs/p3
    "$BB" --rsync-get /root/kata-cp/logs/p3/ /scratch/kata-cp/logs/bigbox/remote-logs/p3/
    ;;
  *) sed -n '2,11p' "$0"; exit 1 ;;
esac
