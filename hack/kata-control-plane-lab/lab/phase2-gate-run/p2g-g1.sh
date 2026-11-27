#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# G1: the forced certificate renewal (the operator start of the product page), then health and traffic.
# Usage (detached): setsid nohup p2-gate/p2g-g1.sh <label> >logs/p2g/<label>-g1.out 2>&1 &
label=${1:?label}
. /root/kata-cp/bin/env.sh
export LOG_DIR=$W/logs/p2g/$label
cd "$W/p2-gate" || exit 1
echo "== $(utc) G1 in $label"
./run.sh g1 g1; echo "g1 exit code: $?"
./run.sh health after-g1; echo "health exit code: $?"
./run.sh w2 after-g1; echo "w2 exit code: $?"
./run.sh facts after-g1 >/dev/null; echo "facts exit code: $?"
echo "== $(utc) end of G1 in $label"
