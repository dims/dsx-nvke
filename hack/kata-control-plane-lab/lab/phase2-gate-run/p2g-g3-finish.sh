#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# The end of G3, after the chain deleted the new worker in the place of the old one (a fault of my
# script: it took the first worker by address). Delete the old worker by its name through the NVKE
# API, then the final records.
# Usage (detached): OLD_WORKER=<name> setsid nohup p2-gate/p2g-g3-finish.sh <label> >logs/p2g/<label>-finish.out 2>&1 &
label=${1:?label}
. /root/kata-cp/bin/env.sh
export LOG_DIR=$W/logs/p2g/$label IMG_WORKER=${NEW_IMG:-docker.io/library/nvke-node-podvm:bcc4376f-p5}
cd "$W/p2-gate" || exit 1
echo "== $(utc) end of G3 by hand in $label"
WORKER_NAME=${OLD_WORKER:?} ./run.sh worker-delete wp-old; echo "worker-delete wp-old exit code: $?"
./run.sh w1 final; echo "w1 final exit code: $?"
./run.sh health final; echo "health final exit code: $?"
./run.sh w2 final; echo "w2 final exit code: $?"
./run.sh facts final >/dev/null
echo "== $(utc) end of G3 in $label"
