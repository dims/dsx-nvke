#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Steps 6 and 7, part A: the cluster with the image p2, the literal DELETE with three nodes, then
# the way that the answer of NVKE names: raise the desired count to 4.
# Usage (detached): setsid nohup p2-replace/p2s6-a.sh <label> >logs/p2s6/<label>-a.out 2>&1 &
label=${1:?label}
. /root/kata-cp/bin/env.sh
export LOG_DIR=$W/logs/p2s6/$label
mkdir -p "$LOG_DIR"
cd "$W/p2-replace" || exit 1
echo "== $(utc) part A of $label"
pgrep -f "storage-loop[.]sh" >/dev/null || (setsid nohup ./storage-loop.sh >>"$W/logs/p2s6/storage-loop.out" 2>&1 &)
WAIT=1 ./disk.sh "$label flow"
./run.sh flow; echo "flow exit code: $?"
./run.sh after flow; echo "after flow exit code: $?"
./run.sh refuse-delete other; echo "refuse-delete exit code: $?"
./run.sh scale 4 up; echo "scale up exit code: $?"
./run.sh after scale-up; echo "after scale-up exit code: $?"
echo "== $(utc) end of part A of $label"
