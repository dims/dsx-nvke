#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Phase 2, step 8: one worker node, as a pod of the provider, joins a cluster whose three control
# plane nodes are pods of the provider. Each change of the cluster goes through the NVKE API. The
# two steps by hand are the ones the tests name: the label nvke.nvidia.com/reboot on the worker Node
# of the new cluster (W3) and the delete of the worker pod (W4). Nothing is written into a guest.
#
# It loads the steps of p2-agentfix/run.sh (and with it p2-replace, p2-provider, block D) and adds:
#   init                      copy the cluster ID of the cluster that is up, write the pod map
#   pool-post [name] [prefix] [count]   POST /api/nodePools with a PodVMMachineTemplate (image p5)
#   pool-wait <workers> <label>         wait until NVKE reports 3 + <workers> good nodes
#   pool-scale <count> <label>          PATCH /api/nodePools/<id> with desiredNodeCount
#   pool-delete <label>                 DELETE /api/nodePools/<id>
#   worker-delete <label>               DELETE /api/nodes/<id> of the worker
#   w1 <label>                the worker against the pass rules of W1, and the record of the worker flow
#   w2 <label>                pod traffic with the worker, the tunnels, calls of the API server to a pod on the worker
#   w3 <label>                the reboot request of NVKE for the worker
#   w4 <label>                a lost worker pod
#   cp-state <label>          the identity of the control plane (to compare before and after a step)
# Usage: LOG_DIR=<run folder> run.sh <step>
set -euo pipefail
. /root/kata-cp/bin/env.sh
export NS=${NS:-d}
export LOG_DIR=${LOG_DIR:-$W/logs/p2s8/w-1}
export IMG_CLUSTER=${IMG_CLUSTER:-docker.io/library/nvke-node-podvm:bcc4376f-p5}   # the image of the control plane now
export IMG_ROLLOUT=${IMG_ROLLOUT:-docker.io/library/nvke-node-podvm:bcc4376f-p5}
IMG_WORKER=${IMG_WORKER:-docker.io/library/nvke-node-podvm:bcc4376f-p5}
CLUSTER_RUN=${CLUSTER_RUN:-$W/logs/p2s6b/fix-1}       # the run folder of the cluster that is up

# shellcheck disable=SC1090
source <(sed '/^step=\${1:-}$/,$d' "$W/p2-agentfix/run.sh")
export DISK_LOG=$W/logs/p2s8/disk.txt
export STORAGE_LOOP_LOG=$W/logs/p2s8/storage-loop.out
export MEASURE_VIA=a

pool_id() { cat "$LOG_DIR/pool-id.txt"; }
worker_nodes() { jqs '[($n[0].nodes // [])[] | select(.controlPlane != true)] | length'; }

# --- the pod map with roles: control plane Machines first (a, b, c), then the workers ----------
CPS=()
WKS=()
load_roles() {
  local r role
  CPS=(); WKS=()
  [ -s "$LOG_DIR/roles.txt" ] || return 0
  while read -r r role; do
    if [ "$role" = cp ]; then CPS+=("$r"); else WKS+=("$r"); fi
  done <"$LOG_DIR/roles.txt"
}
write_podmap() {
  local i=0 role m ip hn
  sample 1
  : >"$PODMAP.new"
  : >"$LOG_DIR/roles.new"
  while read -r role m ip hn; do
    echo "${LETTERS[$i]} $m $ip $hn" >>"$PODMAP.new"
    echo "${LETTERS[$i]} $role" >>"$LOG_DIR/roles.new"
    i=$((i + 1))
  done < <(jqs '[$i[0].items[] | select(.status.address) | .metadata.name as $x
      | {name: $x, ip: .status.address,
         role: (if ([$m[0].items[] | select(.metadata.name==$x) | .metadata.labels["cluster.x-k8s.io/control-plane"] | select(. != null)] | length) > 0 then "cp" else "worker" end),
         hn: (([$p[0].items[] | select(.metadata.name==$x)][0].spec.nodeName) // "none")}]
    | sort_by([(if .role=="cp" then 0 else 1 end)] + (.ip | split(".") | map(tonumber)))
    | .[] | "\(.role) \(.name) \(.ip) \(.hn)"')
  mv "$PODMAP.new" "$PODMAP"
  mv "$LOG_DIR/roles.new" "$LOG_DIR/roles.txt"
  load_podmap
  load_roles
}
load_roles

cmd_init() {
  mkdir -p "$LOG_DIR"
  [ -s "$LOG_DIR/cluster-id.txt" ] || cp "$CLUSTER_RUN/cluster-id.txt" "$LOG_DIR/cluster-id.txt"
  [ -s "$LOG_DIR/post-time.txt" ] || date -u +%FT%T.%3NZ >"$LOG_DIR/post-time.txt"
  write_podmap
  say "cluster $(cluster_id), the pod map and the roles"
  paste -d' ' "$PODMAP" <(cut -d' ' -f2 "$LOG_DIR/roles.txt")
  state_line
  say "provider"
  k -n "$PROVIDER_NS" get deployment podvm-controller-manager -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
  k -n "$PROVIDER_NS" get lease -o custom-columns=NAME:.metadata.name,HOLDER:.spec.holderIdentity,ACQUIRED:.spec.acquireTime
  say "node pools of the cluster in NVKE before the test"
  api get "/api/nodePools?clusterID=$(cluster_id)" | api_body | jq -c '(.nodePools // .)[]? | {id, name, controlPlane, desiredNodeCount}' || true
  say "storage"
  "$P/storage.sh" status | tail -14
}

# --- the node pool through the NVKE API ----------------------------------------------------------
cmd_pool_post() {
  local name=${1:-workers} prefix=${2:-wk} count=${3:-1}
  jq -n --arg c "$(cluster_id)" --arg n "$name" --arg p "$prefix" --argjson k "$count" --argjson t "$(machine_template "$IMG_WORKER")" \
    '{clusterID: $c, name: $n, nodeNamePrefix: $p, desiredNodeCount: $k, systemReservedMemory: "512Mi", infra: {machineTemplate: $t}}' >"$LOG_DIR/pool-$name-request.json"
  WAIT=1 "$W/p2-replace/disk.sh" "$(basename "$LOG_DIR") node pool $name"
  sample 1
  echo "before: $(state_line)"
  say "POST /api/nodePools: pool $name, prefix $prefix, desiredNodeCount $count, image ${IMG_WORKER##*:}, at $(date -u +%T)"
  stamp "pool-$name-post"
  date -u +%FT%TZ >"$LOG_DIR/pool-$name-post-time.txt"
  api post /api/nodePools "$LOG_DIR/pool-$name-request.json" >"$LOG_DIR/pool-$name-response.txt" 2>&1 || true
  tail -1 "$LOG_DIR/pool-$name-response.txt"
  grep -q '^HTTP 20[012]$' "$LOG_DIR/pool-$name-response.txt" || { cut -c1-900 "$LOG_DIR/pool-$name-response.txt"; echo "RESULT pool-post $name: NVKE did not accept the request"; return 2; }
  api_body <"$LOG_DIR/pool-$name-response.txt" | jq -r '.id' >"$LOG_DIR/pool-id.txt"
  echo "$name" >"$LOG_DIR/pool-name.txt"
  api_body <"$LOG_DIR/pool-$name-response.txt" | jq -c '{id, name, controlPlane, desiredNodeCount, nodeNamePrefix, kubernetesVersion, systemReservedMemory, kubeReservedMemory}' || true
}

cmd_pool_wait() {
  local n=${1:?workers} label=${2:?label} total name since t0 m i ok=0
  total=$((3 + n))
  name=$(cat "$LOG_DIR/pool-name.txt")
  since=$(cat "$LOG_DIR/pool-$name-post-time.txt")
  if watch_until "$LOG_DIR/pool-$label-timeline.txt" "[ \"\$(all_nodes)\" = $total ] && [ \"\$(good_nodes)\" = $total ] && [ \"\$(ready_pods)\" = $total ] && [ \"\$(jqs '\$m[0].items | length')\" = $total ] && [ \"\$(worker_nodes)\" = $n ]"; then
    stamp "pool-$label-good"
    echo "NVKE reports $total good nodes ($n worker) $(between "pool-$name-post" "pool-$label-good") s after the request"
  else
    echo "FAIL not $total good nodes after $WATCH_LIMIT s: $(state_line)"
    return 1
  fi
  write_podmap
  # The Node of each worker in the new cluster: Ready.
  for i in $(seq 1 60); do
    ok=1
    for m in "${WKS[@]}"; do
      [ "$(ik a get node "$(pn "$m")" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] || ok=0
    done
    [ "$ok" = 1 ] && break
    sleep 5
  done
  if [ "$ok" = 1 ]; then stamp "pool-$label-ready"; echo "each worker Node is Ready $(between "pool-$name-post" "pool-$label-ready") s after the request"; else echo "FAIL a worker Node is not Ready"; return 1; fi
  echo "after: $(state_line)"
  say "workflows since the request"
  workflows_since "$since" "$LOG_DIR/pool-$label-record"
  say "the provider log since the request"
  provider_log_since "$since" | grep -v 'Waiting for' | head -30 || true
  echo "error lines of the provider: $(provider_log_since "$since" | grep -c ' ERROR ' || true)"
}

cmd_pool_scale() {
  local n=${1:?count} label=${2:?label} since total before fail=0 gone
  total=$((3 + n))
  {
    say "node pool $(cat "$LOG_DIR/pool-name.txt"): desiredNodeCount $n ($label) at $(date -u +%FT%TZ)"
    WAIT=1 "$W/p2-replace/disk.sh" "$(basename "$LOG_DIR") pool scale $label"
    write_podmap
    before=$(jqs '[$i[0].items[].metadata.name] | join(" ")')
    echo "before: $(state_line)"
    cmd_cp_state "$label-before" >/dev/null
    cmd_probe_start "pool-$label" $((WATCH_LIMIT + 300))
    sleep 5
    since=$(date -u +%FT%TZ)
    echo "$since" >"$LOG_DIR/pool-$(cat "$LOG_DIR/pool-name.txt")-post-time.txt"
    printf '{"desiredNodeCount": %s}\n' "$n" >"$LOG_DIR/pool-$label-body.json"
    stamp "pool-$label-patch"
    stamp "pool-$(cat "$LOG_DIR/pool-name.txt")-post"
    say "PATCH /api/nodePools/$(pool_id) at $(date -u +%T)"
    api patch "/api/nodePools/$(pool_id)" "$LOG_DIR/pool-$label-body.json" >"$LOG_DIR/pool-$label-response.txt" 2>&1 || true
    tail -1 "$LOG_DIR/pool-$label-response.txt"
    if ! grep -q '^HTTP 20[0-9]$' "$LOG_DIR/pool-$label-response.txt"; then
      cut -c1-900 "$LOG_DIR/pool-$label-response.txt"
      cmd_probe_stop "pool-$label" >/dev/null
      echo "RESULT pool-scale $label: NVKE did not accept the PATCH"
      exit 2
    fi
    if watch_until "$LOG_DIR/pool-$label-timeline.txt" "[ \"\$(all_nodes)\" = $total ] && [ \"\$(good_nodes)\" = $total ] && [ \"\$(ready_pods)\" = $total ] && [ \"\$(jqs '\$m[0].items | length')\" = $total ] && [ \"\$(jqs '\$i[0].items | length')\" = $total ] && [ \"\$(jqs '\$p[0].items | length')\" = $total ] && [ \"\$(worker_nodes)\" = $n ]"; then
      stamp "pool-$label-done"
      echo "the cluster has $total good nodes ($n worker) $(between "pool-$label-patch" "pool-$label-done") s after the PATCH"
    else
      echo "FAIL not $total good nodes after $WATCH_LIMIT s"; fail=1
    fi
    cmd_probe_stop "pool-$label"
    echo "after: $(state_line)"
    echo "Machines before: $before"
    echo "Machines now:    $(jqs '[$i[0].items[].metadata.name] | join(" ")')"
    gone=$(jqs --arg b "$before" '[($b | split(" "))[] | select(. as $x | [$i[0].items[].metadata.name] | index($x) | not)] | join(" ")')
    left_of "$gone" || fail=1
    say "the provider log since the PATCH"
    provider_log_since "$since" | grep -v 'Waiting for' | head -30 || true
    echo "error lines of the provider: $(provider_log_since "$since" | grep -c ' ERROR ' || true). Lines with the finalizer fault: $(k -n "$PROVIDER_NS" logs deployment/podvm-controller-manager --since-time="$since" 2>/dev/null | grep -c 'failed to remove the finalizer' || true)"
    say "workflows since the PATCH"
    workflows_since "$since" "$LOG_DIR/pool-$label-record"
    say "the control plane before and after"
    cmd_cp_state "$label-after" >/dev/null
    if diff "$LOG_DIR/cp-state-$label-before.txt" "$LOG_DIR/cp-state-$label-after.txt"; then echo "ok   the control plane has no change (pods, claims, etcd members, Nodes)"; else echo "FAIL the control plane changed"; fail=1; fi
    grep -q 'failed: 0$' "$LOG_DIR/probe-pool-$label-summary.txt" && echo "ok   the shared address answered each call with 200" || echo "note the shared address has calls that are not 200"
    say "storage"
    awk -v s="$(date -u -d "$since" +%T)" '$1 >= s' "$STORAGE_LOOP_LOG" 2>/dev/null | tail -6 || true
    placement_table
    [ "$fail" = 0 ] && echo "RESULT pool-scale $label: PASS" || echo "RESULT pool-scale $label: FAIL"
  } 2>&1 | tee "$LOG_DIR/pool-scale-$label.txt"
  grep -q "RESULT pool-scale $label: PASS" "$LOG_DIR/pool-scale-$label.txt"
}

# DELETE of the worker node through the NVKE API. NVKE does not tear a node down when the count of
# the pool goes down (controllers/nodeset/controller.go:148-158), so this is the way to get the
# pool to its count: with desiredNodeCount 0 NVKE makes no new node after the delete.
cmd_worker_delete() {
  local label=${1:?label} since before fail=0 w m id n total
  {
    write_podmap
    w=${WKS[0]}; m=$(pn "$w"); id=$(node_id "$m")
    n=$(api get "/api/nodePools/$(pool_id)" | api_body | jq -r '.desiredNodeCount')
    total=$((3 + n))
    say "DELETE of the worker node $m ($id) through the NVKE API ($label) at $(date -u +%FT%TZ). desiredNodeCount of its pool: $n"
    WAIT=1 "$W/p2-replace/disk.sh" "$(basename "$LOG_DIR") worker delete $label"
    before=$(jqs '[$i[0].items[].metadata.name] | join(" ")')
    echo "before: $(state_line)"
    cmd_cp_state "$label-before" >/dev/null
    say "the pods on the worker before"
    worker_pods "$m" || true
    cmd_probe_start "pool-$label" $((WATCH_LIMIT + 300))
    sleep 5
    since=$(date -u +%FT%TZ)
    stamp "pool-$label-delete"
    say "DELETE /api/nodes/$id at $(date -u +%T)"
    api delete "/api/nodes/$id" 2>&1 | tee "$LOG_DIR/pool-$label-response.txt" | tail -2
    if ! grep -q '^HTTP 20[0-9]$' "$LOG_DIR/pool-$label-response.txt"; then
      cmd_probe_stop "pool-$label" >/dev/null
      echo "RESULT worker-delete $label: NVKE did not accept the DELETE"
      exit 2
    fi
    if watch_until "$LOG_DIR/pool-$label-timeline.txt" "[ -z \"\$(node_id $m)\" ] && [ \"\$(all_nodes)\" = $total ] && [ \"\$(good_nodes)\" = $total ] && [ \"\$(ready_pods)\" = $total ] && [ \"\$(jqs '\$m[0].items | length')\" = $total ] && [ \"\$(jqs '\$i[0].items | length')\" = $total ] && [ \"\$(jqs '\$p[0].items | length')\" = $total ]"; then
      stamp "pool-$label-done"
      echo "the node $m is gone and the cluster has $total good nodes $(between "pool-$label-delete" "pool-$label-done") s after the DELETE"
    else
      echo "FAIL the end state did not come in $WATCH_LIMIT s"; fail=1
    fi
    # One more minute: NVKE must make no node above the count of the pool.
    sleep 60
    sample 1
    [ "$(all_nodes)" = "$total" ] && [ "$(jqs '$m[0].items | length')" = "$total" ] && echo "ok   60 s later: NVKE has $total nodes, no node above the count of the pool ($n)" || { echo "FAIL NVKE has $(all_nodes) nodes 60 s later"; fail=1; }
    cmd_probe_stop "pool-$label"
    echo "after: $(state_line)"
    echo "Machines before: $before"
    echo "Machines now:    $(jqs '[$i[0].items[].metadata.name] | join(" ")')"
    left_of "$m" || fail=1
    say "the provider log since the DELETE"
    provider_log_since "$since" | grep -v 'Waiting for' | head -30 || true
    echo "error lines of the provider: $(provider_log_since "$since" | grep -c ' ERROR ' || true). Lines with the finalizer fault: $(k -n "$PROVIDER_NS" logs deployment/podvm-controller-manager --since-time="$since" 2>/dev/null | grep -c 'failed to remove the finalizer' || true)"
    say "workflows since the DELETE"
    workflows_since "$since" "$LOG_DIR/pool-$label-record"
    say "the control plane before and after"
    cmd_cp_state "$label-after" >/dev/null
    if diff "$LOG_DIR/cp-state-$label-before.txt" "$LOG_DIR/cp-state-$label-after.txt"; then echo "ok   the control plane has no change (pods, claims, etcd members, Nodes)"; else echo "FAIL the control plane changed"; fail=1; fi
    grep -q 'failed: 0$' "$LOG_DIR/probe-pool-$label-summary.txt" && echo "ok   the shared address answered each call with 200" || echo "note the shared address has calls that are not 200"
    echo "Nodes of the new cluster: $(ik a get nodes --no-headers | awk '{print $1 "=" $2}' | tr '\n' ' ')"
    echo "pods of the deleted node in the new cluster: [$(ik a get pods -A -o wide --no-headers --field-selector "spec.nodeName=$m" 2>/dev/null | awk '{print $2 "=" $4}' | tr '\n' ' ')]"
    say "storage"
    awk -v s="$(date -u -d "$since" +%T)" '$1 >= s' "$STORAGE_LOOP_LOG" 2>/dev/null | tail -6 || true
    placement_table
    [ "$fail" = 0 ] && echo "RESULT worker-delete $label: PASS" || echo "RESULT worker-delete $label: FAIL"
  } 2>&1 | tee "$LOG_DIR/worker-delete-$label.txt"
  grep -q "RESULT worker-delete $label: PASS" "$LOG_DIR/worker-delete-$label.txt"
}

# What is left of the Machines in $1 (names): pod, claims, Secret copy, PodVMMachine, Machine.
left_of() {
  local x rc=0
  for x in $1; do
    echo "what is left of $x: pod [$(k -n "$NS" get pod "$x" -o name 2>/dev/null)] claims [$(k -n "$NS" get pvc "$x-var" "$x-etcd" -o name 2>/dev/null | tr '\n' ' ')] Secret copy [$(k -n "$NS" get secret "$x-bootstrap" -o name 2>/dev/null)] PodVMMachine [$(k -n "$CAPI_NS" get podvmmachine "$x" -o name 2>/dev/null)] Machine [$(k -n "$CAPI_NS" get machine.cluster.x-k8s.io "$x" -o name 2>/dev/null)] bootstrap Secret of NVKE [$(k -n "$CAPI_NS" get secret "$x-bootstrap-data" -o name 2>/dev/null)] Node in the new cluster [$(ik a get node "$x" -o name 2>/dev/null)]"
    if [ -z "$(k -n "$NS" get pod,pvc,secret -o name 2>/dev/null | grep -F "$x")" ] && [ -z "$(k -n "$CAPI_NS" get podvmmachine,machine.cluster.x-k8s.io -o name 2>/dev/null | grep -F "$x")" ]; then
      echo "ok   no pod, claim, Secret copy, PodVMMachine or Machine of $x"
    else
      echo "FAIL objects of $x are left"; rc=1
    fi
  done
  return "$rc"
}

cmd_pool_delete() {
  local label=${1:?label} since before fail=0 id name code="" total
  id=$(pool_id); name=$(cat "$LOG_DIR/pool-name.txt")
  {
    say "DELETE of the node pool $name ($id) ($label) at $(date -u +%FT%TZ)"
    WAIT=1 "$W/p2-replace/disk.sh" "$(basename "$LOG_DIR") pool delete $label"
    write_podmap
    # The nodes of this pool, from the NVKE API. The other nodes must stay.
    before=$(jqs --arg pid "$id" '[($n[0].nodes // [])[] | select(.nodePoolID==$pid) | .name] | join(" ")')
    total=$(( $(all_nodes) - $(wc -w <<<"$before") ))
    echo "before: $(state_line)"
    echo "nodes of the pool before: [$before]. Nodes that must stay: $total"
    echo "machine templates before: $(k -n "$CAPI_NS" get podvmmachinetemplates -o name | tr '\n' ' ')"
    cmd_cp_state "$label-before" >/dev/null
    cmd_probe_start "pool-$label" $((WATCH_LIMIT + 300))
    sleep 5
    since=$(date -u +%FT%TZ)
    stamp "pool-$label-delete"
    say "DELETE /api/nodePools/$id at $(date -u +%T)"
    api delete "/api/nodePools/$id" 2>&1 | tee "$LOG_DIR/pool-$label-response.txt" | tail -2
    if ! grep -q '^HTTP 20[0-9]$' "$LOG_DIR/pool-$label-response.txt"; then
      cmd_probe_stop "pool-$label" >/dev/null
      echo "RESULT pool-delete $label: NVKE did not accept the DELETE"
      exit 2
    fi
    if watch_until "$LOG_DIR/pool-$label-timeline.txt" "[ \"\$(all_nodes)\" = $total ] && [ \"\$(good_nodes)\" = $total ] && [ \"\$(ready_pods)\" = $total ] && [ \"\$(jqs '\$m[0].items | length')\" = $total ] && [ \"\$(jqs '\$i[0].items | length')\" = $total ] && [ \"\$(jqs '\$p[0].items | length')\" = $total ]"; then
      stamp "pool-$label-nodes-gone"
      echo "the cluster has $total good nodes and no node of the pool $(between "pool-$label-delete" "pool-$label-nodes-gone") s after the DELETE"
    else
      echo "FAIL the nodes of the pool are not gone after $WATCH_LIMIT s"; fail=1
    fi
    # The row of the pool: one look each 10 s, for at most 5 minutes.
    for _ in $(seq 1 30); do
      code=$(api get "/api/nodePools/$id" 2>/dev/null | tail -1)
      [ "$code" = "HTTP 404" ] && break
      sleep 10
    done
    if [ "$code" = "HTTP 404" ]; then stamp "pool-$label-row-gone"; echo "ok   GET of the pool gives 404, $(between "pool-$label-delete" "pool-$label-row-gone") s after the DELETE"; else echo "FAIL the pool row exists: $code"; fail=1; fi
    cmd_probe_stop "pool-$label"
    echo "after: $(state_line)"
    left_of "$before" || fail=1
    echo "machine templates after: $(k -n "$CAPI_NS" get podvmmachinetemplates -o name | tr '\n' ' ')"
    echo "node pools of the cluster in NVKE: $(api get "/api/nodePools?clusterID=$(cluster_id)" | api_body | jq -c '[(.nodePools // .)[]? | {name, controlPlane, desiredNodeCount}]')"
    say "the provider log since the DELETE"
    provider_log_since "$since" | grep -v 'Waiting for' | head -30 || true
    echo "error lines of the provider: $(provider_log_since "$since" | grep -c ' ERROR ' || true). Lines with the finalizer fault: $(k -n "$PROVIDER_NS" logs deployment/podvm-controller-manager --since-time="$since" 2>/dev/null | grep -c 'failed to remove the finalizer' || true)"
    say "workflows since the DELETE"
    workflows_since "$since" "$LOG_DIR/pool-$label-record"
    say "the control plane before and after"
    cmd_cp_state "$label-after" >/dev/null
    if diff "$LOG_DIR/cp-state-$label-before.txt" "$LOG_DIR/cp-state-$label-after.txt"; then echo "ok   the control plane has no change (pods, claims, etcd members, Nodes)"; else echo "FAIL the control plane changed"; fail=1; fi
    grep -q 'failed: 0$' "$LOG_DIR/probe-pool-$label-summary.txt" && echo "ok   the shared address answered each call with 200" || echo "note the shared address has calls that are not 200"
    say "storage"
    awk -v s="$(date -u -d "$since" +%T)" '$1 >= s' "$STORAGE_LOOP_LOG" 2>/dev/null | tail -6 || true
    placement_table
    [ "$fail" = 0 ] && echo "RESULT pool-delete $label: PASS" || echo "RESULT pool-delete $label: FAIL"
  } 2>&1 | tee "$LOG_DIR/pool-delete-$label.txt"
  grep -q "RESULT pool-delete $label: PASS" "$LOG_DIR/pool-delete-$label.txt"
}

# The identity of the control plane: nothing here may change when a worker comes or goes.
cmd_cp_state() {
  local label=${1:-now} r m
  {
    for r in "${CPS[@]}"; do
      m=$(pn "$r")
      k -n "$NS" get pod "$m" -o json | jq -r '"pod \(.metadata.name) uid \(.metadata.uid) node \(.spec.nodeName) restarts \(.status.containerStatuses[0].restartCount) ready \(.status.containerStatuses[0].ready) image \(.spec.containers[0].image | sub(".*:"; ""))"'
      k -n "$NS" get pvc "$m-var" "$m-etcd" -o json | jq -r '.items[] | "claim \(.metadata.name) uid \(.metadata.uid) volume \(.spec.volumeName)"'
      k -n "$CAPI_NS" get podvmmachine "$m" -o json | jq -r '"machine \(.metadata.name) address \(.status.address) providerID \(.spec.providerID)"'
      echo "node $m ready $(ik a get node "$m" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}') boot $(ik a get node "$m" -o jsonpath='{.status.nodeInfo.bootID}')"
    done
    etcdctl a member list -w simple | sort || true
    echo "healthy etcd endpoints: $(etcdctl a endpoint health --cluster 2>&1 | grep -c 'is healthy' || true)"
    echo "endpoints of cp-api: $(k -n "$NS" get endpointslices -l kubernetes.io/service-name=cp-api -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{"="}{.conditions.ready}{" "}{end}' | tr ' ' '\n' | sort | tr '\n' ' ')"
  } 2>&1 | tee "$LOG_DIR/cp-state-$label.txt"
}

# --- W1 ----------------------------------------------------------------------------------------
cmd_w1() {
  local label=${1:-w1} out fail=0 w m id c cm x f
  out="$LOG_DIR/w1-$label.txt"
  write_podmap
  {
    say "W1 ($label) at $(date -u +%FT%TZ): one worker of the provider in the cluster"
    paste -d' ' "$PODMAP" <(cut -d' ' -f2 "$LOG_DIR/roles.txt")
    if [ "${#WKS[@]}" -lt 1 ]; then echo "FAIL no worker Machine with an address"; echo "RESULT w1 $label: FAIL"; exit 1; fi
    w=${WKS[${WORKER_INDEX:-0}]}; m=$(pn "$w"); c=${CPS[0]}; cm=$(pn "$c")
    id=$(node_id "$m")
    say "1. NVKE: the node pool and its node"
    api get "/api/nodePools/$(api get "/api/nodes/$id" | api_body | jq -r '.nodePoolID')" | api_body | jq -c '{id, name, controlPlane, desiredNodeCount, nodeNamePrefix, kubernetesVersion, systemReservedMemory, kubeReservedMemory, maxSurge, recycleBudget, conditions: ((.conditions // {}) | to_entries | map(select(.value.status=="True") | "\(.key)[\(.value.message // "")]"))}' | cut -c1-900
    api get "/api/nodes/$id" | api_body | jq -c '{name, id, ip, controlPlane, nodePoolID, agentVersion, conditions: ((.conditions // {}) | to_entries | map(select(.value.status=="True") | "\(.key)[\(.value.message // "")]"))}' | cut -c1-900
    [ "$(api get "/api/nodes/$id" | api_body | jq -r '.controlPlane')" != true ] && echo "ok   NVKE has the node as a worker" || { echo "FAIL NVKE has the node as a control plane node"; fail=1; }
    [ "$(good_nodes)" = "$(all_nodes)" ] && echo "ok   NVKE reports each of its $(all_nodes) nodes as good" || { echo "FAIL not each node is good in NVKE"; fail=1; }

    say "2. Cluster API objects of the worker (and the same for one control plane Machine)"
    for x in "$m" "$cm"; do
      k -n "$CAPI_NS" get machine.cluster.x-k8s.io "$x" -o json | jq -c '{machine: .metadata.name, labels: .metadata.labels, annotations: ((.metadata.annotations // {}) | keys), owner: [.metadata.ownerReferences[]? | .kind], failureDomain: (.spec.failureDomain // null), providerID: .spec.providerID, bootstrapSecret: .spec.bootstrap.dataSecretName, infrastructureRef: .spec.infrastructureRef, phase: .status.phase}' | cut -c1-1000
    done
    k -n "$CAPI_NS" get podvmmachine "$m" -o json | jq -c '{spec: .spec, status: {address: .status.address, hardwareAddress: .status.hardwareAddress, pod: "\(.status.podNamespace)/\(.status.podName)", addresses: .status.addresses, provisioned: .status.initialization.provisioned, conditions: [.status.conditions[]? | "\(.type)=\(.status)"]}}' | cut -c1-1000
    echo "machine templates: $(k -n "$CAPI_NS" get podvmmachinetemplates -o json | jq -r '[.items[] | "\(.metadata.name) (image \(.spec.template.spec.image | sub(".*:"; "")), created \(.metadata.creationTimestamp))"] | join("; ")')"
    echo "other Cluster API objects: $(k -n "$CAPI_NS" get machinedeployments.cluster.x-k8s.io,machinesets.cluster.x-k8s.io,kubeadmconfigs.bootstrap.cluster.x-k8s.io,kubeadmcontrolplanes.controlplane.cluster.x-k8s.io -o name 2>&1 | tr '\n' ' ' | cut -c1-300)"
    echo "Secrets of the worker in $CAPI_NS: $(k -n "$CAPI_NS" get secrets -o name | grep -F "$m" | tr '\n' ' ')"
    echo "SPIRE entry: $(k get clusterstaticentry "host-$id" -o jsonpath='{.spec.spiffeID}' 2>&1 | mask | cut -c1-200)"

    say "3. the pod of the worker against the pod table of the provider"
    k -n "$NS" get pod "$m" -o json >"$LOG_DIR/.wpod.json"
    k -n "$NS" get pod "$cm" -o json >"$LOG_DIR/.cpod.json"
    for f in .wpod.json .cpod.json; do
      jq -c '{pod: .metadata.name, node: .spec.nodeName, labels: .metadata.labels, networks: .metadata.annotations["k8s.v1.cni.cncf.io/networks"], runtimeClass: .spec.runtimeClassName, grace: .spec.terminationGracePeriodSeconds, image: (.spec.containers[0].image | sub(".*:"; "")), resources: .spec.containers[0].resources.limits, env: [.spec.containers[0].env[] | "\(.name)=\(.value)"], volumeDevices: [.spec.containers[0].volumeDevices[] | "\(.name)=\(.devicePath)"], volumes: [.spec.volumes[] | "\(.name)=\(.persistentVolumeClaim.claimName // .secret.secretName)"], startupProbe: .spec.containers[0].startupProbe, readinessProbe: (.spec.containers[0].readinessProbe // null), token: .spec.automountServiceAccountToken, started: .status.containerStatuses[0].started, ready: .status.containerStatuses[0].ready, restarts: .status.containerStatuses[0].restartCount}' "$LOG_DIR/$f" | cut -c1-1500
    done
    pj() { jq -r "$1" "$LOG_DIR/.wpod.json"; }
    [ "$(pj '.metadata.labels | has("cluster.x-k8s.io/control-plane")')" = false ] && echo "ok   the worker pod has no control plane label" || { echo "FAIL the worker pod has the control plane label"; fail=1; }
    [ "$(pj '.metadata.labels["cluster.x-k8s.io/cluster-name"]')" = "$CLUSTER_NAME" ] && echo "ok   cluster name label" || { echo "FAIL cluster name label"; fail=1; }
    [ "$(pj '.spec.containers[0].readinessProbe // "none"')" = none ] && echo "ok   no readiness probe" || { echo "FAIL the worker pod has a readiness probe"; fail=1; }
    [ "$(pj '.spec.containers[0].startupProbe.tcpSocket.port')" = 15005 ] && echo "ok   startup probe: TCP 15005, each $(pj '.spec.containers[0].startupProbe.periodSeconds') s, $(pj '.spec.containers[0].startupProbe.failureThreshold') failures" || { echo "FAIL startup probe"; fail=1; }
    [ "$(pj '.spec.containers[0].image')" = "$IMG_WORKER" ] && echo "ok   image ${IMG_WORKER##*:}" || { echo "FAIL image $(pj '.spec.containers[0].image')"; fail=1; }
    [ "$(pj '[.spec.containers[0].volumeDevices[].devicePath] | sort | join(" ")')" = "/dev/podvm-etcd /dev/podvm-var" ] && echo "ok   two volume devices (var and etcd)" || { echo "FAIL volume devices"; fail=1; }
    [ "$(pj '.status.containerStatuses[0].ready')" = true ] && echo "ok   the pod is Ready (startup probe passed)" || { echo "FAIL the pod is not Ready"; fail=1; }
    echo "endpoints of the shared Service cp-api: $(k -n "$NS" get endpointslices -l kubernetes.io/service-name=cp-api -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}{"="}{.addresses[0]}{" "}{end}')"
    k -n "$NS" get endpointslices -l kubernetes.io/service-name=cp-api -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}{"\n"}{end}' | grep -q -x "$m" && { echo "FAIL the worker pod is behind the shared Service"; fail=1; } || echo "ok   the worker pod is not behind the shared Service"

    say "4. the Node of the worker in the new cluster (and one control plane Node)"
    ik a get nodes -o wide
    for x in "$m" "$cm"; do
      ik a get node "$x" -o json | jq -c '{node: .metadata.name, providerID: .spec.providerID, podCIDR: .spec.podCIDR, taints: (.spec.taints // []), labels: .metadata.labels, ready: ([.status.conditions[] | select(.type=="Ready") | "\(.status) since \(.lastTransitionTime)"] | join("")), bootID: .status.nodeInfo.bootID[0:8], kubelet: .status.nodeInfo.kubeletVersion, addresses: [.status.addresses[] | "\(.type)=\(.address)"], capacity: {cpu: .status.capacity.cpu, memory: .status.capacity.memory}, allocatable: {cpu: .status.allocatable.cpu, memory: .status.allocatable.memory}, created: .metadata.creationTimestamp}' | cut -c1-2200
    done
    nj() { ik a get node "$m" -o json | jq -r "$1"; }
    [ "$(nj '[.status.conditions[] | select(.type=="Ready") | .status] | join("")')" = True ] && echo "ok   the worker Node is Ready" || { echo "FAIL the worker Node is not Ready"; fail=1; }
    [ "$(nj '.spec.providerID')" = "podvm://$NS/$m" ] && echo "ok   provider ID podvm://$NS/$m" || { echo "FAIL provider ID $(nj '.spec.providerID')"; fail=1; }
    [ "$(nj '.metadata.labels | has("node-role.kubernetes.io/control-plane")')" = false ] && echo "ok   no control plane role label on the Node" || { echo "FAIL the Node has the control plane role label"; fail=1; }
    [ "$(nj '[.status.addresses[] | select(.type=="InternalIP") | .address] | join(" ")')" = "${IPS[$w]}" ] && echo "ok   InternalIP ${IPS[$w]} (the fixed address)" || { echo "FAIL InternalIP $(nj '[.status.addresses[] | select(.type=="InternalIP") | .address] | join(" ")')"; fail=1; }
    echo "certificate requests in the new cluster:"
    ik a get csr --sort-by=.metadata.creationTimestamp -o custom-columns=NAME:.metadata.name,CREATED:.metadata.creationTimestamp,SIGNER:.spec.signerName,REQUESTOR:.spec.username,CONDITION:.status.conditions[0].type,REASON:.status.conditions[0].reason 2>&1 | tail -6
    ik a get csr -o json | jq -r --arg n "system:node:$m" '[.items[] | select(.spec.username==$n and .spec.signerName=="kubernetes.io/kubelet-serving") | "\(.metadata.name) \(.status.conditions[0].type // "Pending") (\(.status.conditions[0].reason // "-"))"] | "kubelet serving certificate requests of the worker: \(join("; "))"' || true

    say "5. placement"
    placement_table

    say "6. what runs on the worker"
    ik a get pods -A -o wide --field-selector "spec.nodeName=$m" | cut -c1-200
    # The OVN pod needs some time after the Node is Ready (the image is unpacked at its first use). Wait for it, at most 3 minutes.
    for _ in $(seq 1 36); do
      [ "$(ik a -n ovn-kubernetes get pods -o wide --field-selector "spec.nodeName=$m" --no-headers 2>/dev/null | awk '$1 ~ /^ovnkube-node/ {print $2 "/" $3}')" = "5/5/Running" ] && break
      sleep 5
    done
    ik a -n ovn-kubernetes get pods -o json --field-selector "spec.nodeName=$m" | jq -r '.items[] | "\(.metadata.name): created \(.metadata.creationTimestamp), containers ready \([.status.containerStatuses[] | select(.ready)] | length)/\(.status.containerStatuses | length), Ready \([.status.conditions[] | select(.type=="Ready") | "\(.status) since \(.lastTransitionTime)"] | join(""))"' || true
    echo "the Node: created $(ik a get node "$m" -o jsonpath='{.metadata.creationTimestamp}'), Ready since $(ik a get node "$m" -o jsonpath='{.status.conditions[?(@.type=="Ready")].lastTransitionTime}')"
    [ "$(ik a -n ovn-kubernetes get pods -o wide --field-selector "spec.nodeName=$m" --no-headers | awk '$1 ~ /^ovnkube-node/ {print $2 "/" $3}')" = "5/5/Running" ] && echo "ok   the OVN pod on the worker is 5/5 Running" || { echo "FAIL the OVN pod on the worker is not 5/5 Running"; fail=1; }

    say "7. the worker guest (read only): units, mounts, files, the join"
    pod "$w" sh -c 'echo "systemd: $(systemctl is-system-running), failed units: $(systemctl --failed --no-legend --plain | awk "{print \$1}" | tr "\n" " ")"
      echo "mounts: $(findmnt -n -o TARGET,SOURCE,FSTYPE,SIZE,USED /var | tr -s " ") | $(findmnt -n -o TARGET,SOURCE,FSTYPE,SIZE,USED /var/lib/etcd | tr -s " ")"
      echo "/var/lib/etcd has: [$(ls -A /var/lib/etcd | tr "\n" " ")]"
      echo "/etc/kubernetes: [$(ls /etc/kubernetes | tr "\n" " ")] manifests: [$(ls /etc/kubernetes/manifests 2>/dev/null | tr "\n" " ")] pki: [$(ls /etc/kubernetes/pki 2>/dev/null | tr "\n" " ")]"
      echo "/tmp: [$(ls /tmp | tr "\n" " ")] /var/lib/nvke: [$(ls /var/lib/nvke 2>/dev/null | tr "\n" " ")]"
      echo "kubelet.conf server: $(awk "\$1==\"server:\" {print \$2}" /etc/kubernetes/kubelet.conf)"
      echo "agent: $(/usr/local/bin/nvke-agent --version 2>&1 | head -1), image marker [$(cat /usr/share/podvm/image-form 2>/dev/null)], active: nvke-agent=$(systemctl is-active nvke-agent) spire-agent=$(systemctl is-active spire-agent 2>/dev/null) kubelet=$(systemctl is-active kubelet) containerd=$(systemctl is-active containerd) openvswitch=$(systemctl is-active openvswitch-switch 2>/dev/null)"
      echo "containers: $(crictl ps -o yaml 2>/dev/null | awk "\$1==\"metadata:\" {m=1; next} m && \$1==\"name:\" {print \$2; m=0}" | sort | tr "\n" " ")"
      echo "kernel boot ID: $(cut -c1-8 /proc/sys/kernel/random/boot_id), uptime $(cut -d" " -f1 /proc/uptime) s, memory $(free -m | awk "/^Mem:/ {print \$2 \" MB total, \" \$7 \" MB available\"}")"
      echo "join config kinds and keys (no token): $(grep -E "^kind:|^controlPlane:|^  taints:|key:|effect:|node-labels|apiServerEndpoint|unsafeSkipCAVerification" /tmp/kubeadm-join-config.yaml 2>/dev/null | grep -v -i -E "certificatekey|token" | tr -s " " | tr "\n" ";" | cut -c1-600)"
      echo "the join command of the agent (redacted by the agent):"
      journalctl --no-pager -u nvke-agent | grep "issuing kubeadm join command" | sed -E "s/.*\"args\":(\[[^]]*\]).*/\1/" | cut -c1-400' 2>&1 | mask
    say "7b. the same lines of one control plane node, for the comparison"
    pod "$c" sh -c 'echo "mounts: $(findmnt -n -o TARGET,SOURCE,FSTYPE,SIZE,USED /var | tr -s " ") | $(findmnt -n -o TARGET,SOURCE,FSTYPE,SIZE,USED /var/lib/etcd | tr -s " ")"
      echo "/etc/kubernetes: [$(ls /etc/kubernetes | tr "\n" " ")] manifests: [$(ls /etc/kubernetes/manifests 2>/dev/null | tr "\n" " ")]"
      echo "join config kinds and keys (no token): $(grep -E "^kind:|^controlPlane:|^  taints:|key:|effect:|node-labels|apiServerEndpoint|unsafeSkipCAVerification" /tmp/kubeadm-join-config.yaml 2>/dev/null | grep -v -i -E "certificatekey|token" | tr -s " " | tr "\n" ";" | cut -c1-600)"
      journalctl --no-pager -u nvke-agent | grep "issuing kubeadm join command" | sed -E "s/.*\"args\":(\[[^]]*\]).*/\1/" | cut -c1-400' 2>&1 | mask
    say "8. the entry point and the bootstrap units of the worker"
    k -n "$NS" logs "$m" 2>/dev/null | grep -a 'PODVM:' | tr -d '\r' | grep -E 'start at|no filesystem|first use|volumes:|state is ready' | cut -c1-200 || true
    pod "$w" sh -c 'journalctl --no-pager -o short-precise -u podvm-bootstrap -u podvm-bootstrap-final | grep RESULT | cut -c1-220' 2>&1 || true
    [ "$fail" = 0 ] && echo "RESULT w1 $label: PASS" || echo "RESULT w1 $label: FAIL"
  } 2>&1 | tee "$out"
  grep -q "RESULT w1 $label: PASS" "$out"
}

# --- W2 ----------------------------------------------------------------------------------------
# Tunnel facts, read only (no probe table, no file in a guest).
tunnel_facts() {
  local r
  say "node annotations of OVN"
  ck get nodes -o json | jq -r '.items[] | .metadata.name as $n | .metadata.annotations | to_entries[] | select(.key | test("k8s.ovn.org/(node-encap-ips|node-primary-ifaddr|node-subnets|zone-name|node-chassis-id)")) | "\($n) \(.key) = \(.value)"'
  for r in "${REPLICAS[@]}"; do
    echo "--- node $r ($(pn "$r"), node address ${IPS[$r]}, pod IP of the provider pod $(pod_ip "$r"))"
    pod "$r" sh -c 'echo "ovn-encap-ip: $(ovs-vsctl --timeout=5 get Open_vSwitch . external_ids:ovn-encap-ip), ovn-encap-type: $(ovs-vsctl --timeout=5 get Open_vSwitch . external_ids:ovn-encap-type)"
      ovs-vsctl --timeout=5 --format=csv --no-headings --columns=name,ofport,options find interface type=geneve | sed "s/^/tunnel port: /"
      for p in $(ovs-vsctl --timeout=5 --bare --columns=name find interface type=geneve); do echo "counters of $p: $(ovs-vsctl --timeout=5 get interface "$p" statistics | grep -oE "(rx|tx)_packets=[0-9]+" | tr "\n" " ")"; done
      echo "tunnel flows in the datapath now (source and destination of the outer packet):"
      ovs-appctl --timeout=5 dpctl/dump-flows 2>/dev/null | grep -oE "tunnel\(tun_id=[^)]*\)|set\(tunnel\([^)]*\)\)" | grep -oE "src=[0-9.]+,dst=[0-9.]+|dst=[0-9.]+" | sort | uniq -c | sed "s/^/   /"' 2>&1 || true
  done
}

cmd_w2() {
  local label=${1:-w2} out fail=0 w wm c s d tp sb srv=() name tot good line src
  out="$LOG_DIR/w2-$label.txt"
  write_podmap
  w=${WKS[${WORKER_INDEX:-0}]}; wm=$(pn "$w")
  tp="p1-t-$w"
  # New test pods on the nodes of now.
  ik a -n default delete pod -l p1-node --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1 || true
  ik a -n default delete service -l p1-node --ignore-not-found >/dev/null 2>&1 || true
  { ik a -n default get service -o name 2>/dev/null | grep '/p1-t-' | while read -r s; do ik a -n default delete "$s" >/dev/null 2>&1 || true; done; } || true
  node_names
  # shellcheck disable=SC1091
  . "$D/measure.sh"
  cmd_traffic "$label" >/dev/null 2>&1 || true
  {
    say "W2 ($label) at $(date -u +%FT%TZ): traffic with the worker $wm (letter $w)"
    paste -d' ' "$PODMAP" <(cut -d' ' -f2 "$LOG_DIR/roles.txt")
    say "1. pod traffic: the matrix lines with the worker (source -> destination: ping, pod tcp, service)"
    grep -E "^[a-f] -> [a-f]:" "$LOG_DIR/traffic-$label.txt" | grep -E "^$w -> |-> $w:" | cut -c1-230 || true
    tot=$(grep -E "^[a-f] -> [a-f]:" "$LOG_DIR/traffic-$label.txt" | grep -c -E "^$w -> [^$w]|^[^$w] -> $w:" || true)
    good=$(grep -E "^[a-f] -> [a-f]:" "$LOG_DIR/traffic-$label.txt" | grep -E "^$w -> [^$w]|^[^$w] -> $w:" | grep -c -E '3 of 3 answers.*http 200.*http 200' || true)
    echo "lines between the worker and a control plane node that pass (ping 3 of 3, pod tcp 200, service 200): $good of $tot"
    [ "$good" = "$tot" ] && [ "$tot" = $((2 * (${#REPLICAS[@]} - 1))) ] && echo "ok   pod to pod in each direction between the worker and each other node" || { echo "FAIL pod traffic with the worker"; fail=1; }
    echo "all lines of the matrix that pass: $(grep -E '^[a-f] -> [a-f]:' "$LOG_DIR/traffic-$label.txt" | grep -c -E '3 of 3 answers.*http 200.*http 200' || true) of $(grep -c -E '^[a-f] -> [a-f]:' "$LOG_DIR/traffic-$label.txt")"
    say "2. from the test pod on the worker: the API Service and a name lookup"
    grep -E "^node $w: " "$LOG_DIR/traffic-$label.txt" | cut -c1-200 || true
    grep -q -E "^node $w: .*dns \[[0-9.]+ +kubernetes" "$LOG_DIR/traffic-$label.txt" && echo "ok   name lookup from a pod on the worker" || { echo "FAIL name lookup from a pod on the worker"; fail=1; }
    grep -q -E "^node $w: api \[http 200" "$LOG_DIR/traffic-$label.txt" && echo "ok   the API Service from a pod on the worker" || { echo "FAIL the API Service from a pod on the worker"; fail=1; }
    sed -n '/^== where the DNS pods are/,$p' "$LOG_DIR/traffic-$label.txt" | cut -c1-200 || true
    say "3. OVN and DNS pods on the worker"
    ik a get pods -A -o wide --field-selector "spec.nodeName=$wm" | cut -c1-180 || true
    [ "$(ik a -n ovn-kubernetes get pods -o wide --field-selector "spec.nodeName=$wm" --no-headers | awk '$1 ~ /^ovnkube-node/ {print $2 "/" $3}')" = "5/5/Running" ] && echo "ok   the OVN pod on the worker is Ready (5/5)" || { echo "FAIL the OVN pod on the worker is not Ready"; fail=1; }
    say "4. tunnels (read only), right after calls between the test pods"
    for s in "${REPLICAS[@]}"; do
      [ "$s" = "$w" ] || { texec "$w" curl -s -m 2 -o /dev/null "http://$(tpod_ip "$s"):8080/ping.py" 2>/dev/null || true; texec "$s" curl -s -m 2 -o /dev/null "http://$(tpod_ip "$w"):8080/ping.py" 2>/dev/null || true; }
    done
    tunnel_facts | tee "$LOG_DIR/tunnels-$label.txt"
    # The rule: the worker has one tunnel port to the fixed address of each control plane node, and each control plane node has one to the worker.
    for c in "${CPS[@]}"; do
      grep -A12 -E "^--- node $w " "$LOG_DIR/tunnels-$label.txt" | grep -q "tunnel port: .*remote_ip=\"*${IPS[$c]}\"*" && echo "ok   the worker has a tunnel port to ${IPS[$c]}" || { echo "FAIL the worker has no tunnel port to ${IPS[$c]}"; fail=1; }
      grep -A12 -E "^--- node $c " "$LOG_DIR/tunnels-$label.txt" | grep -q "tunnel port: .*remote_ip=\"*${IPS[$w]}\"*" && echo "ok   node $c has a tunnel port to the worker address ${IPS[$w]}" || { echo "FAIL node $c has no tunnel port to ${IPS[$w]}"; fail=1; }
    done
    grep -A2 -E "^--- node $w " "$LOG_DIR/tunnels-$label.txt" | grep -q "ovn-encap-ip: \"*${IPS[$w]}\"*" && echo "ok   the tunnel address of the worker is its fixed address ${IPS[$w]}" || { echo "FAIL the tunnel address of the worker is not ${IPS[$w]}"; fail=1; }
    echo "outer addresses that are not in the node range ${RANGE_CIDR%.*}.: [$(grep -oE '(src|dst)=[0-9.]+' "$LOG_DIR/tunnels-$label.txt" | cut -d= -f2 | grep -v -F "${RANGE_CIDR%.*}." | sort -u | tr '\n' ' ')]"

    say "5. calls of an API server to the pod $tp on the worker: logs and exec (kubelet), Service proxy and pod proxy (pod network)"
    echo "kubelet address types of the API servers: $(pod a sh -c 'grep -o -- "--kubelet-preferred-address-types=[^ ]*" /etc/kubernetes/manifests/kube-apiserver.yaml')"
    echo "addresses of the worker Node: $(ik a get node "$wm" -o jsonpath='{range .status.addresses[*]}{.type}{"="}{.address}{" "}{end}')"
    echo "pod address of $tp: $(tpod_ip "$w"), Service p1-t-$w: $(tsvc_ip "$w"), endpoints: $(ik a -n default get endpointslices -l kubernetes.io/service-name=p1-t-$w -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{" on "}{.nodeName}{" "}{end}')"
    echo "node subnets (the address .2 of a subnet is the address of that node on the pod network):"
    ik a get nodes -o json | jq -r '.items[] | "   \(.metadata.name) \(.metadata.annotations["k8s.ovn.org/node-subnets"])"'
    for c in "${CPS[@]}" shared; do
      if [ "$c" = shared ]; then srv=(); name="the shared address $ENDPOINT (which API server answers is not known)"; else srv=(--server "https://${IPS[$c]}:6443"); name="the API server of $(pn "$c") (${IPS[$c]})"; fi
      echo "--- through $name"
      line=$(ik a "${srv[@]}" -n default logs "$tp" --tail=1 2>&1 | tail -1 | cut -c1-110) || true
      case "$line" in *"GET /"*) echo "ok   logs: [$line]" ;; *) echo "FAIL logs: [$line]"; fail=1 ;; esac
      line=$(ik a "${srv[@]}" -n default exec "$tp" -- sh -c 'echo "exec in $(hostname), kernel boot $(cut -c1-8 /proc/sys/kernel/random/boot_id)"' 2>&1 | tail -1 | cut -c1-110) || true
      case "$line" in "exec in $tp"*) echo "ok   exec: [$line]" ;; *) echo "FAIL exec: [$line]"; fail=1 ;; esac
      line=$(ik a "${srv[@]}" get --raw "/api/v1/namespaces/default/services/p1-t-$w:80/proxy/ping.py" 2>&1 | head -1 | cut -c1-80) || true
      src=$(ik a -n default logs "$tp" --tail=1 2>/dev/null | awk '{print $1}') || true
      case "$line" in "# ICMP echo"*) echo "ok   Service proxy: first line [$line], the pod saw the call from $src" ;; *) echo "FAIL Service proxy: [$line]"; fail=1 ;; esac
      line=$(ik a "${srv[@]}" get --raw "/api/v1/namespaces/default/pods/$tp:8080/proxy/ping.py" 2>&1 | head -1 | cut -c1-80) || true
      src=$(ik a -n default logs "$tp" --tail=1 2>/dev/null | awk '{print $1}') || true
      case "$line" in "# ICMP echo"*) echo "ok   pod proxy: first line [$line], the pod saw the call from $src" ;; *) echo "FAIL pod proxy: [$line]"; fail=1 ;; esac
    done
    [ "$fail" = 0 ] && echo "RESULT w2 $label: PASS" || echo "RESULT w2 $label: FAIL"
  } 2>&1 | tee "$out"
  grep -q "RESULT w2 $label: PASS" "$out"
}

# --- W3 ----------------------------------------------------------------------------------------
# The pods on the worker: name, UID, restarts, state.
worker_pods() {
  ik a get pods -A -o json --field-selector "spec.nodeName=$1" | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name) uid \(.metadata.uid[0:8]) phase \(.status.phase) ready \([.status.containerStatuses[]? | select(.ready)] | length)/\(.status.containerStatuses | length) restarts \([.status.containerStatuses[]?.restartCount] | add) started \([.status.containerStatuses[]?.state.running.startedAt // "-"] | max)"' | sort
}

cmd_w3() {
  local label=${1:-w3} out fail=0 w m o=a id wid since watch=${REBOOT_WATCH:-3000} st end_seen=0 i=0 step uid0 uid1 boot0 boot1 dels
  out="$LOG_DIR/w3-$label.txt"
  write_podmap
  w=${WKS[0]}; m=$(pn "$w")
  id=$(node_id "$m")
  wid="reboot-node-$id"
  view() {
    echo "$(date -u +%T) node labels [$(ik "$o" get node "$m" -o json | jq -r '.metadata.labels | to_entries | map(select(.key | test("reboot|terminate"))) | map(.key + "=" + .value) | join(" ")')] ready $(ik "$o" get node "$m" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}') boot ID $(ik "$o" get node "$m" -o jsonpath='{.status.nodeInfo.bootID}' | cut -c1-8) | Machine annotations [$(k -n "$CAPI_NS" get machine.cluster.x-k8s.io "$m" -o json | jq -r '.metadata.annotations // {} | to_entries | map(select(.key | test("reboot"))) | map(.key + "=" + .value) | join(" ")')] | PodVMMachine lastRebootRequest [$(k -n "$CAPI_NS" get podvmmachine "$m" -o jsonpath='{.status.lastRebootRequest}')] | pod uid $(k -n "$NS" get pod "$m" -o jsonpath='{.metadata.uid}' 2>/dev/null | cut -c1-8) restarts $(k -n "$NS" get pod "$m" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null) ready $(k -n "$NS" get pod "$m" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null) | workflow $st"
  }
  {
    say "W3 ($label): reboot request for the worker $m (letter $w, NVKE node ID $id) at $(date -u +%FT%TZ)"
    WAIT=1 "$W/p2-replace/disk.sh" "$(basename "$LOG_DIR") reboot $label"
    say "before"
    st=none
    view
    api get "/api/nodes/$id" | api_body | jq -c '{name, controlPlane, conditions: [.conditions | to_entries[] | select(.value.status=="True") | .key]}'
    identity "$w" "$o" | tee "$LOG_DIR/.w3-before"
    worker_pods "$m" | tee "$LOG_DIR/.w3-pods-before" || true
    uid0=$(k -n "$NS" get pod "$m" -o jsonpath='{.metadata.uid}')
    boot0=$(ik "$o" get node "$m" -o jsonpath='{.status.nodeInfo.bootID}')
    cmd_cp_state "$label-before" >/dev/null
    cmd_probe_start "w3-$label" $((watch + 300))
    since=$(date -u +%FT%TZ)
    stamp "w3-$label-request"
    say "the request: label nvke.nvidia.com/reboot=p2s8-test on the Node $m of the new cluster, at $(date -u +%T)"
    ik "$o" label node "$m" nvke.nvidia.com/reboot=p2s8-test
    # One look each 10 s in the first 5 minutes and after a change, then each 30 s.
    while [ "$(( $(date +%s) - $(awk -v k="w3-$label-request" '$2==k {print int($1)}' "$LOG_DIR/times.txt") ))" -lt "$watch" ]; do
      step=30
      [ "$i" -lt 30 ] && step=10
      sleep "$step"
      st=$(temporal workflow describe --workflow-id "$wid" --output json 2>/dev/null | jq -r '.workflowExecutionInfo.status // "none"' 2>/dev/null || echo none)
      view >>"$LOG_DIR/w3-$label-timeline.txt"
      # Print a line when something in it changed (the time and the heartbeat are not in the comparison).
      if [ "$(tail -1 "$LOG_DIR/w3-$label-timeline.txt" | cut -d' ' -f2-)" != "$(tail -2 "$LOG_DIR/w3-$label-timeline.txt" | head -1 | cut -d' ' -f2-)" ] || [ "$i" = 0 ]; then tail -1 "$LOG_DIR/w3-$label-timeline.txt" | cut -c1-600; fi
      case "$st" in *COMPLETED* | *FAILED* | *CANCELED* | *TERMINATED* | *TIMED_OUT*) end_seen=$((end_seen + 1)) ;; esac
      [ "$end_seen" -ge 3 ] && break
      i=$((i + 1))
    done
    stamp "w3-$label-end"
    cmd_probe_stop "w3-$label"
    say "the workflow $wid"
    temporal workflow describe --workflow-id "$wid" 2>&1 | grep -E '^ *(Status|Type|StartTime|CloseTime|ExecutionTime|RunTime|HistoryLength)' || echo "no workflow with this ID"
    workflow_timeline "$wid" || true
    grep -v -E 'GetNodePoolForNode|GetClusterForNode|UpdateNodeConditions' "$LOG_DIR/workflow-$wid.txt" 2>/dev/null | cut -c1-200 || true
    say "what the controller logged for the reboot"
    k -n nvke-controller logs deployment/nvke-controller --since-time="$since" 2>/dev/null | grep -i -E 'reboot' | mask | jq -r '"\(.time[11:23]) \(.level) \(.msg) \(.rebootAttempt // "") \(.error // "")"' 2>/dev/null | uniq -c -f1 | head -40 | cut -c1-260 || true
    say "what the provider logged since the request"
    provider_log_since "$since" | grep -v 'Waiting for' | head -30 || true
    echo "lines 'Deleting the pod for a reboot request': $(k -n "$PROVIDER_NS" logs deployment/podvm-controller-manager --since-time="$since" 2>/dev/null | grep -c 'Deleting the pod for a reboot request' || true)"
    say "what the agent of the worker logged for the reboot (journal of the worker)"
    pod "$w" sh -c 'journalctl --no-pager -u nvke-agent -o short-precise | grep -i -E "reboot" | tail -8 | cut -c1-260; echo "boots in the journal: $(journalctl --list-boots --no-pager 2>/dev/null | wc -l)"; journalctl --list-boots --no-pager 2>/dev/null | tail -5 | cut -c1-160' 2>&1 || true
    say "events of the worker pod since the request"
    k -n "$NS" get events --field-selector "involvedObject.name=$m" --sort-by=.lastTimestamp -o custom-columns=TIME:.lastTimestamp,REASON:.reason,MESSAGE:.message 2>/dev/null | tail -16 | cut -c1-200 || true
    say "after"
    view
    api get "/api/nodes/$id" | api_body | jq -c '{name, controlPlane, conditions: [.conditions | to_entries[] | select(.value.status=="True") | .key]}'
    ik "$o" get node "$m" -o json | jq -r '"labels of the Node with reboot in the key: \(.metadata.labels | to_entries | map(select(.key | test("reboot"))) | map(.key + "=" + .value) | join(" "))"'
    identity "$w" "$o" | tee "$LOG_DIR/.w3-after"
    worker_pods "$m" | tee "$LOG_DIR/.w3-pods-after" || true
    say "checks"
    uid1=$(k -n "$NS" get pod "$m" -o jsonpath='{.metadata.uid}')
    boot1=$(ik "$o" get node "$m" -o jsonpath='{.status.nodeInfo.bootID}')
    temporal workflow describe --workflow-id "$wid" 2>&1 | grep -E '^ *Status' | grep -q -i COMPLETED && echo "ok   the reboot workflow of NVKE is completed" || { echo "FAIL the reboot workflow is not completed"; fail=1; }
    grep -q 'done   ApplyCAPIMachineRebootAnnotation' "$LOG_DIR/workflow-$wid.txt" && echo "ok   NVKE set the annotation on the Machine (ApplyCAPIMachineRebootAnnotation)" || { echo "FAIL NVKE did not set the annotation on the Machine"; fail=1; }
    dels=$(k -n "$PROVIDER_NS" logs deployment/podvm-controller-manager --since-time="$since" 2>/dev/null | grep -c 'Deleting the pod for a reboot request' || true)
    [ "$dels" = 1 ] && echo "ok   the provider deleted the pod one time for the request" || { echo "FAIL the provider deleted the pod $dels times"; fail=1; }
    [ "$uid0" != "$uid1" ] && echo "ok   the pod has a new UID" || { echo "FAIL the pod UID is the same"; fail=1; }
    if diff <(grep -E '^(pod|claim|secret|machine):' "$LOG_DIR/.w3-before") <(grep -E '^(pod|claim|secret|machine):' "$LOG_DIR/.w3-after"); then echo "ok   same pod name, host node, address, hardware address, claims, Secret copy and machine record"; else echo "FAIL something of the identity changed"; fail=1; fi
    [ "$boot0" != "$boot1" ] && echo "ok   the Node has a new boot ID (${boot0:0:8} before, ${boot1:0:8} now)" || { echo "FAIL the boot ID is the same"; fail=1; }
    [ "$(ik "$o" get node "$m" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True ] && echo "ok   the worker Node is Ready" || { echo "FAIL the worker Node is not Ready"; fail=1; }
    [ -z "$(k -n "$CAPI_NS" get machine.cluster.x-k8s.io "$m" -o json | jq -r '.metadata.annotations["nvke.nvidia.com/reboot"] // ""')" ] && echo "ok   NVKE removed the annotation from the Machine at the end" || echo "note the Machine has the reboot annotation"
    cmd_cp_state "$label-after" >/dev/null
    if diff "$LOG_DIR/cp-state-$label-before.txt" "$LOG_DIR/cp-state-$label-after.txt"; then echo "ok   the control plane has no change"; else echo "FAIL the control plane changed"; fail=1; fi
    grep -q 'failed: 0$' "$LOG_DIR/probe-w3-$label-summary.txt" && echo "ok   the shared address answered each call with 200" || echo "note the shared address has calls that are not 200"
    echo "time from the label to the end of the workflow: $(temporal workflow describe --workflow-id "$wid" 2>&1 | grep -E '^ *RunTime' | tr -s ' ')"
    [ "$fail" = 0 ] && echo "RESULT w3 $label: PASS" || echo "RESULT w3 $label: FAIL"
  } 2>&1 | tee "$out"
  grep -q "RESULT w3 $label: PASS" "$out"
}

# --- W4 ----------------------------------------------------------------------------------------
cmd_w4() {
  local label=${1:-w4} w m rc=0
  write_podmap
  w=${WKS[0]}; m=$(pn "$w")
  WAIT=1 "$W/p2-replace/disk.sh" "$(basename "$LOG_DIR") lost worker pod $label"
  say "the pods on the worker before"
  worker_pods "$m" || true
  cmd_cp_state "$label-before" >/dev/null
  cmd_lost_pod "$w" || rc=1
  say "the pods on the worker after"
  worker_pods "$m" || true
  cmd_cp_state "$label-after" >/dev/null
  if diff "$LOG_DIR/cp-state-$label-before.txt" "$LOG_DIR/cp-state-$label-after.txt"; then echo "ok   the control plane has no change"; else echo "FAIL the control plane changed"; rc=1; fi
  return "$rc"
}

step=${1:-}
shift || true
case "$step" in
  init | pool-post | pool-wait | pool-scale | pool-delete | worker-delete | cp-state | w1 | w2 | w3 | w4 | placement | lost-pod | wait-good | probe-start | probe-stop)
    mkdir -p "$LOG_DIR"
    "cmd_${step//-/_}" "$@" 2>&1 | tee -a "$LOG_DIR/run.log"
    exit "${PIPESTATUS[0]}"
    ;;
  state) sample 1; state_line ;;
  podmap) write_podmap; paste -d' ' "$PODMAP" <(cut -d' ' -f2 "$LOG_DIR/roles.txt") ;;
  *) sed -n '2,19p' "$0"; exit 1 ;;
esac
