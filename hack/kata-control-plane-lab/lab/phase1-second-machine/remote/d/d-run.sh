#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Block D: one run from empty volumes through the real NVKE controller. The host pods are the C3 form
# (fixed address and hardware address on net1, the class with the Open vSwitch kernel, stock datapath mode,
# no etcd patch file), the endpoint is the shared LoadBalancer address. Then the measurements of C3.
# Usage (detached): setsid nohup d/d-run.sh <label> [replace] >logs/d/<label>.out 2>&1 &
label=${1:?label}
. /root/kata-cp/bin/env.sh
export LOG_DIR=$W/logs/d/$label
mkdir -p "$LOG_DIR"
cd "$W/d/endpoint-run"
echo "== $(utc) start of $label. br_netfilter loaded: $(lsmod | grep -c '^br_netfilter'). Lab rule in the firewall: $(nft list chain inet cm_filter forward | grep -c 'br-kata') (0 = none)"
./run.sh full
echo "full exit code: $?"
echo "== $(utc) NVKE view before the measurements"; ./run.sh poll
./run.sh traffic after-flow
./run.sh tunnels after-flow
echo "== $(utc) NVKE view after the measurements"; ./run.sh poll
if [ "${2:-}" = replace ]; then
  ./run.sh replace-init
  echo "replace-init exit code: $?"
  ./run.sh traffic after-replace
  ./run.sh check after-replace
  ./run.sh endpoint after-replace
  echo "== $(utc) NVKE view after the replace"; ./run.sh poll
fi
echo "== $(utc) end of $label"
