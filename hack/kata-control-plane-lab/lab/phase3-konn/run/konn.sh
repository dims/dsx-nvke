#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# konn.sh: the lab driver of the Konnectivity prototype of phase 3. It runs on the second machine.
# It builds on the phase 3 driver p3/run/p3ab.sh as it is (steps watch, kc, tpods, rule3, snap,
# stop-watches) and does not change it. A run folder is /root/kata-cp/logs/p3/<run>, as there.
#
# Changes that this script makes, and only when its step is called:
#   sim start      the simulator container again, with the settings for ONE network
#   policy apply   one NetworkPolicy in the namespace of the control plane pods (host cluster)
#   port add       one more port (8132) on the lab Service of the shared address
#   post           the base check of the lab and one POST /api/clusters
#   agent apply    one ServiceAccount and one DaemonSet in the NEW cluster
#   cp-count       one PATCH of the control plane count
# Each other step reads only.
#
# Steps with no run:
#   sim start|status|command|diff   the simulator with one network (kata-bb) and a fixed address
#                             for each worker, with the program docker-two-nets as it is. "diff"
#                             compares the command with the step B command of the lab
#   policy apply|delete|status      the NetworkPolicy of the design
#   port add|remove|status          the port 8132 of the lab Service
# Steps of a run:
#   post <run> <variant> [workers]  variant = direct | proxy | proxy-ds | direct-route | proxy-route
#   agent <run> apply|status|delete the agent DaemonSet of the new cluster
#   server <run> apply|status|delete   the proxy server as a DaemonSet on the control plane nodes
#                                   of the new cluster (request variant proxy-ds)
#   reach <run> <label>             NEW connections from each control plane pod to each worker
#                                   (kubelet port), and from a kind node to the node agent port
#   facts <run> <label>             the flag, the two files, the proxy server, the socket and the
#                                   tunnels of each control plane node, and the agent of each worker
#   rule <run> <label> pass|fail    the lab check rule3 (logs, exec, port forward through each API
#                                   server), judged against the expectation, and for "pass" the
#                                   address from which the kubelet of the worker sees the call
#   logs-watch <run> start|stop|summary [interval]   "logs" through each API server each few seconds
#   cp-count <run> <count>          PATCH controlPlaneConfig.desiredCount (a fourth node, and back)
#   still <run> <label>             pass rule 4: what still fails with the proxy
# Usage: konn.sh <step> ...
set -uo pipefail
export LC_ALL=C
. /root/kata-cp/bin/env.sh
. /root/kata-cp/p3/env-p3.sh
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../env-konn.sh
. "$HERE/../env-konn.sh"
P3AB=$P3/run/p3ab.sh
G=$W/p2-gaps
A=$W/d/stack/api.sh
L=$P3_LOGS
CLUSTER_NAME=${CLUSTER_NAME:-kata-cp1}
IP_API=${IP_API:-172.29.255.220}
# p3ab.sh and the phase 2 scripts read the pod image from these names.
export IMG=${IMG:-docker.io/library/$KONN_POD_IMAGE}
export IMG_CLUSTER=$IMG IMG_WORKER=$IMG
export NODE_IMAGE_REF=$IMG

now() { date -u +%FT%TZ; }
say() { echo "== $*"; }
k() { "$W/bin/kubectl" --kubeconfig "$W/secrets/kubeconfig" "$@"; }
gk() { "$W/bin/kubectl" --kubeconfig "$KCFG" --request-timeout=10s "$@"; }
api() { env -u LOG_DIR "$A" "$@"; }
body() { sed '$d'; }
workers() { docker ps -a --filter label=nvidia.com/nico-containers.managed=true --format '{{.Names}}' | sort; }
worker_ip() { docker inspect -f "{{(index .NetworkSettings.Networks \"$API_NET\").IPAddress}}" "$1" 2>/dev/null; }
cp_pods() { k -n "$KONN_NS" get pods -l cluster.x-k8s.io/control-plane -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | sort; }

# --- the simulator with one network -------------------------------------------------------------
# The command of p3/sim/run-sim.sh for step B, with these changes: the node network of the
# simulator and of docker-two-nets is kata-bb, the node address prefix is the block of this test,
# no second network, the worker image is w2, and the prefixes that the program refuses are the
# range that Docker gives out on kata-bb and the range of MetalLB.
sim_command() {
  CMD=(docker run --detach
    --name "$SIM_NAME"
    --label p3.sim-form=konn-one-net
    --network "$API_NET" --ip "$SIM_IP"
    --restart no
    --volume /var/run/docker.sock:/var/run/docker.sock
    --volume "$P3/sim:/sim:ro"
    --volume "$SIM_STATE:/state"
    --env DOCKER_HOST=unix:///var/run/docker.sock
    --env "NICO_SIM_LISTEN_ADDR=:$SIM_PORT"
    --env NICO_SIM_SEED_PATH=/sim/default-seed.yaml
    --env NICO_SIM_DB_PATH=/state/nico-sim.db
    --env NICO_SIM_FILES_DIR=/state/files
    --env NICO_SIM_LOG_FORMAT=text
    --env NO_COLOR=1
    --env NICO_VMS_VM_BACKEND=mock
    --env NICO_VMS_BGP_ENABLED=false
    --env NICO_VMS_BRIDGE_CIDR=172.30.0.0/24
    --env NICO_VMS_CONSOLE_SSH_PORT=-1
    --env NICO_CONTAINERS_ENABLED=true
    --env "NICO_CONTAINERS_NODE_IMAGE=$KONN_WORKER_IMAGE"
    --env "NICO_CONTAINERS_NODE_NETWORK=$API_NET"
    --env NICO_CONTAINERS_SPIRE_ATTESTATION_METHOD=joinToken
    --env NICO_CONTAINERS_DOCKER_BINARY=/sim/docker-two-nets
    --env NICO_CONTAINERS_REQUIRE_HEALTHY=true
    --env P3_REAL_DOCKER=docker
    --env "P3_NODE_NET=$API_NET"
    --env "P3_NODE_IP_PREFIX=$KONN_WORKER_PREFIX"
    --env P3_API_NET=
    --env "P3_IP_FIRST=$WORKER_IP_FIRST" --env "P3_IP_LAST=$WORKER_IP_LAST"
    --env "P3_NODE_IFNAME=$WORKER_NODE_IFNAME" --env P3_HOSTS_ENTRY=1
    --env "P3_FORBIDDEN_PREFIXES=172.29.0 172.29.255"
    --env P3_LOG=/state/docker-two-nets.log
    --env P3_LOCK=/state/docker-two-nets.lock
    --entrypoint /sim/nico-sim "$SIM_IMAGE")
}
print_command() {
  local i=2 n=${#CMD[@]}
  printf 'docker run'
  while [ "$i" -lt "$n" ]; do
    if [[ "${CMD[$i]}" == --* ]] && [ $((i + 1)) -lt "$n" ] && [[ "${CMD[$((i + 1))]}" != --* ]]; then
      printf ' \\\n  %s %s' "${CMD[$i]}" "${CMD[$((i + 1))]}"; i=$((i + 2))
    else
      printf ' \\\n  %s' "${CMD[$i]}"; i=$((i + 1))
    fi
  done
  printf '\n'
}
cmd_sim() {
  sim_command
  case "${1:-}" in
    command) print_command ;;
    diff) diff <("$P3/sim/run-sim.sh" command b) <(print_command) && echo "no difference to the step B command of the lab" ;;
    start)
      [ -d /sys/module/openvswitch ] || { echo "the kernel module openvswitch is not loaded. Nothing started"; return 1; }
      docker image inspect "$KONN_WORKER_IMAGE" >/dev/null 2>&1 || { echo "no image $KONN_WORKER_IMAGE in Docker. Build it first (image/build-konn-images.sh)"; return 1; }
      docker image inspect "$SIM_IMAGE" >/dev/null 2>&1 || { echo "no image $SIM_IMAGE in Docker"; return 1; }
      if docker inspect "$SIM_NAME" >/dev/null 2>&1; then echo "a container $SIM_NAME exists (form $(docker inspect -f '{{index .Config.Labels "p3.sim-form"}}' "$SIM_NAME")). Run \"$P3/sim/run-sim.sh remove\" first"; return 1; fi
      [ -z "$(workers)" ] || { echo "worker containers exist: $(workers | tr '\n' ' '). Delete the cluster through the NVKE API first"; return 1; }
      mkdir -p "$SIM_STATE/files" "$L"
      say "$(now) start of the simulator, one network"
      print_command | tee "$L/sim-run-command-konn.txt"
      "${CMD[@]}" || return 1
      sleep 3
      "$P3/sim/run-sim.sh" status
      ;;
    status) "$P3/sim/run-sim.sh" status ;;
    *) echo "sim start|status|command|diff"; return 1 ;;
  esac
}

# --- the NetworkPolicy of the host cluster ---------------------------------------------------------
cmd_policy() {
  local n
  case "${1:-}" in
    apply)
      say "$(now) NetworkPolicy $KONN_POLICY in the namespace $KONN_NS of the host cluster: no new connection from a control plane pod to $KONN_WORKER_BLOCK"
      NS=$KONN_NS WORKER_BLOCK=$KONN_WORKER_BLOCK envsubst '$NS $WORKER_BLOCK' <"$HERE/../manifests/networkpolicy-cp-egress.yaml.tmpl" | k apply -f -
      cmd_policy status
      ;;
    delete) k -n "$KONN_NS" delete networkpolicy "$KONN_POLICY" --ignore-not-found ;;
    status)
      echo "NetworkPolicy objects in $KONN_NS: [$(k -n "$KONN_NS" get networkpolicy -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>&1)] in each namespace: $(k get networkpolicy -A --no-headers 2>/dev/null | wc -l)"
      k -n "$KONN_NS" get networkpolicy "$KONN_POLICY" -o json 2>/dev/null | jq -c '{name: .metadata.name, created: .metadata.creationTimestamp, selector: .spec.podSelector, types: .spec.policyTypes, egress: .spec.egress}'
      echo "pods that it selects: [$(cp_pods | tr '\n' ' ')]"
      echo "network plugin of the host cluster: $(k -n kube-system get daemonset kindnet -o jsonpath='{.spec.template.spec.containers[0].image}' 2>&1)"
      # Reads inside the kind node containers: the table that kindnet makes for policies.
      for n in $NODES; do
        echo "$n: $(docker exec "$n" sh -c 'if command -v nft >/dev/null 2>&1; then nft list tables 2>&1 | grep -c -i network-polic; else echo "no nft program in the node"; fi' 2>&1 | tr '\n' ' ') table(s) with network-polic in the name; kindnet lines about policies: $(docker exec "$n" sh -c 'crictl logs --tail 400 "$(crictl ps --name kindnet-cni -q | head -1)" 2>&1 | grep -c -i -E "polic"' 2>&1 | tr '\n' ' ')"
      done
      ;;
    *) echo "policy apply|delete|status"; return 1 ;;
  esac
}

# --- the port of the agents on the lab Service -----------------------------------------------------
svc_json() { k -n "$KONN_NS" get service "$KONN_SERVICE" -o json; }
cmd_port() {
  local idx
  case "${1:-}" in
    add)
      svc_json >/dev/null || { echo "no Service $KONN_NS/$KONN_SERVICE (the base step of the lab makes it)"; return 1; }
      if [ -n "$(svc_json | jq -r --argjson p "$KONN_AGENT_PORT" '.spec.ports[] | select(.port==$p) | .port')" ]; then
        echo "the Service $KONN_SERVICE has the port $KONN_AGENT_PORT already"
      else
        say "$(now) one more port on the Service $KONN_NS/$KONN_SERVICE: $KONN_AGENT_PORT"
        k -n "$KONN_NS" patch service "$KONN_SERVICE" --type=json -p "[{\"op\":\"add\",\"path\":\"/spec/ports/-\",\"value\":{\"name\":\"konnectivity\",\"port\":$KONN_AGENT_PORT,\"protocol\":\"TCP\",\"targetPort\":$KONN_AGENT_PORT}}]"
      fi
      cmd_port status
      ;;
    remove)
      idx=$(svc_json | jq -r --argjson p "$KONN_AGENT_PORT" '.spec.ports | to_entries[] | select(.value.port==$p) | .key')
      if [ -z "$idx" ]; then echo "the Service $KONN_SERVICE has no port $KONN_AGENT_PORT"; else
        say "$(now) remove the port $KONN_AGENT_PORT (entry $idx) of the Service $KONN_NS/$KONN_SERVICE"
        k -n "$KONN_NS" patch service "$KONN_SERVICE" --type=json -p "[{\"op\":\"test\",\"path\":\"/spec/ports/$idx/port\",\"value\":$KONN_AGENT_PORT},{\"op\":\"remove\",\"path\":\"/spec/ports/$idx\"}]"
      fi
      cmd_port status
      ;;
    status)
      svc_json | jq -c '{service: .metadata.name, type: .spec.type, address: [.status.loadBalancer.ingress[]?.ip], trafficPolicy: .spec.externalTrafficPolicy, sessionAffinity: .spec.sessionAffinity, ports: [.spec.ports[] | "\(.name) \(.port)->\(.targetPort)"], selector: .spec.selector}'
      k -n "$KONN_NS" get endpointslices -l "kubernetes.io/service-name=$KONN_SERVICE" -o json | jq -c '.items[] | {ports: [(.ports // [])[] | "\(.name) \(.port)"], endpoints: [(.endpoints // [])[] | "\(.addresses[0]) ready=\(.conditions.ready) \(.targetRef.name // "-")"]}' || true
      ;;
    *) echo "port add|remove|status"; return 1 ;;
  esac
}

# --- steps of a run --------------------------------------------------------------------------------
need_run() {
  run=${1:-}
  [ -n "$run" ] || { echo "no run name"; exit 1; }
  D=$L/$run
  SEC=$W/secrets/d-$run
  KCFG=$SEC/kubeconfig-$CLUSTER_NAME
  TN=$D/tnodes.txt       # written by p3ab.sh tpods: <index> <node name> <role> <node address>
  mkdir -p "$D"
}
cid() { cat "$D/cluster-id.txt"; }
gaps() { LOG_DIR=$D "$G/run.sh" "$@"; }
need_kc() { # the kubeconfig of the new cluster, fetched by the lab step (it refuses an old file)
  "$P3AB" kc "$run" >/dev/null 2>&1 || { echo "no kubeconfig of the run $run yet (p3ab.sh kc $run)"; return 1; }
}
need_tn() { [ -s "$TN" ] || { echo "no node list $TN. Run \"$P3AB tpods $run\" first"; return 1; }; }

cmd_post() {
  local variant=${1:?variant} n=${2:-2} req form
  say "$(now) run $run: request $variant, $n worker(s), pod image $IMG"
  "$HERE/../requests/render.sh" "$variant" "$D" "$n" || return 1
  req=$D/cluster-request-$variant.json
  echo "$req" >"$D/posted-request.txt"
  echo "$variant" >"$D/konn-variant.txt"
  for x in $WORKERS; do docker exec "$x" crictl inspecti "$IMG" >/dev/null 2>&1 || { echo "the pod image $IMG is not in $x"; return 1; }; done
  form=$(docker inspect -f '{{index .Config.Labels "p3.sim-form"}}' "$SIM_NAME" 2>/dev/null)
  [ "$form" = konn-one-net ] || { echo "the simulator container has the form [$form], not konn-one-net. Run \"$0 sim start\" first"; return 1; }
  echo "NetworkPolicy $KONN_POLICY: $(k -n "$KONN_NS" get networkpolicy "$KONN_POLICY" -o name 2>&1 | tail -1)"
  gaps base >"$D/base.txt" 2>&1 || { echo "the base check failed:"; tail -5 "$D/base.txt"; return 1; }
  grep -E 'free volumes|NVKE clusters|objects of the cluster' "$D/base.txt" | cut -c1-200
  case "$variant" in proxy*) cmd_port add || return 1 ;; *) cmd_port status ;; esac
  gaps probe-start "$run" "${PROBE_SECS:-28800}" || true
  date -u +%FT%T.%3NZ >"$D/post-time.txt"
  api post /api/clusters "$req" >"$D/post-response.txt" 2>&1
  echo "POST /api/clusters at $(cat "$D/post-time.txt"): $(tail -1 "$D/post-response.txt")"
  body <"$D/post-response.txt" | jq -r '.id // empty' >"$D/cluster-id.txt" 2>/dev/null
  if [ -s "$D/cluster-id.txt" ]; then echo "cluster ID $(cid)"; else echo "no cluster ID. The answer:"; body <"$D/post-response.txt" | cut -c1-1500; return 1; fi
}

# The proxy server as a DaemonSet on the control plane nodes of the new cluster.
cmd_server() {
  need_kc || return 1
  case "${1:-}" in
    apply)
      say "$(now) the proxy server of the new cluster: DaemonSet konnectivity-server in kube-system, on the control plane nodes"
      KONN_SOCKET=$KONN_SOCKET KONN_SOCKET_DIR=$(dirname "$KONN_SOCKET") KONN_AGENT_PORT=$KONN_AGENT_PORT envsubst '$KONN_SOCKET $KONN_SOCKET_DIR $KONN_AGENT_PORT' <"$HERE/../manifests/konnectivity-server-ds.yaml.tmpl" >"$D/konnectivity-server-ds.yaml"
      gk apply -f "$D/konnectivity-server-ds.yaml"
      gk -n kube-system rollout status daemonset/konnectivity-server --timeout=180s
      cmd_server status
      ;;
    delete) gk -n kube-system delete daemonset/konnectivity-server --ignore-not-found ;;
    status)
      gk -n kube-system get daemonset konnectivity-server -o jsonpath='{"DaemonSet konnectivity-server: desired "}{.status.desiredNumberScheduled}{", ready "}{.status.numberReady}{", image "}{.spec.template.spec.containers[0].image}{"\n"}' 2>&1
      gk -n kube-system get pods -l k8s-app=konnectivity-server -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,ADDRESS:.status.podIP,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount,STARTED:.status.containerStatuses[0].state.running.startedAt --no-headers 2>&1
      ;;
    *) echo "server <run> apply|status|delete"; return 1 ;;
  esac
}

cmd_agent() {
  local w c
  need_kc || return 1
  case "${1:-}" in
    apply)
      say "$(now) the agent of the new cluster: ServiceAccount and DaemonSet konnectivity-agent in kube-system, server $IP_API:$KONN_AGENT_PORT"
      IP_API=$IP_API KONN_AGENT_PORT=$KONN_AGENT_PORT envsubst '$IP_API $KONN_AGENT_PORT' <"$HERE/../manifests/konnectivity-agent.yaml.tmpl" >"$D/konnectivity-agent.yaml"
      gk apply -f "$D/konnectivity-agent.yaml"
      gk -n kube-system rollout status daemonset/konnectivity-agent --timeout=180s
      cmd_agent status
      ;;
    delete) gk -n kube-system delete daemonset/konnectivity-agent serviceaccount/konnectivity-agent --ignore-not-found ;;
    status)
      gk -n kube-system get daemonset konnectivity-agent -o jsonpath='{"DaemonSet: desired "}{.status.desiredNumberScheduled}{", ready "}{.status.numberReady}{", image "}{.spec.template.spec.containers[0].image}{"\n"}' 2>&1
      gk -n kube-system get pods -l k8s-app=konnectivity-agent -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,ADDRESS:.status.podIP,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount --no-headers 2>&1
      # The agent of each worker, read in the worker container (not through the API server).
      for w in $(workers); do
        c=$(docker exec "$w" crictl ps --name konnectivity-agent -q 2>/dev/null | head -1)
        echo "$w ($(worker_ip "$w")): agent container [${c:0:12}], connections to port $KONN_AGENT_PORT: [$(docker exec "$w" ss -Htn state established "( dport = :$KONN_AGENT_PORT )" 2>&1 | awk '{print $NF}' | sort | uniq -c | awk '{print $2 " x" $1}' | tr '\n' ' ')]"
        [ -z "$c" ] || docker exec "$w" crictl logs --tail 6 "$c" 2>&1 | cut -c1-220 | sed 's/^/    /'
      done
      ;;
    *) echo "agent <run> apply|status|delete"; return 1 ;;
  esac
}

# NEW connections, so the answer does not come from a connection that was open before a policy.
cmd_reach() {
  local label=${1:-now} p w ip out total=0 answered=0 n
  {
    say "reach ($label) at $(now): a NEW connection from each control plane pod to the kubelet port of each worker"
    echo "NetworkPolicy in $KONN_NS: [$(k -n "$KONN_NS" get networkpolicy -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>&1)]"
    for p in $(cp_pods); do
      echo "$p: routes to the worker block: [$(k -n "$KONN_NS" exec "$p" -- sh -c "ip route show | grep -F '${KONN_WORKER_PREFIX}.' | tr '\n' ';'" </dev/null 2>&1)] default: [$(k -n "$KONN_NS" exec "$p" -- sh -c 'ip route show default | head -1' </dev/null 2>&1)]"
      for w in $(workers); do
        ip=$(worker_ip "$w")
        total=$((total + 1))
        out=$(k -n "$KONN_NS" exec "$p" -- curl -sk --max-time 4 -o /dev/null -w 'http %{http_code} connected in %{time_connect} s' "https://$ip:10250/healthz" </dev/null 2>&1 | tail -1 | cut -c1-120)
        case "$out" in
          "http 000"* | "") echo "  $p -> $ip:10250 ($w): no answer [$out]" ;;
          http*) answered=$((answered + 1)); echo "  $p -> $ip:10250 ($w): answer [$out]" ;;
          *) echo "  $p -> $ip:10250 ($w): no answer [$out]" ;;
        esac
      done
    done
    echo "RESULT reach $label: $answered of $total new connections from a control plane pod to a worker got an answer"
    say "the same port from a kind node, which no policy selects (the way of the NVKE controller is through a kind node)"
    n=$(k -n nvke-controller get pods -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)
    for w in $(workers); do
      ip=$(worker_ip "$w")
      echo "  $n -> $ip:15005 (node agent of $w): [$(docker exec "$n" curl -sk --max-time 4 -o /dev/null -w 'connected in %{time_connect} s, curl exit %{exitcode}' "https://$ip:15005/" 2>&1 | tail -1 | cut -c1-100)]"
      echo "  $n -> $ip:10250 (kubelet of $w): [$(docker exec "$n" curl -sk --max-time 4 -o /dev/null -w 'http %{http_code}' "https://$ip:10250/healthz" 2>&1 | tail -1 | cut -c1-60)]"
    done
    echo "NVKE: $(api get "/api/nodes?clusterID=$(cid)" 2>/dev/null | body | jq -c '[(.nodes // [])[] | "\(.name[-8:]) agent=\(.conditions.nodeAgentReady.status) kube=\(.conditions.kubernetesReady.status)"]' 2>&1 | cut -c1-400)"
  } 2>&1 | tee "$D/reach-$label.txt"
}

cmd_facts() {
  local label=${1:-now} p w c
  {
    say "facts ($label) at $(now), request variant [$(cat "$D/konn-variant.txt" 2>/dev/null)]"
    for p in $(cp_pods); do
      echo "=== control plane pod $p on $(k -n "$KONN_NS" get pod "$p" -o jsonpath='{.spec.nodeName}' 2>/dev/null)"
      # The commands go to a shell in the guest through stdin. No file goes into the guest.
      k -n "$KONN_NS" exec -i "$p" -- env EGRESS="$KONN_EGRESS_FILE" MANIFEST="$KONN_MANIFEST" SOCKET="$KONN_SOCKET" PORT="$KONN_AGENT_PORT" IMAGE="$KONN_SERVER_IMAGE" sh -s 2>&1 <<'GUEST'
api=/etc/kubernetes/manifests/kube-apiserver.yaml
echo "flag in the API server manifest: [$(grep -o -- '--egress-selector-config-file=[^ ]*' "$api")]"
pid=$(pgrep -o kube-apiserver 2>/dev/null)
echo "flag of the running API server: [$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | grep -o -- '--egress-selector-config-file=[^ ]*')]"
echo "mount of the policies folder in the manifest: [$(grep -A2 -F 'mountPath: /etc/kubernetes/policies' "$api" | tr -s ' \n' ' ')]"
echo "egress selector config: [$(ls -l "$EGRESS" 2>&1 | cut -c1-100)] sha256 $(sha256sum "$EGRESS" 2>/dev/null | cut -c1-16)"
echo "static pod manifest: [$(ls -l "$MANIFEST" 2>&1 | cut -c1-100)] sha256 $(sha256sum "$MANIFEST" 2>/dev/null | cut -c1-16)"
echo "manifest folder: [$(ls /etc/kubernetes/manifests | tr '\n' ' ')]"
echo "proxy server container (each attempt): [$(crictl ps -a --name konnectivity-server 2>/dev/null | tail -n +2 | awk '{print $5 " attempt " $7 " created " $3 " " $4}' | tr '\n' ';')]"
echo "socket folder: [$(ls -l "$(dirname "$SOCKET")" 2>&1 | tail -n +2 | tr -s ' ' | cut -c1-100 | tr '\n' ';')]"
echo "listener of the agent port: [$(ss -Hltn "sport = :$PORT" | awk '{print $4}' | tr '\n' ' ')]"
echo "tunnels of agents (connections on port $PORT): $(ss -Htn state established "( sport = :$PORT )" | wc -l), peers [$(ss -Htn state established "( sport = :$PORT )" | awk '{print $NF}' | sed -E 's/:[0-9]+$//' | sort | uniq -c | awk '{print $2 " x" $1}' | tr '\n' ' ')]"
echo "health port of the proxy server: healthz [$(curl -s -m 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:8133/healthz)] readyz [$(curl -s -m 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:8133/readyz)]"
echo "images of the prototype in the node: [$(crictl images 2>/dev/null | grep -F kas-network-proxy | awk '{print $1 ":" $2 " " $3}' | tr '\n' ' ')]"
echo "agent container on this node: [$(crictl ps --name konnectivity-agent 2>/dev/null | tail -n +2 | awk '{print $5 " attempt " $7}' | tr '\n' ';')], its connections to port $PORT: [$(ss -Htn state established "( dport = :$PORT )" | awk '{print $(NF-1) " -> " $NF}' | sed -E 's/:[0-9]+ -> / -> /' | sort | uniq -c | awk '{print $2, $3, $4 " x" $1}' | tr '\n' ';')]"
c=$(crictl ps --name konnectivity-server -q 2>/dev/null | head -1)
if [ -n "$c" ]; then echo "last lines of the proxy server:"; crictl logs --tail 5 "$c" 2>&1 | cut -c1-220 | sed 's/^/    /'; fi
echo "lines of the API server about the socket or the proxy (last 3):"
crictl logs --tail 400 "$(crictl ps --name kube-apiserver -q | head -1)" 2>&1 | grep -i -E 'konnectivity|egress|No agent available' | tail -3 | cut -c1-240 | sed 's/^/    /'
GUEST
    done
    echo "sha256 of the two files of this folder: egress config $(sha256sum "$HERE/../files/egress-selector-configuration.yaml" | cut -c1-16), manifest $(sha256sum "$HERE/../files/konnectivity-server.yaml" | cut -c1-16)"
    if need_kc; then
      echo "kubeadm-config of the new cluster: [$(gk -n kube-system get configmap kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' 2>&1 | grep -A1 -F 'egress-selector-config-file' | tr -s ' \n' ' ')]"
      echo "mirror pods of the proxy server:"
      gk -n kube-system get pods -l component=konnectivity-server -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount --no-headers 2>&1 | sed 's/^/    /'
      cmd_agent status 2>&1 | sed 's/^/  /'
    fi
    for w in $(workers); do
      c=$(docker inspect -f '{{.Config.Image}} {{range $k, $v := .NetworkSettings.Networks}}{{$k}}={{$v.IPAddress}} {{end}}' "$w" 2>&1)
      echo "worker $w: $c; agent image in the worker: [$(docker exec "$w" crictl images 2>/dev/null | grep -F kas-network-proxy | awk '{print $1 ":" $2 " " $3}' | tr '\n' ' ')]"
    done
  } 2>&1 | tee "$D/facts-$label.txt"
}

# The lab check rule3 of p3ab.sh, and a verdict against what this step of the test expects.
cmd_rule() {
  local label=${1:?label} expect=${2:?pass or fail} f ok bad verdict src
  need_kc || return 1
  [ -s "$TN" ] || "$P3AB" tpods "$run" >"$D/tpods-$label.txt" 2>&1
  "$P3AB" rule3 "$run" "$label" >/dev/null 2>&1
  f=$D/rule3-$label.txt
  [ -s "$f" ] || { echo "no file $f from p3ab.sh rule3"; return 1; }
  ok=$(grep -c -E '^ok +(logs|exec|port forward)' "$f")
  bad=$(grep -c -E '^FAIL +(logs|exec|port forward)' "$f")
  # For each API server call: the addresses from which the kubelet of the worker saw the call,
  # against the node address of that worker.
  src=$(awk '/^=== worker / { own=""; if (match($0, /InternalIP=[0-9.]+/)) own=substr($0, RSTART+11, RLENGTH-11) }
             /the kubelet of the worker sees the call from:/ { n++; line=$0; other=0; mine=0
               while (match(line, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) { a=substr(line, RSTART, RLENGTH); line=substr(line, RSTART+RLENGTH); if (a==own) mine++; else if (a!="127.0.0.1") other++ }
               if (mine>0 && other==0) good++; else print "    not only its own address (" own "): " $0 }
             END { printf "SUMMARY %d of %d calls came only from the node address of the worker itself\n", good, n }' "$f")
  {
    say "rule ($label) at $(now), expectation: $expect"
    grep -E '^(=== worker|--- through|ok |FAIL |     the kubelet)' "$f" | cut -c1-200
    echo "$src"
    echo "checks ok: $ok, checks FAIL: $bad"
    case "$expect" in
      fail) if [ "$ok" = 0 ] && [ "$bad" -gt 0 ]; then verdict=PASS; else verdict=FAIL; fi
            echo "RESULT rule $label (each call must fail): $verdict" ;;
      pass) if [ "$bad" = 0 ] && [ "$ok" -gt 0 ] && echo "$src" | grep -q -E '^SUMMARY ([0-9]+) of \1 calls' && ! echo "$src" | grep -q '^SUMMARY 0 of'; then verdict=PASS; else verdict=FAIL; fi
            echo "RESULT rule $label (each call must pass, and the kubelet must see its own node as the caller): $verdict" ;;
      *) echo "expectation pass or fail" ;;
    esac
  } | tee "$D/rule-$label.txt"
}

cmd_logs_watch() {
  local what=${1:-} interval=${2:-5} f pod wi
  f=$D/logs-watch.txt
  case "$what" in
    start)
      need_kc || return 1
      need_tn || return 1
      wi=$(awk '$3=="worker" {print $1; exit}' "$TN")
      pod=p3-t-$wi
      setsid nohup "$HERE/logs-watch.sh" "$KCFG" "$f" "$pod" "$interval" "${LOGS_WATCH_SECS:-14400}" </dev/null >>"$D/logs-watch.err" 2>&1 &
      echo "logs watch started: pod $pod (on $(awk -v i="$wi" '$1==i {print $2}' "$TN")), each $interval s, file $f"
      ;;
    stop) touch "$f.stop"; sleep $((interval + 12)); cmd_logs_watch summary ;;
    summary)
      [ -s "$f" ] || { echo "no file $f"; return 1; }
      {
        say "logs through each API server, read at $(now). One line for each time range with the same result"
        awk '$2!="-" { key=$2
               if (!(key in name)) order[++n]=key
               name[key]=$3; calls[key]++
               res=$4; if (res=="FAIL") { fails[key]++; msg=""; for (i=6; i<=NF && i<=14; i++) msg=msg " " $i; res="FAIL" msg }
               if (key in last && res!=last[key]) { printf "%s %s  %s to %s  %4d calls  %s\n", key, name[key], substr(t0[key],12,8), substr(t1[key],12,8), c[key], last[key]; c[key]=0 }
               if (c[key]==0) t0[key]=$1
               last[key]=res; t1[key]=$1; c[key]++ }
             END { for (j=1; j<=n; j++) { key=order[j]; printf "%s %s  %s to %s  %4d calls  %s\n", key, name[key], substr(t0[key],12,8), substr(t1[key],12,8), c[key], last[key] }
                   for (j=1; j<=n; j++) { key=order[j]; printf "TOTAL %s %s: %d calls, %d ok, %d FAIL\n", key, name[key], calls[key], calls[key]-fails[key], fails[key] } }' "$f"
        echo "rounds in which the list of the control plane nodes did not come: $(grep -c ' - - FAIL ' "$f")"
      } | tee "$D/logs-watch-summary.txt"
      ;;
    *) echo "logs-watch <run> start|stop|summary [interval]"; return 1 ;;
  esac
}

# For one control plane node: when its API server started, when its proxy server started, and what
# the API server logged about the socket in between (pass rule 3 with the DaemonSet form).
cmd_gap() {
  local p=${1:?control plane pod name} label=${2:-now}
  {
    say "gap ($label) for the control plane node $p at $(now): the time between the API server and its proxy server"
    k -n "$KONN_NS" exec -i "$p" -- env SOCKET="$KONN_SOCKET" sh -s 2>&1 <<'GUEST'
a=$(crictl ps --name kube-apiserver -q 2>/dev/null | head -1)
s=$(crictl ps --name konnectivity-server -q 2>/dev/null | head -1)
g=$(crictl ps --name konnectivity-agent -q 2>/dev/null | head -1)
t() { crictl inspect -o go-template --template '{{.status.startedAt}}' "$1" 2>/dev/null; }
echo "API server container started:   $(t "$a")"
echo "proxy server container started: $([ -n "$s" ] && t "$s" || echo none)"
echo "agent container started:        $([ -n "$g" ] && t "$g" || echo none)"
echo "socket file:                    $(TZ=UTC stat -c %y "$SOCKET" 2>&1 | cut -c1-29)"
echo "kubelet registered the node:    $(journalctl -u kubelet --no-pager 2>/dev/null | grep -m1 -i 'Successfully registered node' | cut -c1-15)"
echo "API server lines with the absent socket: $(crictl logs "$a" 2>&1 | grep -c 'konnectivity-server.socket: connect: no such file'), first $(crictl logs "$a" 2>&1 | grep -m1 'konnectivity-server.socket: connect: no such file' | cut -c1-21), last $(crictl logs "$a" 2>&1 | grep 'konnectivity-server.socket: connect: no such file' | tail -1 | cut -c1-21)"
echo "API server lines with a refused socket: $(crictl logs "$a" 2>&1 | grep -c 'konnectivity-server.socket: connect: connection refused')"
echo "API server lines with No agent available: $(crictl logs "$a" 2>&1 | grep -c -i 'No agent available'), first $(crictl logs "$a" 2>&1 | grep -m1 -i 'No agent available' | cut -c1-21), last $(crictl logs "$a" 2>&1 | grep -i 'No agent available' | tail -1 | cut -c1-21)"
if [ -n "$s" ]; then
  echo "proxy server: first agent line: $(crictl logs "$s" 2>&1 | grep -m1 -i -E 'agent connected|Register backend|AddBackend' | cut -c1-200)"
  echo "proxy server: agent lines in all: $(crictl logs "$s" 2>&1 | grep -c -i -E 'agent connected|Register backend|AddBackend')"
fi
GUEST
  } 2>&1 | tee "$D/gap-$label.txt"
}

cmd_cp_count() {
  local n=${1:?count}
  case "$n" in 3 | 4 | 5) ;; *) echo "count 3, 4 or 5"; return 1 ;; esac
  printf '{"controlPlaneConfig": {"desiredCount": %s}}\n' "$n" >"$D/cp-count-$n.json"
  say "$(now) PATCH /api/clusters/$(cid) with controlPlaneConfig.desiredCount $n"
  api patch "/api/clusters/$(cid)" "$D/cp-count-$n.json" >"$D/cp-count-$n-response.txt" 2>&1
  tail -1 "$D/cp-count-$n-response.txt"
  grep -q '^HTTP 20[0-4]$' "$D/cp-count-$n-response.txt" || { body <"$D/cp-count-$n-response.txt" | cut -c1-600; return 1; }
}

# Pass rule 4: what still fails with the proxy. Each line says what the design expects.
cmd_still() {
  local label=${1:-now} i name role role2 ip wi wname pip apiip out p exp okp oks msg
  need_kc || return 1
  need_tn || return 1
  tp() { gk -n default get pod "p3-t-$1" -o jsonpath='{.status.podIP}' </dev/null 2>/dev/null; }
  wx() { local i=$1; shift; gk -n default exec "p3-t-$i" -- "$@" </dev/null 2>&1 | tail -1 | cut -c1-110; }
  judge() { # <what> <expected: works|fails> <result text> <pattern that means "works">
    local got=fails
    if echo "$3" | grep -q -E "$4"; then got=works; fi
    if [ "$got" = "$2" ]; then echo "as expected ($2): $1: [$3]"; else echo "DIFFERENT (expected $2, it $got): $1: [$3]"; fi
  }
  {
    say "still ($label) at $(now): what works and what fails with the proxy and a worker that the control plane pods cannot reach"
    echo "--- what NVKE and Kubernetes show"
    api get "/api/nodes?clusterID=$(cid)" 2>/dev/null | body | jq -r '(.nodes // [])[] | "NVKE node \(.name): " + ([.conditions | to_entries[] | select(.value.status=="True") | .key] | join("+"))' 2>&1 | cut -c1-200
    gk get nodes -o 'custom-columns=NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,ADDRESS:.status.addresses[0].address,TAINTS:.spec.taints[*].key' --no-headers 2>&1
    echo "OVN pods: $(gk -n ovn-kubernetes get pods -o json 2>/dev/null | jq -r '[.items[] | "\(.spec.nodeName[-8:])=\([.status.containerStatuses[]? | select(.ready)] | length)/\(.spec.containers | length)"] | join(" ")')"
    apiip=$(gk -n default get service kubernetes -o jsonpath='{.spec.clusterIP}' </dev/null 2>/dev/null)
    echo "--- from the test pod on each worker (exec through an API server, so through the proxy)"
    while read -r wi wname role _; do
      [ "$role" = worker ] || continue
      judge "exec into the test pod on the worker $wname" works "$(wx "$wi" sh -c 'echo "exec in $(hostname)"')" "^exec in p3-t-$wi"
      while read -r i name role ip; do
        [ "$i" = "$wi" ] && continue
        pip=$(tp "$i")
        if [ "$role" = cp ]; then
          judge "pod on the worker $wname to the pod $pip on the control plane node $name, ping" fails "$(wx "$wi" python3 /probe/ping.py "$pip" 3)" '[1-3] of 3 answers'
          judge "pod on the worker $wname to the pod $pip on the control plane node $name, TCP" fails "$(wx "$wi" curl -s -m 3 -o /dev/null -w 'http %{http_code}' "http://$pip:8080/ping.py")" '^http 200'
        else
          echo "for the record, pod on the worker $wname to the pod $pip on the worker $name: [$(wx "$wi" curl -s -m 3 -o /dev/null -w 'http %{http_code}' "http://$pip:8080/ping.py")]"
        fi
      done <"$TN"
      judge "the API Service ($apiip:443) from a pod on the worker $wname" fails "$(wx "$wi" curl -sk -m 5 -o /dev/null -w 'http %{http_code}' "https://$apiip:443/version")" '^http (200|401|403)'
      judge "name lookup from a pod on the worker $wname" fails "$(wx "$wi" python3 -c 'import socket; print("resolved", socket.gethostbyname("kubernetes.default.svc.cluster.local"))')" '^resolved '
    done <"$TN"
    echo "--- from each control plane node (a command in the guest, through the host cluster) to the test pod on each worker"
    while read -r i name role ip; do
      [ "$role" = cp ] || continue
      while read -r wi wname role2 _; do
        [ "$role2" = worker ] || continue
        pip=$(tp "$wi")
        judge "control plane node $name to the pod $pip on the worker $wname, TCP" fails "$(k -n "$KONN_NS" exec "$name" -- curl -s -m 3 -o /dev/null -w 'http %{http_code}' "http://$pip:8080/ping.py" </dev/null 2>&1 | tail -1 | cut -c1-80)" '^http 200'
      done <"$TN"
    done <"$TN"
    # KONN_AGENTS=all (the form of the test): an agent runs on each control plane node too, so a
    # kubelet call for a control plane node has an agent. KONN_AGENTS=workers: the first form.
    echo "--- logs of a pod on a control plane node, through each API server (agents on: ${KONN_AGENTS:-all})"
    p=$(awk '$3=="cp" {print $1; exit}' "$TN")
    gk -n default exec "p3-t-$p" -- curl -s -m 3 -o /dev/null http://127.0.0.1:8080/ping.py </dev/null >/dev/null 2>&1 || true
    while read -r i name role ip; do
      [ "$role" = cp ] || continue
      out=$(gk --server "https://$ip:6443" -n default logs "p3-t-$p" --tail=1 </dev/null 2>&1 | tail -1 | cut -c1-110)
      if [ "${KONN_AGENTS:-all}" = all ]; then exp=works; else exp=fails; fi
      judge "logs of the test pod p3-t-$p on a control plane node, through the API server of $name" "$exp" "$out" 'GET /|Serving HTTP'
    done <"$TN"
    echo "--- for the record: pod proxy and Service proxy from each API server to the test pod on each worker, 4 calls each (a call to a pod address goes to any agent)"
    while read -r i name role ip; do
      [ "$role" = cp ] || continue
      while read -r wi wname role2 _; do
        [ "$role2" = worker ] || continue
        okp=0; oks=0; msg=""
        for _ in 1 2 3 4; do
          out=$(gk --server "https://$ip:6443" get --raw "/api/v1/namespaces/default/pods/p3-t-$wi:8080/proxy/ping.py" </dev/null 2>&1 | head -1 | cut -c1-90)
          case "$out" in "# ICMP echo"*) okp=$((okp + 1)) ;; *) msg=$out ;; esac
          out=$(gk --server "https://$ip:6443" get --raw "/api/v1/namespaces/default/services/p3-t-$wi:80/proxy/ping.py" </dev/null 2>&1 | head -1 | cut -c1-90)
          case "$out" in "# ICMP echo"*) oks=$((oks + 1)) ;; *) msg=$out ;; esac
        done
        echo "for the record, API server of $name to the pod on the worker $wname: pod proxy $okp of 4, Service proxy $oks of 4${msg:+, a failed call said [$msg]}"
      done <"$TN"
    done <"$TN"
    echo "--- the NVKE controller and the node agent of each worker: the nodeAgentReady condition above, and the step reach"
  } 2>&1 | tee "$D/still-$label.txt"
  echo "RESULT still $label: $(grep -c '^as expected' "$D/still-$label.txt") lines as the design expects, $(grep -c '^DIFFERENT' "$D/still-$label.txt") lines different"
}

step=${1:-}
case "$step" in
  sim) shift; cmd_sim "$@" ;;
  policy) shift; cmd_policy "$@" ;;
  port) shift; cmd_port "$@" ;;
  post | agent | server | reach | facts | rule | logs-watch | cp-count | still | gap)
    need_run "${2:-}"
    shift 2
    "cmd_${step//-/_}" "$@"
    ;;
  *) sed -n '2,38p' "$0"; exit 1 ;;
esac
