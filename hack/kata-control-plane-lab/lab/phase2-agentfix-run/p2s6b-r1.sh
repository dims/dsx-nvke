#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# R1: desired count 4, then DELETE of the first node of the cluster through the NVKE API. The new
# Machine must join by itself. Then desired count 3.
# Usage (detached): setsid nohup p2-agentfix/p2s6b-r1.sh <label> >logs/p2s6b/<label>-r1.out 2>&1 &
label=${1:?label}
. /root/kata-cp/bin/env.sh
export LOG_DIR=$W/logs/p2s6b/$label
cd "$W/p2-agentfix" || exit 1
echo "== $(utc) R1 in $label"
./run.sh scale 4 r1-up; echo "scale r1-up exit code: $?"
./run.sh after r1-up; echo "after r1-up exit code: $?"
./run.sh fix-evidence r1-up >/dev/null
./run.sh delete-node first r1; echo "delete-node r1 exit code: $?"
./run.sh after r1; echo "after r1 exit code: $?"
./run.sh fix-evidence r1 >/dev/null
./run.sh scale 3 r1-down; echo "scale r1-down exit code: $?"
./run.sh after r1-down; echo "after r1-down exit code: $?"
echo "== $(utc) end of R1 in $label"
