#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Steps 6 and 7, part B (S6a): DELETE of a joined node that is not the first node, then of the first
# node, each through the NVKE API, with four nodes. NVKE must make a new Machine after each.
# Usage (detached): setsid nohup p2-replace/p2s6-b.sh <label> >logs/p2s6/<label>-b.out 2>&1 &
label=${1:?label}
. /root/kata-cp/bin/env.sh
export LOG_DIR=$W/logs/p2s6/$label
cd "$W/p2-replace" || exit 1
echo "== $(utc) part B of $label"
./run.sh delete-node other joined; echo "delete-node joined exit code: $?"
./run.sh after replace-joined; echo "after replace-joined exit code: $?"
./run.sh delete-node first first; echo "delete-node first exit code: $?"
./run.sh after replace-first; echo "after replace-first exit code: $?"
echo "== $(utc) end of part B of $label"
