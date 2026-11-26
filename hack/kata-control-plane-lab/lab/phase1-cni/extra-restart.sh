#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Extra test, not a pass rule: one full Kata run with no node-local-dns step (no image pull), then a stop of
# the container with crictl, then the pod network test again. Usage: extra-restart.sh <run name>
set -uo pipefail
cd "$(dirname "$0")"
. ./env-kata.sh
export P1_OVS_NO_MODPROBE=1 P1_TUN=1 SKIP_DNS=1 KEEP=1
export LOG_DIR=/scratch/kata-cp/logs/phase1-cni/$1
./run.sh full
echo "full exit code: $?"
./run.sh restart
echo "restart exit code: $?"
./run.sh check after-restart
echo "check exit code: $?"
./run.sh evidence
./run.sh logs
./run.sh down
./run.sh wipe
