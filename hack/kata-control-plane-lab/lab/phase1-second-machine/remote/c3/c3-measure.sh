#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Block C3, the measurements on the cluster of a full run that stays (c3.sh with STOP_AFTER_FULL=1):
# pod traffic between nodes, tunnel endpoints, a replace of one node pod, traffic again, the checks.
# Usage (detached): setsid nohup c3/c3-measure.sh <label of the full run> >logs/c3/<label>-measure.out 2>&1 &
label=${1:?label of the full run}
. /root/kata-cp/c3/env-c3.sh
export LOG_DIR=$W/logs/c3/$label SEC=$W/secrets/c3-$label
cd "$W/c3/dry"
echo "== $(utc) measurements on the cluster of $label"
./run.sh traffic after-flow
./run.sh tunnels after-flow
./run.sh replace "${REPLACE:-b}"
echo "replace exit code: $?"
./run.sh traffic after-replace
./run.sh check end
echo "check exit code: $?"
./run.sh evidence end
echo "== $(utc) end of the measurements"
