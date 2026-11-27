#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Steps 6 and 7, part C (S6b): back to three nodes, then the rollout to the image p3.
# Usage (detached): setsid nohup p2-replace/p2s6-c.sh <label> >logs/p2s6/<label>-c.out 2>&1 &
label=${1:?label}
. /root/kata-cp/bin/env.sh
export LOG_DIR=$W/logs/p2s6/$label
cd "$W/p2-replace" || exit 1
echo "== $(utc) part C of $label"
./run.sh scale 3 down; echo "scale down exit code: $?"
./run.sh after scale-down; echo "after scale-down exit code: $?"
./run.sh rollout p3; echo "rollout exit code: $?"
./run.sh after rollout; echo "after rollout exit code: $?"
echo "== $(utc) end of part C of $label"
