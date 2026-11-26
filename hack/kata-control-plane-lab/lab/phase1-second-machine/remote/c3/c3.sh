#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Block C3: one full run of the dry run flow with fixed addresses and the kernel datapath, then the
# measurements (pod traffic between nodes, tunnel endpoints, a replace of one node pod).
# Usage (detached): setsid nohup c3/c3.sh <label> >logs/c3/<label>.out 2>&1 &
label=${1:-c3-run-1}
. /root/kata-cp/c3/env-c3.sh
export LOG_DIR=$W/logs/c3/$label SEC=$W/secrets/c3-$label
mkdir -p "$LOG_DIR"
cd "$W/c3/dry"
echo "== $(utc) start of $label: class $RUNTIME_CLASS, image $IMAGE, datapath '${P1_OVS_DATAPATH:-image value (system)}', FIXED_MAC=${FIXED_MAC:-0}"
echo "br_netfilter loaded: $(lsmod | grep -c '^br_netfilter'). Lab rule in the firewall: $(nft list chain inet cm_filter forward | grep -c 'br-kata') (0 = none)"
if kubectl get namespace "$NS" >/dev/null 2>&1; then ./run.sh down >/dev/null 2>&1; fi
./run.sh full
echo "full exit code: $?"
[ "${STOP_AFTER_FULL:-0}" = 1 ] && exit 0
./run.sh traffic after-flow
./run.sh tunnels after-flow
./run.sh replace b
echo "replace b exit code: $?"
./run.sh traffic after-replace
./run.sh check end
echo "check exit code: $?"
./run.sh evidence end
echo "== $(utc) end of $label"
