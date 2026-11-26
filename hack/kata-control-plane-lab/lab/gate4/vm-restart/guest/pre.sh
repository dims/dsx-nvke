#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Before a restart test: save the state of the three replicas, then mark the run as pending.
# The boot unit vm-restart-watch.service does the rest after the next boot.
# Usage: pre.sh <label>      (as root in the VM)
set -euo pipefail
label=${1:?label}
. /opt/vm-restart/env.sh
STATE=/var/lib/vm-restart
D=$STATE/runs/$label
[ ! -e "$D" ] || { echo "the run $label exists" >&2; exit 1; }
[ ! -s "$STATE/pending" ] || { echo "a run is pending: $(cat "$STATE/pending")" >&2; exit 1; }
mkdir -p "$D"
export LOG_DIR=$D
. /opt/vm-restart/lib.sh
R=/opt/vm-restart/gate4/run.sh

say "checks before the restart ($label)"
for r in a b c; do
  [ "$(k -n "$NS" get pod "cp-$r-0" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] ||
    { echo "the pod cp-$r-0 is not ready" >&2; exit 1; }
done
[ "$(node systemctl is-enabled g4-loop-nodes.service)" = enabled ] || { echo "g4-loop-nodes.service is not enabled in the kind node" >&2; exit 1; }
for u in vm-restart-loops.service vm-restart-watch.service vm-restart-record.service docker.service; do
  [ "$(systemctl is-enabled "$u")" = enabled ] || { echo "$u is not enabled" >&2; exit 1; }
done
snapshot before
k get node -o jsonpath='{.items[0].status.runtimeHandlers[*].name}' | tr ' ' '\n' | sort >"$D/handlers-before.txt"
losetup -l -n -O NAME,BACK-FILE,DIO | awk 'index($2, "/var/lib/vm-restart/disks/") == 1' | sort -k2 >"$D/loop-map-before.txt"
"$R" check 5-before-restart | tail -1
"$R" reach 5-before-restart | tail -1
"$R" identity before
pod_lines >"$D/pods-before.txt"
for r in a b c; do
  k -n "$NS" get pod "cp-$r-0" -o jsonpath='{.status.containerStatuses[0].containerID}' >"$D/.container-$r-before"
done
{
  echo "label $label"
  echo "boot-id-before $(cat /proc/sys/kernel/random/boot_id)"
  echo "uptime-before $(cut -d' ' -f1 /proc/uptime)"
  echo "time-before $(date -u +%FT%TZ)"
  echo "container-id $(docker inspect -f '{{.Id}}' "$KIND_NODE")"
  echo "container-started-before $(docker inspect -f '{{.State.StartedAt}}' "$KIND_NODE")"
  echo "container-restart-count-before $(docker inspect -f '{{.RestartCount}}' "$KIND_NODE")"
} >"$D/before.txt"
cat "$D/before.txt"
echo "$label" >"$STATE/pending"
# Write only the files of this test to the disk. No sync of the whole system.
sync "$D"/* "$D"/.container-* "$D" "$STATE/pending" "$STATE/runs" "$STATE"
echo "PRE DONE $label"
