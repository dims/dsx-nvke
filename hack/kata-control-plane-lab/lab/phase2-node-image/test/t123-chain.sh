#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# T1, T2 and T3 in one chain, with the image that is in the host nodes now.
# Usage (detached): setsid nohup p2-image/test/t123-chain.sh >logs/p2/t123-chain.out 2>&1 &
. /root/kata-cp/bin/env.sh
cd "$W"
T=p2-image/test/t123.sh
step() { echo "== $(utc) $*"; "$T" "$@"; echo "exit code of '$*': $?"; }
step base
step wipe t1
step up t1 first                 # T1: empty volumes, the data "full"
step check t1 first first
step delete-pod t1               # T2: a new pod with the same name and the same claims
step up t1 again
step check t1 again repeat 3
step compare t1 first again
step restart t1                  # T3: a new container in the same pod
step check t1 restart repeat 3
step compare t1 first restart
step wipe t1b                    # the answer "error": the data "fail" in a second pod
step up t1b first
step check t1b first first
echo "== $(utc) T123 CHAIN DONE"
