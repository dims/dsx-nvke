#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# One run of step 4: the cluster through NVKE with the pod VM provider, then the measurements of
# block D (pod traffic, tunnels) and the PATCH check.
# Usage (detached): setsid nohup p2-provider/p2s4-run.sh <label> >logs/p2s4/<label>.out 2>&1 &
label=${1:?label}
. /root/kata-cp/bin/env.sh
export LOG_DIR=$W/logs/p2s4/$label
mkdir -p "$LOG_DIR"
cd "$W/p2-provider" || exit 1
echo "== $(utc) start of $label. br_netfilter loaded: $(lsmod | grep -c '^br_netfilter'). Lab rule in the firewall: $(nft list chain inet cm_filter forward | grep -c 'br-kata') (0 = none)"
./run.sh flow
echo "flow exit code: $?"
echo "== $(utc) NVKE view before the measurements"; ./run.sh poll
./run.sh traffic after-flow
./run.sh tunnels after-flow
./run.sh patch-check
echo "patch-check exit code: $?"
echo "== $(utc) NVKE view after the measurements"; ./run.sh poll
echo "== $(utc) end of $label"
