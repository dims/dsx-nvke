#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# W4: delete the pod of the worker by hand, the provider makes it again, then the traffic again.
# Usage (detached): setsid nohup p2-worker/p2s8-w4.sh <label> >logs/p2s8/<label>-w4.out 2>&1 &
label=${1:?label}
. /root/kata-cp/bin/env.sh
export LOG_DIR=$W/logs/p2s8/$label LOST_WATCH=${LOST_WATCH:-120}
cd "$W/p2-worker" || exit 1
echo "== $(utc) W4 in $label"
./run.sh w4 w4; echo "w4 exit code: $?"
./run.sh w2 w4; echo "w2 after w4 exit code: $?"
echo "== $(utc) end of W4 in $label"
