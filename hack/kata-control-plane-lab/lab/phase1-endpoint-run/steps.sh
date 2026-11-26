#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# steps.sh <run folder>: the workflow steps of one run that took 0.9 s or more, from the time lines of record-final.
set -euo pipefail
r=$1
dur() { awk -v min=0.9 'function sec(t){return substr(t,12,2)*3600+substr(t,15,2)*60+substr(t,18)+0} /workflow started/ {printf "  %s workflow started\n", substr($1,12,12)} /done/ {s=$0; m=match(s,/\(scheduled [^)]*\)/); sch=substr(s,RSTART+11,30); d=sec($1)-sec(sch); if (d>=min) printf "  %s %-36s %.1f s (from %s)\n", substr($1,12,12), $3, d, substr(sch,12,12)} /FAILED/ {print "  " substr($1,12,12) " FAILED " $3} /WORKFLOW_EXECUTION/ {printf "  %s workflow end %s\n", substr($1,12,12), $3}' "$1" | sed 's/EVENT_TYPE_WORKFLOW_EXECUTION_//'; }
cid=$(cat "$r/cluster-id.txt")
echo "POST $(cat "$r/post-time.txt")"
echo "=== provision-cluster"; dur "$r/record-final/workflow-provision-cluster-$cid.txt"
jq -r '(.nodes // [])[] | "\(.id) \(.ip) \(.name)"' "$r/record-final/api-nodes.json" | while read -r id ip name; do
  echo "=== provision-node $ip $name"; dur "$r/record-final/workflow-provision-node-$id.txt"
  echo "=== join-node $ip"; dur "$r/record-final/workflow-join-node-$id.txt"
done
echo "=== failed activity attempts in the controller log"
grep '"msg":"Activity attempt returned"' "$r/record-final/nvke-controller-warn-error.txt" | grep -oE '"ActivityType":"[A-Za-z]+","attempt":[0-9]+' | sort | uniq -c
grep -vE '"msg":"Activity (attempt returned|error\.)"' "$r/record-final/nvke-controller-warn-error.txt" | grep -oE '"level":"[A-Z]+","msg":"[^"]{0,110}' | sort | uniq -c
echo "=== workflow runs that failed"
grep -E 'Failed|TimedOut|Terminated|Canceled' "$r/record-final/temporal-workflows.txt" | grep -F -f <(jq -r '(.nodes // [])[] | .id' "$r/record-final/api-nodes.json"; echo "$cid") || echo "  none"
