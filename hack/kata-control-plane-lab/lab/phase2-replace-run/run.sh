#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Phase 2, steps 6 and 7: a node replace through the NVKE API, a rollout to a new node image, and
# the placement after each step. The cluster comes from one request to NVKE with the pod VM
# provider. Each change of the cluster goes through the NVKE API. This script makes no pod, no
# claim, no Secret copy, and writes no NVKE or Cluster API object.
#
# It loads the functions of steps 4 and 5 (p2-provider/run.sh) and adds the steps below.
# Usage: LOG_DIR=<run folder> run.sh <step>
#   flow                      the cluster with the image p2 (as step 4), maxSurge 1, recycling on
#   refuse-delete <who>       DELETE of a node while only three are joined: record the answer of NVKE
#   scale <n> <label>         PATCH controlPlaneConfig.desiredCount
#   delete-node <who> <label> DELETE /api/nodes/<id>, then watch the teardown and the new Machine
#   rollout <label>           PATCH the machine template to the image p3, then watch the rollout
#   after <label>             the state checks, the placement table (S7) and pod traffic
#   placement <label>         only the placement table
#   who: a letter of the pod map (a, b, ...), "first" (the node of kubeadm init) or "other"
set -euo pipefail
. /root/kata-cp/bin/env.sh
R="$(cd "$(dirname "$0")" && pwd)"
export NS=${NS:-d}
export LOG_DIR=${LOG_DIR:-$W/logs/p2s6/run-1}
IMG_P2=${IMG_P2:-docker.io/library/nvke-node-podvm:bcc4376f-p2}
IMG_P3=${IMG_P3:-docker.io/library/nvke-node-podvm:bcc4376f-p3}
WATCH_LIMIT=${WATCH_LIMIT:-1800}

# shellcheck disable=SC1090
source <(sed '/^step=\${1:-}$/,$d' "$W/p2-provider/run.sh")
P=$W/p2-provider      # its storage script and Service template
HERE=$D

machine_template() { # <image>
  NODE_IMAGE_REF=$1 CPU=$CPU MEMORY=$MEMORY SC=$SC envsubst '$NODE_IMAGE_REF $CPU $MEMORY $SC' <"$R/machine-template.json.tmpl"
}

cmd_post() {
  export NS IP_API POD_CIDR SERVICE_CIDR CLUSTER_NAME RUNTIME_CLASS RANGE_CIDR MACHINE_TEMPLATE
  MACHINE_TEMPLATE=$(machine_template "$IMG_P2")
  envsubst '$NS $IP_API $POD_CIDR $SERVICE_CIDR $CLUSTER_NAME $RUNTIME_CLASS $RANGE_CIDR $MACHINE_TEMPLATE' <"$R/request.json.tmpl" >"$LOG_DIR/request.json"
  jq -e . "$LOG_DIR/request.json" >/dev/null || die "the request is not JSON"
  say "POST /api/clusters ($CLUSTER_NAME), desiredCount 3, maxSurge 1, enableCPNodeRecycling true, image ${IMG_P2##*:}"
  stamp post
  date -u +%FT%T.%3NZ >"$LOG_DIR/post-time.txt"
  api post /api/clusters "$LOG_DIR/request.json" >"$LOG_DIR/post-response.txt" 2>&1 || true
  tail -1 "$LOG_DIR/post-response.txt"
  grep -q '^HTTP 20[012]$' "$LOG_DIR/post-response.txt" || { cat "$LOG_DIR/post-response.txt"; die "the API did not accept the request"; }
  api_body <"$LOG_DIR/post-response.txt" | jq -r '.id' >"$LOG_DIR/cluster-id.txt"
  say "cluster ID $(cluster_id)"
  api_body <"$LOG_DIR/post-response.txt" | jq -c '{name, id, controlPlaneEndpoint, enableCPNodeRecycling}' || true
}

# --- the state of the cluster, for any number of nodes -----------------------------------------
sample() { # refresh the JSON files of the state. sample 1 = with the NVKE API (one call each 10 s at most)
  if [ "${1:-1}" = 1 ]; then
    api get "/api/nodes?clusterID=$(cluster_id)" 2>/dev/null | api_body >"$LOG_DIR/.n.new" 2>/dev/null && jq -e . "$LOG_DIR/.n.new" >/dev/null 2>&1 && mv "$LOG_DIR/.n.new" "$LOG_DIR/.n.json"
    api get "/api/clusters/$(cluster_id)/control-plane" 2>/dev/null | api_body >"$LOG_DIR/.cp.new" 2>/dev/null && jq -e . "$LOG_DIR/.cp.new" >/dev/null 2>&1 && mv "$LOG_DIR/.cp.new" "$LOG_DIR/.cp.json"
  fi
  [ -s "$LOG_DIR/.n.json" ] || echo '{"nodes":[]}' >"$LOG_DIR/.n.json"
  [ -s "$LOG_DIR/.cp.json" ] || echo '{}' >"$LOG_DIR/.cp.json"
  pvmm_json >"$LOG_DIR/.i.json" 2>/dev/null || echo '{"items":[]}' >"$LOG_DIR/.i.json"
  k -n "$CAPI_NS" get machines.cluster.x-k8s.io -l "cluster.x-k8s.io/cluster-name=$CLUSTER_NAME" -o json >"$LOG_DIR/.m.json" 2>/dev/null || echo '{"items":[]}' >"$LOG_DIR/.m.json"
  k -n "$NS" get pods -o json >"$LOG_DIR/.p.json" 2>/dev/null || echo '{"items":[]}' >"$LOG_DIR/.p.json"
  k -n "$NS" get pvc -o json >"$LOG_DIR/.c.json" 2>/dev/null || echo '{"items":[]}' >"$LOG_DIR/.c.json"
  k get pv -l podvm.lab/use -o json >"$LOG_DIR/.v.json" 2>/dev/null || echo '{"items":[]}' >"$LOG_DIR/.v.json"
}
jqs() { jq -n -r --slurpfile n "$LOG_DIR/.n.json" --slurpfile cp "$LOG_DIR/.cp.json" --slurpfile i "$LOG_DIR/.i.json" --slurpfile m "$LOG_DIR/.m.json" --slurpfile p "$LOG_DIR/.p.json" --slurpfile c "$LOG_DIR/.c.json" --slurpfile v "$LOG_DIR/.v.json" "$@"; }
JQ_DEFS='def good: (.conditions.joined.status=="True" and .conditions.kubernetesReady.status=="True" and .conditions.nodeAgentReady.status=="True" and .conditions.provisioned.status=="True" and (.conditions.deleting.status!="True") and (.conditions.deleteRequested.status!="True"));
  def short: {"pending":"pend","provisioningClaimed":"claim","nodeAgentReady":"agent","readyToJoin":"rtj","joined":"join","kubernetesReady":"kube","provisioned":"prov","provisioning":"prov-ing","deleting":"DELETING","deleteRequested":"delete-requested"}[.] // .;
  def podstate: if .metadata.deletionTimestamp then "terminating" elif (.status.containerStatuses[0].ready // false) then "ready" elif (.status.containerStatuses[0].started // false) then "started" else (.status.phase // "-") end;'
state_line() {
  jqs "$JQ_DEFS"'
    "nvke \(($n[0].nodes // []) | length) (good \([($n[0].nodes // [])[] | select(good)] | length)): " + ([($n[0].nodes // [])[] | "\(.name[-8:])=" + ([.conditions | to_entries[] | select(.value.status=="True") | .key | short] | join("+"))] | join(" "))
    + " | machines \($m[0].items | length) pvmm \($i[0].items | length) | pods " + ([$p[0].items[] | "\(.metadata.name[-8:])@\((.spec.nodeName // "-") | sub("kata-bb-"; ""))=\(.spec.containers[0].image | sub(".*-"; ""))/\(podstate)"] | join(" "))
    + " | claims \([$c[0].items[] | select(.status.phase=="Bound")] | length)/\($c[0].items | length) | volumes " + ([$v[0].items[].status.phase] | group_by(.) | map("\(.[0])=\(length)") | join(" "))'
}
count() { jqs "$JQ_DEFS$1"; }
good_nodes() { count '[($n[0].nodes // [])[] | select(good)] | length'; }
all_nodes() { count '($n[0].nodes // []) | length'; }
ready_pods() { count '[$p[0].items[] | select(.metadata.deletionTimestamp | not) | select(.status.containerStatuses[0].ready // false)] | length'; }

# S7: for each Machine its failure domain, host node, address, volumes, image, and the rule.
placement_table() {
  jqs "$JQ_DEFS"'
    def byname($arr; $x): ([$arr[] | select(.metadata.name==$x)][0] // {});
    ($i[0].items | sort_by((.status.address // "999.999.999.999") | split(".") | map(tonumber))) [] as $x
    | $x.metadata.name as $name
    | byname($m[0].items; $name) as $mm | byname($p[0].items; $name) as $pp
    | ([($n[0].nodes // [])[] | select(.name==$name)][0] // {}) as $nn
    | "\($name)  address \($x.status.address // "-")  domain \($mm.spec.failureDomain // "-")  host \($pp.spec.nodeName // "-")  volumes \(([$c[0].items[] | select(.metadata.name==($name + "-var"))][0].spec.volumeName) // "-") \(([$c[0].items[] | select(.metadata.name==($name + "-etcd"))][0].spec.volumeName) // "-")  image \(($pp.spec.containers[0].image // "-") | sub(".*:"; ""))  pod \(if $pp.metadata then ($pp | podstate) else "none" end)  nvke [\(($nn.conditions // {}) | to_entries | map(select(.value.status=="True") | .key | short) | join("+"))]\(if $x.metadata.deletionTimestamp then "  machine is deleting" else "" end)"'
  jqs '"nodes in NVKE with no PodVMMachine: [\([($n[0].nodes // [])[] | .name as $x | select([$i[0].items[] | select(.metadata.name==$x)] | length == 0) | .name] | join(" "))]"'
  jqs '([$p[0].items[] | select(.metadata.deletionTimestamp | not) | .spec.nodeName // "-"]) as $h | "pods \($h | length) on \($h | unique | length) host nodes: \($h | group_by(.) | map("\(.[0] | sub("kata-bb-"; ""))=\(length)") | join(" "))  RULE one pod for each host node: \(if ($h | length) == ($h | unique | length) then "holds" else "does NOT hold" end)"'
  jqs '"volumes: " + ([$v[0].items[] | "\(.metadata.name | sub("podvm-"; ""))@\(.metadata.labels["podvm.lab/host-node"] | sub("kata-bb-"; ""))=\(.status.phase)"] | sort | join(" "))'
}
cmd_placement() {
  local label=${1:-now}
  sample 1
  { say "placement ($label) at $(date -u +%FT%TZ)"; placement_table; } | tee "$LOG_DIR/placement-$label.txt"
}

# The pod map for any number of nodes: the good nodes of NVKE (all Machines with an address while no node
# is good yet, at the start of a cluster), with letters in the order of their addresses.
LETTERS=(a b c d e f)
load_podmap() {
  local r m ip hn
  REPLICAS=()
  [ -s "$PODMAP" ] || { REPLICAS=(a b c); return 0; }
  while read -r r m ip hn; do
    REPLICAS+=("$r"); PODS[$r]=$m; IPS[$r]=$ip; HOST_NODES[$r]=$hn
    # The render function of block D reads these arrays for each letter. They have no use here.
    HOSTS[$r]=${HOSTS[$r]:-none}; VAR_LOOPS[$r]=${VAR_LOOPS[$r]:-none}; ETCD_LOOPS[$r]=${ETCD_LOOPS[$r]:-none}; VAR_SIZES[$r]=${VAR_SIZES[$r]:-none}
  done <"$PODMAP"
}
write_podmap() {
  local i=0 m ip hn
  sample 1
  : >"$PODMAP.new"
  while read -r m ip hn; do
    echo "${LETTERS[$i]} $m $ip $hn" >>"$PODMAP.new"
    i=$((i + 1))
  done < <(jqs "$JQ_DEFS"'([($n[0].nodes // [])[] | select(good) | .name]) as $g | $i[0].items | map(select(.status.address and (($g | length) == 0 or (.metadata.name as $x | $g | index($x))))) | sort_by(.status.address | split(".") | map(tonumber)) | .[] | .metadata.name as $x | "\($x) \(.status.address) \(([$p[0].items[] | select(.metadata.name==$x)][0].spec.nodeName) // "none")"')
  mv "$PODMAP.new" "$PODMAP"
  load_podmap
}
load_podmap
who() { # letter, first or other -> letter
  local w=$1 f r
  case "$w" in
    first) init_host ;;
    other) f=$(init_host) || f=""; for r in "${REPLICAS[@]}"; do [ "$r" != "$f" ] && { echo "$r"; return 0; }; done ;;
    *) echo "$w" ;;
  esac
}
observer() { # a letter that is not $1
  local r
  for r in "${REPLICAS[@]}"; do [ "$r" != "$1" ] && { echo "$r"; return 0; }; done
}
node_id() { jqs --arg x "$1" '($n[0].nodes // [])[] | select(.name==$x) | .id'; }

# Watch until a test for the end is true two times in a row. One state line each 5 s, the NVKE API each 10 s.
watch_until() { # <file> <end test (shell)> [extra line function]
  local file=$1 test=$2 extra=${3:-} end i=0 okc=0
  end=$(( $(date +%s) + WATCH_LIMIT ))
  while [ "$(date +%s)" -lt "$end" ]; do
    sample $(( (i + 1) % 2 ))
    echo "$(date -u +%T) $(state_line)" >>"$file"
    [ -n "$extra" ] && [ $((i % 2)) = 1 ] && echo "$(date -u +%T) $($extra)" >>"$file"
    if [ $((i % 6)) = 0 ]; then tail -1 "$file" | cut -c1-330; fi
    if eval "$test"; then okc=$((okc + 1)); else okc=0; fi
    [ "$okc" -ge 2 ] && return 0
    i=$((i + 1))
    sleep 5
  done
  return 1
}

# The workflows of Temporal that started after a time: a time line for each (read only).
workflows_since() { # <iso time> <folder>
  local since=$1 d=$2 wid
  mkdir -p "$d"
  temporal workflow list --query "StartTime > \"$since\"" --limit 100 2>&1 | tee "$d/temporal-workflows.txt" | head -40
  awk 'NR>1 {print $2}' "$d/temporal-workflows.txt" | grep -E '^[A-Za-z]' | sort -u >"$d/.workflow-ids.txt" || true
  while read -r wid; do [ -n "$wid" ] && LOG_DIR="$d" workflow_timeline "$wid"; done <"$d/.workflow-ids.txt"
  for wid in $(cat "$d/.workflow-ids.txt"); do
    echo "--- $wid"
    grep -v -E 'GetNodePoolForNode|GetClusterForNode|UpdateNodeConditions|GetNodeProvisioningContext|UpdateClusterConditions' "$d/workflow-$(printf '%s' "$wid" | tr -c 'A-Za-z0-9._-' '_').txt" 2>/dev/null | sed -E 's/^[0-9-]+T([0-9:]+\.[0-9]{3})[0-9]*Z/\1/; s/\(scheduled [0-9-]+T([0-9:]+\.[0-9]{3})[0-9]*Z\)/(scheduled \1)/' | cut -c1-140
  done
}
provider_log_since() { k -n "$PROVIDER_NS" logs deployment/podvm-controller-manager --since-time="$1" 2>/dev/null | jq -r 'select(.msg) | "\(.time[11:23]) \(.level) \(.msg) \(.PodVMMachine.name // "") \(.kind // "") \(.name // "") \(.address // "") \(.err // .error // "")"' 2>/dev/null; }

# The checks after a step: NVKE, the nodes and etcd of the new cluster, the placement, pod traffic.
cmd_after() {
  local label=${1:?label} want out fail=0 h members healthy ready
  out="$LOG_DIR/after-$label.txt"
  write_podmap
  want=${#REPLICAS[@]}
  {
    say "after $label at $(date -u +%FT%TZ): $want good nodes in NVKE"
    cat "$PODMAP"
    h=${REPLICAS[0]}
    say "NVKE"
    api get "/api/clusters/$(cluster_id)" | api_body | jq -c '{name, provisioned: .conditions.provisioned.status, deleting: .conditions.deleting.status, upgrading: .conditions.controlPlaneUpgrading.status, recycling: .conditions.cpNodesRecycling, enableCPNodeRecycling}'
    jq -c '.' "$LOG_DIR/.cp.json" | cut -c1-900
    [ "$(all_nodes)" = "$want" ] || { echo "FAIL NVKE has $(all_nodes) nodes, $want are good"; fail=1; }
    say "nodes and etcd of the new cluster"
    ik "$h" get nodes -o wide | tee "$LOG_DIR/.nodes" || true
    ready=$(grep -c -E ' Ready +control-plane ' "$LOG_DIR/.nodes" || true)
    [ "$ready" = "$want" ] && echo "ok   $ready Ready control plane nodes" || { echo "FAIL $ready Ready control plane nodes, rule $want"; fail=1; }
    [ "$(grep -c -E ' (NotReady|Unknown) ' "$LOG_DIR/.nodes" || true)" = 0 ] || { echo "FAIL a node is not Ready"; fail=1; }
    etcdctl "$h" member list -w simple | tee "$LOG_DIR/.members" || true
    members=$(grep -c ', started, ' "$LOG_DIR/.members" || true)
    etcdctl "$h" endpoint health --cluster 2>&1 | tee "$LOG_DIR/.health" || true
    healthy=$(grep -c 'is healthy' "$LOG_DIR/.health" || true)
    [ "$members" = "$want" ] && [ "$healthy" = "$want" ] && echo "ok   $members started etcd members, $healthy healthy" || { echo "FAIL etcd: $members started members, $healthy healthy, rule $want"; fail=1; }
    [ "$(grep -c . "$LOG_DIR/.members")" = "$want" ] || { echo "FAIL the etcd member list has $(grep -c . "$LOG_DIR/.members") lines"; fail=1; }
    say "OVN and DNS pods of the new cluster"
    ik "$h" get pods -A --no-headers -o wide | awk '$2 ~ /ovnkube|node-local-dns|coredns/ {print $1, $2, $3, $4, $8}' | column -t
    say "placement (S7)"
    placement_table | tee "$LOG_DIR/placement-$label.txt"
    say "the pods of the provider: image, probes, grace period"
    k -n "$NS" get pods -o json | jq -r '.items[] | "\(.metadata.name): image \(.spec.containers[0].image | sub(".*:"; "")), grace \(.spec.terminationGracePeriodSeconds), readiness timeout \(.spec.containers[0].readinessProbe.timeoutSeconds) s failures \(.spec.containers[0].readinessProbe.failureThreshold), restarts \(.status.containerStatuses[0].restartCount), Ready since \([.status.conditions[] | select(.type=="Ready") | .lastTransitionTime] | join(""))"'
    [ "$fail" = 0 ] && echo "RESULT after $label: PASS" || echo "RESULT after $label: FAIL"
  } 2>&1 | tee "$out"
  # Pod traffic with new test pods on the nodes of now.
  ik "${REPLICAS[0]}" -n default delete pod -l p1-node --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1 || true
  ik "${REPLICAS[0]}" -n default delete service -l p1-node --ignore-not-found >/dev/null 2>&1 || true
  node_names
  # shellcheck disable=SC1091
  . "$D/measure.sh"
  cmd_traffic "$label" >/dev/null 2>&1 || true
  {
    say "pod traffic ($label): lines of the matrix that pass (ping 3 of 3, pod tcp 200, service 200), of $((want * want)); between different nodes $(grep -E '^[a-f] -> [a-f]:' "$LOG_DIR/traffic-$label.txt" | awk '$1 != substr($3, 1, 1)' | grep -c -E '3 of 3 answers.*http 200.*http 200' || true) of $((want * (want - 1)))"
    grep -E '^[a-f] -> [a-f]:' "$LOG_DIR/traffic-$label.txt" | grep -c -E '3 of 3 answers.*http 200.*http 200' || true
    grep -E '^[a-f] -> [a-f]:' "$LOG_DIR/traffic-$label.txt" | grep -v -E '3 of 3 answers.*http 200.*http 200' | cut -c1-200 || true
    echo "name lookup: $(grep -c -E '^node [a-f]: .*dns \[[0-9.]+ +kubernetes' "$LOG_DIR/traffic-$label.txt" || true) of $want, API Service: $(grep -c -E '^node [a-f]: api \[http 200' "$LOG_DIR/traffic-$label.txt" || true) of $want"
  } 2>&1 | tee -a "$out"
  grep -q "RESULT after $label: PASS" "$out"
}

# The literal test of S6a: a DELETE while only three nodes are joined.
cmd_refuse_delete() {
  local r x id out="$LOG_DIR/refuse-delete.txt"
  write_podmap
  r=$(who "${1:-other}"); x=$(pn "$r"); id=$(node_id "$x")
  {
    say "DELETE /api/nodes/$id ($x, host $r) with $(good_nodes) joined nodes, at $(date -u +%FT%TZ)"
    api delete "/api/nodes/$id" 2>&1 | tee "$LOG_DIR/refuse-delete-response.txt"
    sleep "$POLL"
    sample 1
    echo "after 10 s: $(state_line)"
  } 2>&1 | tee "$out"
}

cmd_scale() {
  local n=${1:?count} label=${2:?label} out since before
  out="$LOG_DIR/scale-$label.txt"
  {
    say "scale $label: desiredCount $n, at $(date -u +%FT%TZ)"
    WAIT=1 "$W/p2-replace/disk.sh" "$(basename "$LOG_DIR") scale $label"
    sample 1
    before=$(jqs '[$i[0].items[].metadata.name] | join(" ")')
    echo "before: $(state_line)"
    placement_table
    since=$(date -u +%FT%TZ)
    printf '{"controlPlaneConfig": {"desiredCount": %s}}\n' "$n" >"$LOG_DIR/scale-$label-body.json"
    stamp "scale-$label-patch"
    api patch "/api/clusters/$(cluster_id)" "$LOG_DIR/scale-$label-body.json" 2>&1 | tail -1 | tee "$LOG_DIR/scale-$label-response.txt"
    grep -q '^HTTP 20[0-9]$' "$LOG_DIR/scale-$label-response.txt" || { api patch "/api/clusters/$(cluster_id)" "$LOG_DIR/scale-$label-body.json" 2>&1 | head -5; echo "RESULT scale $label: the API did not accept the PATCH"; exit 1; }
    if watch_until "$LOG_DIR/scale-$label-timeline.txt" "[ \"\$(all_nodes)\" = $n ] && [ \"\$(good_nodes)\" = $n ] && [ \"\$(ready_pods)\" = $n ] && [ \"\$(jqs '\$m[0].items | length')\" = $n ]"; then
      stamp "scale-$label-done"
      echo "the cluster has $n good nodes $(between "scale-$label-patch" "scale-$label-done") s after the PATCH"
    else
      echo "FAIL not $n good nodes after $WATCH_LIMIT s"
    fi
    echo "after: $(state_line)"
    echo "Machines before: $before"
    echo "Machines now:    $(jqs '[$i[0].items[].metadata.name] | join(" ")')"
    say "the provider log"
    provider_log_since "$since" | grep -v 'Waiting for' | head -30
    say "workflows since the PATCH"
    workflows_since "$since" "$LOG_DIR/scale-$label-record"
    say "events of the new pods (scheduling)"
    k -n "$NS" get events --sort-by=.lastTimestamp -o custom-columns=TIME:.lastTimestamp,OBJ:.involvedObject.name,REASON:.reason,MESSAGE:.message 2>/dev/null | grep -E 'FailedScheduling|Scheduled' | tail -6 | cut -c1-220
    say "placement"
    placement_table
  } 2>&1 | tee "$out"
}

# S6a: DELETE of one joined control plane node through the NVKE API. NVKE must tear it down and make a new Machine.
cmd_delete_node() {
  local r x id o out since before n fail=0 new newid label=${2:?label}
  write_podmap
  r=$(who "${1:?who}"); x=$(pn "$r"); o=$(observer "$r")
  out="$LOG_DIR/delete-node-$label.txt"
  {
    say "node replace $label at $(date -u +%FT%TZ): node $x (host $r, address ${IPS[$r]}, host node ${HOST_NODES[$r]}). First node of the cluster: $(pn "$(init_host)" 2>/dev/null || true). Observer: $(pn "$o")"
    WAIT=1 "$W/p2-replace/disk.sh" "$(basename "$LOG_DIR") delete-node $label"
    sample 1
    id=$(node_id "$x")
    n=$(all_nodes)
    before=$(jqs '[$i[0].items[].metadata.name] | join(" ")')
    echo "before: $(state_line)"
    placement_table
    etcdctl "$o" member list -w simple || true
    k -n "$NS" get pvc "$x-var" "$x-etcd" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.volumeName}{"\n"}{end}'
    cmd_probe_start "delete-$label" $((WATCH_LIMIT + 300))
    sleep 5
    since=$(date -u +%FT%TZ)
    stamp "delete-$label-request"
    say "DELETE /api/nodes/$id at $(date -u +%T)"
    api delete "/api/nodes/$id" 2>&1 | tee "$LOG_DIR/delete-node-$label-response.txt" | tail -3
    if ! grep -q '^HTTP 20[0-9]$' "$LOG_DIR/delete-node-$label-response.txt"; then
      cmd_probe_stop "delete-$label" >/dev/null
      echo "RESULT delete-node $label: NVKE did not accept the DELETE"
      exit 2
    fi
    # The end: the node is gone from NVKE, its Machine, PodVMMachine and pod are gone, and the cluster has n good nodes and n ready pods again.
    if watch_until "$LOG_DIR/delete-node-$label-timeline.txt" "[ -z \"\$(node_id $x)\" ] && [ \"\$(jqs --arg x $x '[\$i[0].items[], \$m[0].items[], \$p[0].items[] | select(.metadata.name==\$x)] | length')\" = 0 ] && [ \"\$(all_nodes)\" = $n ] && [ \"\$(good_nodes)\" = $n ] && [ \"\$(ready_pods)\" = $n ]"; then
      stamp "delete-$label-done"
      echo "the cluster has $n good nodes again $(between "delete-$label-request" "delete-$label-done") s after the DELETE"
    else
      echo "FAIL the end state did not come in $WATCH_LIMIT s"; fail=1
    fi
    cmd_probe_stop "delete-$label"
    echo "after: $(state_line)"
    new=$(jqs --arg b "$before" '[$i[0].items[].metadata.name | select(. as $x | ($b | split(" ")) | index($x) | not)] | join(" ")')
    echo "Machines before: $before"
    echo "new Machine: ${new:-none}"
    say "what is left of $x"
    echo "pod [$(k -n "$NS" get pod "$x" -o name 2>/dev/null)] claims [$(k -n "$NS" get pvc "$x-var" "$x-etcd" -o name 2>/dev/null | tr '\n' ' ')] Secret copy [$(k -n "$NS" get secret "$x-bootstrap" -o name 2>/dev/null)] PodVMMachine [$(k -n "$CAPI_NS" get podvmmachine "$x" -o name 2>/dev/null)] Machine [$(k -n "$CAPI_NS" get machine.cluster.x-k8s.io "$x" -o name 2>/dev/null)] bootstrap Secret of NVKE [$(k -n "$CAPI_NS" get secret "$x-bootstrap-data" -o name 2>/dev/null)] SPIRE entry [$(k get clusterstaticentry "host-$id" -o name 2>/dev/null)]"
    [ -z "$(k -n "$NS" get pod,pvc,secret -o name 2>/dev/null | grep -F "$x")" ] && echo "ok   no pod, claim or Secret copy of $x" || { echo "FAIL objects of $x are left in $NS"; fail=1; }
    say "the new Machine"
    for m in $new; do
      k -n "$CAPI_NS" get podvmmachine "$m" -o json | jq -r '"PodVMMachine \(.metadata.name): created \(.metadata.creationTimestamp), address \(.status.address) \(.status.hardwareAddress), providerID \(.spec.providerID), Ready \([.status.conditions[]? | select(.type=="Ready") | .status + " since " + .lastTransitionTime] | join(""))"'
      k -n "$NS" get pod "$m" -o json | jq -r '"pod: created \(.metadata.creationTimestamp), scheduled \([.status.conditions[] | select(.type=="PodScheduled") | .lastTransitionTime] | join("")) on \(.spec.nodeName), container running \(.status.containerStatuses[0].state.running.startedAt), Ready \([.status.conditions[] | select(.type=="Ready") | .lastTransitionTime] | join("")), image \(.spec.containers[0].image | sub(".*:"; ""))"'
      k -n "$NS" get pvc "$m-var" "$m-etcd" -o jsonpath='{range .items[*]}{"claim "}{.metadata.name}{" volume "}{.spec.volumeName}{" created "}{.metadata.creationTimestamp}{"\n"}{end}'
      k -n "$NS" get events --field-selector "involvedObject.name=$m" --sort-by=.lastTimestamp -o custom-columns=TIME:.lastTimestamp,REASON:.reason,MESSAGE:.message 2>/dev/null | grep -E 'FailedScheduling|Scheduled|Started' | cut -c1-230
      k -n "$NS" logs "$m" 2>/dev/null | grep -a 'PODVM:' | tr -d '\r' | grep -E 'no filesystem|first use|state is ready' | cut -c1-150
      k -n "$NS" exec "$m" -- sh -c 'journalctl --no-pager -o short-precise -u podvm-bootstrap -u podvm-bootstrap-final | grep RESULT | cut -c1-200' 2>&1 || true
    done
    echo "address of the deleted node: ${IPS[$r]}. Address of the new node: $(for m in $new; do k -n "$CAPI_NS" get podvmmachine "$m" -o jsonpath='{.status.address}'; done)"
    say "the provider log since the DELETE"
    provider_log_since "$since" | grep -v 'Waiting for the objects' | head -40
    echo "error lines of the provider: $(provider_log_since "$since" | grep -c ' ERROR ' || true), lines Waiting for the objects: $(provider_log_since "$since" | grep -c 'Waiting for the objects' || true)"
    say "workflows since the DELETE"
    workflows_since "$since" "$LOG_DIR/delete-node-$label-record"
    say "the storage loop during the test"
    awk -v s="$(date -u -d "$since" +%T)" '$1 >= s' "$W/logs/p2s6/storage-loop.out" 2>/dev/null | tail -8
    grep -q 'failed: 0$' "$LOG_DIR/probe-delete-$label-summary.txt" && echo "ok   the shared address answered each call" || echo "note the shared address has failed calls"
    [ "$fail" = 0 ] && echo "RESULT delete-node $label: PASS" || echo "RESULT delete-node $label: FAIL"
  } 2>&1 | tee "$out"
}

# S6b: the rollout. PATCH the control plane machine template to the image p3.
rollout_line() { jq -c '{status: (.status // .controlPlaneStatus // null)} | .status | {desired: (.desiredCount // null), rollout: (.rollout // null), conditions: ((.conditions // {}) | to_entries | map(select(.value.status=="True") | .key))}' "$LOG_DIR/.cp.json" 2>/dev/null | cut -c1-400; }
cmd_rollout() {
  local label=${1:-p3} out since before fail=0
  out="$LOG_DIR/rollout-$label.txt"
  write_podmap
  {
    say "rollout $label at $(date -u +%FT%TZ): machine template image ${IMG_P3##*:}"
    WAIT=1 "$W/p2-replace/disk.sh" "$(basename "$LOG_DIR") rollout $label"
    sample 1
    before=$(jqs '[$i[0].items[].metadata.name] | join(" ")')
    echo "before: $(state_line)"
    placement_table
    jq -c . "$LOG_DIR/.cp.json" | cut -c1-1200
    jq -n --argjson t "$(machine_template "$IMG_P3")" '{controlPlaneConfig: {infra: {machineTemplate: $t}}}' >"$LOG_DIR/rollout-$label-body.json"
    cmd_probe_start "rollout-$label" $((WATCH_LIMIT + 300))
    sleep 5
    since=$(date -u +%FT%TZ)
    stamp "rollout-$label-patch"
    say "PATCH /api/clusters/$(cluster_id) at $(date -u +%T)"
    api patch "/api/clusters/$(cluster_id)" "$LOG_DIR/rollout-$label-body.json" >"$LOG_DIR/rollout-$label-response.txt" 2>&1 || true
    tail -1 "$LOG_DIR/rollout-$label-response.txt"
    if ! grep -q '^HTTP 20[0-9]$' "$LOG_DIR/rollout-$label-response.txt"; then
      cat "$LOG_DIR/rollout-$label-response.txt" | cut -c1-600
      cmd_probe_stop "rollout-$label" >/dev/null
      echo "RESULT rollout $label: NVKE did not accept the PATCH"
      exit 2
    fi
    # The end: three good nodes, three ready pods, each pod with the new image, no old Machine.
    if watch_until "$LOG_DIR/rollout-$label-timeline.txt" "[ \"\$(all_nodes)\" = 3 ] && [ \"\$(good_nodes)\" = 3 ] && [ \"\$(ready_pods)\" = 3 ] && [ \"\$(jqs '\$m[0].items | length')\" = 3 ] && [ \"\$(jqs --arg img $IMG_P3 '[\$p[0].items[] | select(.spec.containers[0].image==\$img)] | length')\" = 3 ] && [ \"\$(jqs '\$p[0].items | length')\" = 3 ]" rollout_line; then
      stamp "rollout-$label-done"
      echo "three good nodes with the new image $(between "rollout-$label-patch" "rollout-$label-done") s after the PATCH"
    else
      echo "FAIL the rollout did not end in $WATCH_LIMIT s"; fail=1
    fi
    sleep 20
    sample 1
    cmd_probe_stop "rollout-$label"
    echo "after: $(state_line)"
    echo "Machines before: $before"
    echo "Machines now:    $(jqs '[$i[0].items[].metadata.name] | join(" ")')"
    say "what NVKE reports at the end"
    api get "/api/clusters/$(cluster_id)" | api_body | jq -c '{provisioned: .conditions.provisioned.status, upgrading: .conditions.controlPlaneUpgrading, recycling: .conditions.cpNodesRecycling}' | cut -c1-500
    jq -c . "$LOG_DIR/.cp.json" | cut -c1-1200
    say "the order: each new pod and each deleted pod (from the provider log)"
    provider_log_since "$since" | grep -E 'Gave an address|Made the pod|Node agent answers, reported|released its address' | cut -c1-160
    echo "error lines of the provider: $(provider_log_since "$since" | grep -c ' ERROR ' || true)"
    say "times when two pods of the cluster were on one host node (from the time line, one look each 5 s)"
    grep -v '^[0-9:]* {' "$LOG_DIR/rollout-$label-timeline.txt" | awk '{t=$1; s=$0; sub(/.*\| pods /, "", s); sub(/ \| claims.*/, "", s); n=split(s, a, " "); delete h; dbl=""; for (j=1; j<=n; j++) { split(a[j], b, /[@=]/); h[b[2]]++ } for (x in h) if (h[x] > 1) dbl=dbl " " x "=" h[x]; if (dbl != "") print t, dbl }' | awk '{k=$2 " " $3; if (k != last) {if (last != "") print first " to " prev ": " last; first=$1; last=k} prev=$1} END {if (last != "") print first " to " prev ": " last}'
    say "workflows since the PATCH"
    workflows_since "$since" "$LOG_DIR/rollout-$label-record"
    say "the storage loop during the rollout"
    awk -v s="$(date -u -d "$since" +%T)" '$1 >= s' "$W/logs/p2s6/storage-loop.out" 2>/dev/null | tail -14
    say "scheduling events of the pods"
    k -n "$NS" get events --sort-by=.lastTimestamp -o custom-columns=TIME:.lastTimestamp,OBJ:.involvedObject.name,REASON:.reason,MESSAGE:.message 2>/dev/null | grep -E 'FailedScheduling' | tail -8 | cut -c1-230
    grep -q 'failed: 0$' "$LOG_DIR/probe-rollout-$label-summary.txt" && echo "ok   the shared address answered each call" || echo "note the shared address has failed calls"
    [ "$fail" = 0 ] && echo "RESULT rollout $label: PASS" || echo "RESULT rollout $label: FAIL"
  } 2>&1 | tee "$out"
}

step=${1:-}
shift || true
case "$step" in
  base | post | wait-pods | wait | wait-nodes | check | endpoint | reach | probe-start | probe-stop | names | etcd | provider | times | flow | delete | placement | after | refuse-delete | scale | delete-node | rollout)
    "cmd_${step//-/_}" "$@" 2>&1 | tee -a "$LOG_DIR/run.log"
    exit "${PIPESTATUS[0]}"
    ;;
  record | evidence)
    { "cmd_$step" "$@"; provider_record "$@"; } 2>&1 | tee -a "$LOG_DIR/run.log"
    exit "${PIPESTATUS[0]}"
    ;;
  traffic | tunnels)
    node_names
    # shellcheck disable=SC1091
    . "$D/measure.sh"
    "cmd_$step" "$@" 2>&1 | tee -a "$LOG_DIR/run.log"
    exit "${PIPESTATUS[0]}"
    ;;
  poll) poll_line ;;
  state) sample 1; state_line ;;
  podmap) write_podmap; cat "$PODMAP" ;;
  *) sed -n '2,18p' "$0"; exit 1 ;;
esac
