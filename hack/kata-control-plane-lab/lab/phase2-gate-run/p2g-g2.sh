#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# G2: etcd encryption on the cluster that is up, through the NVKE API. Then health and traffic.
# Usage (detached): setsid nohup p2-gate/p2g-g2.sh <label> >logs/p2g/<label>-g2.out 2>&1 &
label=${1:?label}
. /root/kata-cp/bin/env.sh
export LOG_DIR=$W/logs/p2g/$label
mkdir -p "$LOG_DIR"
cd "$W/p2-gate" || exit 1
echo "== $(utc) G2 in $label"
./run.sh init; echo "init exit code: $?"
./run.sh facts before-g2 >/dev/null; echo "facts exit code: $?"
./run.sh g2 g2; echo "g2 exit code: $?"
./run.sh health after-g2; echo "health exit code: $?"
./run.sh w2 after-g2; echo "w2 exit code: $?"
./run.sh facts after-g2 >/dev/null; echo "facts exit code: $?"
echo "== $(utc) end of G2 in $label"
