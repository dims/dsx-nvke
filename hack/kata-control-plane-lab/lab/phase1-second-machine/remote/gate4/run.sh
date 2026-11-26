#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Gate 4: three pods, each one a kubeadm control plane node. The node address of a replica is
# the LoadBalancer IP of its Service, so the replica keeps its identity when its pod is new.
#
# Each kubectl, crictl and curl call runs inside a kind node (docker exec), so the host opens
# no TCP connection. Each wait loop sleeps one second between tries.
#
# This copy is for a host cluster with more than one node (lab copy on the-second-machine).
# kubectl, curl and the loops run in KIND_NODE, the control plane node of the host cluster.
# Each replica has its own host node (HOST_NODES): its two volumes have a node affinity for
# that node, which also places the pod there. A command that needs the node of a replica
# (crictl, a cgroup read, losetup, wipefs) runs in that node (function rnode).
#
# Usage: run.sh <step>
#   services            make the namespace, the wrapper ConfigMap and the four Services
#   node-up <r>         make the volumes and the owner (StatefulSet or bare Pod) of replica r (a, b, c)
#   init                kubeadm init on replica a
#   join <r>            kubeadm join --control-plane on replica r
#   check [label]       step 3: etcd member list, /readyz through each Service, nodes of the inner cluster
#   reach [label]       step 6: each pod calls its own address and the shared address
#   identity [label]    save the identity of each replica (certificate checksums, etcd members, node UID)
#   replace <r> [label] step 4: delete the pod of replica r, wait for the new pod, compare the identity
#   restart <r> [label] stop the container of replica r in place (crictl stop), then compare the identity
#   outage [label]      delete the pods of all three replicas at the same time, wait for quorum, compare the identity
#   host-loss <who> <seconds> [label]  stop the host node of a replica (follower, leader, a, b, c or all), start it
#                       again after the time, record the host cluster and the inner cluster, compare the identity
#   peercheck [label]   show what the etcd peer check uses: the etcd flags, the names in the peer certificate, the DNS answer
#   dns-outage <r> [label]  stop the DNS of the host cluster, replace the pod of replica r, start the DNS again
#   move <r> [label]    block C: cordon the host node of replica r and delete its pod, so that the pod moves (PV_NODES=all)
#   host-move <who> <seconds> [label]  block C: stop the host node of a replica and leave it down, then the operator
#                       step (out-of-service taint), so that the pod moves to another node
#   to-bare <r>         change the owner of replica r from StatefulSet to bare Pod (same claims)
#   to-sts <r>          change the owner of replica r back to a StatefulSet
#   loop-start, loop-stop   the loop in the kind node that calls the shared endpoint each second
#   quorum              exit code 0 when the etcd member of one replica commits a proposal
#   diag [label]        save the etcd, API server and kubelet logs of each replica
#   logs                save the pod specs, the Services and the logs
#   down                delete the pods, the claims, the Services, the namespace and the volumes
#   wipe                remove the filesystem signatures from the six loop devices (after "down")
#   full                one full run from empty volumes: steps 3, 4 and 6, then down
#
# Variables (defaults are the final design):
#   ETCD_LISTEN=all|default   all = etcd listens on 0.0.0.0. default = the kubeadm default (the node address only)
#   ETCD_SAN_SKIP=1|0         1 = etcd flag peer-skip-client-san-verification
#   ETP=Cluster|Local         externalTrafficPolicy of the Service of a replica
#   ETCD_PEER_DNS=0|1         1 = keep the etcd peer check. One headless Service (cp-peer) selects all replicas, and
#                             its DNS name is in each peer certificate (peerCertSANs). etcd then finds the pod IP of
#                             a peer in the DNS of the host cluster. Use it with ETP=Local and ETCD_SAN_SKIP=0:
#                             with ETP=Cluster the source of a call is an address of the host node, not the pod IP.
#   INSTANCE=1|2              2 = a second cluster next to the first one: namespace gate4b, other addresses and devices
#   ETCD_PATCH=0|1            1 = the two etcd settings come from a kubeadm patch file in the pod
#                             (/etc/kubernetes/patches/etcd+json.json), not from the kubeadm config. NVKE sets that
#                             patches folder for init and join, so this is the form that needs no NVKE change.
#                             Use it with ETCD_LISTEN=default and ETCD_SAN_SKIP=0.
#   ADDR_FORM=eth0|bridge|none  where the node address is in the pod
#   REPAIR=off|on             the address repair of the kind entrypoint
#   OWNER=sts|bare            the owner that node-up makes
#   RUNTIME_CLASS, G1_SKIP, STOP_TIMEOUT   example for a Kata class with the kill fix and the exec fix:
#     RUNTIME_CLASS=kata-clh-runtime-rs-fix-direct G1_SKIP=init-cgroup STOP_TIMEOUT= KEEP=1 run.sh full
set -euo pipefail

INSTANCE=${INSTANCE:-1}
case "$INSTANCE" in
  1) NS=${NS:-gate4} SFX="" ;;
  2) NS=${NS:-gate4b} SFX="-2" ;;
  *)
    echo "INSTANCE must be 1 or 2" >&2
    exit 1
    ;;
esac
RUNTIME_CLASS=${RUNTIME_CLASS-kata-clh-runtime-rs} # empty = default runtime (runc)
SNAPSHOTTER=${SNAPSHOTTER-overlayfs}
KERNEL_CONFIG=${KERNEL_CONFIG-/scratch/kata-cp/logs/kata-guest-kernel-config-6.18.62-211.txt}
STOP_TIMEOUT=${STOP_TIMEOUT-10} # seconds for DefaultTimeoutStopSec of systemd in the node (gate 1). Empty = the systemd default
G1_SKIP=${G1_SKIP:-}            # wrapper steps to leave out. "init-cgroup" for a Kata class with the exec fix
KEEP=${KEEP:-0}                 # 1 = "full" keeps the cluster at its end, with three StatefulSets
GRACE=${GRACE:-20}
CPU=${CPU:-4}
MEMORY=${MEMORY:-6Gi}
IMAGE=${IMAGE:-kindest/node:v1.36.4}
K8S_VERSION=${K8S_VERSION:-v1.36.4}
KIND_NODE=${KIND_NODE:-kata-cp-control-plane}
ETCD_LISTEN=${ETCD_LISTEN:-all}
ETCD_SAN_SKIP=${ETCD_SAN_SKIP:-1}
ETP=${ETP:-Cluster}
ETCD_PEER_DNS=${ETCD_PEER_DNS:-0}
ETCD_PATCH=${ETCD_PATCH:-0}
ADDR_FORM=${ADDR_FORM:-eth0}
REPAIR=${REPAIR:-off}
OWNER=${OWNER:-sts}
IGNORE_PREFLIGHT=${IGNORE_PREFLIGHT-}
LOOP_MAP=${LOOP_MAP:-/scratch/kata-cp/disks/loop-map.txt}
LOG_DIR=${LOG_DIR:-/scratch/kata-cp/logs/gate4/$(date +%Y%m%d-%H%M%S)}
# The bootstrap token and the certificate key of a run. They stay outside the notes and the logs.
SECRET_DIR=${SECRET_DIR:-/scratch/kata-cp/gate4-secrets$SFX}

# The replicas: node address, device for /var, device for /var/lib/etcd, size of /var.
REPLICAS=(a b c)
IP_API=172.29.255.210
declare -A IPS=([a]=172.29.255.211 [b]=172.29.255.212 [c]=172.29.255.213)
declare -A VAR_LOOPS=([a]=/dev/loop60 [b]=/dev/loop61 [c]=/dev/loop62)
declare -A ETCD_LOOPS=([a]=/dev/loop63 [b]=/dev/loop64 [c]=/dev/loop65)
declare -A VAR_SIZES=([a]=20Gi [b]=20Gi [c]=20Gi)
ETCD_SIZE=8Gi
# The image file that each device must have in the loop map. No other device is permitted.
declare -A EXPECT=([/dev/loop60]=var-0.img [/dev/loop63]=etcd-0.img [/dev/loop61]=var-1.img
  [/dev/loop64]=etcd-1.img [/dev/loop62]=var-2.img [/dev/loop65]=etcd-2.img)
if [ "$INSTANCE" = 2 ]; then
  # The second cluster: the six other devices of the loop map, and four other addresses of the MetalLB pool.
  IP_API=172.29.255.220
  IPS=([a]=172.29.255.221 [b]=172.29.255.222 [c]=172.29.255.223)
  VAR_LOOPS=([a]=/dev/loop66 [b]=/dev/loop67 [c]=/dev/loop68)
  ETCD_LOOPS=([a]=/dev/loop69 [b]=/dev/loop70 [c]=/dev/loop71)
  VAR_SIZES=([a]=20Gi [b]=20Gi [c]=20Gi)
  EXPECT=([/dev/loop66]=var-3.img [/dev/loop69]=etcd-3.img [/dev/loop67]=var-4.img
    [/dev/loop70]=etcd-4.img [/dev/loop68]=var-5.img [/dev/loop71]=etcd-5.img)
fi
# The host node of each replica (more than one host node). The volumes of a replica have a node
# affinity for this node, so the scheduler places the pod there.
declare -A HOST_NODES=([a]=${HOST_NODE_A:-kata-bb-worker} [b]=${HOST_NODE_B:-kata-bb-worker2} [c]=${HOST_NODE_C:-kata-bb-worker3})
# Block C: a fixed address with no NAT. FIXED=1: the node address of a replica is a fixed address on a second
# interface of the pod (Multus network "nodenet" on the node network), not a LoadBalancer address. There is no
# Service and no MetalLB in the path. The endpoint is the address of the first replica. Use it with the stock
# etcd settings: ETCD_LISTEN=default ETCD_SAN_SKIP=0 ETCD_PATCH=0.
#   PV_NODES=pin|all        all = the two volumes of a replica permit each worker node. In the lab a loop device of
#                           the machine is present in each kind node, so this imitates a volume that follows the pod.
#   INNER_CNI=none|kindnet  kindnet = the default CNI of the kind image in the inner cluster, so the nodes get Ready
FIXED=${FIXED:-0}
PV_NODES=${PV_NODES:-pin}
INNER_CNI=${INNER_CNI:-none}
if [ "$FIXED" = 1 ]; then
  if [ "$INSTANCE" = 2 ]; then IPS=([a]=172.28.1.21 [b]=172.28.1.22 [c]=172.28.1.23); else IPS=([a]=172.28.1.11 [b]=172.28.1.12 [c]=172.28.1.13); fi
  IP_API=${IPS[a]}
  ADDR_FORM=none # the address is on the interface net1 already. The wrapper adds nothing.
fi
# The DNS name of the headless Service that selects all replicas (ETCD_PEER_DNS=1).
PEER_NAME="cp-peer.$NS.svc.cluster.local"

HERE="$(cd "$(dirname "$0")" && pwd)"
KC=(kubectl --kubeconfig /etc/kubernetes/admin.conf)
ETCDCTL='crictl exec "$(crictl ps --name etcd -q | head -1)" etcdctl --endpoints https://127.0.0.1:2379 --cacert /etc/kubernetes/pki/etcd/ca.crt --cert /etc/kubernetes/pki/etcd/healthcheck-client.crt --key /etc/kubernetes/pki/etcd/healthcheck-client.key'
LOOP_DIR=/tmp/g4-loop$SFX # in the kind node
mkdir -p "$LOG_DIR"

node() { docker exec "$KIND_NODE" "$@"; }     # a command in the kind node that has kubectl (the control plane node)
rnode() { # rnode <r> <command...>: a command in the host node of replica r (the node of its pod now, or its home node)
  local r=$1 n
  shift
  n=$(k -n "$NS" get pod "$(pn "$r")" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)
  docker exec "${n:-${HOST_NODES[$r]}}" "$@"
}
nodei() { docker exec -i "$KIND_NODE" "$@"; } # the same, with stdin
k() { node "${KC[@]}" "$@"; }                 # kubectl of the host cluster
say() { echo "== $*"; }
die() {
  echo "ERROR: $*" >&2
  exit 1
}
now() { date +%s.%N; }
stamp() { printf '%s %s\n' "$(now)" "$1" >>"$LOG_DIR/times.txt"; }
# Seconds between two stamps (the last one of each name).
between() { awk -v a="$1" -v b="$2" '$2==a {x=$1} $2==b {y=$1} END {printf "%.1f\n", y-x}' "$LOG_DIR/times.txt"; }

# The owner form of a replica in this run: sts or bare.
owner_of() { cat "$LOG_DIR/.owner-$1" 2>/dev/null || echo "$OWNER"; }
# The pod name of a replica: cp-<r>-0 with a StatefulSet, cp-<r> as a bare Pod.
pn() { if [ "$(owner_of "$1")" = sts ]; then echo "cp-$1-0"; else echo "cp-$1"; fi; }
pod() { # pod <r> <command...>: a command in the node pod of replica r
  local r=$1
  shift
  k -n "$NS" exec "$(pn "$r")" -- "$@"
}
podi() {
  local r=$1
  shift
  nodei "${KC[@]}" -n "$NS" exec -i "$(pn "$r")" -- "$@"
}
ik() { # kubectl of the inner cluster, on replica r
  local r=$1
  shift
  pod "$r" "${KC[@]}" "$@"
}
etcdctl() { # etcdctl in the etcd container of replica r
  local r=$1
  shift
  pod "$r" sh -c "$ETCDCTL $*"
}

secrets() {
  [ -s "$SECRET_DIR/token" ] && [ -s "$SECRET_DIR/certkey" ] || die "no token in $SECRET_DIR. Run init first."
  TOKEN=$(cat "$SECRET_DIR/token")
  CERT_KEY=$(cat "$SECRET_DIR/certkey")
  CA_HASH=$(cat "$SECRET_DIR/ca-hash" 2>/dev/null || true)
}
# Remove the token and the certificate key from text that goes to a log.
redact() { sed -e "s/${TOKEN:-@@none@@}/<token>/g" -e "s/${CERT_KEY:-@@none@@}/<certificate-key>/g"; }

# Fill a template: put in the pod spec, remove the lines of an option that is off, set the variables.
render() {
  local tmpl=$1 r=${2:-a} inc="" line drop=()
  [ -n "$RUNTIME_CLASS" ] || drop+=(-e '/#@runtimeclass$/d')
  [ -n "$KERNEL_CONFIG" ] || drop+=(-e '/#@kernelconfig$/d')
  [ "$ETCD_LISTEN" = all ] || drop+=(-e '/#@etcdlisten$/d')
  [ "$ETCD_SAN_SKIP" = 1 ] || drop+=(-e '/#@etcdsan$/d')
  [ "$ETCD_LISTEN" = all ] || [ "$ETCD_SAN_SKIP" = 1 ] || drop+=(-e '/#@etcdargs$/d')
  [ "$ETCD_PEER_DNS" = 1 ] || drop+=(-e '/#@peerdns$/d')
  [ "$ETCD_PATCH" = 1 ] || drop+=(-e '/#@etcdpatch$/d')
  [ "$FIXED" = 1 ] || drop+=(-e '/#@fixed$/d')
  [ "$PV_NODES" = all ] || drop+=(-e '/#@prefer$/d')
  if [ "$PV_NODES" = all ]; then PV_NODE_LIST="\"${HOST_NODES[a]}\", \"${HOST_NODES[b]}\", \"${HOST_NODES[c]}\""; else PV_NODE_LIST="\"${HOST_NODES[$r]}\""; fi
  export PV_NODE_LIST
  # FIXED_MAC=1: the annotation also names a fixed hardware address for net1 (C1: a peer then reaches a
  # replaced pod with no wait for a new neighbor entry).
  export POD_MAC=""
  [ "${FIXED_MAC:-0}" != 1 ] || POD_MAC=$(printf ', "mac": "02:00:ac:1c:01:%02x"' "${IPS[$r]##*.}")
  case "$tmpl" in
    node-sts.yaml.tmpl) inc=$(cat "$HERE/podspec.inc") ;;
    node-pod.yaml.tmpl) inc=$(sed 's/^    //' "$HERE/podspec.inc") ;;
  esac
  export NS RUNTIME_CLASS SNAPSHOTTER STOP_TIMEOUT GRACE CPU MEMORY IMAGE K8S_VERSION KIND_NODE ETP ADDR_FORM REPAIR ETCD_SIZE IP_API G1_SKIP PEER_NAME
  export NAME="cp-$r" NODE_IP="${IPS[$r]}" VAR_LOOP="${VAR_LOOPS[$r]}" ETCD_LOOP="${ETCD_LOOPS[$r]}" VAR_SIZE="${VAR_SIZES[$r]}"
  export IP_A="${IPS[a]}" IP_B="${IPS[b]}" IP_C="${IPS[c]}" HOST_NODE="${HOST_NODES[$r]}"
  export TOKEN=${TOKEN:-} CERT_KEY=${CERT_KEY:-} CA_HASH=${CA_HASH:-}
  while IFS= read -r line; do
    if [ "$line" = "#@podspec" ]; then printf '%s\n' "$inc"; else printf '%s\n' "$line"; fi
  done <"$HERE/$tmpl" | sed "${drop[@]}" -e 's/ *#@[a-z]*$//' |
    envsubst '$NS $NAME $RUNTIME_CLASS $SNAPSHOTTER $STOP_TIMEOUT $GRACE $CPU $MEMORY $IMAGE $K8S_VERSION $KIND_NODE $ETP $ADDR_FORM $REPAIR $ETCD_SIZE $IP_API $NODE_IP $VAR_LOOP $ETCD_LOOP $VAR_SIZE $IP_A $IP_B $IP_C $TOKEN $CERT_KEY $CA_HASH $G1_SKIP $PEER_NAME $HOST_NODE $PV_NODE_LIST $POD_MAC'
}

# wait_node <seconds> <shell test>: repeat the test in the kind node, one time each second.
wait_node() {
  local t=$1
  shift
  node bash -c "for i in \$(seq 1 $t); do if $*; then exit 0; fi; sleep 1; done; exit 1"
}
# wait_here <seconds> <command...>: repeat a command of this script, one time each second.
wait_here() {
  local t=$1 i
  shift
  for i in $(seq 1 "$t"); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  return 1
}
wait_readyz() { wait_node "${2:-300}" "[ \"\$(curl -sk --max-time 2 https://$1:6443/readyz)\" = ok ]"; }
pod_uid() { k -n "$NS" get pod "$(pn "$1")" -o jsonpath='{.metadata.uid}' 2>/dev/null || true; }

# The cgroup of the pod of replica r in its host node. With the Rust runtime of Kata the
# hypervisor is in it. A kill by the kernel there (oom_kill) gives a new sandbox and a new pod IP.
pod_memory() {
  local r=$1 uid cg
  uid=$(pod_uid "$r")
  cg=$(rnode "$r" find /sys/fs/cgroup/kubelet.slice -maxdepth 3 -type d -name "*pod${uid//-/_}.slice" | head -1)
  [ -n "$cg" ] || { echo "cp-$r: no pod cgroup in ${HOST_NODES[$r]}"; return 0; }
  rnode "$r" sh -c "echo \"cp-$r: memory.current \$((\$(cat $cg/memory.current) / 1048576)) MiB, memory.peak \$((\$(cat $cg/memory.peak) / 1048576)) MiB, memory.max \$(cat $cg/memory.max), events: \$(tr '\n' ' ' <$cg/memory.events)\""
  echo "cp-$r: container restarts $(k -n "$NS" get pod "$(pn "$r")" -o jsonpath='{.status.containerStatuses[0].restartCount}'), guest: $(pod "$r" sh -c "free -m | awk '\$1==\"Mem:\" {print \"total \" \$2 \" used \" \$3 \" cache \" \$6 \" MiB\"}'")"
}

check_devices() {
  local d la r
  for d in "${!EXPECT[@]}"; do
    grep -q "^$d .*/${EXPECT[$d]} " "$LOOP_MAP" || die "$d is not ${EXPECT[$d]} in $LOOP_MAP"
  done
  # Each replica: its two devices must be present in its host node.
  for r in "${REPLICAS[@]}"; do
    la=$(rnode "$r" losetup -a)
    for d in "${VAR_LOOPS[$r]}" "${ETCD_LOOPS[$r]}"; do
      grep -q "^$d: .*/${EXPECT[$d]})" <<<"$la" || die "$d is not ${EXPECT[$d]} in the node ${HOST_NODES[$r]}"
    done
  done
}

cmd_services() {
  say "memory of the host"
  free -g
  say "namespace, wrapper script and kernel config"
  k create namespace "$NS" --dry-run=client -o yaml | nodei "${KC[@]}" apply -f -
  nodei "${KC[@]}" -n "$NS" create configmap g4-wrapper --from-file=wrapper.sh=/dev/stdin --dry-run=client -o yaml <"$HERE/wrapper.sh" |
    nodei "${KC[@]}" apply -f -
  if [ -n "$KERNEL_CONFIG" ]; then
    nodei "${KC[@]}" -n "$NS" create configmap g4-kernel-config --from-file=config=/dev/stdin --dry-run=client -o yaml <"$KERNEL_CONFIG" |
      nodei "${KC[@]}" apply -f -
  fi
  if [ "$FIXED" = 1 ]; then
    say "the node network for the pods (NetworkAttachmentDefinition nodenet). No Service."
    NS=$NS envsubst '$NS' <"$HERE/nad.yaml.tmpl" | nodei "${KC[@]}" apply -f -
    return 0
  fi
  say "Services"
  render services.yaml.tmpl >"$LOG_DIR/services.yaml"
  nodei "${KC[@]}" apply -f - <"$LOG_DIR/services.yaml"
  wait_here 60 sh -c "[ \"\$(docker exec $KIND_NODE ${KC[*]} -n $NS get svc -o jsonpath='{.items[*].status.loadBalancer.ingress[0].ip}' | wc -w)\" = 4 ]" ||
    die "a Service has no LoadBalancer address"
  k -n "$NS" get svc -o wide | tee "$LOG_DIR/services.txt"
}

apply_owner() { # apply_owner <r>: the StatefulSet or the bare Pod of replica r
  local r=$1 tmpl=node-sts.yaml.tmpl
  [ "$(owner_of "$r")" = sts ] || tmpl=node-pod.yaml.tmpl
  render "$tmpl" "$r" >"$LOG_DIR/owner-cp-$r-$(owner_of "$r").yaml"
  nodei "${KC[@]}" apply -f - <"$LOG_DIR/owner-cp-$r-$(owner_of "$r").yaml"
}

cmd_node_up() {
  local r=$1
  check_devices
  echo "$OWNER" >"$LOG_DIR/.owner-$r"
  say "replica $r: volumes ${VAR_LOOPS[$r]} and ${ETCD_LOOPS[$r]} on the host node ${HOST_NODES[$r]}, owner $(owner_of "$r"), node address ${IPS[$r]}"
  render volumes.yaml.tmpl "$r" | nodei "${KC[@]}" apply -f -
  stamp "$r-pod-create"
  apply_owner "$r"
  wait_here 300 pod "$r" systemctl is-active containerd || die "containerd is not active in the pod of replica $r"
  stamp "$r-node-up"
  [ "$PV_NODES" = all ] || [ "$(k -n "$NS" get pod "$(pn "$r")" -o jsonpath='{.spec.nodeName}')" = "${HOST_NODES[$r]}" ] || die "the pod of replica $r is not on ${HOST_NODES[$r]}"
  say "replica $r: pod $(pn "$r") runs on $(k -n "$NS" get pod "$(pn "$r")" -o jsonpath='{.spec.nodeName}') and has the IP $(k -n "$NS" get pod "$(pn "$r")" -o jsonpath='{.status.podIP}'). Pod create to node up: $(between "$r-pod-create" "$r-node-up") s"
  k -n "$NS" get pvc -o wide
  k -n "$NS" logs "$(pn "$r")" 2>/dev/null | grep -a 'WRAP:' | tr -d '\r' || true
}

# The etcd patch file of ETCD_PATCH=1. kubeadm applies each file of its patches folder to the
# static pod manifest with the same target name, at init and at join. A JSON patch adds the three
# arguments at the end of the etcd command. etcd takes the last value of an argument that is
# given two times, so the two listen URLs replace the values that kubeadm wrote before them.
etcd_patch_file() {
  local r=$1
  [ "$ETCD_PATCH" = 1 ] || return 0
  say "replica $r: etcd patch file /etc/kubernetes/patches/etcd+json.json"
  printf '%s\n' '[' \
    '  {"op": "add", "path": "/spec/containers/0/command/-", "value": "--listen-client-urls=https://0.0.0.0:2379"},' \
    '  {"op": "add", "path": "/spec/containers/0/command/-", "value": "--listen-peer-urls=https://0.0.0.0:2380"},' \
    '  {"op": "add", "path": "/spec/containers/0/command/-", "value": "--peer-skip-client-san-verification=true"}' \
    ']' | podi "$r" sh -c 'mkdir -p /etc/kubernetes/patches && cat >/etc/kubernetes/patches/etcd+json.json'
  pod "$r" cat /etc/kubernetes/patches/etcd+json.json | tee "$LOG_DIR/etcd-patch-$r.json"
}

cmd_init() {
  local r=a rc=0
  mkdir -p "$SECRET_DIR"
  chmod 700 "$SECRET_DIR"
  (
    umask 077
    pod "$r" kubeadm token generate >"$SECRET_DIR/token"
    pod "$r" kubeadm certs certificate-key >"$SECRET_DIR/certkey"
    : >"$SECRET_DIR/ca-hash"
  )
  secrets
  say "kubeadm config to /kind/kubeadm.conf (copy with no token in $LOG_DIR/kubeadm-init.conf)"
  render kubeadm-init.yaml.tmpl "$r" | podi "$r" sh -c 'umask 077; cat >/kind/kubeadm.conf'
  render kubeadm-init.yaml.tmpl "$r" | redact >"$LOG_DIR/kubeadm-init.conf"
  etcd_patch_file "$r"

  say "kubeadm preflight with no ignore flag (output in $LOG_DIR/preflight-$r.txt)"
  pod "$r" kubeadm init phase preflight --config /kind/kubeadm.conf >"$LOG_DIR/preflight-$r.txt" 2>&1 || rc=$?
  echo "exit code: $rc" >>"$LOG_DIR/preflight-$r.txt"
  grep -E 'WARNING|ERROR|exit code' "$LOG_DIR/preflight-$r.txt" || true

  say "kubeadm init (output in $LOG_DIR/kubeadm-init.txt)"
  stamp "$r-init-start"
  rc=0
  pod "$r" kubeadm init --config /kind/kubeadm.conf --upload-certs --skip-token-print --skip-certificate-key-print \
    ${IGNORE_PREFLIGHT:+--ignore-preflight-errors="$IGNORE_PREFLIGHT"} 2>&1 | redact >"$LOG_DIR/kubeadm-init.txt" || rc=$?
  if [ "$rc" != 0 ]; then
    tail -40 "$LOG_DIR/kubeadm-init.txt"
    die "kubeadm init failed"
  fi
  stamp "$r-init-done"
  pod "$r" sh -c 'openssl x509 -pubkey -noout -in /etc/kubernetes/pki/ca.crt | openssl pkey -pubin -outform der | sha256sum' |
    awk '{print "sha256:" $1}' >"$SECRET_DIR/ca-hash"
  wait_readyz "${IPS[$r]}" 300
  stamp "$r-readyz-own"
  wait_readyz "$IP_API" 300
  stamp "$r-readyz-shared"
  say "init: $(between "$r-init-start" "$r-init-done") s. Pod create to /readyz through the Service of the replica: $(between "$r-pod-create" "$r-readyz-own") s, through the shared Service: $(between "$r-pod-create" "$r-readyz-shared") s"
  # An object to find again after each replace.
  ik "$r" -n default create configmap g4-marker --from-literal=made="$(date -u +%FT%TZ)" >/dev/null
  ik "$r" -n default get configmap g4-marker -o jsonpath='{.metadata.uid}' >"$LOG_DIR/marker-uid.txt"
  if [ "$INNER_CNI" = kindnet ]; then
    # The inner cluster has no kube-proxy, so kindnet gets the API endpoint in place of the Service address.
    say "inner cluster: the default CNI of the kind image (kindnet)"
    pod "$r" sh -c "sed 's#{{ .PodSubnet }}#10.113.0.0/16#' /kind/manifests/default-cni.yaml | ${KC[*]} apply -f - && ${KC[*]} -n kube-system set env daemonset/kindnet CONTROL_PLANE_ENDPOINT=$IP_API:6443" | tail -3
    ik "$r" wait --for=condition=Ready "node/cp-$r" --timeout=180s || echo "WARN: the node cp-$r is not Ready"
  fi
}

cmd_join() {
  local r=$1 rc=0
  secrets
  [ -n "$CA_HASH" ] || die "no CA hash. Run init first."
  say "replica $r: kubeadm join --control-plane (output in $LOG_DIR/kubeadm-join-$r.txt)"
  render kubeadm-join.yaml.tmpl "$r" | podi "$r" sh -c 'umask 077; cat >/kind/kubeadm-join.conf'
  render kubeadm-join.yaml.tmpl "$r" | redact >"$LOG_DIR/kubeadm-join-$r.conf"
  etcd_patch_file "$r"
  stamp "$r-join-start"
  pod "$r" kubeadm join --config /kind/kubeadm-join.conf \
    ${IGNORE_PREFLIGHT:+--ignore-preflight-errors="$IGNORE_PREFLIGHT"} 2>&1 | redact >"$LOG_DIR/kubeadm-join-$r.txt" || rc=$?
  stamp "$r-join-done"
  grep -E 'WARNING|ERROR|error' "$LOG_DIR/kubeadm-join-$r.txt" | head -20 || true
  if [ "$rc" != 0 ]; then
    tail -40 "$LOG_DIR/kubeadm-join-$r.txt"
    say "kubeadm join failed on replica $r after $(between "$r-join-start" "$r-join-done") s"
    return 1
  fi
  wait_readyz "${IPS[$r]}" 300 || { say "replica $r: no /readyz through its Service"; return 1; }
  stamp "$r-readyz-own"
  [ "$INNER_CNI" = none ] || ik a wait --for=condition=Ready "node/cp-$r" --timeout=180s || echo "WARN: the node cp-$r is not Ready"
  say "replica $r: join $(between "$r-join-start" "$r-join-done") s. Join start to /readyz through its Service: $(between "$r-join-start" "$r-readyz-own") s. Pod create to /readyz: $(between "$r-pod-create" "$r-readyz-own") s"
}

# The identity of one replica. A new pod must change only the lines "pod-ip" and "boot-id".
identity() {
  local r=$1
  pod "$r" sh -c 'cd /etc/kubernetes && find pki -name "*.crt" -o -name "*.pub" | sort | xargs sha256sum'
  pod "$r" sh -c 'cd /etc/kubernetes && sha256sum pki/*.key pki/etcd/*.key *.conf | sed "s/^/keys-and-kubeconfigs /"'
  pod "$r" sh -c 'sha256sum /var/lib/kubelet/pki/kubelet.crt; echo "kubelet-client-cert $(readlink -f /var/lib/kubelet/pki/kubelet-client-current.pem)"'
  pod "$r" sh -c 'sha256sum /etc/kubernetes/manifests/*.yaml /var/lib/kubelet/kubeadm-flags.env'
  etcdctl "$r" member list -w simple | sort | sed 's/^/etcd-member /'
  echo "node-uid $(ik "$r" get node "cp-$r" -o jsonpath='{.metadata.uid}')"
  echo "node-internal-ip $(ik "$r" get node "cp-$r" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')"
  echo "marker-configmap-uid $(ik "$r" -n default get configmap g4-marker -o jsonpath='{.metadata.uid}')"
  echo "machine-id $(pod "$r" cat /etc/machine-id)"
  echo "pod-ip $(k -n "$NS" get pod "$(pn "$r")" -o jsonpath='{.status.podIP}')"
  echo "boot-id $(pod "$r" cat /proc/sys/kernel/random/boot_id)"
}

# Step 3: the etcd members, /readyz through each Service, and the nodes of the inner cluster.
cmd_check() {
  local label=${1:-check} out fail=0 r x n
  out="$LOG_DIR/check-$label.txt"
  {
    say "check $label at $(date -u +%FT%TZ)"
    k -n "$NS" get pods -o wide
    k -n "$NS" get svc
    k -n "$NS" get endpointslices

    say "1. etcd member list, from replica a"
    etcdctl a member list -w table | tee "$LOG_DIR/.members" || true
    etcdctl a member list -w simple >"$LOG_DIR/.members-simple" || true
    [ "$(grep -c ', started, ' "$LOG_DIR/.members-simple")" = 3 ] || { echo "FAIL: not three started members"; fail=1; }
    grep -q ', true$' "$LOG_DIR/.members-simple" && { echo "FAIL: a member is a learner"; fail=1; }
    for r in "${REPLICAS[@]}"; do
      grep -q ", cp-$r, https://${IPS[$r]}:2380, https://${IPS[$r]}:2379, false" "$LOG_DIR/.members-simple" ||
        { echo "FAIL: member cp-$r has not the peer URL https://${IPS[$r]}:2380"; fail=1; }
    done
    etcdctl a endpoint status --cluster -w table || true
    etcdctl a endpoint health --cluster 2>&1 | tee "$LOG_DIR/.health" || true
    [ "$(grep -c 'is healthy' "$LOG_DIR/.health")" = 3 ] || { echo "FAIL: not three healthy etcd endpoints"; fail=1; }

    say "2. /readyz through the Service of each replica and through the shared Service, from the kind node"
    for x in "${IPS[a]}" "${IPS[b]}" "${IPS[c]}" "$IP_API"; do
      n=$(node curl -sk --max-time 5 -w ' (http %{http_code})' "https://$x:6443/readyz" || true)
      echo "https://$x:6443/readyz: $n"
      [ "$n" = "ok (http 200)" ] || { echo "FAIL readyz $x"; fail=1; }
    done
    if [ "$FIXED" = 1 ]; then
      say "block C: no Service. Each etcd member must have 0 refused peer connections$([ "$INNER_CNI" = none ] || echo ', and each node must be Ready')"
      for r in "${REPLICAS[@]}"; do
        # grep -c gives exit code 1 for the count 0, which is the good case here.
        n=$(pod "$r" sh -c 'crictl logs "$(crictl ps --name etcd -q | head -1)" 2>&1 | grep -c "rejected connection on peer endpoint"' 2>/dev/null) || true
        echo "cp-$r on $(k -n "$NS" get pod "$(pn "$r")" -o jsonpath='{.spec.nodeName}'): etcd log lines \"rejected connection on peer endpoint\": $n. Flags: $(pod "$r" sh -c "grep -E -- '--(listen-peer-urls|listen-client-urls|peer-skip-client-san-verification)' /etc/kubernetes/manifests/etcd.yaml | sed 's/^ *- //' | tr '\n' ' '"). Sockets: $(pod "$r" sh -c "ss -ltnH | awk '\$4 ~ /:(2379|2380)\$/ {print \$4}' | sort | tr '\n' ' '")"
        [ "$n" = 0 ] || { echo "FAIL: etcd of cp-$r refused a peer"; fail=1; }
        pod "$r" grep -q -- 'peer-skip-client-san-verification' /etc/kubernetes/manifests/etcd.yaml && { echo "FAIL: cp-$r has the skip flag"; fail=1; }
      done
    else
    say "the shared Service reaches each API server: the serving certificate of each replica, then of 30 calls to the shared address (stop when all three were seen)"
    for r in "${REPLICAS[@]}"; do
      echo "cp-$r $(pod "$r" openssl x509 -noout -fingerprint -sha256 -in /etc/kubernetes/pki/apiserver.crt)"
    done | tee "$LOG_DIR/.fp-replicas"
    node bash -c "for i in \$(seq 1 30); do echo | openssl s_client -connect $IP_API:6443 2>/dev/null | openssl x509 -noout -fingerprint -sha256; [ \"\$(sort -u /tmp/g4-fp 2>/dev/null | wc -l)\" = 3 ] && break; sleep 1; done 2>&1 | tee /tmp/g4-fp >/dev/null; sort /tmp/g4-fp | uniq -c; rm -f /tmp/g4-fp" | tee "$LOG_DIR/.fp-shared"
    for r in "${REPLICAS[@]}"; do
      grep -q "$(awk -v n="cp-$r" '$1==n {print $3}' "$LOG_DIR/.fp-replicas")" "$LOG_DIR/.fp-shared" ||
        { echo "FAIL: the shared Service did not reach the API server of cp-$r"; fail=1; }
    done
    k -n "$NS" get endpointslices -l kubernetes.io/service-name=cp-api -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{" ready="}{.conditions.ready}{"\n"}{end}'
    fi

    say "3. nodes of the inner cluster (the InternalIP must be the LoadBalancer IP)"
    ik a get nodes -o wide | tee "$LOG_DIR/.nodes" || true
    for r in "${REPLICAS[@]}"; do
      [ "$(awk -v n="cp-$r" '$1==n {print $6}' "$LOG_DIR/.nodes")" = "${IPS[$r]}" ] || { echo "FAIL: node cp-$r has not the InternalIP ${IPS[$r]}"; fail=1; }
      [ "$INNER_CNI" = none ] || [ "$(awk -v n="cp-$r" '$1==n {print $2}' "$LOG_DIR/.nodes")" = Ready ] || { echo "FAIL: node cp-$r is not Ready"; fail=1; }
    done
    ik a -n kube-system get pods -o wide || true
    ik a -n default get endpointslices kubernetes -o jsonpath='{range .endpoints[*]}{"kubernetes Service endpoint "}{.addresses[0]}{"\n"}{end}' || true

    say "4. identity of each replica (file identity-<replica>-$label.txt)"
    for r in "${REPLICAS[@]}"; do
      identity "$r" >"$LOG_DIR/identity-$r-$label.txt" 2>&1 || true
      echo "cp-$r: $(grep -c . "$LOG_DIR/identity-$r-$label.txt") lines, apiserver.crt $(awk '$2=="pki/apiserver.crt" {print substr($1,1,16)}' "$LOG_DIR/identity-$r-$label.txt"), $(grep -E '^(pod-ip|node-internal-ip) ' "$LOG_DIR/identity-$r-$label.txt" | tr '\n' ' ')"
    done
    say "5. memory of each pod (cgroup in the kind node) and container restarts"
    for r in "${REPLICAS[@]}"; do
      pod_memory "$r" | tee -a "$LOG_DIR/.mem"
    done
    if grep -E 'oom_kill [1-9]' "$LOG_DIR/.mem" >/dev/null; then echo "FAIL: the kernel killed a process of a pod (oom_kill)"; fail=1; fi
    rm -f "$LOG_DIR/.mem"
    [ "$fail" = 0 ] && echo "RESULT $label: PASS" || echo "RESULT $label: FAIL"
  } 2>&1 | tee "$out"
  grep -q "RESULT $label: PASS" "$out"
}

# Save the identity of each replica in identity-<replica>-<label>.txt.
cmd_identity() {
  local label=${1:-now} r
  for r in "${REPLICAS[@]}"; do
    identity "$r" >"$LOG_DIR/identity-$r-$label.txt" 2>&1 || true
    echo "cp-$r: $(grep -c . "$LOG_DIR/identity-$r-$label.txt") lines in $LOG_DIR/identity-$r-$label.txt"
  done
}

# Step 6: each pod calls its own LoadBalancer address and the shared address on port 6443.
cmd_reach() {
  local label=${1:-reach} out fail=0 r x n
  out="$LOG_DIR/reach-$label.txt"
  {
    say "reach $label at $(date -u +%FT%TZ)"
    for r in "${REPLICAS[@]}"; do
      echo "-- pod $(pn "$r"): addresses $(pod "$r" sh -c "ip -o -4 addr show | awk '{print \$2 \"=\" \$4}' | tr '\n' ' '")"
      echo "route to the own address: $(pod "$r" ip route get "${IPS[$r]}" | head -1)"
      echo "route to the shared address: $(pod "$r" ip route get "$IP_API" | head -1)"
      for x in "${IPS[$r]}" "$IP_API" "${IPS[a]}" "${IPS[b]}" "${IPS[c]}"; do
        n=$(pod "$r" curl -sk --max-time 5 -w ' (http %{http_code}, local address %{local_ip})' "https://$x:6443/readyz" || true)
        echo "cp-$r to https://$x:6443/readyz: $n"
        case "$n" in "ok (http 200"*) ;; *)
          echo "FAIL: cp-$r does not reach $x"
          fail=1
          ;;
        esac
      done
    done
    [ "$fail" = 0 ] && echo "RESULT $label: PASS" || echo "RESULT $label: FAIL"
  } 2>&1 | tee "$out"
  grep -q "RESULT $label: PASS" "$out"
}

# A loop in the kind node that calls the shared endpoint each second, and a second loop that
# calls the Service of each replica. The loops stop when the file $LOOP_DIR/run goes away.
#
# Each loop runs as a systemd unit of the node, not with "docker exec -d". The kubelet unit of
# a kind node does not start while the root cgroup of the node holds a process. On a node that
# runs, a process of "docker exec" is in the cgroup /init.scope (measured on 2026-11-26). In
# cold start run 1 of 2026-11-25 the script started its loops with "docker exec -d" right
# after "docker start". The two loop processes (PIDs 88 and 106) were in the root cgroup, the
# kubelet did not start, and the run was not valid. The likely reason: at that moment systemd
# of the node had not yet made its cgroups.
node_loop() { # node_loop <unit name> <bash script>
  local unit=$1 script=$2 i
  for i in $(seq 1 60); do
    # --expand-environment=no: systemd must not replace ${...} in the script. With the default it
    # made ${x%%=*} empty, and the replica loop of cold start run 2 logged no replica name.
    docker exec "$KIND_NODE" systemd-run --quiet --collect --expand-environment=no --unit="$unit" bash -c "$script" 2>/dev/null && return 0
    sleep 1
  done
  die "cannot start the loop $unit in the kind node"
}
cmd_loop_start() {
  node sh -c "mkdir -p $LOOP_DIR && touch $LOOP_DIR/run"
  node_loop "g4-loop-shared$SFX" "while [ -e $LOOP_DIR/run ]; do printf '%s shared %s\n' \"\$(date +%s.%N)\" \"\$(curl -sk --max-time 2 -o /dev/null -w '%{http_code} %{time_total}' https://$IP_API:6443/readyz)\"; sleep 1; done >>$LOOP_DIR/shared.log 2>&1"
  node_loop "g4-loop-replicas$SFX" "while [ -e $LOOP_DIR/run ]; do for x in a=${IPS[a]} b=${IPS[b]} c=${IPS[c]}; do printf '%s %s %s\n' \"\$(date +%s.%N)\" \"\${x%%=*}\" \"\$(curl -sk --max-time 2 -o /dev/null -w '%{http_code} %{time_total}' https://\${x##*=}:6443/readyz)\"; done; sleep 1; done >>$LOOP_DIR/replicas.log 2>&1"
  say "loops started in the kind node ($LOOP_DIR)"
}
cmd_loop_stop() {
  node rm -f "$LOOP_DIR/run"
  sleep 4
  node cat "$LOOP_DIR/shared.log" >"$LOG_DIR/loop-shared.log" 2>/dev/null || true
  node cat "$LOOP_DIR/replicas.log" >"$LOG_DIR/loop-replicas.log" 2>/dev/null || true
  node rm -rf "$LOOP_DIR"
  say "loop logs: $(wc -l <"$LOG_DIR/loop-shared.log") calls to the shared endpoint, $(awk '$3 != 200' "$LOG_DIR/loop-shared.log" | wc -l) of them not 200"
}
# loop_window <from stamp> <to stamp> <who>: the calls of one target between two stamps.
loop_window() {
  local a b
  a=$(awk -v n="$1" '$2==n {x=$1} END {print x}' "$LOG_DIR/times.txt")
  b=$(awk -v n="$2" '$2==n {x=$1} END {print x}' "$LOG_DIR/times.txt")
  { node cat "$LOOP_DIR/shared.log" "$LOOP_DIR/replicas.log" 2>/dev/null || true; } |
    awk -v a="$a" -v b="$b" -v w="$3" '$1>=a && $1<=b && $2==w {n++; if ($3 != 200) {bad++; if (!first) first=$1; last=$1}} END {printf "%s: %d calls, %d not 200", w, n, bad; if (bad) printf " (from %.1f s to %.1f s after the delete)", first-a, last-a; printf "\n"}'
}

leader() { # leader <r>: the replica letter of the etcd leader, asked on replica r
  local s ip x
  s=$(etcdctl "$1" endpoint status --cluster -w json 2>/dev/null) || return 1
  ip=$(jq -r '[.[] | select(.Status.header.member_id == .Status.leader) | .Endpoint][0]' <<<"$s" | sed -E 's#https://##; s#:2379##')
  for x in "${REPLICAS[@]}"; do if [ "${IPS[$x]}" = "$ip" ]; then echo "$x"; fi; done
}
# quorum: true when the etcd member of one replica commits a proposal.
cmd_quorum() {
  local r
  for r in "${REPLICAS[@]}"; do
    if etcdctl "$r" endpoint health 2>/dev/null | grep 'is healthy'; then return 0; fi
  done
  return 1
}
etcd_all_healthy() { [ "$(etcdctl "$1" endpoint health --cluster 2>&1 | grep -c 'is healthy')" = 3 ]; }

# Step 4: delete the pod of one replica. The owner makes the pod again: the StatefulSet
# controller, or this script for a bare Pod. Then compare the identity of all replicas.
cmd_replace() {
  local r=$1 label=${2:-replace-$1} out fail=0 s x old lead uid
  out="$LOG_DIR/replace-$label.txt"
  for s in "${REPLICAS[@]}"; do [ "$s" != "$r" ] && break; done # s = a replica that stays
  {
    say "replace $label at $(date -u +%FT%TZ): replica $r, owner $(owner_of "$r"), pod $(pn "$r")"
    lead=$(leader "$s")
    echo "etcd leader before: cp-$lead. Replica $r is $([ "$lead" = "$r" ] && echo the leader || echo a follower)."
    for x in "${REPLICAS[@]}"; do identity "$x" >"$LOG_DIR/identity-$x-$label-before.txt" 2>&1; done
    etcdctl "$s" endpoint status --cluster -w table
    old=$(pod_uid "$r")

    stamp "$label-delete"
    k -n "$NS" delete pod "$(pn "$r")" --wait=true
    stamp "$label-old-pod-gone"
    if [ "$(owner_of "$r")" = bare ]; then
      # Nothing in the host cluster makes a bare Pod again. Show it, then do the work of the provider.
      sleep 5
      echo "bare Pod, 5 s after the delete: $(k -n "$NS" get pod "$(pn "$r")" 2>&1 | tail -1)"
      stamp "$label-provider-apply"
      apply_owner "$r"
    fi
    wait_here 300 sh -c "u=\$(docker exec $KIND_NODE ${KC[*]} -n $NS get pod $(pn "$r") -o jsonpath='{.metadata.uid} {.status.phase}' 2>/dev/null); [ \"\${u%% *}\" != '$old' ] && [ \"\${u##* }\" = Running ]" ||
      echo "FAIL: no new pod"
    stamp "$label-new-pod-running"
    wait_readyz "${IPS[$r]}" 300 || echo "FAIL: no /readyz"
    stamp "$label-readyz-own"
    wait_here 120 etcd_all_healthy "$s" || echo "FAIL: etcd"
    stamp "$label-etcd-healthy"
    # The pod is ready in the host cluster, so the shared Service has it again.
    wait_here 60 sh -c "[ \"\$(docker exec $KIND_NODE ${KC[*]} -n $NS get pod $(pn "$r") -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}')\" = True ]" || echo "FAIL: pod not ready"
    stamp "$label-pod-ready"

    echo "times after the delete (s): old pod gone $(between "$label-delete" "$label-old-pod-gone"), new pod running $(between "$label-delete" "$label-new-pod-running"), /readyz through the Service of the replica $(between "$label-delete" "$label-readyz-own"), three healthy etcd endpoints $(between "$label-delete" "$label-etcd-healthy"), pod ready $(between "$label-delete" "$label-pod-ready")"
    echo "new pod create to /readyz (s): $(between "$label-old-pod-gone" "$label-readyz-own")"
    echo "calls of the loops between the delete and the ready pod:"
    loop_window "$label-delete" "$label-pod-ready" shared
    for x in "${REPLICAS[@]}"; do loop_window "$label-delete" "$label-pod-ready" "$x"; done
    echo "etcd leader after: cp-$(leader "$s")"
    etcdctl "$s" endpoint status --cluster -w table
    say "address repair of the kind entrypoint in the new pod (REPAIR=$REPAIR)"
    echo "pod IP before: $(awk '$1=="pod-ip" {print $2}' "$LOG_DIR/identity-$r-$label-before.txt"). Pod IP after: $(k -n "$NS" get pod "$(pn "$r")" -o jsonpath='{.status.podIP}')"
    k -n "$NS" logs "$(pn "$r")" 2>/dev/null | grep -a -E 'WRAP: (node address|address repair)|old IPv[46]|regenerating|detected IPv[46]' | tr -d '\r' || true
    echo "lines of the pod log with \"regenerating the certificate\": $(k -n "$NS" logs "$(pn "$r")" 2>/dev/null | grep -a -c 'regenerating the certificate' || true)"
    echo "apiserver.crt sha256 before: $(awk '$2=="pki/apiserver.crt" {print $1}' "$LOG_DIR/identity-$r-$label-before.txt")"
    echo "apiserver.crt sha256 after:  $(pod "$r" sha256sum /etc/kubernetes/pki/apiserver.crt | awk '{print $1}')"
    pod_memory "$r"

    say "identity after the replace (only pod-ip and boot-id of replica $r may differ)"
    for x in "${REPLICAS[@]}"; do
      identity "$x" >"$LOG_DIR/identity-$x-$label-after.txt" 2>&1
      if diff "$LOG_DIR/identity-$x-$label-before.txt" "$LOG_DIR/identity-$x-$label-after.txt" >"$LOG_DIR/.diff"; then
        echo "cp-$x: no difference"
      else
        echo "cp-$x: differences:"
        cat "$LOG_DIR/.diff"
        if grep -E '^[<>]' "$LOG_DIR/.diff" | grep -v -E '^[<>] (pod-ip|boot-id) ' | grep -q .; then
          echo "FAIL: the identity of cp-$x changed"
          fail=1
        fi
        [ "$x" = "$r" ] || { echo "FAIL: replica cp-$x changed, and its pod was not replaced"; fail=1; }
      fi
    done
    grep -q '^FAIL' "$out" && fail=1
    [ "$fail" = 0 ] && echo "RESULT $label: PASS" || echo "RESULT $label: FAIL"
  } 2>&1 | tee "$out"
  grep -q "RESULT $label: PASS" "$out"
}

# Restart in place: stop the container of a replica from the kind node (crictl stop with the
# grace period of the pod). The kubelet starts a new container in the same sandbox, so the pod
# IP and the VM stay. Exit code 137 = the runtime killed the container. 130 = systemd in the
# node ended its own shutdown.
cmd_restart() {
  local r=$1 label=${2:-restart-$1} out fail=0 x before cid
  out="$LOG_DIR/restart-$label.txt"
  {
    say "restart in place $label at $(date -u +%FT%TZ): replica $r, crictl stop --timeout $GRACE"
    for x in "${REPLICAS[@]}"; do identity "$x" >"$LOG_DIR/identity-$x-$label-before.txt" 2>&1; done
    before=$(k -n "$NS" get pod "$(pn "$r")" -o jsonpath='{.status.containerStatuses[0].restartCount}')
    cid=$(rnode "$r" crictl ps -q --label io.kubernetes.pod.namespace="$NS" --label io.kubernetes.pod.name="$(pn "$r")" --label io.kubernetes.container.name=node)
    stamp "$label-stop"
    rnode "$r" crictl stop --timeout "$GRACE" "$cid" || echo "crictl stop gave an error. The container did not stop inside $GRACE s."
    stamp "$label-stop-returned"
    wait_here 300 sh -c "[ \"\$(docker exec $KIND_NODE ${KC[*]} -n $NS get pod $(pn "$r") -o jsonpath='{.status.containerStatuses[0].restartCount}')\" -gt $before ]" || echo "FAIL: no new container"
    stamp "$label-new-container"
    echo "the old container ended with: $(k -n "$NS" get pod "$(pn "$r")" -o jsonpath='{.status.containerStatuses[0].lastState.terminated}')"
    wait_readyz "${IPS[$r]}" 300 || echo "FAIL: no /readyz"
    stamp "$label-readyz-own"
    wait_here 120 etcd_all_healthy "$r" || echo "FAIL: etcd"
    stamp "$label-etcd-healthy"
    echo "times after the stop (s): crictl stop returned $(between "$label-stop" "$label-stop-returned"), new container $(between "$label-stop" "$label-new-container"), /readyz through the Service of the replica $(between "$label-stop" "$label-readyz-own"), three healthy etcd endpoints $(between "$label-stop" "$label-etcd-healthy")"
    say "identity after the restart (nothing may differ: the pod IP and the VM stay)"
    for x in "${REPLICAS[@]}"; do
      identity "$x" >"$LOG_DIR/identity-$x-$label-after.txt" 2>&1
      if diff "$LOG_DIR/identity-$x-$label-before.txt" "$LOG_DIR/identity-$x-$label-after.txt"; then echo "cp-$x: no difference"; else
        echo "FAIL: the identity of cp-$x changed"
        fail=1
      fi
    done
    pod_memory "$r"
    grep -q '^FAIL' "$out" && fail=1
    [ "$fail" = 0 ] && echo "RESULT $label: PASS" || echo "RESULT $label: FAIL"
  } 2>&1 | tee "$out"
  grep -q "RESULT $label: PASS" "$out"
}

# All replicas at the same time: delete the three pods with one command. etcd loses quorum, and
# each replica returns with a new pod IP. This is the part of a cold start that needs no stop of
# the host: it does not test the kubelet, containerd or the loop devices of the host.
cmd_outage() {
  local label=${1:-outage} out fail=0 x t0
  out="$LOG_DIR/outage-$label.txt"
  {
    say "outage $label at $(date -u +%FT%TZ): delete the pods of all three replicas at the same time"
    for x in "${REPLICAS[@]}"; do
      [ "$(owner_of "$x")" = sts ] || die "replica $x is not a StatefulSet"
      identity "$x" >"$LOG_DIR/identity-$x-$label-before.txt" 2>&1
    done
    cmd_loop_start
    sleep 3
    stamp "$label-delete"
    k -n "$NS" delete pod cp-a-0 cp-b-0 cp-c-0 --wait=true
    stamp "$label-old-pods-gone"
    wait_here 300 sh -c "[ \"\$(docker exec $KIND_NODE ${KC[*]} -n $NS get pods --no-headers | grep -c ' Running ')\" = 3 ]" || echo "FAIL: not three running pods"
    stamp "$label-new-pods-running"
    wait_here 300 cmd_quorum || echo "FAIL: no etcd quorum"
    stamp "$label-etcd-quorum"
    for x in "${REPLICAS[@]}"; do wait_readyz "${IPS[$x]}" 300 || echo "FAIL: no /readyz of cp-$x"; done
    wait_readyz "$IP_API" 300 || echo "FAIL: no /readyz of the shared address"
    stamp "$label-readyz-all"
    wait_here 120 etcd_all_healthy a || echo "FAIL: etcd"
    stamp "$label-etcd-healthy"
    sleep 3
    echo "times after the delete (s): old pods gone $(between "$label-delete" "$label-old-pods-gone"), three new pods running $(between "$label-delete" "$label-new-pods-running"), first etcdctl call with quorum $(between "$label-delete" "$label-etcd-quorum"), three healthy etcd endpoints $(between "$label-delete" "$label-etcd-healthy")"
    t0=$(awk -v n="$label-delete" '$2==n {x=$1} END {print x}' "$LOG_DIR/times.txt")
    echo "from the loops in the kind node (one call each second): for each address, the last answer 200 before the gap and the first answer 200 after it, in seconds after the delete"
    { node cat "$LOOP_DIR/shared.log" "$LOOP_DIR/replicas.log" 2>/dev/null || true; } |
      awk -v t0="$t0" '$1>=t0-3 {w=$2; if ($3==200) {if (bad[w] && !back[w]) back[w]=$1; if (!bad[w]) last[w]=$1} else bad[w]++} END {for (w in last) printf "%s: last 200 at %.1f, first 200 again at %.1f, %d calls not 200\n", w, last[w]-t0, back[w]-t0, bad[w]}' | sort
    cmd_loop_stop
    k -n "$NS" get pods -o wide
    say "identity after the outage (only pod-ip and boot-id may differ)"
    for x in "${REPLICAS[@]}"; do
      identity "$x" >"$LOG_DIR/identity-$x-$label-after.txt" 2>&1
      if diff "$LOG_DIR/identity-$x-$label-before.txt" "$LOG_DIR/identity-$x-$label-after.txt" >"$LOG_DIR/.diff"; then
        echo "cp-$x: no difference"
      else
        cat "$LOG_DIR/.diff"
        if grep -E '^[<>]' "$LOG_DIR/.diff" | grep -v -E '^[<>] (pod-ip|boot-id) ' | grep -q .; then
          echo "FAIL: the identity of cp-$x changed"
          fail=1
        else
          echo "cp-$x: only the pod IP and the boot ID changed"
        fi
      fi
      echo "cp-$x: lines of the pod log with \"regenerating the certificate\": $(k -n "$NS" logs "cp-$x-0" 2>/dev/null | grep -a -c 'regenerating the certificate' || true)"
    done
    grep -q '^FAIL' "$out" && fail=1
    [ "$fail" = 0 ] && echo "RESULT $label: PASS" || echo "RESULT $label: FAIL"
  } 2>&1 | tee "$out"
  grep -q "RESULT $label: PASS" "$out"
}

# The etcd peer check. etcd compares the source address of a call from a peer with the names in
# the certificate of that peer. For an IP address in the certificate, the two must be equal. For
# a DNS name, etcd asks the DNS for the name and looks for the source address in the answer.
# This step shows the inputs of that check on each replica.
cmd_peercheck() {
  local label=${1:-peercheck} out fail=0 r ips n
  out="$LOG_DIR/peercheck-$label.txt"
  {
    set +e
    say "peer check $label at $(date -u +%FT%TZ): ETCD_PEER_DNS=$ETCD_PEER_DNS ETCD_SAN_SKIP=$ETCD_SAN_SKIP ETCD_PATCH=$ETCD_PATCH ETCD_LISTEN=$ETCD_LISTEN ETP=$ETP"
    k -n "$NS" get svc -o custom-columns=NAME:.metadata.name,TYPE:.spec.type,CLUSTER-IP:.spec.clusterIP,POLICY:.spec.externalTrafficPolicy,NOT-READY:.spec.publishNotReadyAddresses
    ips=$(k -n "$NS" get pods -l g4-role=control-plane -o jsonpath='{range .items[*]}{.status.podIP}{"\n"}{end}' | sort)
    echo "pod IPs: $(tr '\n' ' ' <<<"$ips")"
    for r in "${REPLICAS[@]}"; do
      echo "-- cp-$r"
      pod "$r" sh -c "grep -E -- '--(listen-peer-urls|listen-client-urls|initial-advertise-peer-urls|peer-client-cert-auth|peer-skip-client-san-verification)' /etc/kubernetes/manifests/etcd.yaml | sed 's/^ *- //'"
      echo "names in peer.crt: $(pod "$r" sh -c 'openssl x509 -noout -ext subjectAltName -in /etc/kubernetes/pki/etcd/peer.crt | tail -1' | sed 's/^ *//')"
      echo "resolv.conf: $(pod "$r" sh -c "grep -v '^#' /etc/resolv.conf | tr '\n' ';'")"
      n=$(pod "$r" sh -c "getent ahostsv4 $PEER_NAME | awk '{print \$1}' | sort -u" 2>/dev/null)
      echo "DNS answer for $PEER_NAME: $(tr '\n' ' ' <<<"$n")"
      echo "etcd log lines with \"rejected connection on peer endpoint\": $(pod "$r" sh -c 'crictl logs "$(crictl ps --name etcd -q | head -1)" 2>&1 | grep -c "rejected connection on peer endpoint"')"
      echo "etcd sockets: $(pod "$r" sh -c "ss -ltnH | awk '\$4 ~ /:(2379|2380)\$/ {print \$4}' | sort | tr '\n' ' '")"
      if [ "$ETCD_PATCH" = 1 ]; then
        pod "$r" grep -q -- 'peer-skip-client-san-verification=true' /etc/kubernetes/manifests/etcd.yaml || { echo "FAIL: cp-$r has not the skip flag from the patch file"; fail=1; }
        pod "$r" sh -c "ss -ltnH | grep -q -E '(0\\.0\\.0\\.0|\\*):2380 '" || { echo "FAIL: etcd of cp-$r does not listen on all addresses for peers"; fail=1; }
      elif [ "$ETCD_SAN_SKIP" != 1 ] && pod "$r" grep -q -- 'peer-skip-client-san-verification=true' /etc/kubernetes/manifests/etcd.yaml; then
        echo "FAIL: cp-$r has the skip flag"
        fail=1
      fi
      if [ "$ETCD_PEER_DNS" = 1 ]; then
        pod "$r" openssl x509 -noout -ext subjectAltName -in /etc/kubernetes/pki/etcd/peer.crt | grep -q "DNS:$PEER_NAME" ||
          { echo "FAIL: peer.crt of cp-$r has not the name $PEER_NAME"; fail=1; }
        [ "$n" = "$ips" ] || { echo "FAIL: the DNS answer in cp-$r is not the three pod IPs"; fail=1; }
      fi
    done
    [ "$fail" = 0 ] && echo "RESULT $label: PASS" || echo "RESULT $label: FAIL"
  } 2>&1 | tee "$out"
  grep -q "RESULT $label: PASS" "$out"
}

# The DNS of the host cluster stops, and one replica gets a new pod. With ETCD_PEER_DNS=1 the
# etcd peer check needs that DNS, so this step shows what the option costs: does the cluster
# keep quorum, does the member of the new pod return while the DNS is down, and how long does
# the return take after the DNS is back. With the skip flag the same step is the comparison.
# The step sets the CoreDNS Deployment of the host cluster to 0 replicas and back. Run it only
# when no other test uses the kind node. No step in the group stops the script, so CoreDNS
# always gets its replicas again.
cmd_dns_outage() {
  local r=$1 label=${2:-dns-outage-$1} out fail=0 s x old n joined=no
  out="$LOG_DIR/dns-outage-$label.txt"
  for s in "${REPLICAS[@]}"; do [ "$s" != "$r" ] && break; done # s = a replica that stays
  n=$(k -n kube-system get deploy coredns -o jsonpath='{.spec.replicas}')
  [ "$n" -ge 1 ] || die "CoreDNS has no replicas now. Set them first."
  {
    set +e
    say "DNS outage $label at $(date -u +%FT%TZ): replica $r gets a new pod while the DNS of the host cluster is down (ETCD_PEER_DNS=$ETCD_PEER_DNS ETCD_SAN_SKIP=$ETCD_SAN_SKIP ETP=$ETP)"
    echo "CoreDNS replicas before: $n"
    for x in "${REPLICAS[@]}"; do identity "$x" >"$LOG_DIR/identity-$x-$label-before.txt" 2>&1; done
    cmd_loop_start
    sleep 3
    stamp "$label-dns-down"
    k -n kube-system scale deploy coredns --replicas=0
    wait_here 90 sh -c "[ \"\$(docker exec $KIND_NODE ${KC[*]} -n kube-system get pods -l k8s-app=kube-dns --no-headers 2>/dev/null | wc -l)\" = 0 ]" || echo "FAIL: the CoreDNS pods did not go away"
    echo "DNS answer for $PEER_NAME in cp-$s with CoreDNS down: [$(pod "$s" sh -c "getent ahostsv4 $PEER_NAME | awk '{print \$1}' | sort -u | tr '\n' ' '" 2>/dev/null)]"

    say "60 s with no DNS and no other change"
    sleep 60
    echo "healthy etcd endpoints after 60 s: $(etcdctl "$s" endpoint health --cluster 2>&1 | grep -c 'is healthy') of 3"

    say "new pod for replica $r with no DNS"
    old=$(pod_uid "$r")
    stamp "$label-delete"
    k -n "$NS" delete pod "$(pn "$r")" --wait=true
    wait_here 300 sh -c "u=\$(docker exec $KIND_NODE ${KC[*]} -n $NS get pod $(pn "$r") -o jsonpath='{.metadata.uid} {.status.phase}' 2>/dev/null); [ \"\${u%% *}\" != '$old' ] && [ \"\${u##* }\" = Running ]" ||
      echo "FAIL: no new pod"
    stamp "$label-new-pod-running"
    if wait_here 120 etcd_all_healthy "$s"; then joined=yes; fi
    stamp "$label-wait-done"
    echo "the member of cp-$r is healthy while the DNS is down: $joined (waited $(between "$label-new-pod-running" "$label-wait-done") s after the new pod ran)"
    etcdctl "$s" endpoint health --cluster 2>&1
    etcdctl "$s" endpoint status -w table 2>&1
    for x in "${REPLICAS[@]}"; do
      echo "cp-$x: etcd log lines with \"rejected connection on peer endpoint\": $(pod "$x" sh -c 'crictl logs "$(crictl ps --name etcd -q | head -1)" 2>&1 | grep -c "rejected connection on peer endpoint"' 2>/dev/null)"
      pod "$x" sh -c 'crictl logs "$(crictl ps --name etcd -q | head -1)" 2>&1 | grep "rejected connection on peer endpoint" | tail -2' 2>/dev/null
    done
    echo "calls of the loops between the DNS stop and now:"
    loop_window "$label-dns-down" "$label-wait-done" shared
    for x in "${REPLICAS[@]}"; do loop_window "$label-dns-down" "$label-wait-done" "$x"; done

    say "DNS back: CoreDNS to $n replicas"
    stamp "$label-dns-up"
    k -n kube-system scale deploy coredns --replicas="$n"
    wait_here 300 etcd_all_healthy "$s" || echo "FAIL: etcd is not healthy after the DNS is back"
    stamp "$label-etcd-healthy"
    wait_readyz "${IPS[$r]}" 300 || echo "FAIL: no /readyz of cp-$r"
    stamp "$label-readyz-own"
    k -n kube-system rollout status deploy coredns --timeout=120s
    echo "times (s): DNS stop to pod delete $(between "$label-dns-down" "$label-delete"), pod delete to new pod running $(between "$label-delete" "$label-new-pod-running"), DNS start to three healthy etcd endpoints $(between "$label-dns-up" "$label-etcd-healthy"), DNS start to /readyz of cp-$r $(between "$label-dns-up" "$label-readyz-own")"
    etcdctl "$s" endpoint status --cluster -w table
    sleep 3
    cmd_loop_stop

    say "identity after the DNS outage (only pod-ip and boot-id of replica $r may differ)"
    for x in "${REPLICAS[@]}"; do
      identity "$x" >"$LOG_DIR/identity-$x-$label-after.txt" 2>&1
      if diff "$LOG_DIR/identity-$x-$label-before.txt" "$LOG_DIR/identity-$x-$label-after.txt" >"$LOG_DIR/.diff"; then
        echo "cp-$x: no difference"
      else
        cat "$LOG_DIR/.diff"
        if grep -E '^[<>]' "$LOG_DIR/.diff" | grep -v -E '^[<>] (pod-ip|boot-id) ' | grep -q .; then
          echo "FAIL: the identity of cp-$x changed"
          fail=1
        fi
        [ "$x" = "$r" ] || { echo "FAIL: replica cp-$x changed, and its pod was not replaced"; fail=1; }
      fi
    done
    grep -q '^FAIL' "$out" && fail=1
    echo "RESULT $label: member healthy while the DNS was down: $joined. Cluster healthy after the DNS returned: $([ "$fail" = 0 ] && echo yes || echo no)"
  } 2>&1 | tee "$out"
  k -n kube-system get deploy coredns
}

# --- Host node loss (more than one host node) ---------------------------------------------------
# A second set of loops that runs on the machine itself, outside the host cluster. A call from
# the machine to a LoadBalancer address goes through the Docker bridge to the node that answers
# ARP for the address (MetalLB), so these loops also see a change of that node. The loops in
# KIND_NODE do not: kube-proxy of that node translates the address by itself.
ext_loop_start() {
  local x
  touch "$LOG_DIR/.ext-run"
  for x in shared="$IP_API" a="${IPS[a]}" b="${IPS[b]}" c="${IPS[c]}"; do
    # The loop ends when the file .ext-run goes away, and after one hour in any case.
    (
      end=$(($(date +%s) + 3600))
      while [ -e "$LOG_DIR/.ext-run" ] && [ "$(date +%s)" -lt "$end" ]; do
        printf '%s %s %s\n' "$(date +%s.%N)" "ext-${x%%=*}" "$(curl -sk --max-time 2 -o /dev/null -w '%{http_code} %{time_total}' "https://${x##*=}:6443/readyz")"
        sleep 1
      done
    ) >>"$LOG_DIR/ext-loop-${x%%=*}.log" 2>&1 </dev/null &
  done
}
ext_loop_stop() {
  rm -f "$LOG_DIR/.ext-run"
  sleep 4
}
# loop_stats <from> <to> <who> <file...>: the calls of one target between two times (epoch seconds).
loop_stats() {
  local a=$1 b=$2 w=$3
  shift 3
  cat "$@" 2>/dev/null |
    awk -v a="$a" -v b="$b" -v w="$w" '$1>=a && $1<=b && $2==w {n++; if ($3==200) {if (lastok && $1-lastok>gap) gap=$1-lastok; lastok=$1} else {bad++; if (!first) first=$1; last=$1}}
      END {printf "%s: %d calls, %d not 200", w, n, bad; if (bad) printf " (first %.0f s, last %.0f s after the stop)", first-a, last-a; printf ", longest time between two good calls %.1f s\n", gap}'
}
stamp_at() { awk -v n="$1" '$2==n {x=$1} END {print x}' "$LOG_DIR/times.txt"; }
seen() { grep -q " $1\$" "$LOG_DIR/times.txt" 2>/dev/null; }
since() { awk -v f="$1" -v n="$2" '$2==f {s=$1} $2==n {x=$1} END {if (x) printf "%.1f", x-s; else printf "not reached"}' "$LOG_DIR/times.txt"; }
pod_state() { # one line: UID, phase, Ready, deletion time, restarts, pod IP, container ID
  k -n "$NS" get pod "$(pn "$1")" -o jsonpath='{.metadata.uid}{" phase="}{.status.phase}{" ready="}{.status.conditions[?(@.type=="Ready")].status}{" deletion="}{.metadata.deletionTimestamp}{" restarts="}{.status.containerStatuses[0].restartCount}{" ip="}{.status.podIP}{" container="}{.status.containerStatuses[0].containerID}' 2>/dev/null
}
# leader_now <r>: the name of the etcd leader and the raft term, asked on the member of replica r only.
# It works while another member is down ("endpoint status --cluster" does not).
leader_now() {
  local st ml id
  st=$(etcdctl "$1" --command-timeout=3s endpoint status -w json 2>/dev/null) || return 1
  id=$(jq -r '.[0].Status.leader' <<<"$st")
  ml=$(etcdctl "$1" --command-timeout=3s member list -w json 2>/dev/null) || return 1
  echo "$(jq -r --argjson id "$id" '.members[] | select(.ID == $id) | .name' <<<"$ml") term $(jq -r '.[0].Status.raftTerm' <<<"$st")"
}
l2_state() { k -n metallb-system get servicel2statuses -o jsonpath='{range .items[*]}{.status.serviceName}{"="}{.status.node}{" "}{end}' 2>/dev/null | tr ' ' '\n' | sort | tr '\n' ' '; }

# host-loss <who> <seconds down> [label]: stop the host node of one replica (docker stop), wait,
# start it again, and record what the host cluster and the inner cluster do.
#   who = follower | leader | a | b | c | all   (all = the host nodes of the three replicas together)
# The script does no step by hand after the start: it only reads.
cmd_host_loss() {
  local who=$1 down=${2:-180} label=${3:-host-loss-$1} out fail=0 lead r s x n t i targets=() stay=() nodes=() pids=() t_stop t_start t_end timeout=${HL_TIMEOUT:-900}
  out="$LOG_DIR/host-loss-$label.txt"
  {
    set +e
    for r in "${REPLICAS[@]}"; do
      [ "$(k -n "$NS" get pod "$(pn "$r")" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True ] || die "the pod of replica $r is not ready. Start from three ready replicas."
    done
    lead=$(leader a)
    case "$who" in
      leader) targets=("$lead") ;;
      follower) for x in c b a; do [ "$x" != "$lead" ] && break; done; targets=("$x") ;;
      all) targets=("${REPLICAS[@]}") ;;
      a | b | c) targets=("$who") ;;
      *) die "who must be follower, leader, a, b, c or all" ;;
    esac
    for r in "${REPLICAS[@]}"; do case " ${targets[*]} " in *" $r "*) nodes+=("${HOST_NODES[$r]}") ;; *) stay+=("$r") ;; esac; done
    s=${stay[0]:-}
    say "host loss $label at $(date -u +%FT%TZ): stop ${nodes[*]} (replica ${targets[*]}) for $down s. etcd leader before: cp-$lead. Replicas that stay: ${stay[*]:-none}"
    say "state before"
    k get nodes -o wide
    k -n "$NS" get pods -o wide
    for n in "${nodes[@]}"; do
      docker inspect -f '{{.Name}}: status {{.State.Status}}, started {{.State.StartedAt}}, restarts {{.RestartCount}}, address {{range .NetworkSettings.Networks}}{{.IPAddress}} mac {{.MacAddress}}{{end}}' "$n"
      docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$n" >"$LOG_DIR/.addr-$n"
    done
    echo "MetalLB, the node that answers for each address: $(l2_state)"
    l2_state >"$LOG_DIR/.l2-before"
    etcdctl "${s:-a}" endpoint status --cluster -w table
    echo "etcd leader and term before: $(leader_now "${s:-a}")"
    for x in "${REPLICAS[@]}"; do
      identity "$x" >"$LOG_DIR/identity-$x-$label-before.txt" 2>&1
      pod_state "$x" >"$LOG_DIR/.pod-$x-before"
      echo "cp-$x before: $(cat "$LOG_DIR/.pod-$x-before")"
    done
    cmd_loop_start
    ext_loop_start
    sleep 10

    say "docker stop ${nodes[*]}"
    stamp "$label-stop"
    t_stop=$(stamp_at "$label-stop")
    pids=()
    for n in "${nodes[@]}"; do
      docker stop "$n" >/dev/null &
      pids+=($!)
    done
    wait "${pids[@]}"
    stamp "$label-stop-done"
    for n in "${nodes[@]}"; do echo "$n: $(docker inspect -f 'status {{.State.Status}}, exit code {{.State.ExitCode}}' "$n")"; done
    echo "stop took $(since "$label-stop" "$label-stop-done") s"
    echo "loop devices of the kubelet of the stopped node that stay attached in the kernel: $(losetup -a | grep -c "volumeDevices/$NS-cp-")"
    echo "Kata processes on the machine after the stop: $(ps -eo comm= | grep -c -E 'cloud-hyperviso|virtiofsd')"

    say "while the node is down: one sample each 10 to 15 s (file host-loss-$label-samples.txt)"
    while :; do
      t=$(awk -v a="$t_stop" -v b="$(now)" 'BEGIN {printf "%.0f", b-a}')
      [ "$t" -lt "$down" ] || break
      {
        echo "--- $t s after the stop ($(date -u +%T) UTC)"
        k get nodes --no-headers | awk '{print "node " $1, $2}' | tr '\n' ';'
        echo
        k -n "$NS" get pods -o wide --no-headers | awk '{print "pod " $1, $2, $3, "restarts " $4, $6, $7}'
        echo "shared Service endpoints: $(k -n "$NS" get endpointslices -l kubernetes.io/service-name=cp-api -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{" ready="}{.conditions.ready}{"; "}{end}')"
        echo "MetalLB: $(l2_state)"
        if [ -n "$s" ]; then
          echo "etcd from cp-$s: $(etcdctl "$s" --dial-timeout=2s --command-timeout=3s endpoint health --cluster 2>&1 | grep -c 'is healthy') of 3 endpoints healthy, leader and term: $(leader_now "$s")"
        else
          echo "etcd: no replica runs"
        fi
      } >>"$LOG_DIR/host-loss-$label-samples.txt" 2>&1
      for r in "${targets[@]}"; do
        n=${HOST_NODES[$r]}
        if ! seen "$label-node-notready-$r" && [ "$(k get node "$n" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" != True ]; then stamp "$label-node-notready-$r"; fi
        x=$(pod_state "$r")
        if ! seen "$label-pod-notready-$r" && [[ "$x" == *"ready=False"* ]]; then stamp "$label-pod-notready-$r"; fi
        if ! seen "$label-pod-terminating-$r" && [[ "$x" != *"deletion= "* ]]; then stamp "$label-pod-terminating-$r"; fi
      done
      if ! seen "$label-l2-changed" && [ "$(l2_state)" != "$(cat "$LOG_DIR/.l2-before")" ]; then stamp "$label-l2-changed"; echo "MetalLB changed $(since "$label-stop" "$label-l2-changed") s after the stop: $(l2_state)"; fi
      sleep 3
    done
    say "state at the end of the down time ($down s), as an operator sees it"
    k get nodes -o wide
    for n in "${nodes[@]}"; do k get node "$n" -o jsonpath='{.metadata.name}{": taints "}{range .spec.taints[*]}{.key}{":"}{.effect}{" "}{end}{"\n"}{range .status.conditions[*]}{"   "}{.type}{"="}{.status}{" ("}{.reason}{")"}{"\n"}{end}'; done
    k -n "$NS" get statefulset,pods,pvc -o wide
    for r in "${targets[@]}"; do
      echo "cp-$r: $(pod_state "$r")"
      k -n "$NS" get pod "$(pn "$r")" -o jsonpath='{range .status.conditions[*]}{"   "}{.type}{"="}{.status}{" "}{.reason}{" "}{.message}{"\n"}{end}'
    done
    k -n "$NS" get events --sort-by=.lastTimestamp 2>&1 | tail -15
    k get events -A --field-selector involvedObject.kind=Node --sort-by=.lastTimestamp 2>&1 | tail -8
    echo "MetalLB: $(l2_state)"
    if [ -n "$s" ]; then
      echo "etcd leader and term now, from cp-$s: $(leader_now "$s")"
      etcdctl "$s" --dial-timeout=2s --command-timeout=3s endpoint health --cluster 2>&1 | cut -c1-200
      etcdctl "$s" member list -w table
    fi
    for r in "${targets[@]}"; do
      for x in node-notready pod-notready pod-terminating; do echo "cp-$r $x: $(since "$label-stop" "$label-$x-$r") s after the stop (steps of 10 to 15 s)"; done
    done

    say "docker start ${nodes[*]}. No manual step from here."
    for n in "${nodes[@]}"; do docker start "$n" >/dev/null; done
    stamp "$label-start"
    t_start=$(stamp_at "$label-start")
    for n in "${nodes[@]}"; do
      x=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$n")
      if [ "$x" = "$(cat "$LOG_DIR/.addr-$n")" ]; then echo "$n has its address again: $x"; else echo "FAIL: $n has the address $x, before $(cat "$LOG_DIR/.addr-$n")"; fi
    done
    while [ "$(awk -v a="$t_start" -v b="$(now)" 'BEGIN {printf "%.0f", b-a}')" -lt "$timeout" ]; do
      i=0
      for r in "${targets[@]}"; do
        n=${HOST_NODES[$r]}
        if ! seen "$label-node-ready-$r" && [ "$(k get node "$n" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True ]; then stamp "$label-node-ready-$r"; fi
        x=$(pod_state "$r")
        if ! seen "$label-pod-runs-again-$r" && [[ "$x" == *"phase=Running"* ]] && [[ "$x" == *"deletion= "* ]] && [ "${x##*container=}" != "" ] &&
          [ "${x##*container=}" != "$(sed 's/.*container=//' "$LOG_DIR/.pod-$r-before")" ]; then stamp "$label-pod-runs-again-$r"; fi
        if ! seen "$label-readyz-$r" && [ "$(node curl -sk --max-time 2 "https://${IPS[$r]}:6443/readyz" 2>/dev/null)" = ok ]; then stamp "$label-readyz-$r"; fi
        if seen "$label-pod-runs-again-$r" && ! seen "$label-pod-ready-$r" && [[ "$x" == *"ready=True"* ]]; then stamp "$label-pod-ready-$r"; fi
        if seen "$label-pod-ready-$r" && seen "$label-readyz-$r" && seen "$label-node-ready-$r"; then i=$((i + 1)); fi
      done
      if ! seen "$label-etcd-quorum" && cmd_quorum >/dev/null 2>&1; then stamp "$label-etcd-quorum"; fi
      if seen "$label-etcd-quorum" && ! seen "$label-etcd-healthy" && etcd_all_healthy "${s:-a}"; then stamp "$label-etcd-healthy"; fi
      if ! seen "$label-readyz-shared" && [ "$(node curl -sk --max-time 2 "https://$IP_API:6443/readyz" 2>/dev/null)" = ok ]; then stamp "$label-readyz-shared"; fi
      if [ "$i" = "${#targets[@]}" ] && seen "$label-etcd-healthy" && seen "$label-readyz-shared"; then break; fi
      sleep 1
    done
    stamp "$label-back"
    t_end=$(stamp_at "$label-back")
    sleep 5

    say "times after docker start (s)"
    for r in "${targets[@]}"; do
      for x in node-ready pod-runs-again readyz pod-ready; do
        echo "cp-$r $x: $(since "$label-start" "$label-$x-$r")"
        seen "$label-$x-$r" || { echo "FAIL: cp-$r $x not reached in $timeout s"; fail=1; }
      done
    done
    echo "etcd commits on one member (quorum): $(since "$label-start" "$label-etcd-quorum")"
    echo "three healthy etcd endpoints: $(since "$label-start" "$label-etcd-healthy")"
    seen "$label-etcd-healthy" || { echo "FAIL: etcd not healthy in $timeout s"; fail=1; }
    echo "the shared address answers: $(since "$label-start" "$label-readyz-shared")"

    say "calls between the stop and the return (one call each second for each address)"
    echo "from $KIND_NODE (kube-proxy of that node translates the address):"
    node cat "$LOOP_DIR/shared.log" "$LOOP_DIR/replicas.log" >"$LOG_DIR/.loops-in" 2>/dev/null
    for x in shared "${REPLICAS[@]}"; do loop_stats "$t_stop" "$t_end" "$x" "$LOG_DIR/.loops-in"; done
    echo "from the machine (through the node that answers ARP for the address):"
    for x in shared "${REPLICAS[@]}"; do loop_stats "$t_stop" "$t_end" "ext-$x" "$LOG_DIR/ext-loop-$x.log"; done
    echo "the same for the down time only (stop to start):"
    for x in shared "${REPLICAS[@]}"; do loop_stats "$t_stop" "$t_start" "$x" "$LOG_DIR/.loops-in"; done
    for x in shared "${REPLICAS[@]}"; do loop_stats "$t_stop" "$t_start" "ext-$x" "$LOG_DIR/ext-loop-$x.log"; done
    ext_loop_stop
    cmd_loop_stop
    cp "$LOG_DIR/loop-shared.log" "$LOG_DIR/loop-shared-$label.log" 2>/dev/null
    cp "$LOG_DIR/loop-replicas.log" "$LOG_DIR/loop-replicas-$label.log" 2>/dev/null
    for x in shared "${REPLICAS[@]}"; do mv "$LOG_DIR/ext-loop-$x.log" "$LOG_DIR/ext-loop-$x-$label.log" 2>/dev/null; done

    say "state after"
    k get nodes -o wide
    k -n "$NS" get statefulset,pods -o wide
    echo "MetalLB: $(l2_state)"
    for x in "${REPLICAS[@]}"; do
      echo "cp-$x before: $(cat "$LOG_DIR/.pod-$x-before")"
      echo "cp-$x after:  $(pod_state "$x")"
    done
    for r in "${targets[@]}"; do
      echo "the old container of cp-$r, from the pod status: $(k -n "$NS" get pod "$(pn "$r")" -o jsonpath='{.status.containerStatuses[0].lastState}')"
    done
    etcdctl "${s:-a}" endpoint status --cluster -w table
    echo "etcd leader and term after: $(leader_now "${s:-a}")"
    k -n "$NS" get events --sort-by=.lastTimestamp 2>&1 | tail -25
    for n in "${nodes[@]}"; do
      echo "$n: loop device nodes $(docker exec "$n" sh -c 'ls /dev/loop[0-9]* | wc -l'), g4-loop-nodes.service $(docker exec "$n" systemctl is-active g4-loop-nodes.service), D-Bus $(docker exec "$n" systemctl is-active dbus.service), kubelet volumes $(docker exec "$n" sh -c "losetup -a | grep -c volumeDevices/$NS-cp-")"
    done

    say "identity after (only pod-ip and boot-id of the replica on the stopped node may differ)"
    for x in "${REPLICAS[@]}"; do
      identity "$x" >"$LOG_DIR/identity-$x-$label-after.txt" 2>&1
      if diff "$LOG_DIR/identity-$x-$label-before.txt" "$LOG_DIR/identity-$x-$label-after.txt" >"$LOG_DIR/.diff"; then
        echo "cp-$x: no difference"
      else
        cat "$LOG_DIR/.diff"
        if grep -E '^[<>]' "$LOG_DIR/.diff" | grep -v -E '^[<>] (pod-ip|boot-id) ' | grep -q .; then
          echo "FAIL: the identity of cp-$x changed"
          fail=1
        else
          echo "cp-$x: only the pod IP or the boot ID changed"
        fi
        case " ${targets[*]} " in *" $x "*) ;; *) echo "FAIL: replica cp-$x changed, and its host node was not stopped"; fail=1 ;; esac
      fi
    done
    grep -q '^FAIL' "$out" && fail=1
    [ "$fail" = 0 ] && echo "RESULT $label: PASS" || echo "RESULT $label: FAIL"
  } 2>&1 | tee "$out"
  grep -q "RESULT $label: PASS" "$out"
}

# --- Block C: move a pod to another host node ----------------------------------------------------
# id_compare <label> <replica that may differ ...>: compare identity-<x>-<label>-before.txt with the state now.
id_compare() {
  local label=$1 x rc=0
  shift
  for x in "${REPLICAS[@]}"; do
    identity "$x" >"$LOG_DIR/identity-$x-$label-after.txt" 2>&1
    if diff "$LOG_DIR/identity-$x-$label-before.txt" "$LOG_DIR/identity-$x-$label-after.txt" >"$LOG_DIR/.diff"; then
      echo "cp-$x: no difference"
    else
      cat "$LOG_DIR/.diff"
      if grep -E '^[<>]' "$LOG_DIR/.diff" | grep -v -E '^[<>] (pod-ip|boot-id) ' | grep -q .; then
        echo "FAIL: the identity of cp-$x changed"
        rc=1
      else
        echo "cp-$x: only the pod IP or the boot ID changed"
      fi
      case " $* " in *" $x "*) ;; *) echo "FAIL: replica cp-$x changed, and its pod was not touched"; rc=1 ;; esac
    fi
  done
  return $rc
}
fixed_addr() { pod "$1" sh -c "ip -o -4 addr show net1 2>/dev/null | awk '{print \$4}'" 2>/dev/null; }

# move <r> [label]: cordon the host node of replica r and delete its pod. The StatefulSet makes the pod again,
# and the scheduler puts it on another node (needs PV_NODES=all). The fixed address and the volumes are the same.
cmd_move() {
  local r=$1 label=${2:-move-$1} out fail=0 s x old from to lead
  out="$LOG_DIR/move-$label.txt"
  case "$r" in
    leader) r=$(leader a) ;;
    follower) lead=$(leader a); for r in c b a; do [ "$r" != "$lead" ] && break; done ;;
  esac
  for s in "${REPLICAS[@]}"; do [ "$s" != "$r" ] && break; done
  {
    set +e
    from=$(k -n "$NS" get pod "$(pn "$r")" -o jsonpath='{.spec.nodeName}')
    say "move $label at $(date -u +%FT%TZ): replica $r from $from. etcd leader before: cp-$(leader "$s"). Fixed address before: $(fixed_addr "$r")"
    for x in "${REPLICAS[@]}"; do identity "$x" >"$LOG_DIR/identity-$x-$label-before.txt" 2>&1; done
    old=$(pod_uid "$r")
    k cordon "$from"
    stamp "$label-delete"
    k -n "$NS" delete pod "$(pn "$r")" --wait=true
    stamp "$label-old-pod-gone"
    wait_here 300 sh -c "u=\$(docker exec $KIND_NODE ${KC[*]} -n $NS get pod $(pn "$r") -o jsonpath='{.metadata.uid} {.status.phase}' 2>/dev/null); [ \"\${u%% *}\" != '$old' ] && [ \"\${u##* }\" = Running ]" || echo "FAIL: no new pod"
    stamp "$label-new-pod-running"
    to=$(k -n "$NS" get pod "$(pn "$r")" -o jsonpath='{.spec.nodeName}')
    wait_readyz "${IPS[$r]}" 300 || echo "FAIL: no /readyz"
    stamp "$label-readyz-own"
    wait_here 120 etcd_all_healthy "$s" || echo "FAIL: etcd"
    stamp "$label-etcd-healthy"
    k uncordon "$from"
    echo "replica $r: pod now on $to (before: $from). Fixed address after: $(fixed_addr "$r"). Pod IP: $(k -n "$NS" get pod "$(pn "$r")" -o jsonpath='{.status.podIP}')"
    [ "$to" != "$from" ] || echo "FAIL: the pod did not move"
    [ "$(fixed_addr "$r")" = "${IPS[$r]}/16" ] || [ "$FIXED" != 1 ] || echo "FAIL: the fixed address is not ${IPS[$r]}"
    echo "times after the delete (s): old pod gone $(between "$label-delete" "$label-old-pod-gone"), new pod running $(between "$label-delete" "$label-new-pod-running"), /readyz on the address of the replica $(between "$label-delete" "$label-readyz-own"), three healthy etcd endpoints $(between "$label-delete" "$label-etcd-healthy")"
    loop_window "$label-delete" "$label-etcd-healthy" shared
    for x in "${REPLICAS[@]}"; do loop_window "$label-delete" "$label-etcd-healthy" "$x"; done
    k -n "$NS" get pods -o wide
    k -n "$NS" get pvc -o wide | cut -c1-150
    echo "the two volumes of cp-$r on $to: $(docker exec "$to" sh -c "losetup -a | grep -c 'volumeDevices/$NS-cp-$r-'") loop devices of the kubelet"
    etcdctl "$s" endpoint status --cluster -w table
    say "identity after the move (only pod-ip and boot-id of replica $r may differ)"
    id_compare "$label" "$r" || fail=1
    if [ "$FIXED" = 1 ]; then
      for x in "${REPLICAS[@]}"; do echo "cp-$x: etcd log lines \"rejected connection on peer endpoint\": $(pod "$x" sh -c 'crictl logs "$(crictl ps --name etcd -q | head -1)" 2>&1 | grep -c "rejected connection on peer endpoint"' 2>/dev/null)"; done
    fi
    grep -q '^FAIL' "$out" && fail=1
    [ "$fail" = 0 ] && echo "RESULT $label: PASS" || echo "RESULT $label: FAIL"
  } 2>&1 | tee "$out"
  grep -q "RESULT $label: PASS" "$out"
}

# host-move <who> <seconds before the operator step> [label]: stop the host node of one replica (docker stop) and
# leave it down. Nothing moves the pod by itself: the node is NotReady and the pod object stays. After the wait
# the script does what an operator or a controller must do: it puts the taint node.kubernetes.io/out-of-service
# on the node. Kubernetes then deletes the pod object, the StatefulSet makes the pod again, and the scheduler
# puts it on another node (needs PV_NODES=all). At the end the node starts again and the taint goes away.
cmd_host_move() {
  local who=$1 waits=${2:-90} label=${3:-host-move-$1} out fail=0 lead r s x n old to t_stop timeout=${HL_TIMEOUT:-600}
  out="$LOG_DIR/host-move-$label.txt"
  {
    set +e
    lead=$(leader a)
    case "$who" in
      leader) r=$lead ;;
      follower) for r in c b a; do [ "$r" != "$lead" ] && break; done ;;
      a | b | c) r=$who ;;
      *) die "who must be follower, leader, a, b or c" ;;
    esac
    for s in "${REPLICAS[@]}"; do [ "$s" != "$r" ] && break; done
    n=$(k -n "$NS" get pod "$(pn "$r")" -o jsonpath='{.spec.nodeName}')
    for x in "${REPLICAS[@]}"; do [ "$x" = "$r" ] || [ "$(k -n "$NS" get pod "$(pn "$x")" -o jsonpath='{.spec.nodeName}')" != "$n" ] || die "replica $x is on $n too. Start with one replica on each node."; done
    say "host move $label at $(date -u +%FT%TZ): stop $n (replica $r, $([ "$r" = "$lead" ] && echo the etcd leader || echo a follower)) and leave it down. Operator step after $waits s."
    k get nodes -o wide
    k -n "$NS" get pods -o wide
    for x in "${REPLICAS[@]}"; do identity "$x" >"$LOG_DIR/identity-$x-$label-before.txt" 2>&1; done
    old=$(pod_uid "$r")
    cmd_loop_start
    sleep 5
    stamp "$label-stop"
    t_stop=$(stamp_at "$label-stop")
    docker stop "$n" >/dev/null
    stamp "$label-stop-done"
    echo "$n: $(docker inspect -f 'status {{.State.Status}}, exit code {{.State.ExitCode}}' "$n"). Stop took $(since "$label-stop" "$label-stop-done") s"
    while [ "$(awk -v a="$t_stop" -v b="$(now)" 'BEGIN {printf "%.0f", b-a}')" -lt "$waits" ]; do
      if ! seen "$label-node-notready" && [ "$(k get node "$n" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" != True ]; then stamp "$label-node-notready"; fi
      sleep 2
    done
    say "state $waits s after the stop, with no step by hand"
    k get nodes --no-headers | awk '{print $1, $2}' | tr '\n' ';'
    echo
    k -n "$NS" get pods -o wide --no-headers | awk '{print $1, $2, $3, $7}'
    echo "node NotReady $(since "$label-stop" "$label-node-notready") s after the stop. etcd from cp-$s: $(etcdctl "$s" --dial-timeout=2s --command-timeout=3s endpoint health --cluster 2>&1 | grep -c 'is healthy') of 3 endpoints healthy, leader and term: $(leader_now "$s")"
    say "operator step: kubectl taint nodes $n node.kubernetes.io/out-of-service=nodeshutdown:NoExecute"
    stamp "$label-taint"
    k taint nodes "$n" node.kubernetes.io/out-of-service=nodeshutdown:NoExecute
    while [ "$(awk -v a="$(stamp_at "$label-taint")" -v b="$(now)" 'BEGIN {printf "%.0f", b-a}')" -lt "$timeout" ]; do
      x=$(k -n "$NS" get pod "$(pn "$r")" -o jsonpath='{.metadata.uid} {.spec.nodeName} {.status.phase}' 2>/dev/null)
      if ! seen "$label-old-pod-gone" && [ "${x%% *}" != "$old" ]; then stamp "$label-old-pod-gone"; fi
      if ! seen "$label-new-pod-running" && [ -n "$x" ] && [ "${x%% *}" != "$old" ] && [ "${x##* }" = Running ]; then stamp "$label-new-pod-running"; fi
      if seen "$label-new-pod-running" && ! seen "$label-readyz-own" && [ "$(node curl -sk --max-time 2 "https://${IPS[$r]}:6443/readyz" 2>/dev/null)" = ok ]; then stamp "$label-readyz-own"; fi
      if seen "$label-new-pod-running" && ! seen "$label-etcd-healthy" && etcd_all_healthy "$s"; then stamp "$label-etcd-healthy"; fi
      if seen "$label-readyz-own" && seen "$label-etcd-healthy"; then break; fi
      sleep 1
    done
    to=$(k -n "$NS" get pod "$(pn "$r")" -o jsonpath='{.spec.nodeName}')
    echo "replica $r: pod now on $to (before: $n). Fixed address: $(fixed_addr "$r"). Pod IP: $(k -n "$NS" get pod "$(pn "$r")" -o jsonpath='{.status.podIP}')"
    [ -n "$to" ] && [ "$to" != "$n" ] || echo "FAIL: the pod did not move"
    seen "$label-etcd-healthy" || echo "FAIL: etcd has not three healthy endpoints"
    echo "times after the stop (s): node NotReady $(since "$label-stop" "$label-node-notready"), operator step $(since "$label-stop" "$label-taint"), old pod object gone $(since "$label-stop" "$label-old-pod-gone"), new pod running $(since "$label-stop" "$label-new-pod-running"), /readyz on the address of the replica $(since "$label-stop" "$label-readyz-own"), three healthy etcd endpoints $(since "$label-stop" "$label-etcd-healthy")"
    echo "times after the operator step (s): old pod object gone $(since "$label-taint" "$label-old-pod-gone"), new pod running $(since "$label-taint" "$label-new-pod-running"), /readyz $(since "$label-taint" "$label-readyz-own"), three healthy etcd endpoints $(since "$label-taint" "$label-etcd-healthy")"
    node cat "$LOOP_DIR/shared.log" "$LOOP_DIR/replicas.log" >"$LOG_DIR/.loops-in" 2>/dev/null
    for x in shared "${REPLICAS[@]}"; do loop_stats "$t_stop" "$(stamp_at "$label-etcd-healthy")" "$x" "$LOG_DIR/.loops-in"; done
    cmd_loop_stop
    k -n "$NS" get pods -o wide
    k -n "$NS" get events --sort-by=.lastTimestamp 2>&1 | tail -12 | cut -c1-220
    etcdctl "$s" endpoint status --cluster -w table
    say "identity after the move (only pod-ip and boot-id of replica $r may differ)"
    id_compare "$label" "$r" || fail=1
    if [ "$FIXED" = 1 ]; then
      for x in "${REPLICAS[@]}"; do echo "cp-$x: etcd log lines \"rejected connection on peer endpoint\": $(pod "$x" sh -c 'crictl logs "$(crictl ps --name etcd -q | head -1)" 2>&1 | grep -c "rejected connection on peer endpoint"' 2>/dev/null)"; done
    fi
    say "the node starts again, and the taint goes away"
    docker start "$n" >/dev/null
    stamp "$label-start"
    wait_here 180 sh -c "[ \"\$(docker exec $KIND_NODE ${KC[*]} get node $n -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}')\" = True ]" || echo "FAIL: the node $n is not Ready"
    echo "node $n Ready $(awk -v a="$(stamp_at "$label-start")" -v b="$(now)" 'BEGIN {printf "%.0f", b-a}') s after docker start"
    k taint nodes "$n" node.kubernetes.io/out-of-service-
    sleep 10
    k get nodes --no-headers | awk '{print $1, $2}' | tr '\n' ';'
    echo
    k -n "$NS" get pods -o wide --no-headers | awk '{print $1, $2, $3, $7}'
    echo "sandboxes of the namespace on $n after its start (must be none that run): $(docker exec "$n" crictl pods --namespace "$NS" --state Ready -q 2>/dev/null | wc -l)"
    grep -q '^FAIL' "$out" && fail=1
    [ "$fail" = 0 ] && echo "RESULT $label: PASS" || echo "RESULT $label: FAIL"
  } 2>&1 | tee "$out"
  grep -q "RESULT $label: PASS" "$out"
}

# Change the owner of a replica. The claims and the volumes stay.
cmd_to_bare() {
  local r=$1
  [ "$(owner_of "$r")" = sts ] || die "replica $r is not a StatefulSet"
  say "replica $r: delete the StatefulSet (the claims stay), then make the bare Pod cp-$r with the same claims"
  stamp "to-bare-$r-delete"
  k -n "$NS" delete statefulset "cp-$r" --wait=true
  wait_here 120 sh -c "! docker exec $KIND_NODE ${KC[*]} -n $NS get pod cp-$r-0 >/dev/null 2>&1" || die "the pod cp-$r-0 did not go away"
  k -n "$NS" get pvc
  echo bare >"$LOG_DIR/.owner-$r"
  stamp "to-bare-$r-apply"
  apply_owner "$r"
  wait_readyz "${IPS[$r]}" 300
  stamp "to-bare-$r-readyz-own"
  wait_here 120 etcd_all_healthy "$r"
  say "replica $r as a bare Pod: StatefulSet delete to /readyz $(between "to-bare-$r-delete" "to-bare-$r-readyz-own") s. Hostname in the pod: $(pod "$r" hostname). Node name: cp-$r"
}
cmd_to_sts() {
  local r=$1
  [ "$(owner_of "$r")" = bare ] || die "replica $r is not a bare Pod"
  say "replica $r: delete the bare Pod, then make the StatefulSet again (it takes the claims that exist)"
  k -n "$NS" delete pod "cp-$r" --wait=true
  echo sts >"$LOG_DIR/.owner-$r"
  apply_owner "$r"
  wait_readyz "${IPS[$r]}" 300
  wait_here 120 etcd_all_healthy "$r"
  say "replica $r is a StatefulSet again. Hostname in the pod: $(pod "$r" hostname)"
}

cmd_diag() {
  local label=${1:-diag} r d
  for r in "${REPLICAS[@]}"; do
    d="$LOG_DIR/diag-$label-cp-$r"
    mkdir -p "$d"
    k -n "$NS" get pod "$(pn "$r")" -o wide >"$d/pod.txt" 2>&1 || continue
    k -n "$NS" logs "$(pn "$r")" 2>&1 | head -c 400000 >"$d/pod-log.txt" || true
    pod "$r" sh -c 'crictl ps -a' >"$d/crictl-ps.txt" 2>&1 || true
    pod "$r" sh -c 'for c in $(crictl ps -a --name etcd -q); do echo "== etcd $c"; crictl logs --tail 300 $c 2>&1; done' >"$d/etcd.log" 2>&1 || true
    pod "$r" sh -c 'for c in $(crictl ps -a --name kube-apiserver -q); do echo "== kube-apiserver $c"; crictl logs --tail 200 $c 2>&1; done' >"$d/kube-apiserver.log" 2>&1 || true
    pod "$r" sh -c 'journalctl --no-pager -u kubelet | tail -400' >"$d/kubelet.log" 2>&1 || true
    pod "$r" sh -c 'cat /etc/kubernetes/manifests/etcd.yaml' >"$d/etcd.yaml" 2>&1 || true
    pod "$r" sh -c 'ss -ltnp | grep -E ":(2379|2380|2381|6443|10250) "' >"$d/listen.txt" 2>&1 || true
    pod "$r" sh -c 'ip -4 addr; ip route; cat /etc/hosts; cat /etc/resolv.conf' >"$d/network.txt" 2>&1 || true
  done
  say "diagnosis files are in $LOG_DIR/diag-$label-cp-*"
}

cmd_versions() {
  {
    say "host cluster (kubectl in $KIND_NODE), and the host node of each replica"
    k get nodes -o wide
    for r in "${REPLICAS[@]}"; do echo "cp-$r: host node ${HOST_NODES[$r]}, pod on $(k -n "$NS" get pod "$(pn "$r")" -o jsonpath='{.spec.nodeName}' 2>/dev/null)"; done
    k version | grep -v '^Client'
    node containerd --version
    node uname -r
    k -n metallb-system get deploy metallb-controller -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
    k -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep -E '^mode'
    node sh -c '/opt/kata/runtime-rs/bin/containerd-shim-kata-v2 --version | head -1; /opt/kata/bin/cloud-hypervisor --version'
    say "pod of replica a"
    pod a sh -c 'kubeadm version -o short; kubelet --version; containerd --version; systemctl --version | head -1; uname -r; nproc; grep MemTotal /proc/meminfo'
    pod a sh -c 'crictl images | grep -E "etcd|kube-apiserver |pause"'
    say "runtime class: ${RUNTIME_CLASS:-default (runc)}"
  } 2>&1 | tee "$LOG_DIR/versions.txt"
}

cmd_logs() {
  local r
  k -n "$NS" get statefulset,pod,svc,pvc,endpointslices -o wide >"$LOG_DIR/objects.txt" 2>&1 || true
  k get pv -o wide >>"$LOG_DIR/objects.txt" 2>&1 || true
  k -n "$NS" get statefulset,pod,svc,pvc -o yaml >"$LOG_DIR/objects.yaml" 2>&1 || true
  k -n "$NS" get events --sort-by=.lastTimestamp >"$LOG_DIR/events.txt" 2>&1 || true
  for r in "${REPLICAS[@]}"; do
    pod "$r" journalctl --no-pager -b >"$LOG_DIR/journal-cp-$r.txt" 2>&1 || true
  done
  cmd_diag final >/dev/null
  cmd_versions >/dev/null || true
  say "logs are in $LOG_DIR"
}

cmd_down() {
  local r
  node rm -f "$LOOP_DIR/run" || true
  k -n "$NS" delete statefulset --all --ignore-not-found --wait=true || true
  k -n "$NS" delete pod --all --ignore-not-found --wait=true || true
  k delete namespace "$NS" --ignore-not-found --wait=true
  for r in "${REPLICAS[@]}"; do
    k delete pv "$NS-cp-$r-var" "$NS-cp-$r-etcd" --ignore-not-found --wait=true
  done
  rm -f "$SECRET_DIR/token" "$SECRET_DIR/certkey" "$SECRET_DIR/ca-hash"
}

cmd_wipe() {
  local d pvs r
  check_devices
  pvs=$(k get pv -o name)
  if grep -q "^persistentvolume/$NS-" <<<"$pvs"; then
    die "the volumes are still in the cluster. Run 'down' first."
  fi
  # A volume of another test must not name one of the six devices.
  pvs=$(k get pv -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.local.path}{"\n"}{end}')
  for d in "${!EXPECT[@]}"; do
    if awk -v d="$d" '$2==d' <<<"$pvs" | grep -q .; then die "another volume in the cluster uses $d: $(awk -v d="$d" '$2==d {print $1}' <<<"$pvs")"; fi
  done
  # The kubelet holds each raw block volume with one more loop device. Wait until they are gone.
  for r in "${REPLICAS[@]}"; do
    wait_here 90 sh -c "! docker exec ${HOST_NODES[$r]} losetup -a | grep -q -E 'volumeDevices/$NS-cp-'" || die "the kubelet of ${HOST_NODES[$r]} still holds a volume of $NS"
    rnode "$r" wipefs -a "${VAR_LOOPS[$r]}" "${ETCD_LOOPS[$r]}"
    rnode "$r" sh -c "for d in ${VAR_LOOPS[$r]} ${ETCD_LOOPS[$r]}; do blkid -p \$d; echo \"\$d in ${HOST_NODES[$r]}: blkid exit code \$? (2 = no signature)\"; done"
  done
}

cmd_full() {
  local lead foll r
  cmd_wipe
  stamp run-start
  cmd_services
  cmd_node_up a
  cmd_init
  for r in b c; do
    cmd_node_up "$r"
    cmd_join "$r" || { cmd_diag "join-$r-failed"; die "join of replica $r failed"; }
  done
  stamp cluster-ready
  cmd_rest
}

# The part of "full" after the three replicas have joined: the checks, the replaces, the logs.
cmd_rest() {
  local lead foll r
  cmd_versions
  cmd_check 3-after-join
  if [ "$ETCD_PEER_DNS" = 1 ] || [ "$ETCD_SAN_SKIP" != 1 ] || [ "$ETCD_PATCH" = 1 ]; then cmd_peercheck after-join || true; fi
  cmd_reach 6-after-join
  cmd_loop_start
  sleep 5
  # Step 4 with the StatefulSet: first a follower, then the leader.
  lead=$(leader a)
  for foll in c b a; do [ "$foll" != "$lead" ] && break; done
  cmd_replace "$foll" 4-follower || true
  lead=$(leader a)
  cmd_replace "$lead" 4-leader || true
  # Step 4 with a bare Pod: change the owner of one replica, then replace its pod.
  lead=$(leader a)
  for foll in c b a; do [ "$foll" != "$lead" ] && break; done
  cmd_to_bare "$foll"
  cmd_replace "$foll" 4-bare-pod || true
  if [ "$KEEP" = 1 ]; then
    # Keep the cluster: make the bare Pod a StatefulSet again, and stop one container in place.
    cmd_to_sts "$foll"
    cmd_restart "$foll" 4-restart-in-place || true
  fi
  sleep 5
  cmd_loop_stop
  cmd_check 3-after-replaces
  cmd_reach 6-after-replaces
  cmd_logs
  [ "$KEEP" = 1 ] || cmd_down
  say "results"
  # grep gives exit code 2 when one of the file patterns has no file (no peercheck with the default
  # settings). With "set -e" and "pipefail" that ended the script with exit code 2 after a run in
  # which each step passed (b1-run-1 on the-second-machine). The result lines decide, not this grep.
  { grep -h '^RESULT' "$LOG_DIR"/check-*.txt "$LOG_DIR"/peercheck-*.txt "$LOG_DIR"/reach-*.txt "$LOG_DIR"/replace-*.txt "$LOG_DIR"/restart-*.txt 2>/dev/null || true; } | tee "$LOG_DIR/summary.txt"
  { grep -h -E 'join [0-9.]+ s|^init:|times after the (delete|stop)|new pod create to|^shared: ' "$LOG_DIR/run.log" || true; } | tee -a "$LOG_DIR/summary.txt"
  if grep -v ': PASS$' "$LOG_DIR/summary.txt" | grep -q '^RESULT'; then return 1; fi
}

step=${1:-}
shift || true
case "$step" in
  services | init | check | reach | identity | diag | logs | down | wipe | full | rest | versions | peercheck) "cmd_$step" "$@" 2>&1 | tee -a "$LOG_DIR/run.log" ;;
  dns-outage) cmd_dns_outage "$@" 2>&1 | tee -a "$LOG_DIR/run.log" ;;
  node-up) cmd_node_up "$@" 2>&1 | tee -a "$LOG_DIR/run.log" ;;
  join) cmd_join "$@" 2>&1 | tee -a "$LOG_DIR/run.log" ;;
  replace) cmd_replace "$@" 2>&1 | tee -a "$LOG_DIR/run.log" ;;
  restart) cmd_restart "$@" 2>&1 | tee -a "$LOG_DIR/run.log" ;;
  outage) cmd_outage "$@" 2>&1 | tee -a "$LOG_DIR/run.log" ;;
  host-loss) cmd_host_loss "$@" 2>&1 | tee -a "$LOG_DIR/run.log" ;;
  move) cmd_move "$@" 2>&1 | tee -a "$LOG_DIR/run.log" ;;
  host-move) cmd_host_move "$@" 2>&1 | tee -a "$LOG_DIR/run.log" ;;
  to-bare) cmd_to_bare "$@" 2>&1 | tee -a "$LOG_DIR/run.log" ;;
  to-sts) cmd_to_sts "$@" 2>&1 | tee -a "$LOG_DIR/run.log" ;;
  quorum) cmd_quorum ;;
  loop-start) cmd_loop_start ;;
  loop-stop) cmd_loop_stop ;;
  render) render "$@" ;;
  *)
    sed -n '2,/^set -euo/p' "$0" | sed '$d'
    exit 1
    ;;
esac
