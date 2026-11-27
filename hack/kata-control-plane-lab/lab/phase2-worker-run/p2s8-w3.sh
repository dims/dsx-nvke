#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# W3: the reboot request of NVKE for the worker (a label on its Node in the new cluster), then the traffic again.
# Usage (detached): setsid nohup p2-worker/p2s8-w3.sh <label> >logs/p2s8/<label>-w3.out 2>&1 &
label=${1:?label}
. /root/kata-cp/bin/env.sh
export LOG_DIR=$W/logs/p2s8/$label REBOOT_WATCH=${REBOOT_WATCH:-3000}
cd "$W/p2-worker" || exit 1
echo "== $(utc) W3 in $label"
./run.sh w3 w3; echo "w3 exit code: $?"
./run.sh w2 w3; echo "w2 after w3 exit code: $?"
echo "== $(utc) end of W3 in $label"
