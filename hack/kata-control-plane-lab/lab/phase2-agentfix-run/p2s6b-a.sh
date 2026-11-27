#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Part A: the cluster with the image p4 (the first kubeadm init with an image of the p3 kind).
# Usage (detached): setsid nohup p2-agentfix/p2s6b-a.sh <label> >logs/p2s6b/<label>-a.out 2>&1 &
label=${1:?label}
. /root/kata-cp/bin/env.sh
export LOG_DIR=$W/logs/p2s6b/$label DISK_LOG=$W/logs/p2s6b/disk.txt
mkdir -p "$LOG_DIR"
cd "$W/p2-agentfix" || exit 1
echo "== $(utc) part A of $label"
pgrep -f "storage-loop[.]sh" >/dev/null || (setsid nohup "$W/p2-replace/storage-loop.sh" >>"$W/logs/p2s6b/storage-loop.out" 2>&1 &)
pgrep -f "fix-evidence-loop[.]sh" >/dev/null || (LOG_DIR=$LOG_DIR setsid nohup ./fix-evidence-loop.sh >/dev/null 2>&1 &)
WAIT=1 "$W/p2-replace/disk.sh" "$label cluster with p4"
./run.sh flow; echo "flow exit code: $?"
./run.sh wait-good 3 300; echo "wait-good exit code: $?"
./run.sh after flow; echo "after flow exit code: $?"
./run.sh fix-evidence flow >/dev/null; echo "fix-evidence exit code: $?"
echo "== $(utc) end of part A of $label"
