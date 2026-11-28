#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# p3ab.sh: the lab driver of phase 3 for step A (one network) and step B (two networks).
# It runs on the second machine. It makes no change of the machine by itself: each change comes
# from the NVKE API (a POST, a PATCH or a DELETE) and from what NVKE, CAPNICo and the simulator
# do after it. It writes no file into a guest.
#
#   post <run> <workers>      render the mixed request (requests/render.sh), the base check, the
#                             each-second call to the shared address, then POST /api/clusters
#   watch <run> [s] [nodes]   one look each 10 s. A line in timeline.txt for each change. It ends
#                             when NVKE reports <nodes> good nodes, or after s seconds
#   line <run>                one look, one line
#   snap <run> <label>        the objects, the logs and the worker facts of now, into snap-<label>/
#   kc <run>                  fetch the kubeconfig of the new cluster into the secrets folder
#   ready-start <run>         the Ready watch of the phase 2 scripts (needs the kubeconfig)
#   stop-watches <run>        stop the each-second call and the Ready watch, print the summaries
#   worker-facts <run> <label>   for each worker container: networks, units, the agent lines
#   modules <run> <label>     the kernel modules that are new since the list of the preparation
#   watch-summary <run> <label>   the numbers of the each-second call and of the Ready watch (stops nothing)
#   kubelet-errors <run> <label> <since> [until]   lease and connection lines of the kubelet of each worker
#   reboot <run> <node> <label> [s]   the reboot request of NVKE for one worker, with a watch
#   konn <run> <label>        the connections of the direct path, for the Konnectivity decision
#   starts <run>              one record for each worker start (times, simulator line, cloud-init, workflow)
#   scale <run> <count> [label]   PATCH the worker pool to a count (pass rule 4)
#   node-delete <run> <node> <label>   DELETE one node through the NVKE API
#   gone-check <run> <label>  what is left of that node (Node, NVKE, Machine, NicoMachine, instance, container)
#   tpods <run>               one test pod and one Service on each node of the new cluster
#   tunnels <run> <label>     node address, tunnel address and tunnel ports of each node
#   traffic <run> <label>     the pod traffic matrix, the API Service and a name lookup
#   rule3 <run> <label>       logs, exec and port forward to a pod on each worker, through each API server
# Usage: p3ab.sh <step> <run> ...     The run folder is /root/kata-cp/logs/p3/<run>.
set -uo pipefail
export LC_ALL=C
. /root/kata-cp/bin/env.sh
. /root/kata-cp/p3/env-p3.sh
G=$W/p2-gaps
A=$W/d/stack/api.sh
L=$P3_LOGS
KIND_NODE=$CP_NODE
CAPI_NS=nvke-system
CLUSTER_NAME=${CLUSTER_NAME:-kata-cp1}
IMG=${IMG:-docker.io/library/nvke-node-podvm:bcc4376f-p10}
export IMG_CLUSTER=$IMG IMG_WORKER=$IMG IMG_ROLLOUT=${IMG_ROLLOUT:-docker.io/library/nvke-node-podvm:bcc4376f-p9}
LSMOD_BASE=${LSMOD_BASE:-$L/prep/lsmod-after.txt}

step=${1:-}
run=${2:-}
[ -n "$step" ] && [ -n "$run" ] || { sed -n '2,31p' "$0"; exit 1; }
D=$L/$run
SEC=$W/secrets/d-$run
KCFG=$SEC/kubeconfig-$CLUSTER_NAME
mkdir -p "$D"

now() { date -u +%FT%TZ; }
say() { echo "== $*"; }
k() { "$W/bin/kubectl" --kubeconfig "$W/secrets/kubeconfig" "$@"; }
gk() { "$W/bin/kubectl" --kubeconfig "$KCFG" --request-timeout=10s "$@"; }
api() { env -u LOG_DIR "$A" "$@"; }
body() { sed '$d'; }
cid() { cat "$D/cluster-id.txt"; }
gaps() { LOG_DIR=$D "$G/run.sh" "$@"; }
workers() { docker ps -a --filter label=nvidia.com/nico-containers.managed=true --format '{{.Names}}' | sort; }
sim_get() { docker exec "$KIND_NODE" curl -sS --max-time 5 -H 'Authorization: Bearer example-token' "http://$SIM_IP:$SIM_PORT/v2/org/$NICO_ORG_ID/$NICO_API_NAME/$1"; }
# A join token is part of a SPIFFE ID and of the agent settings. A bootstrap token is in a join command.
mask() { sed -E 's#(join_token/)[0-9a-f-]+#\1TOKEN#g; s#(join[_-]?[tT]oken["=: ]+)[0-9a-f-]{8,}#\1TOKEN#g; s#[a-z0-9]{6}\.[a-z0-9]{16}#<bootstrap-token>#g'; }
mod_names() { awk '$1!="Module" {print $1}' "$1" | sort -u; }
new_modules() { lsmod >"$D/.lsmod"; comm -13 <(mod_names "$LSMOD_BASE") <(mod_names "$D/.lsmod") | tr '\n' ' '; }

COND_SHORT='def short: {"pending":"pend","provisioningClaimed":"claim","nodeAgentReady":"agent","readyToJoin":"rtj","joined":"join","kubernetesReady":"kube","provisioned":"prov","provisioning":"prov-ing","deleting":"DELETING","deleteRequested":"delete-requested"}[.] // .;
  def good: (.conditions.joined.status=="True" and .conditions.kubernetesReady.status=="True" and .conditions.nodeAgentReady.status=="True" and .conditions.provisioned.status=="True" and (.conditions.deleting.status!="True") and (.conditions.deleteRequested.status!="True"));'

look() {
  local id
  id=$(cid)
  api get "/api/clusters/$id" >"$D/.cluster.raw" 2>/dev/null
  api get "/api/nodes?clusterID=$id" 2>/dev/null | body >"$D/.nodes.json"
  api get "/api/nodePools?clusterID=$id" 2>/dev/null | body >"$D/.pools.json"
  k -n "$CAPI_NS" get machines.cluster.x-k8s.io -o json >"$D/.m.json" 2>/dev/null || echo '{"items":[]}' >"$D/.m.json"
  k -n "$CAPI_NS" get nicomachines -o json >"$D/.nm.json" 2>/dev/null || echo '{"items":[]}' >"$D/.nm.json"
  k -n "$CAPI_NS" get podvmmachines -o json >"$D/.pm.json" 2>/dev/null || echo '{"items":[]}' >"$D/.pm.json"
  k -n d get pods -o json >"$D/.p.json" 2>/dev/null || echo '{"items":[]}' >"$D/.p.json"
  sim_get instance >"$D/.inst.json" 2>/dev/null || echo '[]' >"$D/.inst.json"
}
state_line() {
  local c n p m nm pm pods inst dk mods
  c="cluster[$(tail -1 "$D/.cluster.raw" | tr -d '\n') $(body <"$D/.cluster.raw" | jq -r '[(.conditions // {}) | to_entries[] | select(.value.status=="True") | .key] | join("+")' 2>/dev/null)]"
  n="nvke-nodes[$(jq -r "$COND_SHORT"'[(.nodes // [])[] | "\(.name[-11:])@\(.ip // "-")=" + ([.conditions | to_entries[] | select(.value.status=="True") | .key | short] | join("+")) + (if good then "(GOOD)" else "" end)] | join(" ")' "$D/.nodes.json" 2>/dev/null)]"
  p="pools[$(jq -r '[(.nodePools // .nodepools // .items // [])[] | "\(.name) desired=\(.desiredNodeCount // "-") " + ([(.conditions // {}) | to_entries[] | select(.value.status=="True") | .key] | join("+"))] | join(" ")' "$D/.pools.json" 2>/dev/null)]"
  m="machines[$(jq -r '[.items[] | "\(.metadata.name[-11:])=\(.status.phase // "-")" + (if .spec.providerID then "/pid" else "" end) + (if .status.nodeRef then "/node" else "" end)] | join(" ")' "$D/.m.json")]"
  nm="nico[$(jq -r '[.items[] | "\(.metadata.name[-11:]) ready=\(.status.ready // "-") instance=\((.status.instanceID // .status.instanceId // .spec.instanceID // "-") | tostring | .[0:8]) pid=\(if .spec.providerID then "set" else "-" end) " + ([(.status.conditions // [])[] | "\(.type)=\(.status)" + (if .reason and .status!="True" then "(\(.reason))" else "" end)] | join(","))] | join(" ; ")' "$D/.nm.json")]"
  pm="pvmm[$(jq -r '[.items[] | "\(.metadata.name[-8:])=\(.status.address // "-")/\(if .status.ready then "ready" else "not-ready" end)"] | join(" ")' "$D/.pm.json")]"
  pods="pods[$(jq -r '[.items[] | "\(.metadata.name[-8:])@\((.spec.nodeName // "-") | sub("kata-bb-"; ""))=\(if .metadata.deletionTimestamp then "terminating" elif (.status.containerStatuses[0].ready // false) then "ready" else (.status.phase // "-") end)"] | join(" ")' "$D/.p.json")]"
  inst="sim[$(jq -r '[.[]? | "\(.name[-11:])=\(.status)@" + ([.interfaces[]?.ipAddresses[]?] | join(","))] | join(" ")' "$D/.inst.json" 2>/dev/null)]"
  dk="docker[$(docker ps -a --filter label=nvidia.com/nico-containers.managed=true --format '{{.Names}}={{.State}}' | sort | tr '\n' ' ')]"
  mods="new-modules[$(new_modules)]"
  echo "$c | $n | $p | $m | $nm | $pm | $pods | $inst | $dk | $mods"
}
good_count() { jq -r "$COND_SHORT"'[(.nodes // [])[] | select(good)] | length' "$D/.nodes.json" 2>/dev/null || echo 0; }

cmd_post() {
  local n=${1:?worker count} req
  say "$(now) base of the run $run: kernel modules that are new since the preparation: [$(new_modules)]"
  cp "$D/.lsmod" "$D/lsmod-before-post.txt"
  df -h /root | tail -1 >"$D/disk-before.txt"
  "$P3/requests/render.sh" cluster "$D" "$n" || return 1
  jq -c '{name, infraCluster: .infra.cluster.kind, controlPlane: {template: .controlPlaneConfig.infra.machineTemplate.kind, count: .controlPlaneConfig.desiredCount, image: .controlPlaneConfig.infra.machineTemplate.spec.template.spec.image}, pools: [.nodePools[]? | {name, count: .desiredNodeCount, template: .infra.machineTemplate.kind}], controlPlaneEndpoint}' "$D/cluster-request.json" 2>/dev/null || jq -c 'paths(scalars) as $p | select($p | map(tostring) | join(".") | test("kind|desired|Endpoint")) | {($p | map(tostring) | join(".")): getpath($p)}' "$D/cluster-request.json"
  # REQUEST_FORM=nowait: the pool commands as the preparation had them, with no wait for systemd
  # (the same two commands as the e2e request of NVKE). The request with the wait stays in its file.
  req="$D/cluster-request.json"
  if [ "${REQUEST_FORM:-wait}" = nowait ]; then
    jq '(.nodePools[].infra.preKubeadmCommands) |= map(select(test("lab wait for systemd") | not))' "$D/cluster-request.json" >"$D/cluster-request-nowait.json" || return 1
    req="$D/cluster-request-nowait.json"
  fi
  echo "$req" >"$D/posted-request.txt"
  echo "file to post: $req; pool commands: $(jq -c '[.nodePools[].infra.preKubeadmCommands[]]' "$req" | cut -c1-200)"
  gaps base >"$D/base.txt" 2>&1 || { echo "the base check failed:"; tail -5 "$D/base.txt"; return 1; }
  grep -E 'free volumes|NVKE clusters|objects of the cluster|answers to an echo' "$D/base.txt" | cut -c1-200
  gaps probe-start "$run" "${PROBE_SECS:-28800}" || true
  date -u +%FT%T.%3NZ >"$D/post-time.txt"
  api post /api/clusters "$req" >"$D/post-response.txt" 2>&1
  echo "POST /api/clusters at $(cat "$D/post-time.txt"): $(tail -1 "$D/post-response.txt")"
  body <"$D/post-response.txt" | jq -r '.id // empty' >"$D/cluster-id.txt" 2>/dev/null
  if [ -s "$D/cluster-id.txt" ]; then echo "cluster ID $(cid)"; else echo "no cluster ID. The answer:"; body <"$D/post-response.txt" | cut -c1-1500; return 1; fi
}

node_count() { jq -r '(.nodes // []) | length' "$D/.nodes.json" 2>/dev/null || echo 0; }
has_node() { jq -e --arg n "$1" '[(.nodes // [])[] | select(.name==$n)] | length > 0' "$D/.nodes.json" >/dev/null 2>&1; }
cmd_watch() { # [seconds] [good nodes that end the watch] [a node name that must be gone at the end]
  local secs=${1:-1500} want=${2:-0} absent=${3:-} end last="" line
  end=$(( $(date +%s) + secs ))
  while [ "$(date +%s)" -lt "$end" ]; do
    look
    line=$(state_line)
    if [ "$line" != "$last" ]; then echo "$(date -u +%T) $line" >>"$D/timeline.txt"; last=$line; fi
    if [ "$want" -gt 0 ] && [ "$(good_count)" = "$want" ] && [ "$(node_count)" = "$want" ] && { [ -z "$absent" ] || ! has_node "$absent"; }; then echo "$(date -u +%T) NVKE reports $want nodes, each one good${absent:+, and $absent is gone}" | tee -a "$D/timeline.txt"; return 0; fi
    [ -e "$D/.watch-stop" ] && { unlink "$D/.watch-stop"; echo "$(date -u +%T) watch stopped by the stop file" >>"$D/timeline.txt"; return 2; }
    sleep 10
  done
  echo "$(date -u +%T) watch limit of $secs s reached, good nodes $(good_count)" | tee -a "$D/timeline.txt"
  return 1
}

cmd_kc() {
  local m
  mkdir -p "$SEC"; chmod 700 "$SEC"
  for m in $(k -n d get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
    if ( umask 077; k -n d exec "$m" -- cat /etc/kubernetes/admin.conf >"$KCFG.new" 2>/dev/null ) && grep -q '^kind: Config' "$KCFG.new"; then mv "$KCFG.new" "$KCFG"; break; fi
  done
  # Only a file that this call fetched counts. A run folder of phase 2 can have the same name, and
  # then the secrets folder has the kubeconfig of a cluster that is gone (run c-1, 2026-11-28).
  if [ -s "$KCFG" ] && [ -n "$(find "$KCFG" -newermt "$(cut -c1-19 "$D/post-time.txt" | tr T ' ') UTC" 2>/dev/null)" ]; then
    echo "kubeconfig of $CLUSTER_NAME is in the secrets folder (server $(grep -m1 'server:' "$KCFG" | awk '{print $2}'))"
  else
    echo "no kubeconfig of this run yet"; return 1
  fi
}

cmd_ready_start() {
  cmd_kc || return 1
  : >"$D/ready-$run.txt"
  setsid nohup "$G/ready-watch.sh" "$KCFG" "$D/ready-$run.txt" "${READY_SECS:-28800}" </dev/null >>"$D/ready-$run.err" 2>&1 &
  echo "Ready watch started (ready-$run.txt)"
}

cmd_stop_watches() {
  touch "$D/ready-$run.txt.stop"; sleep 3
  say "Ready watch: each change (UTC)"; cat "$D/ready-$run.txt" 2>/dev/null
  gaps probe-stop "$run" 2>&1 | tail -70
}

cmd_modules() {
  local label=${1:-now}
  { echo "kernel modules at $(now) that are not in the list of the preparation ($LSMOD_BASE):"
    lsmod >"$D/lsmod-$label.txt"
    comm -13 <(mod_names "$LSMOD_BASE") <(mod_names "$D/lsmod-$label.txt") | while read -r mod; do grep -E "^$mod " "$D/lsmod-$label.txt"; done
    echo "modules of the preparation list that are gone: [$(comm -23 <(mod_names "$LSMOD_BASE") <(mod_names "$D/lsmod-$label.txt") | tr '\n' ' ')]"
  } | tee "$D/modules-$label.txt"
}

cmd_worker_facts() {
  local label=${1:-now} w out
  for w in $(workers); do
    out="$D/worker-$w-$label.txt"
    {
      say "worker container $w at $(now)"
      docker inspect "$w" | jq -r '.[0] | "state \(.State.Status), started \(.State.StartedAt), restarts \(.RestartCount), privileged \(.HostConfig.Privileged), restart policy \(.HostConfig.RestartPolicy.Name), image \(.Config.Image)", "networks: " + ([.NetworkSettings.Networks | to_entries[] | "\(.key)=\(.value.IPAddress) gateway \(.value.Gateway)"] | join("; "))'
      say "addresses and routes"
      docker exec "$w" ip -4 -o addr show 2>&1 | awk '{print $2, $4}'
      docker exec "$w" ip -4 route show 2>&1
      say "units"
      for u in nke-container-network ovs-vswitchd ovsdb-server spire-agent nvke-agent kubelet containerd; do echo "$u: $(docker exec "$w" systemctl is-active "$u" 2>&1)"; done
      echo "failed units: [$(docker exec "$w" systemctl --failed --no-legend --plain 2>&1 | awk '{print $1}' | tr '\n' ' ')]"
      say "the agent: start command, version, the mlx5 line"
      docker exec "$w" systemctl show nvke-agent -p ExecStart --no-pager 2>&1 | grep -o 'argv\[\]=[^;]*' | mask | cut -c1-600
      docker exec "$w" /usr/local/bin/nvke-agent --version 2>&1 | head -1
      echo "process: $(docker exec "$w" sh -c 'tr "\0" " " </proc/$(pidof nvke-agent)/cmdline' 2>&1 | mask | cut -c1-600)"
      echo "journal lines with mlx5 or rescan:"
      docker exec "$w" journalctl -u nvke-agent --no-pager 2>&1 | grep -i -E 'mlx5|rescan' | mask | cut -c1-400 | head -10
      say "the agent journal: identity, join, errors (first 40 matching lines)"
      docker exec "$w" journalctl -u nvke-agent --no-pager 2>&1 | grep -i -E 'spiffe|svid|identity|listening|serving|kubeadm|join|error|fail' | mask | cut -c1-300 | head -40
      say "SPIRE agent (last 8 lines)"
      docker exec "$w" journalctl -u spire-agent --no-pager 2>&1 | mask | tail -8 | cut -c1-300
      say "kubelet flags and the address files"
      docker exec "$w" cat /var/lib/kubelet/kubeadm-flags.env 2>&1 | cut -c1-400
      echo "old-ipv4: $(docker exec "$w" cat /kind/old-ipv4 2>&1)"
      docker exec "$w" cat /etc/netplan/50-nke-container.yaml 2>&1 | head -30
      say "Open vSwitch"
      docker exec "$w" ovs-vsctl show 2>&1 | head -60
      say "swap and the kernel log of the machine about this (no change expected)"
      docker exec "$w" sh -c 'cat /proc/swaps | wc -l' 2>&1
    } >"$out" 2>&1
    echo "worker facts: $out ($(wc -l <"$out") lines)"
  done
  [ -n "$(workers)" ] || echo "no worker container"
}

cmd_snap() {
  local label=${1:?label} s="$D/snap-$1" since
  mkdir -p "$s" "$SEC"; chmod 700 "$SEC"
  since=$(cut -c1-19 "$D/post-time.txt")Z
  look; state_line >"$s/state-line.txt"
  body <"$D/.cluster.raw" | jq . >"$s/api-cluster.json" 2>/dev/null
  jq . "$D/.nodes.json" >"$s/api-nodes.json" 2>/dev/null
  jq . "$D/.pools.json" >"$s/api-nodepools.json" 2>/dev/null
  k -n "$CAPI_NS" get clusters.cluster.x-k8s.io,machinedeployments.cluster.x-k8s.io,machinesets.cluster.x-k8s.io,machines.cluster.x-k8s.io,podvmclusters,podvmmachines,podvmmachinetemplates,nicomachines,nicomachinetemplates,nicoclusters -o wide >"$s/capi-objects.txt" 2>&1
  k -n "$CAPI_NS" get nicomachines,nicomachinetemplates,nicoclusters -o yaml >"$s/nico-objects.yaml" 2>&1
  k -n "$CAPI_NS" get clusters.cluster.x-k8s.io,machinedeployments.cluster.x-k8s.io,machines.cluster.x-k8s.io -o yaml >"$s/capi-objects.yaml" 2>&1
  k -n "$CAPI_NS" get events --sort-by=.lastTimestamp 2>&1 | tail -80 >"$s/events.txt"
  k -n "$CAPNICO_NS" logs deployment/capnico-controller-manager --since-time="$since" 2>&1 | mask >"$s/capnico.log" || true
  [ -s "$s/capnico.log" ] && ! grep -q 'NotFound\|not found' <(head -1 "$s/capnico.log") || k -n "$CAPNICO_NS" logs -l control-plane=controller-manager --since-time="$since" --tail=-1 2>&1 | mask >"$s/capnico.log"
  k -n nvke-controller logs deployment/nvke-controller --since-time="$since" >"$SEC/nvke-controller-$label.log" 2>&1 || true
  docker logs "$SIM_NAME" 2>&1 | mask >"$s/sim.log"
  sim_get instance 2>&1 | jq . >"$s/sim-instances.json" 2>/dev/null
  k -n temporal exec deploy/temporal-admintools -- temporal workflow list --query "StartTime > \"$since\"" --limit 60 --namespace cloud-workflow-engine --address temporal-frontend.temporal.svc.cluster.local:7233 >"$s/temporal-workflows.txt" 2>&1 || true
  cmd_modules "$label" >/dev/null
  echo "snap $label: $(ls "$s" | tr '\n' ' ')"
}

# --- the test pods: one on each node, with one Service for each ----------------------------------
# The pod uses the OVN image of the node (python3, curl), so a node pulls nothing.
TN="$D/tnodes.txt"      # one line for each node: <index> <node name> <role> <node address>
tnodes() {
  # A node keeps its index for the life of the run folder. A new node gets the next number, and a
  # number is not used again. So the test pod p3-t-<index> stays on its node when nodes come and go.
  local cur="$TN.cur" max=0 i name role ip line
  gk get nodes -o json | jq -r '.items | sort_by(.metadata.name)[] | "\(.metadata.name) \(if ((.metadata.labels // {}) | has("node-role.kubernetes.io/control-plane")) then "cp" else "worker" end) \([.status.addresses[] | select(.type=="InternalIP") | .address] | join(","))"' >"$cur" 2>/dev/null
  [ -s "$cur" ] || return 1
  [ -s "$TN.max" ] && max=$(cat "$TN.max")
  : >"$TN.new"
  if [ -s "$TN" ]; then
    while read -r i name role ip; do
      [ "$i" -gt "$max" ] && max=$i
      if line=$(grep -E "^$name " "$cur"); then echo "$i $line" >>"$TN.new"; fi
    done <"$TN"
  fi
  while read -r name role ip; do
    grep -q -E "^[0-9]+ $name " "$TN.new" || { max=$((max + 1)); echo "$max $name $role $ip" >>"$TN.new"; }
  done <"$cur"
  echo "$max" >"$TN.max"
  mv "$TN.new" "$TN"
}
tpod_ip() { gk -n default get pod "p3-t-$1" -o jsonpath='{.status.podIP}'; }
tsvc_ip() { gk -n default get service "p3-t-$1" -o jsonpath='{.spec.clusterIP}'; }
texec() { local i=$1; shift; gk -n default exec "p3-t-$i" -- "$@"; }
cmd_tpods() {
  local img i name role ip
  tnodes || { echo "no node list"; return 1; }
  img=$(gk -n ovn-kubernetes get pods -o jsonpath='{.items[0].spec.containers[0].image}')
  [ -n "$img" ] || { echo "no OVN image name"; return 1; }
  gk -n default create configmap p3-probe --from-file=ping.py="$(dirname "$0")/ping.py" --dry-run=client -o yaml | gk apply -f - >/dev/null
  while read -r i name role ip; do
    # A test pod has the restart policy Never. After a restart of its node it is Failed. Make it new.
    case "$(gk -n default get pod "p3-t-$i" -o jsonpath='{.status.phase}' </dev/null 2>/dev/null)" in
      Failed | Succeeded | Unknown) echo "the test pod p3-t-$i on $name ended ($(gk -n default get pod "p3-t-$i" -o jsonpath='{.status.phase} {.status.reason}' </dev/null 2>/dev/null)). A new one"; gk -n default delete pod "p3-t-$i" --wait=true --timeout=60s </dev/null >/dev/null 2>&1 ;;
    esac
    cat <<EOF_POD | gk apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: p3-t-$i
  namespace: default
  labels: {app: p3-t, p3-node: "n$i"}
spec:
  nodeName: $name
  restartPolicy: Never
  terminationGracePeriodSeconds: 2
  automountServiceAccountToken: false
  tolerations:
    - {operator: Exists}
  containers:
    - name: test
      image: $img
      imagePullPolicy: Never
      command: ["python3", "-m", "http.server", "8080", "--directory", "/probe"]
      resources:
        requests: {cpu: 10m, memory: 32Mi}
      volumeMounts:
        - {name: probe, mountPath: /probe, readOnly: true}
  volumes:
    - name: probe
      configMap: {name: p3-probe}
---
apiVersion: v1
kind: Service
metadata:
  name: p3-t-$i
  namespace: default
spec:
  selector: {p3-node: "n$i"}
  ports:
    - {port: 80, targetPort: 8080, protocol: TCP}
EOF_POD
  done <"$TN"
  while read -r i name role ip; do
    gk -n default wait --for=condition=Ready "pod/p3-t-$i" --timeout=180s >/dev/null 2>&1 || echo "the test pod p3-t-$i on $name is not Ready: $(gk -n default get pod "p3-t-$i" -o jsonpath='{.status.phase} {.status.containerStatuses[0].state}' 2>&1 | cut -c1-200)"
  done <"$TN"
  # The test pod and the Service of a node that is gone.
  for name in $(gk -n default get pods -l app=p3-t -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
    grep -q -E "^${name#p3-t-} " "$TN" || { gk -n default delete pod "$name" --wait=false --ignore-not-found >/dev/null 2>&1; gk -n default delete service "$name" --ignore-not-found >/dev/null 2>&1; echo "removed the test pod $name of a node that is gone"; }
  done
  gk -n default get pods -l app=p3-t -o wide 2>&1 | cut -c1-150
}

# The tunnel address and the tunnel ports of each node (read only).
node_ovs() { # <node name>: run ovs-vsctl in the node (a pod of the host cluster, or a worker container)
  local name=$1 w; shift
  w=$(docker ps --filter label=nvidia.com/nico-containers.managed=true --filter "label=nvidia.com/nico-containers.instance-name=$name" --format '{{.Names}}' | head -1)
  if [ -n "$w" ]; then docker exec "$w" "$@"; else k -n d exec "$name" -- "$@"; fi
}
cmd_tunnels() {
  local label=${1:-now} i name role ip
  tnodes
  {
    say "node address and tunnel address of each node ($label) at $(now)"
    while read -r i name role ip; do
      echo "--- n$i $name ($role): node address (InternalIP) $ip, tunnel address (ovn-encap-ip) $(node_ovs "$name" ovs-vsctl get Open_vSwitch . external_ids:ovn-encap-ip </dev/null 2>&1 | tr -d '"'), node subnet $(gk get node "$name" -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/node-subnets}' 2>&1), provider ID $(gk get node "$name" -o jsonpath='{.spec.providerID}' 2>&1)"
      node_ovs "$name" ovs-vsctl --format=csv --no-headings --columns=name,options find interface type=geneve </dev/null 2>&1 | sed -E 's/^/    tunnel port: /' | cut -c1-200
    done <"$TN"
  } | tee "$D/tunnels-$label.txt"
}

# The traffic matrix: from the test pod of each node to the test pod of each other node.
cmd_traffic() {
  local label=${1:-now} s d sn dn sr dr sip dip a b c line
  local -A PIP=() SIP=() NAME=() ROLE=()
  tnodes
  while read -r s sn sr sip; do NAME[$s]=$sn; ROLE[$s]=$sr; PIP[$s]=$(tpod_ip "$s" </dev/null); SIP[$s]=$(tsvc_ip "$s" </dev/null); done <"$TN"
  {
    say "pod traffic ($label) at $(now): source -> destination: ping (3 echo requests), pod tcp (port 8080), Service (port 80)"
    for s in "${!NAME[@]}"; do echo "n$s ${NAME[$s]} (${ROLE[$s]}): test pod ${PIP[$s]}, Service ${SIP[$s]}"; done | sort
    for s in $(printf '%s\n' "${!NAME[@]}" | sort -n); do
      for d in $(printf '%s\n' "${!NAME[@]}" | sort -n); do
        [ "$s" = "$d" ] && continue
        a=$(texec "$s" python3 /probe/ping.py "${PIP[$d]}" 3 </dev/null 2>&1 | tail -1 | cut -c1-60)
        b=$(texec "$s" curl -s -m 3 -o /dev/null -w 'http %{http_code} in %{time_total} s' "http://${PIP[$d]}:8080/ping.py" </dev/null 2>&1 | tail -1 | cut -c1-40)
        c=$(texec "$s" curl -s -m 3 -o /dev/null -w 'http %{http_code} in %{time_total} s' "http://${SIP[$d]}:80/ping.py" </dev/null 2>&1 | tail -1 | cut -c1-40)
        echo "n$s(${ROLE[$s]}) -> n$d(${ROLE[$d]}): ping [$a] pod tcp [$b] service [$c]"
      done
    done
    say "from the test pod of each node: the API Service and a name lookup"
    for s in $(printf '%s\n' "${!NAME[@]}" | sort -n); do
      echo "n$s(${ROLE[$s]}): api [$(texec "$s" curl -sk -m 5 -o /dev/null -w 'http %{http_code} remote %{remote_ip}' "https://$(gk -n default get service kubernetes -o jsonpath='{.spec.clusterIP}' </dev/null):443/version" </dev/null 2>&1 | tail -1)] dns [$(texec "$s" timeout 12 getent hosts kubernetes.default.svc.cluster.local </dev/null 2>&1 | tail -1 | cut -c1-80)]"
    done
    say "where the DNS pods are"
    gk -n kube-system get endpointslices -l kubernetes.io/service-name=kube-dns -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{" ready="}{.conditions.ready}{" node="}{.nodeName}{"\n"}{end}' 2>&1
  } 2>&1 | tee "$D/traffic-$label.txt"
  {
    say "summary of the matrix ($label)"
    for pair in "cp cp" "cp worker" "worker cp" "worker worker"; do
      set -- $pair
      echo "$1 -> $2: $(grep -E "^n[0-9]+\($1\) -> n[0-9]+\($2\):" "$D/traffic-$label.txt" | grep -c -E '3 of 3 answers.*http 200.*http 200') of $(grep -c -E "^n[0-9]+\($1\) -> n[0-9]+\($2\):" "$D/traffic-$label.txt") lines pass (ping 3 of 3, pod tcp 200, Service 200)"
    done
    echo "name lookup: $(grep -c -E '^n[0-9]+\((cp|worker)\): .*dns \[[0-9.]+ +kubernetes' "$D/traffic-$label.txt") of $(grep -c -E '^n[0-9]+\((cp|worker)\): api' "$D/traffic-$label.txt") nodes; API Service: $(grep -c -E '^n[0-9]+\((cp|worker)\): api \[http 200' "$D/traffic-$label.txt") of $(grep -c -E '^n[0-9]+\((cp|worker)\): api' "$D/traffic-$label.txt") nodes"
  } | tee "$D/traffic-$label-summary.txt"
}

# Pass rule 3: through each API server, one at a time: logs, exec and a port forward to the test
# pod on each worker. And the source address that the kubelet of the worker sees for the call.
cmd_rule3() {
  local label=${1:-now} fail=0 i name role ip wi wname wrole wip w srv line pf port=18471 peers
  tnodes
  {
    say "pass rule 3 ($label) at $(now): logs, exec and port forward to a pod on each worker, through each API server"
    echo "kubelet address types of the API servers: $(k -n d exec "$(awk '$3=="cp" {print $2; exit}' "$TN")" -- sh -c 'grep -o -- "--kubelet-preferred-address-types=[^ ]*" /etc/kubernetes/manifests/kube-apiserver.yaml' </dev/null 2>&1)"
    while read -r wi wname wrole wip; do
      [ "$wrole" = worker ] || continue
      w=$(docker ps --filter label=nvidia.com/nico-containers.managed=true --filter "label=nvidia.com/nico-containers.instance-name=$wname" --format '{{.Names}}' | head -1)
      echo "=== worker n$wi $wname: Node addresses [$(gk get node "$wname" -o jsonpath='{range .status.addresses[*]}{.type}{"="}{.address}{" "}{end}' </dev/null)], test pod p3-t-$wi $(tpod_ip "$wi" </dev/null), container $w"
      texec "$wi" curl -s -m 3 -o /dev/null http://127.0.0.1:8080/ping.py </dev/null 2>/dev/null || true   # one line in the pod log
      echo "connections to the kubelet port 10250 of the worker before the calls: [$(docker exec "$w" ss -Htn state established '( sport = :10250 )' </dev/null 2>&1 | awk '{print $NF}' | sed -E 's/:[0-9]+$//' | sort | uniq -c | awk '{print $2 " x" $1}' | tr '\n' ' ')]"
      while read -r i name role ip; do
        [ "$role" = cp ] || continue
        srv="https://$ip:6443"
        echo "--- through the API server of n$i $name ($srv)"
        line=$(gk --server "$srv" -n default logs "p3-t-$wi" --tail=1 </dev/null 2>&1 | tail -1 | cut -c1-110)
        case "$line" in *"GET /"* | *"Serving HTTP"*) echo "ok   logs: [$line]" ;; *) echo "FAIL logs: [$line]"; fail=1 ;; esac
        line=$(gk --server "$srv" -n default exec "p3-t-$wi" -- sh -c 'echo "exec in $(hostname)"' </dev/null 2>&1 | tail -1 | cut -c1-110)
        case "$line" in "exec in p3-t-$wi"*) echo "ok   exec: [$line]" ;; *) echo "FAIL exec: [$line]"; fail=1 ;; esac
        # The source address: a long exec, and the peers of port 10250 in the worker while it runs.
        ( gk --server "$srv" --request-timeout=20s -n default exec "p3-t-$wi" -- sleep 4 </dev/null >/dev/null 2>&1 ) &
        sleep 2
        peers=$(docker exec "$w" ss -Htn state established '( sport = :10250 )' </dev/null 2>&1 | awk '{print $NF}' | sed -E 's/:[0-9]+$//' | sort | uniq -c | awk '{print $2 " x" $1}' | tr '\n' ' ')
        wait
        echo "     the kubelet of the worker sees the call from: [$peers]"
        port=$((port + 1))
        gk --server "$srv" --request-timeout=30s -n default port-forward "pod/p3-t-$wi" "$port:8080" </dev/null >"$D/.pf.out" 2>&1 &
        pf=$!
        sleep 3
        line=$(curl -s -m 5 -o /dev/null -w 'http %{http_code} in %{time_total} s' "http://127.0.0.1:$port/ping.py" 2>&1 | tail -1)
        kill "$pf" 2>/dev/null; wait "$pf" 2>/dev/null
        case "$line" in "http 200"*) echo "ok   port forward (local port $port to 8080 of the pod): [$line]" ;; *) echo "FAIL port forward: [$line] [$(head -2 "$D/.pf.out" | tr '\n' ' ' | cut -c1-160)]"; fail=1 ;; esac
      done <"$TN"
    done <"$TN"
    [ "$fail" = 0 ] && echo "RESULT rule3 $label: PASS" || echo "RESULT rule3 $label: FAIL"
  } 2>&1 | tee "$D/rule3-$label.txt"
}

# The numbers of the two watches of now. It stops nothing.
cmd_watch_summary() {
  local label=${1:-now} f r
  f="$D/probe-$run-$label.txt"
  r="$D/ready-$run.txt"
  docker exec "$KIND_NODE" cat "/var/tmp/p2gaps-probe-$run.log" >"$f" 2>/dev/null
  {
    say "the each-second call to the shared address, run $run, read at $(now) ($label). One line for each time range with the same answer"
    awk 'function show() { printf "%s  %s to %s  %4d calls\n", (st=="200" ? "answer 200" : "FAILED " st), substr(t0, 12, 8), substr(t1, 12, 8), c }
         { code=$2; for (i=3; i<=NF; i++) code=code " " $i
           n++; by[code]++
           if (code=="200") g++; else b++
           if (NR>1 && code!=st) { show(); c=0 }
           if (c==0) t0=$1
           st=code; t1=$1; c++ }
         END { if (n) show(); s=""; for (x in by) s=s sprintf(" [%s] %d", x, by[x]); printf "by answer:%s\n", s; printf "calls %d, answer 200: %d, failed: %d\n", n, g, b }' "$f"
    echo "calls with another answer than 200 after the first answer 200: $(awk '$2=="200" {ok=1} ok && $2!="200"' "$f" | wc -l)"
    say "the Ready watch: each change (UTC)"
    cut -c1-170 "$r"
    say "time ranges in which a Node that was Ready was not Ready"
    awk '$2=="node" && $5 ~ /^Ready=/ { n=$3; st=substr($5, 7); was=substr($6, 5)
           if (st!="True" && was=="True") { from[n]=$1; r[n]=$4; s[n]=st }
           else if (st!="True" && (n in from)) { s[n]=s[n] "," st }
           else if (st=="True" && (n in from)) { print n, r[n], s[n], from[n], $1; delete from[n] } }
         $2=="node" && $5=="gone" { n=$3; if (n in from) { print n, r[n], s[n], from[n], $1, "gone"; delete from[n] } }
         END { for (n in from) print n, r[n], s[n], from[n], "open" }' "$r" | tee "$D/.ranges"
    [ -s "$D/.ranges" ] || echo "none"
    echo "time in which the list of the Nodes did not come: $(grep -c ' api no answer$' "$r") start(s)"
    echo "watch processes: $(pgrep -f "ready-watch.sh .*ready-$run.txt" | wc -l) Ready watch, probe unit $(docker exec "$KIND_NODE" systemctl is-active "$(cat "$D/.probe-unit-$run").service" 2>&1)"
  } | tee "$D/watch-summary-$label.txt"
}

# --- pass rule 4: workers through the NVKE API ---------------------------------------------------
pool_id() { api get "/api/nodePools?clusterID=$(cid)" 2>/dev/null | body | jq -r '(.nodePools // .)[0].id'; }
node_id() { api get "/api/nodes?clusterID=$(cid)" 2>/dev/null | body | jq -r --arg n "$1" '(.nodes // [])[] | select(.name==$n) | .id'; }
cmd_scale() { # <count> [label]
  local n=${1:?count} label
  label=${2:-scale-$n}
  "$P3/requests/render.sh" scale "$D" "$n" >/dev/null || return 1
  date -u +%FT%T.%3NZ >"$D/$label-time.txt"
  api patch "/api/nodePools/$(pool_id)" "$D/pool-scale-$n.json" >"$D/$label-response.txt" 2>&1
  echo "PATCH /api/nodePools/<pool ID> with $(jq -c . "$D/pool-scale-$n.json") at $(cat "$D/$label-time.txt"): $(tail -1 "$D/$label-response.txt")" | tee -a "$D/timeline.txt"
  grep -q '^HTTP 20[0-9]$' "$D/$label-response.txt" || { body <"$D/$label-response.txt" | cut -c1-600; return 1; }
}
# The facts of one worker that the check after its removal needs.
cmd_node_facts() { # <node name> <label>
  local name=${1:?node name} label=${2:?label}
  {
    echo "name=$name"
    echo "id=$(node_id "$name")"
    echo "instance=$(k -n "$CAPI_NS" get nicomachine "$name" -o jsonpath='{.status.instanceID}' 2>/dev/null)"
    echo "container=$(docker ps -a --filter label=nvidia.com/nico-containers.managed=true --filter "label=nvidia.com/nico-containers.instance-name=$name" --format '{{.Names}}' | head -1)"
    echo "address=$(k -n "$CAPI_NS" get nicomachine "$name" -o jsonpath='{.status.addresses[0].address}' 2>/dev/null)"
  } >"$D/node-$label.env"
  cat "$D/node-$label.env" | tr '\n' ' '; echo
}
cmd_node_delete() { # <node name> <label>
  local name=${1:?node name} label=${2:?label} id
  cmd_node_facts "$name" "$label" >/dev/null
  id=$(sed -n 's/^id=//p' "$D/node-$label.env")
  [ -n "$id" ] || { echo "NVKE has no node $name"; return 1; }
  date -u +%FT%T.%3NZ >"$D/$label-time.txt"
  api delete "/api/nodes/$id" >"$D/$label-response.txt" 2>&1
  echo "DELETE /api/nodes/$id ($name) at $(cat "$D/$label-time.txt"): $(tail -1 "$D/$label-response.txt")" | tee -a "$D/timeline.txt"
  grep -q '^HTTP 20[0-9]$' "$D/$label-response.txt" || { body <"$D/$label-response.txt" | cut -c1-600; return 1; }
}
# Pass rule 4, the removal: nothing of the worker is left.
cmd_gone_check() { # <label of node-facts or node-delete>
  local label=${1:?label} fail=0 name id instance container address holder
  # shellcheck disable=SC1090
  . "$D/node-$label.env"
  {
    say "what is left of the worker $name ($label) at $(now)"
    if gk get node "$name" >/dev/null 2>&1; then echo "FAIL the Node $name exists in the new cluster"; fail=1; else echo "ok   no Node $name in the new cluster"; fi
    if [ -n "$(node_id "$name")" ]; then echo "FAIL NVKE lists the node $name"; fail=1; else echo "ok   NVKE does not list the node $name"; fi
    case "$(api get "/api/nodes/$id" 2>/dev/null | tail -1)" in "HTTP 404") echo "ok   GET /api/nodes/$id gives 404" ;; *) echo "FAIL GET /api/nodes/$id gives $(api get "/api/nodes/$id" 2>/dev/null | tail -1)"; fail=1 ;; esac
    if k -n "$CAPI_NS" get machines.cluster.x-k8s.io "$name" >/dev/null 2>&1; then echo "FAIL the Machine $name exists"; fail=1; else echo "ok   no Machine $name"; fi
    if k -n "$CAPI_NS" get nicomachine "$name" >/dev/null 2>&1; then echo "FAIL the NicoMachine $name exists"; fail=1; else echo "ok   no NicoMachine $name"; fi
    if sim_get instance 2>/dev/null | jq -e --arg i "$instance" '[.[] | select(.id==$i)] | length > 0' >/dev/null; then echo "FAIL the simulator has the instance $instance"; fail=1; else echo "ok   the simulator has no instance $instance"; fi
    if [ -n "$(docker ps -a --filter "name=^${container}$" --format '{{.Names}}')" ]; then echo "FAIL the container $container exists in Docker"; fail=1; else echo "ok   no container $container in Docker (running or stopped)"; fi
    holder=$(docker ps -aq | xargs -r docker inspect --format '{{.Name}} {{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' 2>/dev/null | awk -v a="$address" '{for (i=2; i<=NF; i++) if ($i==a) print substr($1, 2)}' | head -1)
    if [ -z "$holder" ]; then echo "ok   no container holds the address $address"
    elif [ "$holder" = "$container" ]; then echo "FAIL the container $container holds the address $address"; fail=1
    else echo "ok   the address $address is free of the old worker. The new worker $holder has it now"; fi
    echo "simulator calls for the instance: $(docker logs "$SIM_NAME" 2>&1 | grep -F "$instance" | sed -E 's/^(..:..:..) .*method=([A-Z]+) path=[^ ]*instance\/[0-9a-f-]*([^ ]*) status=([0-9]+).*/\1 \2\3 \4/' | tr '\n' ';')"
    if k get clusterstaticentry "host-$id" >/dev/null 2>&1; then echo "note the SPIRE entry host-$id exists"; else echo "ok   no SPIRE entry host-$id"; fi
    [ "$fail" = 0 ] && echo "RESULT gone-check $label: PASS" || echo "RESULT gone-check $label: FAIL"
  } 2>&1 | tee "$D/gone-$label.txt"
}

# Pass rule 5: did the kubelet of a worker keep its connection to the shared address during a flow.
cmd_kubelet_errors() { # <label> <since, UTC, "YYYY-MM-DD HH:MM:SS"> [until]
  local label=${1:?label} since=${2:?since} until=${3:-} w a=()
  [ -z "$until" ] || a=(--until "$until")
  {
    say "kubelet of each worker from $since to ${until:-now} UTC ($label), read at $(now)"
    for w in $(workers); do
      docker exec "$w" journalctl -u kubelet --no-pager -o cat --since "$since" "${a[@]}" >"$D/.kubelet-$w.log" 2>&1
      echo "--- $w: $(wc -l <"$D/.kubelet-$w.log") journal lines, kubelet active since $(docker exec "$w" systemctl show kubelet -p ActiveEnterTimestamp --value 2>&1), restarts of the unit $(docker exec "$w" systemctl show kubelet -p NRestarts --value 2>&1)"
      echo "    lines about the lease: $(grep -c -i 'lease' "$D/.kubelet-$w.log"); about the node status: $(grep -c -i -E 'node status|Unable to register|nodestatus' "$D/.kubelet-$w.log"); connection errors (refused, reset, EOF, timeout, handshake): $(grep -c -i -E 'connection refused|connection reset|unexpected EOF|: EOF|i/o timeout|TLS handshake|context deadline exceeded|http2: client connection lost|no route to host' "$D/.kubelet-$w.log")"
      grep -i -E 'lease|node status|connection refused|connection reset|unexpected EOF|: EOF|i/o timeout|TLS handshake|context deadline exceeded|http2: client connection lost|no route to host' "$D/.kubelet-$w.log" | sed -E 's/^[IEW][0-9]+ +([0-9:.]+) +[0-9]+ /\1 /' | cut -c1-260 | head -12
    done
    say "the node leases now"
    gk -n kube-node-lease get leases -o json | jq -r '.items[] | "\(.metadata.name) renewTime \(.spec.renewTime) holder \(.spec.holderIdentity)"'
  } 2>&1 | tee "$D/kubelet-errors-$label.txt"
}

# --- the reboot try ------------------------------------------------------------------------------
# NVKE has no reboot call in its REST API. The request is the label nvke.nvidia.com/reboot on the
# Node of the new cluster (the same request as in the worker test of phase 2).
temporal() { k -n temporal exec deploy/temporal-admintools -- temporal "$@" --namespace cloud-workflow-engine --address temporal-frontend.temporal.svc.cluster.local:7233; }
wcont() { docker ps -a --filter label=nvidia.com/nico-containers.managed=true --filter "label=nvidia.com/nico-containers.instance-name=$1" --format '{{.Names}}' | head -1; }
cmd_reboot_facts() { # <node name> <label>
  local name=${1:?node} label=${2:?label} w
  w=$(wcont "$name")
  {
    say "facts of the worker $name ($label) at $(now)"
    echo "Node: Ready $(gk get node "$name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>&1), bootID $(gk get node "$name" -o jsonpath='{.status.nodeInfo.bootID}' 2>&1), InternalIP $(gk get node "$name" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>&1)"
    echo "Node labels and annotations with reboot: $(gk get node "$name" -o json 2>/dev/null | jq -c '[(.metadata.labels // {}), (.metadata.annotations // {})] | map(to_entries[] | select(.key | test("reboot")) | "\(.key)=\(.value)")')"
    echo "Machine annotations with reboot: $(k -n "$CAPI_NS" get machines.cluster.x-k8s.io "$name" -o json 2>/dev/null | jq -c '[(.metadata.annotations // {}) | to_entries[] | select(.key | test("reboot")) | "\(.key)=\(.value)"]')"
    echo "NicoMachine: $(k -n "$CAPI_NS" get nicomachine "$name" -o json 2>/dev/null | jq -c '{ready: .status.ready, instanceID: .status.instanceID, annotations: [(.metadata.annotations // {}) | to_entries[] | select(.key | test("reboot")) | "\(.key)=\(.value)"], status: (.status | with_entries(select(.key | test("eboot"))))}')"
    echo "container $w: $(docker inspect "$w" 2>/dev/null | jq -r '.[0] | "state \(.State.Status), started \(.State.StartedAt), finished \(.State.FinishedAt), exit code \(.State.ExitCode), restarts \(.RestartCount)"')"
    echo "boot ID in the container: $(docker exec "$w" cat /proc/sys/kernel/random/boot_id 2>&1); files of the simulator: $(docker exec "$w" sh -c 'ls /var/lib/nico-containers/ | tr "\n" " "' 2>&1)"
    echo "interfaces: $(docker exec "$w" ip -o -4 addr show 2>&1 | awk '$2!="lo" && $2 !~ /^(ovn|br-|genev|ovs)/ {print $2 "=" $4}' | tr '\n' ' ')"
    echo "default route: $(docker exec "$w" ip -4 route show default 2>&1 | head -1)"
    echo "hosts lines of the host name: $(docker exec "$w" sh -c 'grep "$(hostname)" /etc/hosts | awk "{print \$1}" | tr "\n" " "' 2>&1)"
    echo "old-ipv4: $(docker exec "$w" cat /kind/old-ipv4 2>&1)"
    echo "kubelet flags: $(docker exec "$w" cat /var/lib/kubelet/kubeadm-flags.env 2>&1 | cut -c1-200)"
    echo "units: $(for u in nke-container-network ovs-vswitchd spire-agent nvke-agent kubelet containerd; do printf '%s=%s ' "$u" "$(docker exec "$w" systemctl is-active "$u" 2>&1)"; done) failed [$(docker exec "$w" systemctl --failed --no-legend --plain 2>&1 | awk '{print $1}' | tr '\n' ' ')]"
    echo "systemd start: $(docker exec "$w" systemctl show -p UserspaceTimestamp --value 2>&1); agent start: $(docker exec "$w" systemctl show nvke-agent -p ActiveEnterTimestamp --value 2>&1); mlx5 lines in the agent journal: $(docker exec "$w" journalctl -u nvke-agent --no-pager 2>/dev/null | grep -c 'mlx5 rescan is disabled')"
    echo "Open vSwitch: system ID $(docker exec "$w" ovs-vsctl get Open_vSwitch . external_ids:system-id 2>&1 | tr -d '"'), tunnel address $(docker exec "$w" ovs-vsctl get Open_vSwitch . external_ids:ovn-encap-ip 2>&1 | tr -d '"'), tunnel ports $(docker exec "$w" ovs-vsctl --format=csv --no-headings --columns=name find interface type=geneve 2>/dev/null | wc -l)"
    echo "pods on the node:"
    gk get pods -A -o json --field-selector "spec.nodeName=$name" 2>/dev/null | jq -r '.items[] | "   \(.metadata.namespace)/\(.metadata.name) uid \(.metadata.uid[0:8]) phase \(.status.phase) ready \([.status.containerStatuses[]? | select(.ready)] | length)/\(.status.containerStatuses | length) restarts \([.status.containerStatuses[]?.restartCount] | add)"'
  } 2>&1 | tee "$D/reboot-facts-$label.txt"
}
cmd_reboot() { # <node name> <label> [seconds to watch]
  local name=${1:?node} label=${2:?label} secs=${3:-600} id wid w inst end last="" line st t0
  id=$(node_id "$name"); wid="reboot-node-$id"; w=$(wcont "$name")
  inst=$(k -n "$CAPI_NS" get nicomachine "$name" -o jsonpath='{.status.instanceID}')
  cmd_reboot_facts "$name" "$label-before" >/dev/null
  {
    say "reboot request ($label) for the worker $name (NVKE node $id, instance $inst, container $w) at $(now)"
    echo "the request: label nvke.nvidia.com/reboot=p3-$label on the Node"
    date -u +%FT%T.%3NZ >"$D/reboot-$label-time.txt"
    gk label node "$name" "nvke.nvidia.com/reboot=p3-$label" 2>&1 | tail -1
    t0=$(date +%s); end=$((t0 + secs))
    while [ "$(date +%s)" -lt "$end" ]; do
      temporal workflow describe --workflow-id "$wid" --output json >"$D/.wf.json" 2>/dev/null || echo '{}' >"$D/.wf.json"
      st=$(jq -r '(.workflowExecutionInfo.status // "none") | sub("WORKFLOW_EXECUTION_STATUS_"; "")' "$D/.wf.json" 2>/dev/null)
      line="workflow=$st pending=[$(jq -r '[(.pendingActivities // [])[] | "\(.activityType.name) attempt \(.attempt // 1)"] | join(",")' "$D/.wf.json" 2>/dev/null)]"
      line="$line | node Ready=$(gk get node "$name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null) bootID=$(gk get node "$name" -o jsonpath='{.status.nodeInfo.bootID}' 2>/dev/null | cut -c1-8) labels=[$(gk get node "$name" -o json 2>/dev/null | jq -r '[(.metadata.labels // {}) | to_entries[] | select(.key | test("reboot")) | "\(.key | sub("nvke.nvidia.com/"; ""))=\(.value)"] | join(" ")')]"
      line="$line | machine annotation=[$(k -n "$CAPI_NS" get machines.cluster.x-k8s.io "$name" -o json 2>/dev/null | jq -r '[(.metadata.annotations // {}) | to_entries[] | select(.key | test("reboot")) | "\(.key | sub("nvke.nvidia.com/"; ""))=\(.value)"] | join(" ")')]"
      line="$line | nvke=[$(api get "/api/nodes/$id" 2>/dev/null | body | jq -r '[.conditions | to_entries[] | select(.value.status=="True") | .key] | join("+")' 2>/dev/null)]"
      line="$line | container started=$(docker inspect -f '{{.State.StartedAt}}' "$w" 2>/dev/null | cut -c12-19) restarts=$(docker inspect -f '{{.RestartCount}}' "$w" 2>/dev/null) state=$(docker inspect -f '{{.State.Status}}' "$w" 2>/dev/null) boot=$(docker exec "$w" cat /proc/sys/kernel/random/boot_id 2>/dev/null | cut -c1-8)"
      line="$line | simulator calls for the instance=$(docker logs "$SIM_NAME" 2>&1 | grep -c -F "$inst")"
      if [ "$line" != "$last" ]; then echo "$(date -u +%T) +$(( $(date +%s) - t0 ))s $line"; last=$line; fi
      case "$st" in COMPLETED | FAILED | CANCELED | TERMINATED | TIMED_OUT) [ -n "${ended:-}" ] && break; ended=1 ;; esac
      sleep 5
    done
    say "end of the watch at $(now), $(( $(date +%s) - t0 )) s after the request"
    temporal workflow describe --workflow-id "$wid" 2>&1 | grep -E '^ *(Status|StartTime|CloseTime|RunTime|HistoryLength|Type|State|Attempt|LastFailure) ' | cut -c1-400
    say "the activities of the workflow"
    temporal workflow show --workflow-id "$wid" --output json 2>/dev/null | jq -r '(.events // .)[] | select(.activityTaskScheduledEventAttributes != null or .timerStartedEventAttributes != null or .activityTaskFailedEventAttributes != null or .activityTaskTimedOutEventAttributes != null) | "\(.eventTime[11:23]) " + (if .activityTaskScheduledEventAttributes then "scheduled " + .activityTaskScheduledEventAttributes.activityType.name elif .timerStartedEventAttributes then "timer " + (.timerStartedEventAttributes.startToFireTimeout // "") elif .activityTaskFailedEventAttributes then "FAILED " + ((.activityTaskFailedEventAttributes.failure.message // "") | .[0:160]) else "TIMED OUT " + ((.activityTaskTimedOutEventAttributes.failure.message // "") | .[0:120]) end)' 2>/dev/null | tail -40
    say "simulator calls for the instance"
    docker logs "$SIM_NAME" 2>&1 | grep -F "$inst" | sed -E 's/ component=http//; s/ duration=.*//' | cut -c1-200 | tail -8
    say "CAPNICo lines for the machine since the request (not the reconcile lines)"
    k -n "$CAPNICO_NS" logs deployment/capnico-controller-manager --since-time="$(cut -c1-19 "$D/reboot-$label-time.txt")Z" 2>/dev/null | grep -F "$name" | jq -r 'select(.msg | test("reconciling NicoMachine") | not) | "\(.ts) \(.level) \(.msg) \(.error // "")"' 2>/dev/null | cut -c1-260 | tail -12
    say "NVKE controller lines about the reboot since the request (count by message)"
    k -n nvke-controller logs deployment/nvke-controller --since-time="$(cut -c1-19 "$D/reboot-$label-time.txt")Z" 2>/dev/null | grep -i -E 'reboot' | jq -r '"\(.level) \(.msg)"' 2>/dev/null | sort | uniq -c | sort -rn | cut -c1-200 | head -14
    say "the console of the container since the request (last 25 lines with reboot, shutdown, Reached, Stopping, Starting kubelet, entrypoint)"
    docker logs --since "$(cut -c1-19 "$D/reboot-$label-time.txt")Z" "$w" 2>&1 | tr -d '\r' | grep -i -E 'reboot|shutdown|power|Reached target|INFO:|detected|ipv4|Welcome|systemd [0-9]' | cut -c1-160 | tail -25
  } 2>&1 | tee "$D/reboot-$label.txt"
  cmd_reboot_facts "$name" "$label-after" >/dev/null
  say "what changed (before, after)"
  diff <(sed 1d "$D/reboot-facts-$label-before.txt") <(sed 1d "$D/reboot-facts-$label-after.txt") | cut -c1-260 | tee "$D/reboot-$label-diff.txt"
}

# --- facts for the Konnectivity decision: which connections the direct path uses -------------------
cmd_konn() { # <label>
  local label=${1:-now} i name role ip wi wname wrole wip w srv line src
  tnodes
  {
    say "connections of the direct path ($label) at $(now)"
    echo "addresses by kind: 172.28.1.x node address of a control plane node; 172.28.2.x node address of a worker; 172.29.2.x address of a worker on the network of the shared address; 172.29.255.220 the shared address; 172.29.0.x and 172.28.0.x a kind host node; 10.113.N.2 the OVN management port of the node with the pod subnet 10.113.N.0/24; 10.112.0.1 the API Service"
    cat "$TN"
    echo "endpoints of the Service kubernetes: $(gk -n default get endpointslices -l kubernetes.io/service-name=kubernetes -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{" "}{end}{range .items[*].ports[*]}{"port "}{.port}{end}')"
    echo "API server flags: $(k -n d exec "$(awk '$3=="cp" {print $2; exit}' "$TN")" -- sh -c 'grep -o -E -- "--(kubelet-preferred-address-types|advertise-address|egress-selector-config-file|enable-aggregator-routing)=[^ ]*" /etc/kubernetes/manifests/kube-apiserver.yaml | tr "\n" " "' </dev/null 2>&1)"
    echo "konnectivity pods in the cluster: $(gk get pods -A --no-headers 2>/dev/null | grep -c -i konnectivity)"
    while read -r wi wname wrole wip; do
      [ "$wrole" = worker ] || continue
      w=$(wcont "$wname")
      echo "=== worker n$wi $wname ($wip), container $w"
      echo "1. worker to the API server (port 6443): process, local address, target, count"
      docker exec "$w" ss -Htnp state established '( dport = :6443 )' </dev/null 2>&1 | sed -E 's/users:\(\("([^"]*)".*/\1/' | awk '{l=$(NF-2); p=$(NF-1); sub(/:[0-9]+$/, "", l); print "   " $NF, l, "->", p}' | sort | uniq -c | awk '{print "  ", $2, $3, $4, $5, "x" $1}'
      echo "2. NVKE controller to the agent of the worker (port 15005): the worker sees the call from [$(docker exec "$w" ss -Htn state established '( sport = :15005 )' </dev/null 2>&1 | awk '{print $NF}' | sed -E 's/:[0-9]+$//' | sort | uniq -c | awk '{print $2 " x" $1}' | tr '\n' ' ')] (a connection lives only for a call)"
      echo "3. SPIRE agent of the worker to the SPIRE server: [$(docker exec "$w" ss -Htnp state established </dev/null 2>&1 | grep spire-agent | awk '{l=$(NF-2); sub(/:[0-9]+$/, "", l); print l " -> " $(NF-1)}' | sort -u | tr '\n' ' ')]"
      echo "4. API server to a pod on the worker (pod proxy and Service proxy), through each API server: what the pod sees as source"
      while read -r i name role ip; do
        [ "$role" = cp ] || continue
        srv="https://$ip:6443"
        line=$(gk --server "$srv" get --raw "/api/v1/namespaces/default/pods/p3-t-$wi:8080/proxy/ping.py" </dev/null 2>&1 | head -1 | cut -c1-40)
        src=$(gk -n default logs "p3-t-$wi" --tail=1 </dev/null 2>/dev/null | awk '{print $1}')
        echo "   through $ip: pod proxy first line [$line], source $src"
        line=$(gk --server "$srv" get --raw "/api/v1/namespaces/default/services/p3-t-$wi:80/proxy/ping.py" </dev/null 2>&1 | head -1 | cut -c1-40)
        src=$(gk -n default logs "p3-t-$wi" --tail=1 </dev/null 2>/dev/null | awk '{print $1}')
        echo "   through $ip: Service proxy first line [$line], source $src"
      done <"$TN"
      echo "5. the kubelet port 10250 of the worker during an exec through each API server: see rule3-*.txt"
      echo "6. tunnels (UDP 6081, Geneve): local address $(docker exec "$w" ovs-vsctl get Open_vSwitch . external_ids:ovn-encap-ip </dev/null 2>&1 | tr -d '"'), remote addresses [$(docker exec "$w" ovs-vsctl --format=csv --no-headings --columns=options find interface type=geneve </dev/null 2>&1 | grep -o 'remote_ip=""[0-9.]*' | sed 's/remote_ip=""//' | sort -t. -k3n -k4n | tr '\n' ' ')]"
    done <"$TN"
    echo "=== a control plane node"
    name=$(awk '$3=="cp" {print $2; exit}' "$TN")
    echo "7. kubelet and other clients of the control plane node $name to an API server: [$(k -n d exec "$name" -- ss -Htnp state established '( dport = :6443 )' </dev/null 2>&1 | sed -E 's/users:\(\("([^"]*)".*/\1/' | awk '{l=$(NF-2); p=$(NF-1); sub(/:[0-9]+$/, "", l); print $NF, l, "->", p}' | sort | uniq -c | awk '{print $2, $3, $4, $5, "x" $1}' | tr '\n' ';')]"
  } 2>&1 | tee "$D/konn-$label.txt"
}

# --- the worker starts of a run (the test of the simulator fix) ----------------------------------
# One record for each worker container, taken while the container exists: the times of the start,
# the line of the simulator about systemd, the simulated cloud-init, and the workflow of the node.
tsec() { date -u -d "$1" +%s.%N; }
cmd_starts() {
  local w id short name nid started runcmd outlog status sock simline wf pre join good
  touch "$D/starts.txt"
  for w in $(workers); do
    grep -q "^container=$w " "$D/starts.txt" && continue
    id=$(docker inspect -f '{{.Id}}' "$w"); short=${id:0:12}
    name=$(docker inspect -f '{{index .Config.Labels "nvidia.com/nico-containers.instance-name"}}' "$w")
    nid=$(node_id "$name")
    started=$(docker inspect -f '{{.State.StartedAt}}' "$w")
    [ "$(docker inspect -f '{{.RestartCount}}' "$w")" = 0 ] || { echo "$w has restarts, no record"; continue; }
    status=$(docker exec "$w" cat /var/lib/nico-containers/cloud-init/status 2>/dev/null | tr -d '\n')
    [ "$status" = running ] && { echo "$w: the simulated cloud-init runs, no record yet"; continue; }
    runcmd=$(docker exec "$w" sh -c 'TZ=UTC stat -c %y /var/lib/nico-containers/cloud-init/runcmd.sh' 2>/dev/null)
    outlog=$(docker exec "$w" sh -c 'TZ=UTC stat -c %y /var/lib/nico-containers/cloud-init/output.log' 2>/dev/null)
    sock=$(docker exec "$w" sh -c 'TZ=UTC stat -c %y /run/systemd/private' 2>/dev/null)
    simline=$(docker logs "$SIM_NAME" 2>&1 | grep 'systemd is ready for cloud-init commands' | grep -F "$short" | tail -1 | sed -E 's/ component=[^ ]*//; s/ container_id=[^ ]*//' | cut -c1-200)
    [ -n "$simline" ] || simline=$(docker logs "$SIM_NAME" 2>&1 | grep 'systemd is ready for cloud-init commands' | grep -F "${id:0:8}" | tail -1 | cut -c1-200)
    wf=""
    for x in "provision-node-$nid" "join-node-$nid"; do
      wf="$wf $(temporal workflow show --workflow-id "$x" --output json 2>/dev/null | jq -r '(.events // .) as $e | ($e | map(select(.activityTaskScheduledEventAttributes != null) | {key: (.eventId | tostring), value: .activityTaskScheduledEventAttributes.activityType.name}) | from_entries) as $n | [$e[] | select(.activityTaskStartedEventAttributes != null) | .activityTaskStartedEventAttributes | {name: $n[(.scheduledEventId | tostring)], attempt: (.attempt // 1), fail: ((.lastFailure.message // "") | .[0:70])} | select(.name | test("Preflight|Join"))] | map("\(.name) attempt \(.attempt)" + (if .fail != "" then " after [\(.fail)]" else "" end)) | join("; ")' 2>/dev/null)"
    done
    good=$(api get "/api/nodes/$nid" 2>/dev/null | body | jq -r 'if (.conditions.joined.status=="True" and .conditions.kubernetesReady.status=="True" and .conditions.nodeAgentReady.status=="True" and .conditions.provisioned.status=="True") then "good" else "not good yet" end' 2>/dev/null)
    echo "container=$w node=$name nvke=[$good] started=$started first-command=${outlog:-none} start-to-first-command=$(echo "$(tsec "$outlog") $(tsec "$started")" | awk '{printf "%.3f", $1-$2}')s runcmd-written=$(echo "$(tsec "$runcmd") $(tsec "$started")" | awk '{printf "%.3f", $1-$2}')s socket=$(echo "$(tsec "$sock") $(tsec "$started")" | awk '{printf "%.3f", $1-$2}')s status=[$status] output=[$(docker exec "$w" cat /var/lib/nico-containers/cloud-init/output.log 2>/dev/null | tr '\n' ';' | cut -c1-120)] commands=[$(docker exec "$w" grep -c '^sh -lc' /var/lib/nico-containers/cloud-init/runcmd.sh 2>/dev/null)] simulator=[$simline] workflow=[$(echo "$wf" | sed 's/^ *//; s/  */ /g')] mlx5=[$(docker exec "$w" journalctl -u nvke-agent --no-pager 2>/dev/null | grep -c 'mlx5 rescan is disabled')]" >>"$D/starts.txt"
  done
  cat "$D/starts.txt"
}

case "$step" in
  post) shift 2; cmd_post "$@" ;;
  watch) shift 2; cmd_watch "$@" ;;
  line) look; state_line ;;
  snap) shift 2; cmd_snap "$@" ;;
  kc) cmd_kc ;;
  ready-start) cmd_ready_start ;;
  stop-watches) cmd_stop_watches ;;
  worker-facts) shift 2; cmd_worker_facts "$@" ;;
  modules) shift 2; cmd_modules "$@" ;;
  watch-summary) shift 2; cmd_watch_summary "$@" ;;
  kubelet-errors) shift 2; cmd_kubelet_errors "$@" ;;
  reboot) shift 2; cmd_reboot "$@" ;;
  reboot-facts) shift 2; cmd_reboot_facts "$@" ;;
  konn) shift 2; cmd_konn "$@" ;;
  starts) cmd_starts ;;
  scale) shift 2; cmd_scale "$@" ;;
  node-facts) shift 2; cmd_node_facts "$@" ;;
  node-delete) shift 2; cmd_node_delete "$@" ;;
  gone-check) shift 2; cmd_gone_check "$@" ;;
  tpods) cmd_tpods ;;
  tunnels) shift 2; cmd_tunnels "$@" ;;
  traffic) shift 2; cmd_traffic "$@" ;;
  rule3) shift 2; cmd_rule3 "$@" ;;
  *) sed -n '2,31p' "$0"; exit 1 ;;
esac
