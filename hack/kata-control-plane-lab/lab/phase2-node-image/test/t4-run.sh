#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# T4: one run through the real NVKE controller with the node image for pods, then the
# measurements of block D (pod traffic, tunnels) and the PATCH check.
# Usage (detached): setsid nohup p2-image/test/t4-run.sh <label> >logs/p2/<label>.out 2>&1 &
label=${1:?label}
. /root/kata-cp/bin/env.sh
export LOG_DIR=$W/logs/p2/$label
mkdir -p "$LOG_DIR"
cd "$W/p2-image/test" || exit 1
echo "== $(utc) start of $label. br_netfilter loaded: $(lsmod | grep -c '^br_netfilter'). Lab rule in the firewall: $(nft list chain inet cm_filter forward | grep -c 'br-kata') (0 = none)"
./t4.sh flow
echo "flow exit code: $?"
echo "== $(utc) NVKE view before the measurements"; ./t4.sh poll
./t4.sh traffic after-flow
./t4.sh tunnels after-flow
./t4.sh patch-check
echo "patch-check exit code: $?"
echo "== $(utc) NVKE view after the measurements"; ./t4.sh poll
echo "== $(utc) end of $label"
