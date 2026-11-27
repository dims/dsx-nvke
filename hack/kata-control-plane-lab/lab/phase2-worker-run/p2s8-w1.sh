#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# W1: one node pool with one worker through the NVKE API, then the checks and the record.
# Usage (detached): setsid nohup p2-worker/p2s8-w1.sh <label> >logs/p2s8/<label>-w1.out 2>&1 &
label=${1:?label}
. /root/kata-cp/bin/env.sh
export LOG_DIR=$W/logs/p2s8/$label
mkdir -p "$LOG_DIR"
cd "$W/p2-worker" || exit 1
echo "== $(utc) W1 in $label"
pgrep -f "storage-loop[.]sh" >/dev/null || (setsid nohup "$W/p2-replace/storage-loop.sh" >>"$W/logs/p2s8/storage-loop.out" 2>&1 &)
./run.sh init; echo "init exit code: $?"
./run.sh pool-post workers wk 1; echo "pool-post exit code: $?"
./run.sh pool-wait 1 w1; echo "pool-wait exit code: $?"
./run.sh w1 w1; echo "w1 exit code: $?"
echo "== $(utc) end of W1 in $label"
