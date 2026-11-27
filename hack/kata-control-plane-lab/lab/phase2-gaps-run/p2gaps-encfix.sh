#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# The lab test of the fix for the encryption join defect. The cluster of this run folder was made
# with the image p9 (the agent with the fix) and encryption off. The chain:
#   1. record the apiServer part of the kubeadm-config ConfigMap,
#   2. turn encryption on through the NVKE API, record the part again and compare,
#   3. roll the three control plane nodes to p10 through the NVKE API. One host node is full, so
#      the chain frees the place through the NVKE API after about one minute of pending,
#   4. check each JoinNode workflow, the flags of the new API servers and a new Secret in etcd.
# One call to the shared address each second and one Ready watch run for the whole chain (label all).
# Usage (detached): setsid nohup p2-gaps/p2gaps-encfix.sh <label> </dev/null >logs/p2gaps/<label>-encfix.out 2>&1 &
label=${1:?label}
. /root/kata-cp/bin/env.sh
export LOG_DIR=$W/logs/p2gaps/$label DISK_LOG=$W/logs/p2gaps/disk.txt
IMG=${IMG:-docker.io/library/nvke-node-podvm:bcc4376f-p10}
OLD_SECTION=${OLD_SECTION:-$W/logs/p2gaps/c-1/kubeadm-clusterconfiguration-after-enc.yaml}
cd "$W/p2-gaps" || exit 1
exec </dev/null
echo "== $(utc) test of the encryption join fix in $label"
./run.sh gate-facts before-encfix; echo "gate-facts exit code: $?"
./run.sh probe-start all 7200; ./run.sh ready-start all 7200
./run.sh apiserver-section before; echo "apiserver-section exit code: $?"
./run.sh enc enc; rc=$?; echo "enc exit code: $rc"
./run.sh health after-enc; echo "health exit code: $?"
./run.sh apiserver-section after-enc; echo "apiserver-section exit code: $?"
./run.sh section-check before after-enc "$OLD_SECTION"; echo "section-check exit code: $?"
if [ "$rc" != 0 ]; then
  echo "== $(utc) encryption is not on. Stop before the rollout"
  ./run.sh probe-stop all; ./run.sh ready-stop all >/dev/null
  exit 1
fi
./run.sh apiserver-flags old; echo "apiserver-flags exit code: $?"
IMG=$IMG RLABEL=r3 FREE_AFTER=${FREE_AFTER:-60} ./p2gaps-t3.sh "$label"; echo "rollout chain exit code: $?"
./run.sh join-check r3; echo "join-check exit code: $?"
./run.sh apiserver-flags new; echo "apiserver-flags exit code: $?"
./run.sh flags-check old new; echo "flags-check exit code: $?"
./run.sh secret-check; echo "secret-check exit code: $?"
./run.sh probe-stop all; echo "probe-stop exit code: $?"
./run.sh ready-stop all >"$LOG_DIR/ready-stop-all.out" 2>&1; echo "ready-stop exit code: $?"
echo "time ranges in which a Node that was Ready was not Ready (whole test): [$(cat "$LOG_DIR/ready-all-ranges.txt")]"
./run.sh health final; echo "health exit code: $?"
./run.sh w2 final; echo "w2 exit code: $?"
./run.sh facts final >/dev/null; echo "facts exit code: $?"
echo "== $(utc) end of the test of the encryption join fix in $label"
