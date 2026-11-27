#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Pass rules 3, 5 and 7: the rollout of the three control plane nodes to another image through the
# NVKE API. One host node has no free volume place (it has a control plane node and the worker), so
# the surge node of that failure domain is pending. The chain waits until it is pending for
# FREE_AFTER seconds, records what NVKE shows (rule 5), and then frees the place through the NVKE
# API (rule 7). It does that one time. The rollout must end by itself.
# Usage (detached): [IMG=<image>] [RLABEL=r1] setsid nohup p2-gaps/p2gaps-t3.sh <label> >logs/p2gaps/<label>-t3.out 2>&1 &
label=${1:?label}
. /root/kata-cp/bin/env.sh
export LOG_DIR=$W/logs/p2gaps/$label DISK_LOG=$W/logs/p2gaps/disk.txt
IMG=${IMG:-docker.io/library/nvke-node-podvm:bcc4376f-p7}
RLABEL=${RLABEL:-r1}
FREE_AFTER=${FREE_AFTER:-180}
k() { docker exec kata-bb-control-plane timeout 40 kubectl --kubeconfig /etc/kubernetes/admin.conf "$@"; }
cd "$W/p2-gaps" || exit 1
exec </dev/null
echo "== $(utc) pass rules 3, 5 and 7 in $label: rollout $RLABEL to ${IMG##*:}"
pgrep -f "storage-loop[.]sh" >/dev/null || (setsid nohup "$W/p2-replace/storage-loop.sh" >>"$W/logs/p2gaps/storage-loop.out" 2>&1 &)
./run.sh gate-facts "before-$RLABEL"; echo "gate-facts exit code: $?"
./run.sh cp-rollout "$RLABEL" "$IMG" &
ROLLOUT=$!
freed=0
while kill -0 "$ROLLOUT" 2>/dev/null; do
  sleep 15
  [ "$freed" = 0 ] || continue
  # A control plane pod of the provider that is Pending, and the age of its Machine.
  surge=$(k -n d get pods -o json 2>/dev/null | jq -r '[.items[] | select(.status.phase=="Pending") | select(.metadata.labels["cluster.x-k8s.io/control-plane"] != null) | select([.status.conditions[]? | select(.type=="PodScheduled" and .status=="False")] | length > 0) | .metadata.name] | first // ""')
  [ -n "$surge" ] || continue
  created=$(k -n nvke-system get machine.cluster.x-k8s.io "$surge" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)
  [ -n "$created" ] || continue
  age=$(( $(date +%s) - $(date -u -d "$created" +%s) ))
  if [ "$age" -ge "$FREE_AFTER" ]; then
    echo "== $(utc) the surge $surge is pending for $age s. Free its volume place through the NVKE API"
    mkdir -p "$LOG_DIR/free-$RLABEL"
    cp "$LOG_DIR/cluster-id.txt" "$LOG_DIR/pool-id.txt" "$LOG_DIR/pool-name.txt" "$LOG_DIR/free-$RLABEL/"
    LOG_DIR="$LOG_DIR/free-$RLABEL" ./run.sh free-place "$RLABEL"; echo "free-place exit code: $?"
    freed=1
  fi
done
wait "$ROLLOUT"; echo "cp-rollout exit code: $?"
./run.sh gap2-check "$RLABEL" free; echo "gap2-check exit code: $?"
./run.sh health "after-$RLABEL"; echo "health exit code: $?"
./run.sh w2 "after-$RLABEL"; echo "w2 exit code: $?"
./run.sh gate-facts "after-$RLABEL"; echo "gate-facts exit code: $?"
echo "== $(utc) end of pass rules 3, 5 and 7 in $label"
