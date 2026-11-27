#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# W5: remove the worker through the NVKE API. First the pool to zero nodes and back to one, then
# the delete of the pool with its node. At the end a new pool with one worker, so that a cluster
# with three control plane nodes and one worker stays up.
# Usage (detached): setsid nohup p2-worker/p2s8-w5.sh <label> >logs/p2s8/<label>-w5.out 2>&1 &
label=${1:?label}
. /root/kata-cp/bin/env.sh
export LOG_DIR=$W/logs/p2s8/$label
cd "$W/p2-worker" || exit 1
echo "== $(utc) W5 in $label"
# The pool is at desiredNodeCount 0 since 04:02:07 (the PATCH of the first try of this chain). NVKE
# accepted it and tore nothing down, by design. So: DELETE of the node with the count at 0.
./run.sh worker-delete w5a; echo "worker-delete w5a exit code: $?"
./run.sh pool-scale 1 w5a-up; echo "pool-scale w5a-up exit code: $?"
./run.sh w1 w5a-up; echo "w1 w5a-up exit code: $?"
./run.sh pool-delete w5b; echo "pool-delete w5b exit code: $?"
# The pool again, with the same name. If NVKE refuses the name, take a second name.
./run.sh pool-post workers wk 1; rc=$?; echo "pool-post final exit code: $rc"
if [ "$rc" != 0 ]; then ./run.sh pool-post workers-b wk 1; rc=$?; echo "pool-post final (second name) exit code: $rc"; fi
if [ "$rc" = 0 ]; then
  ./run.sh pool-wait 1 final; echo "pool-wait final exit code: $?"
  ./run.sh w1 final; echo "w1 final exit code: $?"
  ./run.sh w2 final; echo "w2 final exit code: $?"
fi
echo "== $(utc) end of W5 in $label"
