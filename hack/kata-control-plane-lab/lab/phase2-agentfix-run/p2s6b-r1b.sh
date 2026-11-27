#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# R1b, an added step: in R1 the controller used join strings that it had kept (it keeps them for
# 5 minutes for each cluster), so it asked no node after the first node was gone. Here the first
# node is gone and the kept strings are too old: desired count 4, NVKE must ask a node again.
# Then desired count 3.
# Usage (detached): setsid nohup p2-agentfix/p2s6b-r1b.sh <label> >logs/p2s6b/<label>-r1b.out 2>&1 &
label=${1:?label}
. /root/kata-cp/bin/env.sh
export LOG_DIR=$W/logs/p2s6b/$label
cd "$W/p2-agentfix" || exit 1
echo "== $(utc) R1b in $label"
echo "fix lines so far:"; cat "$LOG_DIR/fix-lines.txt"
./run.sh scale 4 r1b-up; echo "scale r1b-up exit code: $?"
./run.sh after r1b-up; echo "after r1b-up exit code: $?"
./run.sh fix-evidence r1b-up >/dev/null
./run.sh scale 3 r1b-down; echo "scale r1b-down exit code: $?"
./run.sh after r1b-down; echo "after r1b-down exit code: $?"
echo "== $(utc) end of R1b in $label"
