#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Phase 1 step 5: the real NVKE controller makes one cluster with three control plane nodes on
# three Kata pods, through its "infra" path with cluster-api-provider-provisioned.
# No lab client plays the controller. This script makes the host pods, sends one request to the
# NVKE API, and then only watches and records.
#
# Each kubectl, crictl and curl call runs inside the kind node (docker exec), so the host opens no
# TCP connection. The NVKE API is called only through phase1-stack/api.sh, one call each 10 s.
#
# Usage: run.sh <step>
#   base              namespace, wrapper, the three Services
#   node-up <r>       volumes and StatefulSet of host r (a, b, c)
#   units <r> [label] systemd units, addresses and SPIRE state of host r
#   helper            deploy the lab bootstrap helper for this namespace
#   post              send the cluster request to the NVKE API
#   wait              poll the cluster each 10 s until NVKE reports "provisioned"
#   wait-nodes        poll the nodes each 10 s until each one is provisioned in NVKE
#   check [label]     the pass rule: NVKE says provisioned, and three Ready control plane nodes
#   record [label]    save what NVKE, Cluster API, the helper, SPIRE and Temporal show
#   evidence [label]  save the state of each host
#   down, wipe        remove the host pods and volumes, and wipe the six loop devices
#   full              base, three hosts, helper, post, wait, wait-nodes, check, record, evidence
set -euo pipefail

NS=${NS:-phase1-run}
RUNTIME_CLASS=${RUNTIME_CLASS-kata-clh-runtime-rs-fix-direct}
SNAPSHOTTER=${SNAPSHOTTER-overlayfs}
KERNEL_CONFIG=${KERNEL_CONFIG-/scratch/kata-cp/logs/kata-guest-kernel-config-6.18.62-211.txt}
STOP_TIMEOUT=${STOP_TIMEOUT-}
G1_SKIP=${G1_SKIP-init-cgroup}
GRACE=${GRACE:-20}
CPU=${CPU:-2}
MEMORY=${MEMORY:-6Gi}
IMAGE=${IMAGE:-nvke-node:bcc4376f-amd64}
READY_WAIT=${READY_WAIT:-300}
KIND_NODE=${KIND_NODE:-kata-cp-control-plane}
ETP=${ETP:-Cluster}
ADDR_FORM=${ADDR_FORM:-bridge}
REPAIR=${REPAIR:-off}
ETCD_PATCH=${ETCD_PATCH:-1}
P1_OVS_DATAPATH=${P1_OVS_DATAPATH-netdev}
P1_OVS_NO_MODPROBE=${P1_OVS_NO_MODPROBE:-1}
P1_TUN=${P1_TUN:-1}
POD_CIDR=${POD_CIDR:-10.113.0.0/16}
SERVICE_CIDR=${SERVICE_CIDR:-10.112.0.0/16}
CLUSTER_NAME=${CLUSTER_NAME:-kata-cp1}
CAPI_NS=${CAPI_NS:-nvke-system}
HELPER_NS=${HELPER_NS:-nvke-lab-bootstrap-helper}
HELPER_RENDER=${HELPER_RENDER:-/scratch/kata-cp/work/phase1-helper/deploy/render.sh}
API=${API:-/scratch/kata-cp/work/phase1-stack/api.sh}
TEMPORAL_NS=cloud-workflow-engine
TEMPORAL_ADDR=temporal-frontend.temporal.svc.cluster.local:7233
PROVISION_TIMEOUT=${PROVISION_TIMEOUT:-1800}    # seconds for "provisioned" and for the nodes
POLL=${POLL:-10}                                # seconds between two API calls
LOOP_MAP=${LOOP_MAP:-/scratch/kata-cp/disks/loop-map.txt}
LOG_DIR=${LOG_DIR:-/scratch/kata-cp/logs/phase1-run/$(date +%Y%m%d-%H%M%S)}

# The hosts: inventory hostname, LoadBalancer address, devices.
REPLICAS=(a b c)
declare -A HOSTS=([a]=kata-host-a [b]=kata-host-b [c]=kata-host-c)
declare -A IPS=([a]=${IP_A:-172.30.255.221} [b]=${IP_B:-172.30.255.222} [c]=${IP_C:-172.30.255.223})
declare -A VAR_LOOPS=([a]=/dev/loop20 [b]=/dev/loop21 [c]=/dev/loop30)
declare -A ETCD_LOOPS=([a]=/dev/loop24 [b]=/dev/loop25 [c]=/dev/loop28)
declare -A VAR_SIZES=([a]=30Gi [b]=30Gi [c]=20Gi)
ETCD_SIZE=10Gi
declare -A EXPECT=([/dev/loop20]=var-1.img [/dev/loop24]=etcd-1.img [/dev/loop21]=var-2.img
  [/dev/loop25]=etcd-2.img [/dev/loop30]=spare-1.img [/dev/loop28]=fio-1.img)

HERE="$(cd "$(dirname "$0")" && pwd)"
KC=(kubectl --kubeconfig /etc/kubernetes/admin.conf)
ETCDCTL='crictl exec "$(crictl ps --name etcd -q | head -1)" etcdctl --endpoints https://127.0.0.1:2379 --cacert /etc/kubernetes/pki/etcd/ca.crt --cert /etc/kubernetes/pki/etcd/healthcheck-client.crt --key /etc/kubernetes/pki/etcd/healthcheck-client.key'
SEC="$LOG_DIR/secrets"                  # kubeconfig, raw logs with tokens, workflow histories. Never in ~/notes
mkdir -p "$LOG_DIR" "$SEC"
chmod 700 "$SEC"

node() { docker exec "$KIND_NODE" "$@"; }
nodei() { docker exec -i "$KIND_NODE" "$@"; }
k() { node "${KC[@]}" "$@"; }
say() { echo "== $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
stamp() { printf '%s %s\n' "$(date +%s.%N)" "$1" >>"$LOG_DIR/times.txt"; }
between() { awk -v a="$1" -v b="$2" '$2==a {x=$1} $2==b {y=$1} END {if (x && y) printf "%.1f\n", y-x; else print "-"}' "$LOG_DIR/times.txt"; }
pn() { echo "cp-$1-0"; }
pod() { local r=$1; shift; k -n "$NS" exec "$(pn "$r")" -- "$@"; }
ik() { local r=$1; shift; pod "$r" "${KC[@]}" "$@"; }   # kubectl of the new cluster, in the pod of host r
etcdctl() { local r=$1; shift; pod "$r" sh -c "$ETCDCTL $*"; }
# The NVKE API. api.sh prints the body and then one line "HTTP <code>". It has its own log folder.
api() { env -u LOG_DIR "$API" "$@"; }
api_body() { sed '$d' | sed -e '${/^$/d}'; }        # drop the "HTTP <code>" line and the empty line before it
cluster_id() { cat "$LOG_DIR/cluster-id.txt"; }
# A join token is part of a SPIFFE ID of a SPIRE agent, and agent.conf holds it. Remove it from text for the logs.
mask() { sed -E 's#(join_token/)[0-9a-f-]+#\1TOKEN#g; s#(join_token *= *")[^"]*#\1TOKEN#g; s#[a-z0-9]{6}\.[a-z0-9]{16}#<bootstrap-token>#g'; }
temporal() { k -n temporal exec deploy/temporal-admintools -- temporal "$@" --namespace "$TEMPORAL_NS" --address "$TEMPORAL_ADDR"; }

render() {
  local tmpl=$1 r=${2:-a} inc="" line drop=()
  [ -n "$RUNTIME_CLASS" ] || drop+=(-e '/#@runtimeclass$/d')
  [ -n "$KERNEL_CONFIG" ] || drop+=(-e '/#@kernelconfig$/d')
  [ "$tmpl" = node-sts.yaml.tmpl ] && inc=$(cat "$HERE/podspec.inc")
  export NS RUNTIME_CLASS SNAPSHOTTER STOP_TIMEOUT GRACE CPU MEMORY IMAGE KIND_NODE ETP ADDR_FORM REPAIR ETCD_SIZE G1_SKIP ETCD_PATCH
  export P1_OVS_DATAPATH P1_OVS_NO_MODPROBE P1_TUN CLUSTER_NAME POD_CIDR SERVICE_CIDR
  export NAME="cp-$r" NODE_IP="${IPS[$r]}" HOST_NAME="${HOSTS[$r]}" VAR_LOOP="${VAR_LOOPS[$r]}" ETCD_LOOP="${ETCD_LOOPS[$r]}" VAR_SIZE="${VAR_SIZES[$r]}"
  export HOST_A="${HOSTS[a]}" HOST_B="${HOSTS[b]}" HOST_C="${HOSTS[c]}" IP_A="${IPS[a]}" IP_B="${IPS[b]}" IP_C="${IPS[c]}"
  while IFS= read -r line; do
    if [ "$line" = "#@podspec" ]; then printf '%s\n' "$inc"; else printf '%s\n' "$line"; fi
  done <"$HERE/$tmpl" | sed "${drop[@]}" -e 's/ *#@[a-z]*$//' |
    envsubst '$NS $NAME $RUNTIME_CLASS $SNAPSHOTTER $STOP_TIMEOUT $GRACE $CPU $MEMORY $IMAGE $KIND_NODE $ETP $ADDR_FORM $REPAIR $ETCD_SIZE $NODE_IP $HOST_NAME $VAR_LOOP $ETCD_LOOP $VAR_SIZE $G1_SKIP $ETCD_PATCH $P1_OVS_DATAPATH $P1_OVS_NO_MODPROBE $P1_TUN $CLUSTER_NAME $POD_CIDR $SERVICE_CIDR $HOST_A $HOST_B $HOST_C $IP_A $IP_B $IP_C'
}

# wait_node <seconds> <shell test>: repeat the test in the kind node, one time each second, as a transient systemd unit.
wait_node() {
  local t=$1
  shift
  node systemd-run --quiet --wait --collect --expand-environment=no --unit="p1run-wait-$$-$RANDOM" \
    bash -c "for i in \$(seq 1 $t); do if $*; then exit 0; fi; sleep 1; done; exit 1"
}
pod_ip() { k -n "$NS" get pod "$(pn "$1")" -o jsonpath='{.status.podIP}'; }
restarts() { k -n "$NS" get pod "$(pn "$1")" -o jsonpath='{.status.containerStatuses[0].restartCount}'; }
check_devices() {
  local d la
  la=$(node losetup -a)
  for d in "${!EXPECT[@]}"; do
    grep -q "^$d .*/${EXPECT[$d]} " "$LOOP_MAP" || die "$d is not ${EXPECT[$d]} in $LOOP_MAP"
    grep -q "^$d: .*/${EXPECT[$d]})" <<<"$la" || die "$d is not ${EXPECT[$d]} in the kind node"
  done
}
pod_memory() {
  local r=$1 uid cg
  uid=$(k -n "$NS" get pod "$(pn "$r")" -o jsonpath='{.metadata.uid}')
  cg=$(node find /sys/fs/cgroup/kubelet.slice -maxdepth 3 -type d -name "*pod${uid//-/_}.slice" | head -1)
  [ -n "$cg" ] || { echo "cp-$r: no pod cgroup"; return 0; }
  node sh -c "echo \"cp-$r: memory.current \$((\$(cat $cg/memory.current) / 1048576)) MiB, memory.peak \$((\$(cat $cg/memory.peak) / 1048576)) MiB, events: \$(tr '\n' ' ' <$cg/memory.events)\""
  echo "cp-$r: container restarts $(restarts "$r"), guest: $(pod "$r" sh -c "free -m | awk '\$1==\"Mem:\" {print \"total \" \$2 \" used \" \$3 \" cache \" \$6 \" MiB\"}'"), CPUs $(pod "$r" nproc)"
}

cmd_base() {
  check_devices
  say "memory and load of the host"
  free -g
  uptime
  say "namespace, wrapper script, kernel config"
  k create namespace "$NS" --dry-run=client -o yaml | nodei "${KC[@]}" apply -f -
  nodei "${KC[@]}" -n "$NS" create configmap p1-wrapper --from-file=wrapper.sh=/dev/stdin --dry-run=client -o yaml <"$HERE/wrapper.sh" |
    nodei "${KC[@]}" apply -f -
  if [ -n "$KERNEL_CONFIG" ]; then
    k -n "$NS" delete configmap p1-kernel-config --ignore-not-found >/dev/null
    nodei "${KC[@]}" -n "$NS" create configmap p1-kernel-config --from-file=config=/dev/stdin <"$KERNEL_CONFIG"
  fi
  say "Services"
  local r
  for r in "${REPLICAS[@]}"; do
    render service.yaml.tmpl "$r" >"$LOG_DIR/service-cp-$r.yaml"
    nodei "${KC[@]}" apply -f - <"$LOG_DIR/service-cp-$r.yaml"
  done
  for r in "${REPLICAS[@]}"; do
    k -n "$NS" wait --for=jsonpath='{.status.loadBalancer.ingress[0].ip}'="${IPS[$r]}" "service/cp-$r" --timeout=60s
  done
  k -n "$NS" get svc -o wide | tee "$LOG_DIR/services.txt"
}

cmd_node_up() {
  local r=$1
  say "host $r: inventory name ${HOSTS[$r]}, node address ${IPS[$r]}, volumes ${VAR_LOOPS[$r]} and ${ETCD_LOOPS[$r]}"
  render volumes.yaml.tmpl "$r" | nodei "${KC[@]}" apply -f -
  render node-sts.yaml.tmpl "$r" >"$LOG_DIR/sts-cp-$r.yaml"
  stamp "$r-pod-create"
  nodei "${KC[@]}" apply -f - <"$LOG_DIR/sts-cp-$r.yaml"
  k -n "$NS" wait --for=create "pod/$(pn "$r")" --timeout=60s
  k -n "$NS" wait --for=jsonpath='{.status.phase}'=Running "pod/$(pn "$r")" --timeout=300s
  wait_node 300 "${KC[*]} -n $NS exec $(pn "$r") -- systemctl is-active containerd >/dev/null 2>&1" || die "containerd is not active in the pod of host $r"
  stamp "$r-node-up"
  say "host $r: pod $(pn "$r") has the IP $(pod_ip "$r"). Pod create to systemd up: $(between "$r-pod-create" "$r-node-up") s"
  k -n "$NS" logs "$(pn "$r")" 2>/dev/null | grep -a 'WRAP:' | tr -d '\r' | tee "$LOG_DIR/wrapper-log-$r.txt" || true
}

# The state of host r that matters before and after the bootstrap data arrives.
host_state() {
  pod "$1" sh -c 'echo "--- hostname $(hostname), kernel $(uname -r)"
    echo "--- units"; systemctl is-system-running; systemctl --failed --no-legend --plain
    for u in spire-agent nvke-agent ovsdb-server ovs-vswitchd nke-container-network nke-container-cni-images kubelet containerd; do
      printf "%-28s active=%-12s result=%-10s restarts=%s\n" "$u" "$(systemctl is-active "$u" 2>&1 | head -1)" "$(systemctl show -p Result --value "$u" 2>&1 | head -1)" "$(systemctl show -p NRestarts --value "$u" 2>&1 | head -1)"
    done
    echo "--- agent environment"; systemctl show nvke-agent -p Environment; sed -E "s/(join_token *= *\")[^\"]*/\1TOKEN/" /etc/default/nvke-agent
    echo "--- agent process"; ps -o args= -C nvke-agent
    echo "--- /etc/spire-agent"; ls -l /etc/spire-agent; findmnt -n -o TARGET,SOURCE /etc/spire-agent
    echo "--- agent.conf (token masked)"; sed -E "s/(join_token *= *\")[^\"]*/\1TOKEN/" /etc/spire-agent/agent.conf 2>&1
    echo "--- /var/lib/spire-agent"; ls -l /var/lib/spire-agent 2>&1
    echo "--- cloud-init"; cloud-init status 2>&1; ls -l /var/lib/nico-containers/cloud-init 2>&1
    echo "--- agent port"; ss -ltnH | awk "{print \$4}" | grep -E ":(15005|6443|2379|2380|10250)\$" | sort | tr "\n" " "; echo
    echo "--- addresses"; ip -br -4 addr; echo "--- routes"; ip route
    echo "--- Open vSwitch"; ovs-vsctl --timeout=5 show 2>&1 | head -30; ovs-vsctl --timeout=5 get Open_vSwitch . external_ids 2>&1
    echo "--- patches folder"; ls -l /etc/kubernetes/patches 2>&1' 2>&1 || true
}

cmd_units() {
  local r=$1 label=${2:-units}
  host_state "$r" >"$LOG_DIR/units-$r-$label.txt" 2>&1
  grep -E 'active=|^running|^degraded|failed|g4-node|status:' "$LOG_DIR/units-$r-$label.txt" | head -20 || true
}

cmd_helper() {
  say "lab bootstrap helper for the namespace $NS"
  # render() of this script exports IMAGE (the node image). The helper has its own default image.
  env -u IMAGE HOSTS_NS="$NS" CAPI_NS="$CAPI_NS" HELPER_NS="$HELPER_NS" "$HELPER_RENDER" >"$LOG_DIR/helper.yaml"
  if ! grep -q 'image: .*nvke-lab-bootstrap-helper' "$LOG_DIR/helper.yaml"; then
    echo "the helper manifest has a wrong image: $(grep 'image:' "$LOG_DIR/helper.yaml")"
    return 1
  fi
  nodei "${KC[@]}" apply -f - <"$LOG_DIR/helper.yaml"
  k -n "$HELPER_NS" rollout status deployment/nvke-lab-bootstrap-helper --timeout=120s
  # A helper pod from an earlier run has an old view. Start with a new pod and an empty log.
  k -n "$HELPER_NS" rollout restart deployment/nvke-lab-bootstrap-helper >/dev/null
  k -n "$HELPER_NS" rollout status deployment/nvke-lab-bootstrap-helper --timeout=120s
  k -n "$HELPER_NS" get pods -o wide
}

cmd_post() {
  render request.json.tmpl >"$LOG_DIR/request.json"
  say "POST /api/clusters ($CLUSTER_NAME)"
  stamp post
  date -u +%FT%T.%3NZ >"$LOG_DIR/post-time.txt"
  api post /api/clusters "$LOG_DIR/request.json" >"$LOG_DIR/post-response.txt" 2>&1 || true
  tail -1 "$LOG_DIR/post-response.txt"
  grep -q '^HTTP 20[012]$' "$LOG_DIR/post-response.txt" || { cat "$LOG_DIR/post-response.txt"; die "the API did not accept the request"; }
  api_body <"$LOG_DIR/post-response.txt" | jq -r '.id' >"$LOG_DIR/cluster-id.txt"
  say "cluster ID $(cluster_id)"
  api_body <"$LOG_DIR/post-response.txt" | jq -c '{name, id, conditions}' || true
}

# One line for each poll: the conditions of the cluster and of each node, as NVKE reports them.
poll_line() {
  local c n
  c=$(api get "/api/clusters/$(cluster_id)" 2>/dev/null | api_body)
  n=$(api get "/api/nodes?clusterID=$(cluster_id)" 2>/dev/null | api_body)
  printf '%s' "$c" >"$LOG_DIR/.cluster.json"
  printf '%s' "$n" >"$LOG_DIR/.nodes.json"
  printf '%s cluster: %s\n' "$(date -u +%T)" "$(jq -r '[.conditions | to_entries[] | select(.value.status=="True") | "\(.key)[\(.value.message // "")]"] | join(" ")' "$LOG_DIR/.cluster.json" 2>/dev/null)"
  jq -r '(.nodes // .items // .)[]? | "         node \(.name) ip=\(.ip // "-") " + ([.conditions | to_entries[] | select(.value.status=="True") | "\(.key)[\(.value.message // "")]"] | join(" "))' "$LOG_DIR/.nodes.json" 2>/dev/null || true
}
cluster_provisioned() { jq -e '.conditions.provisioned.status=="True"' "$LOG_DIR/.cluster.json" >/dev/null 2>&1; }
nodes_provisioned() { [ "$(jq -r '[(.nodes // .items // .)[]? | select(.conditions.provisioned.status=="True")] | length' "$LOG_DIR/.nodes.json" 2>/dev/null)" = 3 ]; }

cmd_wait() {
  local end=$(( $(date +%s) + PROVISION_TIMEOUT ))
  say "poll the cluster each $POLL s until NVKE reports provisioned (limit $PROVISION_TIMEOUT s)"
  while [ "$(date +%s)" -lt "$end" ]; do
    poll_line | tee -a "$LOG_DIR/timeline.txt"
    if cluster_provisioned; then
      stamp provisioned
      say "NVKE reports the cluster as provisioned: $(between post provisioned) s after the POST"
      return 0
    fi
    sleep "$POLL"
  done
  say "FAIL: the cluster is not provisioned after $PROVISION_TIMEOUT s"
  return 1
}

cmd_wait_nodes() {
  local end=$(( $(date +%s) + PROVISION_TIMEOUT ))
  say "poll the nodes each $POLL s until NVKE reports three provisioned nodes (limit $PROVISION_TIMEOUT s)"
  while [ "$(date +%s)" -lt "$end" ]; do
    poll_line | tee -a "$LOG_DIR/timeline.txt"
    if nodes_provisioned; then
      stamp nodes-provisioned
      say "NVKE reports three provisioned nodes: $(between post nodes-provisioned) s after the POST"
      return 0
    fi
    sleep "$POLL"
  done
  say "FAIL: not three provisioned nodes after $PROVISION_TIMEOUT s"
  return 1
}

# The host whose pod has an admin.conf: any host that ran init or join.
admin_host() {
  local r
  for r in "${REPLICAS[@]}"; do
    if pod "$r" test -s /etc/kubernetes/admin.conf 2>/dev/null; then echo "$r"; return 0; fi
  done
  return 1
}

# The pass rule: NVKE reports the cluster as provisioned, and the new cluster has three Ready control plane nodes.
cmd_check() {
  local label=${1:-check} out fail=0 r h
  out="$LOG_DIR/check-$label.txt"
  {
    say "check $label at $(date -u +%FT%TZ)"
    # NVKE reports a node as provisioned before its kubelet is Ready. Wait for the kubelets with one call.
    say "0. wait for the Ready condition of all nodes of the new cluster (limit ${READY_WAIT}s)"
    h=$(admin_host) || h=a
    ik "$h" wait --for=condition=Ready node --all --timeout="${READY_WAIT}s" || true
    stamp "nodes-ready-$label"
    say "1. the cluster in the NVKE API"
    api get "/api/clusters/$(cluster_id)" | api_body >"$LOG_DIR/api-cluster-$label.json"
    jq '{name, id, kubernetesVersion: (.controlPlaneKubernetesVersion // .kubernetesVersion), conditions}' "$LOG_DIR/api-cluster-$label.json"
    jq -e '.conditions.provisioned.status=="True"' "$LOG_DIR/api-cluster-$label.json" >/dev/null || { echo "FAIL NVKE does not report provisioned"; fail=1; }
    say "2. the nodes in the NVKE API"
    api get "/api/nodes?clusterID=$(cluster_id)" | api_body >"$LOG_DIR/api-nodes-$label.json"
    jq -r '(.nodes // .items // .)[]? | "\(.name) ip=\(.ip // "-") controlPlane=\(.controlPlane // "-") agent=\(.agentVersion // "-") " + ([.conditions | to_entries[] | select(.value.status=="True") | .key] | join(","))' "$LOG_DIR/api-nodes-$label.json"
    say "3. nodes of the new cluster (kubectl in the pod of a host)"
    h=$(admin_host) || { echo "FAIL no host has an admin.conf"; fail=1; h=a; }
    ik "$h" get nodes -o wide | tee "$LOG_DIR/.nodes" || true
    [ "$(grep -c -E ' Ready +control-plane ' "$LOG_DIR/.nodes")" = 3 ] || { echo "FAIL not three Ready control plane nodes"; fail=1; }
    for r in "${REPLICAS[@]}"; do
      grep -q -E " ${IPS[$r]} " "$LOG_DIR/.nodes" || { echo "FAIL no node with the address ${IPS[$r]}"; fail=1; }
    done
    say "4. etcd members"
    etcdctl "$h" member list -w simple | tee "$LOG_DIR/.members" || true
    [ "$(grep -c ', started, ' "$LOG_DIR/.members")" = 3 ] || { echo "FAIL not three started etcd members"; fail=1; }
    etcdctl "$h" endpoint health --cluster 2>&1 || true
    say "5. pods of the new cluster"
    ik "$h" get pods -A -o wide || true
    say "6. kubelet serving requests of the new cluster"
    ik "$h" get csr -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.signerName}{" "}{.spec.username}{" ["}{range .status.conditions[*]}{.type}{":"}{.reason}{" "}{end}{"] "}{.metadata.creationTimestamp}{"\n"}{end}' | mask || true
    say "7. memory and restarts of the host pods"
    for r in "${REPLICAS[@]}"; do pod_memory "$r" || true; done
    [ "$fail" = 0 ] && echo "RESULT $label: PASS" || echo "RESULT $label: FAIL"
  } 2>&1 | tee "$out"
  grep -q "RESULT $label: PASS" "$out"
}

# One workflow of Temporal: the raw history goes to the secrets folder, a time line of its activities to the log folder.
workflow_timeline() {
  local wid=$1 name
  name=$(printf '%s' "$wid" | tr -c 'A-Za-z0-9._-' '_')
  temporal workflow show --workflow-id "$wid" --output json >"$SEC/workflow-$name.json" 2>/dev/null || return 0
  jq -r '
    (.events // .) as $e
    | ($e | map(select(.eventType|test("ACTIVITY_TASK_SCHEDULED$|ActivityTaskScheduled$")) | {key: (.eventId|tostring), value: {name: .activityTaskScheduledEventAttributes.activityType.name, t: .eventTime}}) | from_entries) as $sched
    | $e[]
    | if (.eventType|test("WORKFLOW_EXECUTION_STARTED$|WorkflowExecutionStarted$")) then "\(.eventTime) workflow started"
      elif (.eventType|test("WORKFLOW_EXECUTION_(COMPLETED|FAILED|CANCELED|TIMED_OUT)$|WorkflowExecution(Completed|Failed|Canceled|TimedOut)$")) then "\(.eventTime) workflow \(.eventType)"
      elif (.eventType|test("ACTIVITY_TASK_COMPLETED$|ActivityTaskCompleted$")) then
        ($sched[(.activityTaskCompletedEventAttributes.scheduledEventId|tostring)]) as $s | "\(.eventTime) done   \($s.name) (scheduled \($s.t))"
      elif (.eventType|test("ACTIVITY_TASK_(FAILED|TIMED_OUT)$|ActivityTask(Failed|TimedOut)$")) then
        ($sched[((.activityTaskFailedEventAttributes.scheduledEventId // .activityTaskTimedOutEventAttributes.scheduledEventId)|tostring)]) as $s | "\(.eventTime) FAILED \($s.name) (scheduled \($s.t))"
      else empty end' "$SEC/workflow-$name.json" >"$LOG_DIR/workflow-$name.txt" 2>/dev/null || true
}

# What NVKE, Cluster API, the helper, SPIRE and Temporal show. Raw logs that can hold a token go to the secrets folder.
cmd_record() {
  local label=${1:-final} d since
  d="$LOG_DIR/record-$label"
  mkdir -p "$d"
  since=$(cat "$LOG_DIR/post-time.txt" 2>/dev/null || date -u +%FT%TZ)
  api get "/api/clusters/$(cluster_id)" | api_body | jq . >"$d/api-cluster.json" 2>&1 || true
  api get "/api/nodes?clusterID=$(cluster_id)" | api_body | jq . >"$d/api-nodes.json" 2>&1 || true
  api get "/api/clusters/$(cluster_id)/control-plane" | api_body | jq . >"$d/api-control-plane.json" 2>&1 || true
  k -n "$CAPI_NS" get clusters,machines,provisionedclusters,provisionedmachines,provisionedmachinetemplates -o wide >"$d/capi-objects.txt" 2>&1 || true
  k -n "$CAPI_NS" get clusters,machines,provisionedclusters,provisionedmachines -o yaml 2>/dev/null | mask >"$d/capi-objects.yaml" || true
  k -n "$CAPI_NS" get secrets -o custom-columns=NAME:.metadata.name,TYPE:.type,CREATED:.metadata.creationTimestamp >"$d/capi-secrets.txt" 2>&1 || true
  k get provisionedhostclaims -o wide >"$d/host-claims.txt" 2>&1 || true
  k get clusterstaticentries -o custom-columns=NAME:.metadata.name,SPIFFEID:.spec.spiffeID,PARENT:.spec.parentID,CREATED:.metadata.creationTimestamp 2>&1 | mask >"$d/spire-static-entries.txt" || true
  k -n spire-server exec spire-server-0 -c spire-server -- /opt/spire/bin/spire-server agent list 2>&1 | mask >"$d/spire-agents.txt" || true
  k -n "$HELPER_NS" logs deployment/nvke-lab-bootstrap-helper --since-time="$since" >"$d/helper.log" 2>&1 || true
  k -n provisioned-system logs deployment/provisioned-controller-manager --since-time="$since" 2>&1 | mask >"$d/provisioned-provider.log" || true
  k -n nvke-controller logs deployment/nvke-controller --since-time="$since" >"$SEC/nvke-controller-$label.log" 2>&1 || true
  mask <"$SEC/nvke-controller-$label.log" | grep -E '"level":"(WARN|ERROR)"|level=(WARN|ERROR)' | cut -c1-600 >"$d/nvke-controller-warn-error.txt" || true
  temporal workflow list --limit 100 >"$d/temporal-workflows.txt" 2>&1 || true
  # The workflow IDs come from the list. Each ID has the cluster ID or a node ID in it.
  awk 'NR>1 {print $2}' "$d/temporal-workflows.txt" | grep -E '^[A-Za-z]' | sort -u >"$d/.workflow-ids.txt" || true
  while read -r wid; do
    [ -n "$wid" ] && LOG_DIR="$d" workflow_timeline "$wid"
  done <"$d/.workflow-ids.txt"
  say "record is in $d"
}

cmd_evidence() {
  local label=${1:-final} d r c
  d="$LOG_DIR/evidence-$label"
  mkdir -p "$d"
  for r in "${REPLICAS[@]}"; do
    host_state "$r" >"$d/host-state-$r.txt" 2>&1
    pod "$r" journalctl --no-pager -b -u nvke-agent >"$SEC/journal-nvke-agent-$label-$r.txt" 2>&1 || true
    mask <"$SEC/journal-nvke-agent-$label-$r.txt" | grep -v 'init_config\|join_config' | cut -c1-700 >"$d/journal-nvke-agent-$r.txt" || true
    pod "$r" journalctl --no-pager -b -u spire-agent 2>&1 | mask | cut -c1-500 >"$d/journal-spire-agent-$r.txt" || true
    pod "$r" journalctl --no-pager -b -u kubelet 2>&1 | tail -400 >"$d/journal-kubelet-$r.txt" || true
    pod "$r" journalctl --no-pager -b -u ovs-vswitchd -u ovsdb-server -u nke-container-network >"$d/journal-ovs-units-$r.txt" 2>&1 || true
    pod "$r" sh -c 'tail -200 /var/log/nvke-agent-audit.log' 2>&1 | mask | cut -c1-600 >"$d/nvke-agent-audit-$r.txt" || true
    pod "$r" dmesg >"$d/dmesg-$r.txt" 2>&1 || true
    for c in ovnkube-controller etcd kube-apiserver; do
      pod "$r" sh -c "crictl logs \"\$(crictl ps -a --name '^$c\$' -q | head -1)\" 2>&1 | tail -1500" >"$d/log-$c-$r.txt" 2>&1 || true
    done
    pod "$r" sh -c 'jq -c "{name, role, phase, status, currentMessage, kubeadmStatus, cniPlugin, cniPluginStatus, completedPhases}" /var/lib/nvke/state.json' >"$d/agent-state-$r.json" 2>&1 || true
    k -n "$NS" describe pod "$(pn "$r")" >"$d/outer-pod-describe-$r.txt" 2>&1 || true
  done
  r=$(admin_host) || r=a
  ik "$r" get nodes -o wide >"$d/inner-nodes.txt" 2>&1 || true
  ik "$r" get nodes -o json 2>/dev/null | jq '[.items[] | {name: .metadata.name, labels: .metadata.labels, annotations: .metadata.annotations, providerID: .spec.providerID, taints: .spec.taints, addresses: .status.addresses, allocatable: .status.allocatable}]' >"$d/inner-nodes.json" 2>&1 || true
  ik "$r" get pods -A -o wide >"$d/inner-pods.txt" 2>&1 || true
  ik "$r" get events -A --sort-by=.lastTimestamp >"$d/inner-events.txt" 2>&1 || true
  ik "$r" get csr >"$d/inner-csr.txt" 2>&1 || true
  ( umask 077; pod "$r" cat /etc/kubernetes/admin.conf >"$SEC/kubeconfig-$CLUSTER_NAME" 2>/dev/null ) || true
  k -n "$NS" get all,pvc -o wide >"$d/outer-objects.txt" 2>&1 || true
  say "evidence is in $d"
}

cmd_down() {
  local r
  for r in "${REPLICAS[@]}"; do k -n "$NS" delete statefulset "cp-$r" --ignore-not-found --wait=true; done
  k -n "$NS" delete pod --all --ignore-not-found --wait=true
  k delete namespace "$NS" --ignore-not-found --wait=true
  for r in "${REPLICAS[@]}"; do k delete pv "$NS-cp-$r-var" "$NS-cp-$r-etcd" --ignore-not-found --wait=true; done
}

cmd_wipe() {
  check_devices
  if k get pv 2>/dev/null | grep -q "^$NS-cp-"; then
    echo "the volumes are still in the cluster. Run 'down' first."
    exit 1
  fi
  wait_node 60 "! losetup -a | grep -q -E 'volumeDevices/$NS-cp-'"
  node wipefs -a "${!EXPECT[@]}"
  node sh -c "blkid -p ${!EXPECT[*]}; echo \"blkid exit code \$? (2 = no signature)\""
}

times() {
  say "times (seconds)"
  {
    local r
    for r in "${REPLICAS[@]}"; do echo "host $r: pod create to systemd up $(between "$r-pod-create" "$r-node-up")"; done
    echo "POST to provisioned: $(between post provisioned)"
    echo "POST to three provisioned nodes: $(between post nodes-provisioned)"
    echo "POST to three Ready nodes in the new cluster: $(between post nodes-ready-final)"
  } | tee "$LOG_DIR/summary-times.txt"
}

cmd_full() {
  local rc=0 r
  cmd_wipe
  cmd_base
  for r in "${REPLICAS[@]}"; do cmd_node_up "$r"; done
  cmd_helper
  for r in "${REPLICAS[@]}"; do cmd_units "$r" before-post || true; done
  cmd_post
  cmd_wait || rc=1
  if [ "$rc" = 0 ]; then cmd_wait_nodes || rc=1; fi
  if [ "$rc" = 0 ]; then cmd_check final || rc=1; fi
  times || true
  cmd_record final || true
  cmd_evidence final || true
  if [ "$rc" = 0 ]; then echo "RESULT full: PASS"; else echo "RESULT full: FAIL"; fi
  return "$rc"
}

step=${1:-}
shift || true
case "$step" in
  base | node-up | units | helper | post | wait | wait-nodes | check | record | evidence | down | wipe | full)
    "cmd_${step//-/_}" "$@" 2>&1 | tee -a "$LOG_DIR/run.log"
    exit "${PIPESTATUS[0]}"
    ;;
  poll) poll_line ;;
  times) times ;;
  render) render "$@" ;;
  *) sed -n '2,24p' "$0"; exit 1 ;;
esac
