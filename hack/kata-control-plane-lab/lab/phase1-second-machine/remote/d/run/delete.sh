#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# The delete of a cluster that NVKE made with cluster-api-provider-provisioned, as a lab operator
# procedure (decision of the main session, 2026-11-26). The NVKE API alone cannot finish it: the
# provider keeps its finalizer on a bound ProvisionedMachine and keeps one ProvisionedHostClaim
# for each host address, and the teardown workflow of NVKE waits for the Machines with no end.
#
# Usage: LOG_DIR=<run folder> CLUSTER_NAME=<name> delete.sh <step>
#   api-delete   1. DELETE /api/clusters/<id>. Poll each 10 s and record how far the workflow comes
#   hosts-down   2. delete the host pods and wipe the volumes (run.sh down, run.sh wipe)
#   release      3. the two operator steps, only on the objects of this cluster: remove the provider
#                   finalizer from its ProvisionedMachine objects, delete its ProvisionedHostClaim objects
#   wait-gone    4. wait up to 10 minutes for the workflow and the cluster row, then check that the state is empty
#   all          the four steps in this order. It stops when a step fails
#
# The script does not edit the database, does not end or change a Temporal workflow, and does not
# delete a Cluster, a Machine, a Secret or a ProvisionedCluster.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NS=${NS:-phase1-run}
CAPI_NS=${CAPI_NS:-nvke-system}
KIND_NODE=${KIND_NODE:-kata-cp-control-plane}
API=${API:-/scratch/kata-cp/work/phase1-stack/api.sh}
TEMPORAL_NS=cloud-workflow-engine
TEMPORAL_ADDR=temporal-frontend.temporal.svc.cluster.local:7233
PROVIDER_FINALIZER=provisionedmachine.infrastructure.cluster.x-k8s.io
POLL=${POLL:-10}
STABLE_POLLS=${STABLE_POLLS:-6}          # the wait point counts as reached after this many equal polls (60 s)
API_DELETE_LIMIT=${API_DELETE_LIMIT:-1500} # seconds for step 1. kubeadm reset has up to 23 minutes in the workflow
GONE_LIMIT=${GONE_LIMIT:-600}            # seconds for step 4
: "${LOG_DIR:?set LOG_DIR to the folder of the run}"
: "${CLUSTER_NAME:?set CLUSTER_NAME}"
D="$LOG_DIR/delete"
mkdir -p "$D"

KC=(kubectl --kubeconfig /etc/kubernetes/admin.conf)
node() { docker exec "$KIND_NODE" "$@"; }
k() { node "${KC[@]}" "$@"; }
say() { echo "== $*"; }
stamp() { printf '%s %s\n' "$(date +%s.%N)" "$1" >>"$LOG_DIR/times.txt"; }
between() { awk -v a="$1" -v b="$2" '$2==a {x=$1} $2==b {y=$1} END {if (x && y) printf "%.1f\n", y-x; else print "-"}' "$LOG_DIR/times.txt"; }
api() { env -u LOG_DIR "$API" "$@"; }
api_body() { sed '$d' | sed -e '${/^$/d}'; }
cluster_id() { cat "$LOG_DIR/cluster-id.txt"; }
mask() { sed -E 's#(join_token/)[0-9a-f-]+#\1TOKEN#g; s#(join_token *= *")[^"]*#\1TOKEN#g'; }
temporal() { k -n temporal exec deploy/temporal-admintools -- temporal "$@" --namespace "$TEMPORAL_NS" --address "$TEMPORAL_ADDR"; }
# Print a command, then run it. The log then has the exact command of each operator step.
run() { printf '+ %s\n' "$*"; "$@"; }

# The names of the objects of this one cluster.
machines() { k -n "$CAPI_NS" get machines.cluster.x-k8s.io -l "cluster.x-k8s.io/cluster-name=$CLUSTER_NAME" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'; }
pmachines() { k -n "$CAPI_NS" get provisionedmachines -l "cluster.x-k8s.io/cluster-name=$CLUSTER_NAME" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'; }
claims() { k get provisionedhostclaims -o json | jq -r --arg c "$CLUSTER_NAME" --arg ns "$CAPI_NS" '.items[] | select(.spec.clusterName==$c and .spec.machineNamespace==$ns) | .metadata.name'; }

# What exists for this cluster in NVKE, in Cluster API, in SPIRE and in Temporal.
state() {
  local label=$1 out="$D/state-$1.txt"
  {
    say "state $label at $(date -u +%FT%TZ)"
    say "NVKE API: GET /api/clusters/$(cluster_id)"
    api get "/api/clusters/$(cluster_id)" >"$D/.cluster.txt" 2>&1 || true
    tail -1 "$D/.cluster.txt"
    api_body <"$D/.cluster.txt" | jq -c 'if type=="object" and has("conditions") then {name, id, deleting: .conditions.deleting, provisioned: .conditions.provisioned.status} else . end' 2>/dev/null || api_body <"$D/.cluster.txt" | head -3
    say "NVKE API: all clusters"
    api get /api/clusters | api_body | jq -c '[.clusters[]? | {name, id}]'
    say "NVKE API: nodes of the cluster"
    api get "/api/nodes?clusterID=$(cluster_id)" | api_body | jq -r '(.nodes // [])[] | "\(.name) " + ([.conditions | to_entries[] | select(.value.status=="True") | "\(.key)[\(.value.message // "")]"] | join(" "))' | cut -c1-300
    say "Cluster API objects in $CAPI_NS with the label of the cluster, and the objects with its name"
    k -n "$CAPI_NS" get clusters.cluster.x-k8s.io,machines.cluster.x-k8s.io,provisionedclusters,provisionedmachines,provisionedmachinetemplates -o custom-columns=KIND:.kind,NAME:.metadata.name,DELETION:.metadata.deletionTimestamp,FINALIZERS:.metadata.finalizers 2>&1 | grep -E "KIND|$CLUSTER_NAME" || echo "none"
    say "conditions of the ProvisionedMachine objects"
    k -n "$CAPI_NS" get provisionedmachines -l "cluster.x-k8s.io/cluster-name=$CLUSTER_NAME" -o jsonpath='{range .items[*]}{.metadata.name}{": "}{range .status.conditions[*]}{.type}{"="}{.status}{" "}{.reason}{" ["}{.message}{"] "}{end}{"\n"}{end}' 2>&1 | cut -c1-330
    say "conditions of the Machine objects (Deleting)"
    k -n "$CAPI_NS" get machines.cluster.x-k8s.io -l "cluster.x-k8s.io/cluster-name=$CLUSTER_NAME" -o jsonpath='{range .items[*]}{.metadata.name}{": phase="}{.status.phase}{" "}{range .status.conditions[?(@.type=="Deleting")]}{.reason}{" ["}{.message}{"]"}{end}{"\n"}{end}' 2>&1 | cut -c1-330
    say "Secrets in $CAPI_NS with the name of the cluster (names only)"
    k -n "$CAPI_NS" get secrets -o custom-columns=NAME:.metadata.name,TYPE:.type --no-headers 2>&1 | grep -E "^$CLUSTER_NAME" || echo "none"
    say "host claims of the cluster"
    k get provisionedhostclaims -o custom-columns=NAME:.metadata.name,IP:.spec.ipAddress,CLUSTER:.spec.clusterName,MACHINE:.spec.machineName --no-headers 2>&1 | grep -E " $CLUSTER_NAME " || echo "none"
    say "SPIRE: ClusterStaticEntry objects of nodes (host-<node ID>)"
    k get clusterstaticentries -o custom-columns=NAME:.metadata.name,SPIFFEID:.spec.spiffeID --no-headers 2>&1 | grep -E '^host-' || echo "none"
    say "SPIRE: agents that attested with a join token (the token is used and masked here)"
    k -n spire-server exec spire-server-0 -c spire-server -- /opt/spire/bin/spire-server agent list 2>&1 | mask | grep -A2 'join_token/' | grep -E 'SPIFFE ID|Expiration' || echo "none"
    say "Temporal: workflows that run now"
    temporal workflow list --query 'ExecutionStatus="Running"' --limit 50 2>&1 | cut -c1-150
    say "Temporal: the teardown workflow of the cluster"
    temporal workflow describe --workflow-id "teardown-cluster-$(cluster_id)" 2>&1 | grep -E 'Status|ActivityType|Attempt|State|LastFailure|HeartbeatDetails|WorkflowId|CloseTime|HistoryLength' | cut -c1-260 || true
  } >"$out" 2>&1
  cat "$out"
}

# One line for a poll in step 1: the deleting message of the cluster, the count of node rows, of Machines and of
# ProvisionedMachines, and the activity that the teardown workflow of the cluster waits in.
poll_line() {
  local c n m p a
  # A cluster that is gone gives "HTTP 404" (the body can be empty).
  api get "/api/clusters/$(cluster_id)" >"$D/.poll.txt" 2>/dev/null || true
  if tail -1 "$D/.poll.txt" | grep -q '^HTTP 404$'; then
    c="no cluster row"
  else
    c=$(api_body <"$D/.poll.txt" | jq -r '.conditions.deleting.message // "?"' 2>/dev/null || echo "?")
  fi
  n=$(api get "/api/nodes?clusterID=$(cluster_id)" 2>/dev/null | api_body | jq -r '(.nodes // []) | length' 2>/dev/null || echo "?")
  m=$(machines | grep -c . || true)
  p=$(pmachines | grep -c . || true)
  a=$(temporal workflow describe --workflow-id "teardown-cluster-$(cluster_id)" --output json 2>/dev/null | jq -r '[(.pendingActivities // [])[] | "\(.activityType.name) attempt \(.attempt // 1)"] | join(", ")' 2>/dev/null || echo "?")
  printf 'deleting=[%s] node-rows=%s machines=%s provisionedmachines=%s pending=[%s]\n' "$c" "$n" "$m" "$p" "$a"
}

cmd_api_delete() {
  local end last="" line same=0 first=0 t0
  say "1. DELETE through the NVKE API, cluster $CLUSTER_NAME, ID $(cluster_id)"
  state before-delete >/dev/null
  stamp delete-post
  t0=$(date +%s)
  run api delete "/api/clusters/$(cluster_id)" 2>&1 | tee "$D/delete-response.txt"
  grep -q '^HTTP 20[0-9]$' "$D/delete-response.txt" || { echo "the API did not accept the DELETE"; return 1; }
  say "poll each $POLL s until the state does not change for $((STABLE_POLLS * POLL)) s (limit $API_DELETE_LIMIT s)"
  end=$(( $(date +%s) + API_DELETE_LIMIT ))
  while [ "$(date +%s)" -lt "$end" ]; do
    line=$(poll_line)
    echo "$(date -u +%T) $line" | tee -a "$D/timeline.txt"
    case "$line" in *'deleting=[no cluster row]'*)
      stamp delete-row-gone
      say "the cluster row is gone with no operator step: $(between delete-post delete-row-gone) s after the DELETE"
      return 0
      ;;
    esac
    # Stable means: the same line, and the node rows are gone (the node teardown workflows have ended).
    if [ "$line" = "$last" ] && [[ "$line" == *"node-rows=0 "* ]]; then same=$((same + 1)); else same=0; first=$(date +%s); fi
    last=$line
    if [ "$same" -ge "$STABLE_POLLS" ]; then
      stamp delete-waits
      say "the workflow waits. This state came $((first - t0)) s after the DELETE and did not change for $(( $(date +%s) - first )) s"
      state api-delete-waits
      return 0
    fi
    sleep "$POLL"
  done
  say "the state still changes after $API_DELETE_LIMIT s"
  state api-delete-limit
  return 1
}

cmd_hosts_down() {
  say "2. delete the host pods and wipe the volumes"
  run "$HERE/run.sh" down
  run "$HERE/run.sh" wipe
  stamp hosts-down
}

cmd_release() {
  local pm cl name fins idx
  say "3. the two operator steps on the objects of cluster $CLUSTER_NAME only"
  pmachines >"$D/release-provisionedmachines.txt"
  claims >"$D/release-hostclaims.txt"
  say "ProvisionedMachine objects of the cluster in $CAPI_NS (the provider finalizer goes away):"
  cat "$D/release-provisionedmachines.txt"
  say "ProvisionedHostClaim objects of the cluster (they are deleted):"
  k get provisionedhostclaims -o custom-columns=NAME:.metadata.name,IP:.spec.ipAddress,CLUSTER:.spec.clusterName,MACHINE:.spec.machineName --no-headers | grep -F -f "$D/release-hostclaims.txt" || true
  pm=$(grep -c . "$D/release-provisionedmachines.txt" || true)
  cl=$(grep -c . "$D/release-hostclaims.txt" || true)
  [ "$pm" = 3 ] && [ "$cl" = 3 ] || { echo "STOP: expected 3 ProvisionedMachine objects and 3 host claims, found $pm and $cl"; return 1; }
  # Each claim must name a ProvisionedMachine of the list.
  while read -r name; do
    k get provisionedhostclaim "$name" -o jsonpath='{.spec.machineName}{"\n"}' | grep -q -x -F -f "$D/release-provisionedmachines.txt" || { echo "STOP: claim $name names a machine that is not in the list"; return 1; }
  done <"$D/release-hostclaims.txt"
  stamp release-start
  say "3a. remove the finalizer $PROVIDER_FINALIZER from each ProvisionedMachine (no other finalizer)"
  while read -r name; do
    fins=$(k -n "$CAPI_NS" get provisionedmachine "$name" -o jsonpath='{.metadata.finalizers}')
    echo "$name: finalizers now $fins, deletionTimestamp $(k -n "$CAPI_NS" get provisionedmachine "$name" -o jsonpath='{.metadata.deletionTimestamp}')"
    idx=$(k -n "$CAPI_NS" get provisionedmachine "$name" -o json | jq --arg f "$PROVIDER_FINALIZER" '.metadata.finalizers | index($f)')
    if [ "$idx" = null ] || [ -z "$idx" ]; then echo "$name: the provider finalizer is not there"; continue; fi
    # The test operation makes the patch fail if the list changed between the read and the write.
    run k -n "$CAPI_NS" patch provisionedmachine "$name" --type=json \
      -p "[{\"op\":\"test\",\"path\":\"/metadata/finalizers/$idx\",\"value\":\"$PROVIDER_FINALIZER\"},{\"op\":\"remove\",\"path\":\"/metadata/finalizers/$idx\"}]"
  done <"$D/release-provisionedmachines.txt"
  say "3b. delete the ProvisionedHostClaim objects of the cluster"
  while read -r name; do
    run k delete provisionedhostclaim "$name"
  done <"$D/release-hostclaims.txt"
  stamp release-done
}

cmd_wait_gone() {
  local end line fail=0 ids id
  say "4. wait up to $GONE_LIMIT s for the teardown workflow and the cluster row"
  end=$(( $(date +%s) + GONE_LIMIT ))
  while [ "$(date +%s)" -lt "$end" ]; do
    line=$(poll_line)
    echo "$(date -u +%T) $line" | tee -a "$D/timeline.txt"
    case "$line" in *'deleting=[no cluster row]'*) stamp delete-row-gone; break ;; esac
    sleep "$POLL"
  done
  state after-release
  # The exact times of the teardown workflow. The raw history goes to the secrets folder.
  temporal workflow show --workflow-id "teardown-cluster-$(cluster_id)" --output json >"$LOG_DIR/secrets/workflow-teardown-cluster.json" 2>/dev/null || true
  jq -r '(.events // .) as $e | ($e | map(select(.eventType|test("ACTIVITY_TASK_SCHEDULED$")) | {key: (.eventId|tostring), value: {name: .activityTaskScheduledEventAttributes.activityType.name, t: .eventTime}}) | from_entries) as $s | $e[] | if (.eventType|test("WORKFLOW_EXECUTION_STARTED$")) then "\(.eventTime) workflow started" elif (.eventType|test("WORKFLOW_EXECUTION_COMPLETED$")) then "\(.eventTime) workflow completed" elif (.eventType|test("ACTIVITY_TASK_COMPLETED$")) then ($s[(.activityTaskCompletedEventAttributes.scheduledEventId|tostring)]) as $x | "\(.eventTime) done \($x.name) (scheduled \($x.t))" else empty end' "$LOG_DIR/secrets/workflow-teardown-cluster.json" >"$D/workflow-teardown-cluster.txt" 2>/dev/null || true
  say "check: is the state empty"
  {
    api get "/api/clusters/$(cluster_id)" | tail -1 | grep -q '^HTTP 404$' && echo "ok   no cluster row (GET gives 404)" || { echo "FAIL the cluster row exists"; fail=1; }
    [ "$(api get /api/clusters | api_body | jq -r --arg n "$CLUSTER_NAME" '[.clusters[]? | select(.name==$n)] | length')" = 0 ] && echo "ok   no cluster with the name $CLUSTER_NAME in the list" || { echo "FAIL a cluster with the name exists"; fail=1; }
    [ "$(api get "/api/nodes?clusterID=$(cluster_id)" | api_body | jq -r '(.nodes // []) | length')" = 0 ] && echo "ok   no node row" || { echo "FAIL node rows exist"; fail=1; }
    [ -z "$(k -n "$CAPI_NS" get clusters.cluster.x-k8s.io,machines.cluster.x-k8s.io,provisionedclusters,provisionedmachines -o name 2>/dev/null | grep -F "$CLUSTER_NAME")" ] && echo "ok   no Cluster, Machine, ProvisionedCluster or ProvisionedMachine of the cluster" || { echo "FAIL Cluster API objects of the cluster exist"; fail=1; }
    [ -z "$(k -n "$CAPI_NS" get secrets -o name 2>/dev/null | grep -F "$CLUSTER_NAME" | grep -F -- '-bootstrap-data')" ] && echo "ok   no bootstrap Secret" || { echo "FAIL a bootstrap Secret exists"; fail=1; }
    [ -z "$(claims)" ] && echo "ok   no host claim of the cluster" || { echo "FAIL a host claim exists"; fail=1; }
    ids=$(jq -r '(.nodes // [])[] | .id' "$LOG_DIR/record-final/api-nodes.json" 2>/dev/null || true)
    for id in $ids; do
      k get clusterstaticentry "host-$id" >/dev/null 2>&1 && { echo "FAIL the SPIRE entry host-$id exists"; fail=1; } || echo "ok   no SPIRE entry host-$id"
    done
    temporal workflow describe --workflow-id "teardown-cluster-$(cluster_id)" 2>&1 | grep -E '^ *Status' | grep -q -i 'COMPLETED' && echo "ok   the teardown workflow of the cluster is completed" || { echo "FAIL the teardown workflow is not completed"; fail=1; }
    echo "what stays with the name of the cluster in $CAPI_NS:"
    k -n "$CAPI_NS" get all,secrets,configmaps,provisionedmachinetemplates -o name 2>/dev/null | grep -F "$CLUSTER_NAME" || echo "  nothing"
    [ "$fail" = 0 ] && echo "RESULT delete: PASS (row gone $(between delete-post delete-row-gone) s after the DELETE, $(between release-done delete-row-gone) s after the operator steps)" || echo "RESULT delete: FAIL"
  } 2>&1 | tee "$D/empty-check.txt"
  grep -q 'RESULT delete: PASS' "$D/empty-check.txt"
}

step=${1:-}
case "$step" in
  api-delete | hosts-down | release | wait-gone)
    "cmd_${step//-/_}" 2>&1 | tee -a "$D/delete.log"
    exit "${PIPESTATUS[0]}"
    ;;
  all)
    { cmd_api_delete && cmd_hosts_down && cmd_release && cmd_wait_gone; } 2>&1 | tee -a "$D/delete.log"
    exit "${PIPESTATUS[0]}"
    ;;
  state) state "${2:-manual}" ;;
  *) sed -n '2,17p' "$0"; exit 1 ;;
esac
