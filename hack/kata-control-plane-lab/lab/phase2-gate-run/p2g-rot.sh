#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# G2, second part: the rotation of the etcd encryption key (the operator start of the product page),
# then health and traffic.
# Usage (detached): setsid nohup p2-gate/p2g-rot.sh <label> >logs/p2g/<label>-rot.out 2>&1 &
label=${1:?label}
. /root/kata-cp/bin/env.sh
export LOG_DIR=$W/logs/p2g/$label
cd "$W/p2-gate" || exit 1
echo "== $(utc) key rotation in $label"
./run.sh rotate rot; echo "rotate exit code: $?"
./run.sh health after-rot; echo "health exit code: $?"
./run.sh w2 after-rot; echo "w2 exit code: $?"
./run.sh facts after-rot >/dev/null; echo "facts exit code: $?"
echo "== $(utc) end of the key rotation in $label"
