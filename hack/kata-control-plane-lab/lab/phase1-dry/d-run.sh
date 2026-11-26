#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# One dry run from empty volumes, then the measurements. Usage: d-run.sh <run name> <measure|keep>
#   measure  full flow, traffic, tunnels, replace of node b, replace of node a (the endpoint), check, then remove all
#   keep     full flow, traffic, tunnels, check, and the cluster stays up
set -uo pipefail
cd "$(dirname "$0")"
export LOG_DIR=/scratch/kata-cp/logs/phase1-dry/$1 KEEP=1
./run.sh full
echo "full exit code: $?"
./run.sh traffic after-flow
./run.sh tunnels after-flow
if [ "$2" = measure ]; then
  ./run.sh replace b
  echo "replace b exit code: $?"
  ./run.sh replace a
  echo "replace a exit code: $?"
  ./run.sh traffic after-replaces
fi
./run.sh check end
echo "check exit code: $?"
./run.sh evidence end
if [ "$2" = measure ]; then
  ./run.sh down
  ./run.sh wipe
fi
