#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# The watch part of one run, after "post": wait for provisioned, wait for the nodes, check, record.
# Usage: rest.sh <run folder name> <cluster name>
set -uo pipefail
cd "$(dirname "$0")"
export LOG_DIR=/scratch/kata-cp/logs/phase1-run/$1 CLUSTER_NAME=$2
./run.sh wait; echo "wait exit code: $?"
./run.sh wait-nodes; echo "wait-nodes exit code: $?"
./run.sh check final; echo "check exit code: $?"
./run.sh times
./run.sh record final
./run.sh evidence final
