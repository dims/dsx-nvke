#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# On the workstation: copy this folder to the second machine, copy the new agent binary beside the
# image build script, or fetch the logs. It uses the wrapper bb.sh (one multiplexed SSH
# connection). No address and no credential is in this file.
# Usage: ws-sync.sh scripts | agent | logs
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BB=${BB:-/scratch/kata-cp/work/bigbox/bb.sh}
AGENT=${AGENT:-/scratch/kata-cp/work/phase2-gaps/bin/nvke-agent}
case "${1:-}" in
  scripts)
    if grep -rnE '/dev/(t|u)[cd]p/' "$HERE"; then echo "a script has the bash network socket device path form. Not copied"; exit 1; fi
    "$BB" --rsync-put "$HERE/" /root/kata-cp/p2-gaps/
    ;;
  agent)
    [ -s "$AGENT" ] || { echo "no agent binary at $AGENT"; exit 1; }
    echo "workstation: $(sha256sum "$AGENT")"
    "$BB" --put "$AGENT" /root/kata-cp/p2-gaps/image/nvke-agent
    echo "machine:     $("$BB" sha256sum /root/kata-cp/p2-gaps/image/nvke-agent)"
    echo "give the sha256 above to the build: AGENT_SHA256=... /root/kata-cp/p2-gaps/image/build.sh"
    ;;
  logs)
    mkdir -p /scratch/kata-cp/logs/bigbox/remote-logs/p2gaps
    "$BB" --rsync-get /root/kata-cp/logs/p2gaps/ /scratch/kata-cp/logs/bigbox/remote-logs/p2gaps/
    ;;
  *) sed -n '2,6p' "$0"; exit 1 ;;
esac
