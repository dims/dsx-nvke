#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# R3: the rollout to the image p5 through the NVKE API. NVKE must replace the three nodes by itself.
# Usage (detached): setsid nohup p2-agentfix/p2s6b-r3.sh <label> >logs/p2s6b/<label>-r3.out 2>&1 &
label=${1:?label}
. /root/kata-cp/bin/env.sh
export LOG_DIR=$W/logs/p2s6b/$label
cd "$W/p2-agentfix" || exit 1
echo "== $(utc) R3 in $label"
./run.sh rollout p5; echo "rollout exit code: $?"
./run.sh after rollout; echo "after rollout exit code: $?"
./run.sh fix-evidence rollout >/dev/null
echo "== $(utc) end of R3 in $label"
