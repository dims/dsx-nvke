#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# On the workstation: copy the files of the Konnectivity prototype to the second machine. It uses
# the wrapper bb.sh (one multiplexed SSH connection). No address and no credential is in this file.
#   scripts   this folder to /root/kata-cp/p3-konn/ (after a check for the bash network socket
#             device path form)
#   images    the two image archives (proxy server, proxy agent) to /root/kata-cp/dl/img/
# The logs of a run are in /root/kata-cp/logs/p3/, so "ws-sync.sh logs" of the phase 3 folder
# fetches them.
# Usage: ws-sync.sh scripts | images
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BB=${BB:-/scratch/kata-cp/work/bigbox/bb.sh}
OUT=${OUT:-/scratch/kata-cp/work/phase3-konn}
DEST=/root/kata-cp/p3-konn
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
  images)
    ( cd "$OUT/images" && sha256sum -c SHA256SUMS )
    for f in registry.k8s.io_kas-network-proxy_proxy-server_v0.34.0.tar registry.k8s.io_kas-network-proxy_proxy-agent_v0.34.0.tar; do
      "$BB" --put "$OUT/images/$f" "/root/kata-cp/dl/img/$f"
      both "$OUT/images/$f" "/root/kata-cp/dl/img/$f"
    done
    ;;
  *) sed -n '2,10p' "$0"; exit 1 ;;
esac
