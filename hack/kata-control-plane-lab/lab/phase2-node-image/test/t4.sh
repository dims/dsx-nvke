#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Phase 2 step 3, test T4: one cluster through the real NVKE controller, as in block D, but each
# host is a pod in the form of section 5a with the node image for pods: no wrapper ConfigMap, no
# kernel config ConfigMap, no lab bootstrap helper, no image import by the run script.
#
# The order differs from block D in one point. The name of a node exists only after the POST, and
# the pod has the name of its Machine. So this script sends the POST first, waits for each
# ProvisionedMachine of the cluster to get a host, and then makes for that Machine:
#   1. a copy of the Secret <machine>-bootstrap-data of nvke-system in the pod namespace,
#   2. the two volumes and their claims (the devices of the host that the Machine got),
#   3. the pod <machine> with the fixed address of that host.
#
# It loads the functions of block D (d/endpoint-run/run.sh) and replaces the ones that name a pod.
# Usage: LOG_DIR=<run folder> t4.sh <step>
#   wipe, base, post, pods, wait, wait-nodes, check, record, evidence, endpoint, patch-check, reach,
#   probe-start, probe-stop, traffic, tunnels, names, preflight, times, down
#   flow     wipe, base, post, pods, wait, wait-nodes, check, record, evidence, endpoint, reach, names, preflight
set -euo pipefail
. /root/kata-cp/bin/env.sh
P2="$(cd "$(dirname "$0")" && pwd)"
D=$W/d/endpoint-run
export NS=${NS:-p2c}
export IMAGE=${IMAGE:-nvke-node-podvm:bcc4376f-p2}
export LOG_DIR=${LOG_DIR:-$W/logs/p2/t4-run-1}
BIND_TIMEOUT=${BIND_TIMEOUT:-600}
BLOCK_D=${BLOCK_D:-$W/logs/d/d-run-2}

# The functions and settings of block D, without its command dispatch at the end.
# shellcheck disable=SC1090
source <(sed '/^step=\${1:-}$/,$d' "$D/run.sh")
HERE=$D # the templates and the measure scripts of block D

# --- the pod of a host has the name of its Machine --------------------------------------------
PODS_FILE=$LOG_DIR/pods.txt # one line for each host: <a|b|c> <machine name>
declare -A PODS=()
load_pods() {
  local r m
  [ -f "$PODS_FILE" ] || return 0
  while read -r r m; do PODS[$r]=$m; done <"$PODS_FILE"
}
load_pods
pn() { echo "${PODS[$1]:?no pod for host $1 yet}"; }
mac_of() { local IFS=.; set -- $1; printf '02:00:%02x:%02x:%02x:%02x' "$1" "$2" "$3" "$4"; }

render_p2() { # render_p2 <template> <host> <machine>
  local r=$2 m=$3
  export NS IMAGE RUNTIME_CLASS CPU MEMORY IP_API ETP CLUSTER_NAME
  export CLUSTER="$CLUSTER_NAME" SLOT="$r" MACHINE="$m" ADDRESS="${IPS[$r]}/16" VAR_LOOP="${VAR_LOOPS[$r]}" ETCD_LOOP="${ETCD_LOOPS[$r]}" HOST_NODE="${HOST_NODES[$r]}"
  export SECRET="$m-bootstrap-data"
  export MAC; MAC=$(mac_of "${IPS[$r]}")
  # Not in the contract: the three settings of the block D pods.
  export EXTRA_SPEC; EXTRA_SPEC=$(printf '  automountServiceAccountToken: false\n  enableServiceLinks: false\n  terminationGracePeriodSeconds: %s' "$GRACE")
  envsubst '$NS $IMAGE $RUNTIME_CLASS $CPU $MEMORY $IP_API $ETP $CLUSTER_NAME $CLUSTER $SLOT $MACHINE $ADDRESS $MAC $VAR_LOOP $ETCD_LOOP $HOST_NODE $SECRET $EXTRA_SPEC' <"$P2/$1"
}

device_users() { k get pv -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.local.path}{"\n"}{end}' | grep -E " ($(IFS='|'; echo "${!EXPECT[*]}"))\$" || true; }

cmd_wipe() {
  check_devices
  if [ -n "$(device_users)" ]; then
    echo "a volume still uses a device of this test:"
    device_users
    exit 1
  fi
  node wipefs -a "${!EXPECT[@]}"
  node sh -c "blkid -p ${!EXPECT[*]}; echo \"blkid exit code \$? (2 = no signature)\""
}

cmd_base() {
  check_devices
  say "memory and load of the machine"
  free -g
  uptime
  say "namespace $NS, the node network, the shared API Service. No ConfigMap."
  k create namespace "$NS" --dry-run=client -o yaml | nodei "${KC[@]}" apply -f -
  NS=$NS envsubst '$NS' <"$D/nad.yaml.tmpl" | nodei "${KC[@]}" apply -f -
  render_p2 api-service.yaml.tmpl a none >"$LOG_DIR/service-cp-api.yaml"
  nodei "${KC[@]}" apply -f - <"$LOG_DIR/service-cp-api.yaml"
  k -n "$NS" wait --for=jsonpath='{.status.loadBalancer.ingress[0].ip}'="$IP_API" service/cp-api --timeout=60s
  k -n "$NS" get svc -o wide | tee "$LOG_DIR/services.txt"
  say "what must be absent"
  echo "ConfigMaps in $NS: $(k -n "$NS" get configmaps -o name | grep -v kube-root-ca.crt | tr '\n' ' ')(end of list)"
  echo "lab bootstrap helper: $(k -n "$HELPER_NS" get deployments,pods -o name 2>&1 | tr '\n' ' ')(end of list)"
  echo "image in the host nodes: $(for n in $WORKERS; do docker exec "$n" crictl inspecti -o json "docker.io/library/$IMAGE" 2>/dev/null | jq -r '.status.id' | cut -c8-19; done | tr '\n' ' ')"
}

# The Secret of NVKE for one Machine, copied into the pod namespace with the same name and data.
# The data goes through a pipe from one kubectl to the next. No file and no log line has it.
copy_secret() {
  local m=$1 i
  for i in $(seq 1 60); do
    k -n "$CAPI_NS" get secret "$m-bootstrap-data" >/dev/null 2>&1 && break
    sleep 1
  done
  k -n "$CAPI_NS" get secret "$m-bootstrap-data" -o json |
    jq --arg ns "$NS" --arg c "$CLUSTER_NAME" --arg m "$m" '{apiVersion: "v1", kind: "Secret", type: .type, data: .data,
      metadata: {name: .metadata.name, namespace: $ns, labels: {"cluster.x-k8s.io/cluster-name": $c, "podvm.infrastructure.cluster.x-k8s.io/machine-name": $m}}}' |
    nodei "${KC[@]}" apply -f -
}

make_pod() {
  local r=$1 m=$2
  stamp "$r-bound-seen"
  copy_secret "$m"
  stamp "$r-secret-copied"
  render_p2 volumes.yaml.tmpl "$r" "$m" | nodei "${KC[@]}" apply -f - | tr '\n' ' '
  echo
  render_p2 pod.yaml.tmpl "$r" "$m" >"$LOG_DIR/pod-$r.yaml"
  stamp "$r-pod-create"
  nodei "${KC[@]}" apply -f - <"$LOG_DIR/pod-$r.yaml"
  say "host $r (${HOSTS[$r]}, ${IPS[$r]}, $(mac_of "${IPS[$r]}"), ${HOST_NODES[$r]}): Machine $m, Secret copied, pod made at $(date -u +%T.%3N)"
}

# Wait for each ProvisionedMachine of the cluster to get a host, and make its pod at once.
cmd_pods() {
  local end made=0 m h r x
  : >"$PODS_FILE"
  end=$(( $(date +%s) + BIND_TIMEOUT ))
  say "wait for the three ProvisionedMachine objects of $CLUSTER_NAME to get a host (one look each 2 s, limit $BIND_TIMEOUT s)"
  while [ "$made" -lt 3 ] && [ "$(date +%s)" -lt "$end" ]; do
    while read -r m h; do
      [ -n "${h:-}" ] || continue
      grep -q " $m\$" "$PODS_FILE" && continue
      r=""
      for x in "${REPLICAS[@]}"; do [ "${HOSTS[$x]}" = "$h" ] && r=$x; done
      [ -n "$r" ] || die "the Machine $m has the unknown host $h"
      echo "$(date -u +%T.%3N) ProvisionedMachine $m has the host $h ($(between post "$r-bound-seen" 2>/dev/null || true))"
      make_pod "$r" "$m"
      echo "$r $m" >>"$PODS_FILE"
      PODS[$r]=$m
      made=$((made + 1))
    done < <(k -n "$CAPI_NS" get provisionedmachines -l "cluster.x-k8s.io/cluster-name=$CLUSTER_NAME" -o json 2>/dev/null |
      jq -r '.items[] | "\(.metadata.name) \(.status.hostName // "")"')
    [ "$made" -ge 3 ] || sleep 2
  done
  [ "$made" = 3 ] || { say "FAIL: only $made of 3 Machines got a host in $BIND_TIMEOUT s"; return 1; }
  for r in "${REPLICAS[@]}"; do
    k -n "$NS" wait --for=jsonpath='{.status.phase}'=Running "pod/$(pn "$r")" --timeout=300s
    stamp "$r-running"
  done
  for r in "${REPLICAS[@]}"; do
    wait_node 300 "${KC[*]} -n $NS exec $(pn "$r") -- systemctl is-active containerd >/dev/null 2>&1" || die "containerd is not active in the pod of host $r"
    stamp "$r-node-up"
  done
  k -n "$NS" get pods -o wide
  for r in "${REPLICAS[@]}"; do
    echo "host $r: POST to host known $(between post "$r-bound-seen") s, to pod create $(between post "$r-pod-create") s; pod create to Running $(between "$r-pod-create" "$r-running") s"
  done
}

# Point 4 of the task: the pod name, the hostname, the name in NVKE, the agent, the kubelet and the mirror pods.
cmd_names() {
  local out="$LOG_DIR/names.txt" r m fail=0 h api_names
  {
    say "names at $(date -u +%FT%TZ)"
    api_names=$(api get "/api/nodes?clusterID=$(cluster_id)" | api_body | jq -r '(.nodes // [])[] | "\(.name) \(.ip)"')
    h=$(admin_host) || h=a
    for r in "${REPLICAS[@]}"; do
      m=$(pn "$r")
      echo "host $r, Machine and pod name $m:"
      echo "  pod: hostname field $(k -n "$NS" get pod "$m" -o jsonpath='{.spec.hostname}')(empty = the pod name), label $(k -n "$NS" get pod "$m" -o jsonpath='{.metadata.labels.podvm\.infrastructure\.cluster\.x-k8s\.io/machine-name}')"
      echo "  in the guest: hostname $(pod "$r" hostname), /etc/hostname $(pod "$r" cat /etc/hostname), PODVM_MACHINE_NAME $(pod "$r" sh -c '. /run/podvm/env; echo $PODVM_MACHINE_NAME'), bootstrap marker $(pod "$r" cat /var/lib/podvm/bootstrap/machine)"
      echo "  NVKE API: $(grep -E "^$m " <<<"$api_names" || echo absent)"
      echo "  agent state file: name $(pod "$r" jq -r '.name // .nodeName // "?"' /var/lib/nvke/state.json 2>&1 | head -1)"
      echo "  kubelet: node $(ik "$h" get node "$m" -o jsonpath='{.metadata.name}{" hostname label "}{.metadata.labels.kubernetes\.io/hostname}{" address "}{.status.addresses[?(@.type=="InternalIP")].address}{" Hostname address "}{.status.addresses[?(@.type=="Hostname")].address}{" providerID "}{.spec.providerID}{" machineID "}{.status.nodeInfo.machineID}' 2>&1)"
      echo "  mirror pods: $(ik "$h" -n kube-system get pods --field-selector "spec.nodeName=$m" -o json | jq -r '[.items[] | select(.metadata.annotations["kubernetes.io/config.mirror"]) | .metadata.name] | sort | join(" ")')"
      echo "  etcd member: $(etcdctl "$h" member list -w simple 2>/dev/null | grep -F ", $m," | cut -d, -f3,5 | tr -d ' ')"
      [ "$(pod "$r" hostname)" = "$m" ] || { echo "  FAIL hostname"; fail=1; }
      grep -q -E "^$m ${IPS[$r]}\$" <<<"$api_names" || { echo "  FAIL the NVKE API has no node $m with ${IPS[$r]}"; fail=1; }
      [ "$(ik "$h" get node "$m" -o jsonpath='{.metadata.name}' 2>/dev/null)" = "$m" ] || { echo "  FAIL no node $m in the new cluster"; fail=1; }
      for x in etcd kube-apiserver kube-controller-manager kube-scheduler; do
        ik "$h" -n kube-system get pod "$x-$m" >/dev/null 2>&1 || { echo "  FAIL no mirror pod $x-$m"; fail=1; }
      done
      etcdctl "$h" member list -w simple 2>/dev/null | grep -q -F ", $m," || { echo "  FAIL no etcd member $m"; fail=1; }
    done
    echo "machine IDs of the three nodes: $(ik "$h" get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.machineID}{" "}{end}' | tr ' ' '\n' | grep -c . ) values, $(ik "$h" get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.machineID}{"\n"}{end}' | sort -u | grep -c .) different"
    [ "$fail" = 0 ] && echo "RESULT names: PASS" || echo "RESULT names: FAIL"
  } 2>&1 | tee "$out"
  grep -q "RESULT names: PASS" "$out"
}

# The NodePreflight step of each node workflow, against block D, and what the pod did in that time.
cmd_preflight() {
  local out="$LOG_DIR/preflight.txt" r m id f
  dur() { awk '/done   NodePreflight/ { split($1, a, "T"); split($5, b, "T"); gsub(/[Z)]/, "", a[2]); gsub(/[Z)]/, "", b[2]); split(a[2], x, ":"); split(b[2], y, ":"); printf "scheduled %s done %s = %.1f s\n", b[2], a[2], (x[1]*3600+x[2]*60+x[3]) - (y[1]*3600+y[2]*60+y[3]) }' "$1"; }
  {
    say "NodePreflight at $(date -u +%FT%TZ)"
    say "this run ($LOG_DIR)"
    for r in "${REPLICAS[@]}"; do
      m=$(pn "$r")
      id=$(jq -r --arg n "$m" '(.nodes // [])[] | select(.name==$n) | .id' "$LOG_DIR/record-final/api-nodes.json")
      f="$LOG_DIR/record-final/workflow-provision-node-$id.txt"
      echo "host $r ($m): $(dur "$f")"
      grep -E 'WaitForCAPIMachineReady|NodePreflight|workflow started' "$f" | sed 's/^/    /'
      echo "    failed attempts that the poll saw: $(grep -F "node $m " "$LOG_DIR/timeline.txt" | grep -o '[0-9]* attempts\? ha[sv]e\? failed' | sort -u | tr '\n' ';')"
      echo "    pod: POST to host known $(between post "$r-bound-seen") s, to pod create $(between post "$r-pod-create") s, pod create at $(date -u -d "@$(awk -v k="$r-pod-create" '$2==k {print $1}' "$LOG_DIR/times.txt")" +%T.%3N)"
      k -n "$NS" logs "$m" 2>/dev/null | grep -a 'PODVM:' | tr -d '\r' | grep -E 'start at|state is ready' | sed 's/^/    /'
      pod "$r" sh -c 'journalctl -b --no-pager -o short-precise -u podvm-bootstrap -u podvm-bootstrap-final | grep RESULT | cut -c1-230; echo "boot: $(systemd-analyze 2>&1 | head -1); slowest unit: $(systemd-analyze blame --no-pager 2>/dev/null | head -1 | tr -s " ")"; journalctl -b --no-pager -o short-precise -u nvke-agent | grep -m1 "initializeNodeServer" | cut -c1-60; journalctl -b --no-pager -o short-precise -u nvke-agent | grep -m1 "\"rpc\":\"ExecuteNodePreflight\"" | cut -c1-60 | sed "s/\$/ first ExecuteNodePreflight call/"; journalctl -b --no-pager -o short-precise -u spire-agent | grep -m1 -i -E "attest|SVID" | cut -c1-140' 2>&1 | sed 's/^/    /'
    done
    say "block D ($BLOCK_D): the pods were up before the POST, and the lab helper copied the data"
    for f in "$BLOCK_D"/record-final/workflow-provision-node-*.txt; do
      # The run folder of block D has the workflows of run 1 too. Take the ones of its cluster.
      id=$(basename "$f" .txt); id=${id#workflow-provision-node-}
      jq -e --arg i "$id" '(.nodes // [])[] | select(.id==$i)' "$BLOCK_D/record-final/api-nodes.json" >/dev/null 2>&1 || continue
      echo "node $(jq -r --arg i "$id" '(.nodes // [])[] | select(.id==$i) | .name' "$BLOCK_D/record-final/api-nodes.json"): $(dur "$f")"
    done
  } 2>&1 | tee "$out"
}

# Stock etcd: the flags of kubeadm, no patch file of the lab, no refused peer connection.
cmd_etcd() {
  local label=${1:-final} out r fail=0 f n
  out="$LOG_DIR/etcd-$label.txt"
  {
    say "etcd settings ($label) at $(date -u +%FT%TZ)"
    for r in "${REPLICAS[@]}"; do
      f=$(pod "$r" sh -c "grep -o -E -- '--(listen-client-urls|listen-peer-urls|initial-advertise-peer-urls|advertise-client-urls|peer-skip-client-san-verification)=[^ ]*' /etc/kubernetes/manifests/etcd.yaml | tr '\n' ' '")
      n=$(pod "$r" sh -c 'crictl logs "$(crictl ps --name etcd -q | head -1)" 2>&1 | grep -c "rejected connection on peer endpoint"' 2>/dev/null || true)
      echo "host $r: $f"
      echo "host $r: patches folder [$(pod "$r" sh -c 'ls /etc/kubernetes/patches 2>/dev/null | tr "\n" " "')], refused peer connections ${n:-?}"
      case "$f" in *"--listen-client-urls=https://127.0.0.1:2379,https://${IPS[$r]}:2379"*"--listen-peer-urls=https://${IPS[$r]}:2380"*) ;; *) echo "FAIL host $r: the listen flags are not the kubeadm defaults"; fail=1 ;; esac
      case "$f" in *peer-skip-client-san-verification*) echo "FAIL host $r: a lab flag"; fail=1 ;; esac
      pod "$r" test -e /etc/kubernetes/patches/etcd+json.json && { echo "FAIL host $r: the lab patch file exists"; fail=1; }
      [ "${n:-1}" = 0 ] || { echo "FAIL host $r: refused peer connections"; fail=1; }
    done
    h=$(admin_host) || h=a
    etcdctl "$h" member list -w simple || true
    etcdctl "$h" endpoint health --cluster 2>&1 || true
    [ "$fail" = 0 ] && echo "RESULT etcd $label: PASS" || echo "RESULT etcd $label: FAIL"
  } 2>&1 | tee "$out"
  grep -q "RESULT etcd $label: PASS" "$out"
}

# A new pod for the same Machine, with the real data of NVKE: delete the pod of one host and make it
# again from the same manifest (same name, claims, Secret, address), as the provider does for a
# lost pod. Default: the host of the node that ran kubeadm init, as in block D.
cmd_replace() {
  local r=${1:-} o out fail=0 watch=${REPLACE_WATCH:-240} pollpid m nn t0 hb i okk=0 oke=0
  [ -n "$r" ] || r=$(init_host) || die "no init node in the NVKE API"
  for o in "${REPLICAS[@]}"; do [ "$o" != "$r" ] && break; done
  m=$(pn "$r")
  out="$LOG_DIR/replace-$r.txt"
  {
    say "new pod for the Machine $m (host $r, address ${IPS[$r]}) at $(date -u +%FT%TZ). Observer host: $o"
    say "before: NVKE, etcd, endpoints of cp-api, the state on the /var volume"
    poll_line
    etcdctl "$o" member list -w simple || true
    k -n "$NS" get endpointslices -l kubernetes.io/service-name=cp-api -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{" ready="}{.conditions.ready}{" "}{.targetRef.name}{"\n"}{end}'
    k -n "$NS" get pod "$m" -o jsonpath='{"pod uid "}{.metadata.uid}{" ip "}{.status.podIP}{"\n"}'
    pod "$r" sh -c 'echo "markers: $(cat /var/lib/podvm/bootstrap/machine) | $(cat /var/lib/podvm/bootstrap/commands) | changed $(stat -c %Y /var/lib/podvm/bootstrap/machine /var/lib/podvm/bootstrap/commands | tr "\n" " ")| machine ID $(cat /etc/machine-id)"; echo "SPIRE data: $(ls /var/lib/spire-agent | tr "\n" " ")| changed $(stat -c %Y /var/lib/spire-agent/agent-data.json 2>/dev/null)"; echo "files of NVKE: $(sha256sum /etc/spire-agent/agent.conf /etc/spire-agent/initial-trust-bundle.pem /etc/default/nke-agent | cut -c1-12 | tr "\n" " ")"' | tee "$LOG_DIR/.replace-before"
    cmd_probe_start replace $((watch + 120))
    cmd_probe_start replace-node $((watch + 120)) "${IPS[$r]}:6443"
    sleep 10
    ( end=$(( $(date +%s) + watch )); while [ "$(date +%s)" -lt "$end" ]; do poll_line >>"$LOG_DIR/replace-nvke-timeline.txt" 2>&1; sleep "$POLL"; done ) &
    pollpid=$!
    stamp replace-start
    say "delete pod $m at $(date -u +%T)"
    k -n "$NS" delete pod "$m" --wait=true
    stamp replace-old-pod-gone
    nodei "${KC[@]}" apply -f - <"$LOG_DIR/pod-$r.yaml"
    stamp replace-pod-create
    k -n "$NS" wait --for=jsonpath='{.status.phase}'=Running "pod/$m" --timeout=300s
    wait_node 300 "${KC[*]} -n $NS exec $m -- systemctl is-active containerd >/dev/null 2>&1" || { echo "FAIL containerd of host $r"; fail=1; }
    stamp replace-node-up
    if k -n "$NS" wait --for=condition=Ready "pod/$m" --timeout=300s; then stamp replace-readyz; else echo "FAIL /readyz of host $r"; fail=1; fi
    k -n "$NS" get pod "$m" -o jsonpath='{"new pod uid "}{.metadata.uid}{" ip "}{.status.podIP}{"\n"}'
    t0=$(awk '$2=="replace-old-pod-gone" {print int($1)}' "$LOG_DIR/times.txt")
    for i in $(seq 1 60); do
      hb=$(ik "$o" get node "$m" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{" "}{.status.conditions[?(@.type=="Ready")].lastHeartbeatTime}' 2>/dev/null || true)
      if [ "${hb%% *}" = True ] && [ "$(date -u -d "${hb##* }" +%s 2>/dev/null || echo 0)" -gt "$t0" ]; then okk=1; break; fi
      sleep 5
    done
    if [ "$okk" = 1 ]; then stamp replace-nodes-ready; echo "node $m: Ready with the heartbeat ${hb##* }"; else echo "FAIL node $m has no new Ready heartbeat: $hb"; fail=1; fi
    for i in $(seq 1 36); do
      if etcdctl "$o" endpoint health --cluster >/dev/null 2>&1; then oke=1; break; fi
      sleep 5
    done
    if [ "$oke" = 1 ]; then stamp replace-etcd-healthy; else echo "FAIL etcd health"; fail=1; fi
    ik "$o" get nodes -o wide || true
    say "times after the delete (s): old pod gone $(between replace-start replace-old-pod-gone), new pod made $(between replace-start replace-pod-create), systemd up $(between replace-start replace-node-up), /readyz of the pod $(between replace-start replace-readyz), new kubelet heartbeat seen $(between replace-start replace-nodes-ready), etcd healthy $(between replace-start replace-etcd-healthy)"
    say "the new pod: entry point, bootstrap units, cloud-init answer, SPIRE agent, agent"
    k -n "$NS" logs "$m" 2>/dev/null | grep -a 'PODVM:' | tr -d '\r' | grep -E 'start at|first use|state is ready'
    pod "$r" sh -c 'journalctl -b --no-pager -o short-precise -u podvm-bootstrap -u podvm-bootstrap-final | grep RESULT | cut -c1-260
      echo "cloud-init: $(cloud-init status | head -1); systemd: $(systemctl is-system-running), failed units $(systemctl --failed --no-legend --plain | wc -l)"
      journalctl -b --no-pager -o short-precise -u spire-agent | grep -i -E "pre-existing|attestation|SVID is|Starting Workload|rotat" | cut -c1-200 | head -6
      echo "agent: [$(ps -o args= -C nvke-agent | head -1)] restarts $(systemctl show nvke-agent -p NRestarts --value), first line $(journalctl -b --no-pager -o short-precise -u nvke-agent | grep -m1 initializeNodeServer | cut -c1-22)"' 2>&1 || true
    pod "$r" sh -c 'echo "markers: $(cat /var/lib/podvm/bootstrap/machine) | $(cat /var/lib/podvm/bootstrap/commands) | changed $(stat -c %Y /var/lib/podvm/bootstrap/machine /var/lib/podvm/bootstrap/commands | tr "\n" " ")| machine ID $(cat /etc/machine-id)"; echo "SPIRE data: $(ls /var/lib/spire-agent | tr "\n" " ")| changed $(stat -c %Y /var/lib/spire-agent/agent-data.json 2>/dev/null)"; echo "files of NVKE: $(sha256sum /etc/spire-agent/agent.conf /etc/spire-agent/initial-trust-bundle.pem /etc/default/nke-agent | cut -c1-12 | tr "\n" " ")"' | tee "$LOG_DIR/.replace-after"
    # The markers, the machine ID and the files of NVKE must be the same. The SPIRE data file can change (a new SVID).
    if diff <(grep -E '^(markers|files)' "$LOG_DIR/.replace-before") <(grep -E '^(markers|files)' "$LOG_DIR/.replace-after"); then echo "ok   markers, machine ID and the files of NVKE are the same as before"; else echo "FAIL the state on the /var volume changed"; fail=1; fi
    pod "$r" sh -c 'journalctl -b --no-pager -u podvm-bootstrap -u podvm-bootstrap-final | grep -c "RESULT repeat"' | grep -q -x 2 && echo "ok   two repeat runs (files, commands), no first run" || { echo "FAIL not a repeat run"; fail=1; }
    say "wait for the end of the NVKE poll ($watch s after the delete)"
    wait "$pollpid" || true
    cmd_probe_stop replace
    cmd_probe_stop replace-node
    say "what NVKE reported each $POLL s: lines of the node, and of the cluster"
    grep -F "ip=${IPS[$r]} " "$LOG_DIR/replace-nvke-timeline.txt" | sed -E 's/\[[^]]*\]//g' | sort | uniq -c
    grep ' cluster: ' "$LOG_DIR/replace-nvke-timeline.txt" | sed -E 's/^[0-9:]+ //' | sort | uniq -c
    say "after: NVKE, etcd, endpoints of cp-api, workflows that started after the delete"
    poll_line
    etcdctl "$o" member list -w simple || true
    etcdctl "$o" endpoint health --cluster 2>&1 || true
    k -n "$NS" get endpointslices -l kubernetes.io/service-name=cp-api -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{" ready="}{.conditions.ready}{" "}{.targetRef.name}{"\n"}{end}'
    temporal workflow list --query "StartTime > \"$(date -u -d "@$(awk '$2=="replace-start" {print int($1)}' "$LOG_DIR/times.txt")" +%FT%TZ)\"" 2>&1 | head -20 || true
    [ "$fail" = 0 ] && echo "RESULT replace: PASS" || echo "RESULT replace: FAIL"
  } 2>&1 | tee "$out"
  grep -q "RESULT replace: PASS" "$out"
}

times() {
  say "times (seconds)"
  {
    local r
    for r in "${REPLICAS[@]}"; do
      echo "host $r: POST to host known $(between post "$r-bound-seen"), to Secret copied $(between post "$r-secret-copied"), to pod create $(between post "$r-pod-create"), to pod Running $(between post "$r-running"), to containerd active $(between post "$r-node-up")"
    done
    echo "POST to provisioned: $(between post provisioned)"
    echo "POST to three provisioned nodes: $(between post nodes-provisioned)"
    echo "POST to three Ready nodes in the new cluster: $(between post nodes-ready-final)"
  } | tee "$LOG_DIR/summary-times.txt"
}

cmd_down() {
  local r
  k -n "$NS" delete pod --all --ignore-not-found --wait=true
  k delete namespace "$NS" --ignore-not-found --wait=true
  for r in "${REPLICAS[@]}"; do k delete pv "$NS-$r-var" "$NS-$r-etcd" --ignore-not-found --wait=true; done
}

cmd_flow() {
  local rc=0 r
  cmd_wipe
  cmd_base
  cmd_probe_start run 1500 || true
  for r in "${REPLICAS[@]}"; do cmd_probe_start "node-$r" 1500 "${IPS[$r]}:6443" || true; done
  cmd_post
  cmd_pods || rc=1
  if [ "$rc" = 0 ]; then cmd_wait || rc=1; fi
  if [ "$rc" = 0 ]; then cmd_wait_nodes || rc=1; fi
  if [ "$rc" = 0 ]; then cmd_check final || rc=1; fi
  cmd_probe_stop run || true
  for r in "${REPLICAS[@]}"; do cmd_probe_stop "node-$r" || true; done
  times || true
  cmd_record final || true
  cmd_evidence final || true
  if [ "$rc" = 0 ]; then cmd_endpoint final || rc=1; fi
  if [ "$rc" = 0 ]; then cmd_reach final || rc=1; fi
  cmd_etcd final || rc=1
  cmd_names || rc=1
  cmd_preflight || true
  if [ "$rc" = 0 ]; then echo "RESULT flow: PASS"; else echo "RESULT flow: FAIL"; fi
  return "$rc"
}

step=${1:-}
shift || true
case "$step" in
  wipe | base | post | pods | wait | wait-nodes | check | record | evidence | endpoint | patch-check | reach | probe-start | probe-stop | names | preflight | etcd | replace | down | flow | units)
    "cmd_${step//-/_}" "$@" 2>&1 | tee -a "$LOG_DIR/run.log"
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
  times) times ;;
  render) render_p2 "$@" ;;
  *) sed -n '2,20p' "$0"; exit 1 ;;
esac
