#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Gate 1: run the kind node image as one pod, and make the pod a kubeadm control plane node.
#
# Each kubectl, crictl and curl call runs inside the kind node (docker exec), so the host opens
# no TCP connection. Each wait loop runs in the kind node and sleeps one second between tries.
#
# Usage: run.sh <step>
#   up                 make the volumes, the Service and the pod, then run the preflight check and kubeadm init
#   check [label]      test the pass rules, and record the memory and the identity of the node
#   versions           record the versions in the kind node and in the pod
#   restart [how]      restart the container. how = crictl (default) or poweroff
#   recreate           delete the pod and make a new pod with the same volumes
#   logs               save the pod spec and the logs of the node
#   down               delete the pod, the Service, the claims, the volumes and the namespace
#   wipe               remove the filesystem signatures from the two loop devices (after "down")
#   full               one full run from empty volumes: wipe, up, check, the three restarts, logs, down
#
# Variables. Example for Kata with Cloud Hypervisor and the Rust runtime:
#   NS=gate1-kata RUNTIME_CLASS=kata-clh-runtime-rs LIB_MODULES=0 SNAPSHOTTER=overlayfs IGNORE_PREFLIGHT= STOP_TIMEOUT=10 \
#   VAR_LOOP=/dev/loop19 ETCD_LOOP=/dev/loop23 KERNEL_CONFIG=/scratch/kata-cp/logs/kata-guest-kernel-config-6.18.62-211.txt run.sh full
set -euo pipefail

NS=${NS:-gate1}                         # namespace, and name of the inner cluster
NAME=${NAME:-cp}                        # pod, Service and inner node name
RUNTIME_CLASS=${RUNTIME_CLASS:-}        # empty = default runtime (runc). Example: kata-clh-runtime-rs
LIB_MODULES=${LIB_MODULES:-1}           # 1 = mount /lib/modules of the kind node read-only. 0 for Kata
SNAPSHOTTER=${SNAPSHOTTER:-}            # KIND_EXPERIMENTAL_CONTAINERD_SNAPSHOTTER. Empty = the kind entrypoint selects
VAR_LOOP=${VAR_LOOP:-/dev/loop22}       # var-3 in /scratch/kata-cp/disks/loop-map.txt
ETCD_LOOP=${ETCD_LOOP:-/dev/loop26}     # etcd-3
VAR_SIZE=${VAR_SIZE:-30Gi}
ETCD_SIZE=${ETCD_SIZE:-10Gi}
CPU=${CPU:-4}
MEMORY=${MEMORY:-8Gi}
IMAGE=${IMAGE:-kindest/node:v1.36.4}
K8S_VERSION=${K8S_VERSION:-v1.36.4}
KIND_NODE=${KIND_NODE:-kata-cp-control-plane}
GRACE=${GRACE:-20}                      # terminationGracePeriodSeconds of the pod, and the timeout of crictl stop
# List for kubeadm init --ignore-preflight-errors. Set it to an empty value for no flag.
# SystemVerification: the check needs the kernel config file. The host kernel has no
# /proc/config.gz, and /boot of the host is not in the kind node. Test Kata with an empty value first.
IGNORE_PREFLIGHT=${IGNORE_PREFLIGHT-SystemVerification}
LOOP_MAP=${LOOP_MAP:-/scratch/kata-cp/disks/loop-map.txt}
KERNEL_CONFIG=${KERNEL_CONFIG:-}        # kernel config file on this machine for the pod. Empty = none
FAIL_SWAP_OFF=${FAIL_SWAP_OFF:-1}       # 1 = failSwapOn: false in the kubelet config. 0 = the kubeadm default
G1_SKIP=${G1_SKIP:-}                    # test switch: wrapper steps to leave out (init-cgroup, sysctl, kmsg)
STOP_TIMEOUT=${STOP_TIMEOUT:-}          # seconds for DefaultTimeoutStopSec of systemd in the node. Empty = systemd default (90)
LOG_DIR=${LOG_DIR:-/scratch/kata-cp/logs/gate1/$(date +%Y%m%d-%H%M%S)}

HERE="$(cd "$(dirname "$0")" && pwd)"
KC=(kubectl --kubeconfig /etc/kubernetes/admin.conf)
ETCDCTL='crictl exec "$(crictl ps --name etcd -q)" etcdctl --endpoints https://127.0.0.1:2379 --cacert /etc/kubernetes/pki/etcd/ca.crt --cert /etc/kubernetes/pki/etcd/healthcheck-client.crt --key /etc/kubernetes/pki/etcd/healthcheck-client.key'
mkdir -p "$LOG_DIR"

node() { docker exec "$KIND_NODE" "$@"; }             # a command in the kind node
nodei() { docker exec -i "$KIND_NODE" "$@"; }         # the same, with stdin
k() { node "${KC[@]}" "$@"; }                                # kubectl of the host cluster
pod() { k -n "$NS" exec "$NAME" -- "$@"; }            # a command in the node pod
ik() { pod "${KC[@]}" "$@"; }                                # kubectl of the inner cluster
say() { echo "== $*"; }
stamp() { printf '%s %s\n' "$(date +%s.%N)" "$1" >>"$LOG_DIR/times.txt"; }
# Seconds between two stamps.
between() { awk -v a="$1" -v b="$2" '$2==a {x=$1} $2==b {y=$1} END {printf "%.1f\n", y-x}' "$LOG_DIR/times.txt"; }

# Fill a template: remove the lines of an option that is off, then set the variables.
render() {
  local drop=()
  [ -n "$RUNTIME_CLASS" ] || drop+=(-e '/#@runtimeclass$/d')
  [ "$LIB_MODULES" = 1 ] || drop+=(-e '/#@modules$/d')
  [ -n "$KERNEL_CONFIG" ] || drop+=(-e '/#@kernelconfig$/d')
  [ "$FAIL_SWAP_OFF" = 1 ] || drop+=(-e '/#@failswapoff$/d')
  export NS NAME RUNTIME_CLASS SNAPSHOTTER VAR_LOOP ETCD_LOOP VAR_SIZE ETCD_SIZE CPU MEMORY IMAGE K8S_VERSION KIND_NODE GRACE G1_SKIP STOP_TIMEOUT
  export POD_IP=${POD_IP:-} SVC_IP=${SVC_IP:-}
  sed "${drop[@]}" -e 's/ *#@[a-z]*$//' "$HERE/$1" |
    envsubst '$NS $NAME $RUNTIME_CLASS $SNAPSHOTTER $VAR_LOOP $ETCD_LOOP $VAR_SIZE $ETCD_SIZE $CPU $MEMORY $IMAGE $K8S_VERSION $KIND_NODE $GRACE $G1_SKIP $STOP_TIMEOUT $POD_IP $SVC_IP'
}

# wait_node <seconds> <shell test>: repeat the test in the kind node, one time each second.
wait_node() {
  local t=$1
  shift
  node bash -c "for i in \$(seq 1 $t); do if $*; then exit 0; fi; sleep 1; done; exit 1"
}
svc_ip() { k -n "$NS" get svc "$NAME" -o jsonpath='{.spec.clusterIP}'; }
wait_readyz() { wait_node "${1:-300}" "[ \"\$(curl -sk --max-time 2 https://$(svc_ip):6443/readyz)\" = ok ]"; }
restarts() { k -n "$NS" get pod "$NAME" -o jsonpath='{.status.containerStatuses[0].restartCount}'; }
# The cgroup of the pod in the kind node.
pod_cgroup() {
  local uid
  uid=$(k -n "$NS" get pod "$NAME" -o jsonpath='{.metadata.uid}')
  node find /sys/fs/cgroup/kubelet.slice -maxdepth 3 -type d -name "*pod${uid//-/_}.slice"
}

# The two devices must be loop devices of the lab. No other device is permitted.
check_devices() {
  local d
  for d in "$VAR_LOOP" "$ETCD_LOOP"; do
    grep -q "^$d " "$LOOP_MAP" || { echo "$d is not in $LOOP_MAP"; exit 1; }
  done
  [ "$VAR_LOOP" != "$ETCD_LOOP" ] || { echo "the two devices are the same"; exit 1; }
}

container_id() {
  node crictl ps -q --label io.kubernetes.pod.namespace="$NS" --label io.kubernetes.pod.name="$NAME" --label io.kubernetes.container.name=node
}
sandbox_id() {
  node crictl pods -q --state ready --label io.kubernetes.pod.namespace="$NS" --label io.kubernetes.pod.name="$NAME"
}
# Processes of the Kata sandbox in the kind node: PID, RSS in kB, name. Empty with runc.
sandbox_procs() {
  node sh -c "ps -eo pid=,rss=,args= | grep -E 'cloud-hypervisor|qemu-system|virtiofsd|containerd-shim-kata' | grep '$(sandbox_id)' | awk '{n=split(\$3,a,\"/\"); print \$1, \$2, a[n]}'" || true
}

apply_pod() {
  render node-pod.yaml.tmpl >"$LOG_DIR/node-pod.yaml"
  nodei "${KC[@]}" apply -f - <"$LOG_DIR/node-pod.yaml"
}

cmd_up() {
  check_devices
  say "memory of the host"
  free -g
  say "namespace, volumes and wrapper script"
  k create namespace "$NS" --dry-run=client -o yaml | nodei "${KC[@]}" apply -f -
  render volumes.yaml.tmpl | nodei "${KC[@]}" apply -f -
  nodei "${KC[@]}" -n "$NS" create configmap "$NAME-wrapper" --from-file=wrapper.sh=/dev/stdin --dry-run=client -o yaml <"$HERE/wrapper.sh" |
    nodei "${KC[@]}" apply -f -
  if [ -n "$KERNEL_CONFIG" ]; then
    nodei "${KC[@]}" -n "$NS" create configmap "$NAME-kernel-config" --from-file=config=/dev/stdin --dry-run=client -o yaml <"$KERNEL_CONFIG" |
      nodei "${KC[@]}" apply -f -
  fi

  say "Service and pod"
  stamp pod-create
  apply_pod
  SVC_IP=$(svc_ip)
  wait_node 300 "${KC[*]} -n $NS exec $NAME -- systemctl is-active containerd >/dev/null 2>&1"
  stamp node-up
  POD_IP=$(k -n "$NS" get pod "$NAME" -o jsonpath='{.status.podIP}')
  say "pod IP $POD_IP, Service IP $SVC_IP. systemd and containerd run in the pod."

  say "kubeadm config to /kind/kubeadm.conf"
  render kubeadm.yaml.tmpl >"$LOG_DIR/kubeadm.conf"
  nodei "${KC[@]}" -n "$NS" exec -i "$NAME" -- sh -c 'umask 077; cat >/kind/kubeadm.conf' <"$LOG_DIR/kubeadm.conf"

  say "kubeadm preflight with no ignore flag (output in $LOG_DIR/preflight.txt)"
  local rc=0
  pod kubeadm init phase preflight --config /kind/kubeadm.conf >"$LOG_DIR/preflight.txt" 2>&1 || rc=$?
  echo "exit code: $rc" >>"$LOG_DIR/preflight.txt"
  grep -E 'WARNING|ERROR|exit code' "$LOG_DIR/preflight.txt" || true
  stamp preflight-done

  say "kubeadm init (output in $LOG_DIR/kubeadm-init.txt)"
  pod kubeadm init --config /kind/kubeadm.conf --skip-token-print \
    ${IGNORE_PREFLIGHT:+--ignore-preflight-errors="$IGNORE_PREFLIGHT"} >"$LOG_DIR/kubeadm-init.txt" 2>&1 ||
    { tail -30 "$LOG_DIR/kubeadm-init.txt"; echo "kubeadm init failed"; exit 1; }
  stamp init-done
  wait_readyz 300
  stamp readyz-ok
  # An object to find again after each restart.
  ik -n default create configmap g1-marker --from-literal=made="$(date -u +%FT%TZ)" >/dev/null
  ik -n default get configmap g1-marker -o jsonpath='{.metadata.uid}' >"$LOG_DIR/marker-uid.txt"
  say "pod create to node up: $(between pod-create node-up) s. Pod create to /readyz ok: $(between pod-create readyz-ok) s."
}

# Test the pass rules. The first check of a run saves the identity of the node, and each
# later check compares with it.
cmd_check() {
  local label=${1:-check} out fail=0 ip
  out="$LOG_DIR/check-$label.txt"
  ip=$(svc_ip)
  {
    say "check $label at $(date -u +%FT%TZ)"
    k -n "$NS" get pod "$NAME" -o wide

    say "1. /readyz through the Service $ip, from the kind node"
    node curl -sk --max-time 5 -w ' (http %{http_code})\n' "https://$ip:6443/readyz" | tee "$LOG_DIR/.readyz" || true
    grep -q '^ok (http 200)' "$LOG_DIR/.readyz" || { echo "FAIL readyz"; fail=1; }

    say "2. etcd health, with etcdctl in the etcd container"
    pod sh -c "$ETCDCTL endpoint health" 2>&1 | tee "$LOG_DIR/.etcd" || true
    grep -q 'is healthy' "$LOG_DIR/.etcd" || { echo "FAIL etcd"; fail=1; }
    pod sh -c "$ETCDCTL endpoint status -w table" 2>&1 || true

    say "3. nodes and pods of the inner cluster"
    ik get nodes -o wide | tee "$LOG_DIR/.nodes" || true
    grep -q "^$NAME " "$LOG_DIR/.nodes" || { echo "FAIL node"; fail=1; }
    ik -n kube-system get pods -o wide || true

    say "4. identity of the node (compare with the first check of this run)"
    {
      pod sh -c 'cd /etc/kubernetes/pki && sha256sum ca.crt sa.pub front-proxy-ca.crt etcd/ca.crt etcd/server.crt etcd/peer.crt apiserver-kubelet-client.crt apiserver.crt'
      pod sh -c "$ETCDCTL member list -w simple" | awk -F', ' '{print "etcd-member-id " $1}'
      echo "marker-configmap-uid $(ik -n default get configmap g1-marker -o jsonpath='{.metadata.uid}')"
      echo "machine-id $(pod cat /etc/machine-id)"
      echo "product-uuid $(pod cat /kind/product_uuid)"
      echo "node-uid $(ik get node "$NAME" -o jsonpath='{.metadata.uid}')"
      echo "pod-ip $(k -n "$NS" get pod "$NAME" -o jsonpath='{.status.podIP}')"
    } >"$LOG_DIR/identity-$label.txt" 2>&1 || true
    cat "$LOG_DIR/identity-$label.txt"
    [ -f "$LOG_DIR/identity-base.txt" ] || cp "$LOG_DIR/identity-$label.txt" "$LOG_DIR/identity-base.txt"
    if diff "$LOG_DIR/identity-base.txt" "$LOG_DIR/identity-$label.txt" >"$LOG_DIR/.diff"; then
      echo "identity: no difference from the first check"
    else
      echo "identity: differences from the first check:"
      cat "$LOG_DIR/.diff"
    fi
    grep -q "marker-configmap-uid $(cat "$LOG_DIR/marker-uid.txt")" "$LOG_DIR/identity-$label.txt" || { echo "FAIL marker"; fail=1; }

    say "5. what a restart changes: kernel, VM and cgroup (compare with the check before)"
    {
      echo "boot-id $(pod cat /proc/sys/kernel/random/boot_id)"
      echo "kernel $(pod uname -r)"
      echo "sandbox-id $(sandbox_id)"
      echo "container-id $(container_id)"
      echo "vmm-pid $(sandbox_procs | awk '$3 ~ /cloud-hypervisor|qemu/ {print $1}' | tr '\n' ' ')"
      # Number of cgroups in the whole kernel. In a guest, a number that grows with each restart shows old cgroups.
      echo "kernel-cgroup-count $(pod awk '$1 == "pids" {print $3}' /proc/cgroups)"
      k -n "$NS" logs "$NAME" | grep -m1 'cgroup at start' | tr -d '\r'
    } >"$LOG_DIR/guest-$label.txt" 2>&1 || true
    cat "$LOG_DIR/guest-$label.txt"
    if [ -f "$LOG_DIR/.guest-prev" ]; then
      for key in boot-id sandbox-id container-id vmm-pid; do
        if [ "$(grep "^$key " "$LOG_DIR/.guest-prev")" = "$(grep "^$key " "$LOG_DIR/guest-$label.txt")" ]; then echo "$key: same"; else echo "$key: CHANGED"; fi
      done
    fi
    cp "$LOG_DIR/guest-$label.txt" "$LOG_DIR/.guest-prev"

    say "memory of the pod, from its cgroup in the kind node"
    local cg
    cg=$(pod_cgroup)
    echo "$cg"
    node sh -c "echo memory.current \$(cat $cg/memory.current); echo memory.peak \$(cat $cg/memory.peak); grep -E '^(anon|file|shmem|kernel|slab) ' $cg/memory.stat; echo memory.events \$(tr '\n' ' ' <$cg/memory.events)"
    say "processes of the sandbox in the kind node (PID, RSS in kB, name) and memory in the pod (free -m)"
    sandbox_procs
    pod free -m

    say "container restarts: $(restarts)"
    [ "$fail" = 0 ] && echo "RESULT $label: PASS" || echo "RESULT $label: FAIL"
  } 2>&1 | tee "$out"
  # The start of the pod log is the output of the wrapper and of the kind entrypoint.
  k -n "$NS" logs "$NAME" 2>&1 | head -c 300000 >"$LOG_DIR/pod-log-$label.txt"
  grep -q "RESULT $label: PASS" "$out"
}

cmd_versions() {
  {
    say "kind node"
    k version | grep -v '^Client'
    node containerd --version
    node uname -r
    say "pod"
    pod sh -c 'kubeadm version -o short; kubelet --version; containerd --version; runc --version | head -1; crictl --version; systemctl --version | head -1; uname -r; cat /kind/version'
    pod sh -c 'crictl images | grep -E "etcd|kube-apiserver |pause"'
    pod sh -c 'grep -E "snapshotter = " /etc/containerd/config.toml; findmnt -n -o SOURCE,FSTYPE,OPTIONS /var; findmnt -n -o SOURCE,FSTYPE,OPTIONS /var/lib/etcd'
    say "runtime class of the pod: ${RUNTIME_CLASS:-default (runc)}"
    if [ -n "$RUNTIME_CLASS" ]; then
      node sh -c '/opt/kata/bin/kata-runtime --version | head -2; /opt/kata/bin/containerd-shim-kata-v2 --version | head -1; /opt/kata/runtime-rs/bin/containerd-shim-kata-v2 --version | head -1; /opt/kata/bin/cloud-hypervisor --version'
      pod sh -c 'echo "guest kernel: $(uname -r)"; echo "guest command line: $(cat /proc/cmdline)"; nproc; grep MemTotal /proc/meminfo'
    fi
  } 2>&1 | tee "$LOG_DIR/versions.txt"
}

# Restart the container in a way that Kubernetes sees as a container restart.
cmd_restart() {
  local how=${1:-crictl} before cid
  before=$(restarts)
  say "restart of the container with $how (restart count now: $before)"
  stamp "restart-$how-start"
  case "$how" in
    crictl)
      cid=$(node crictl ps -q --label io.kubernetes.pod.namespace="$NS" --label io.kubernetes.pod.name="$NAME" --label io.kubernetes.container.name=node)
      # With Kata the kill after the timeout does not stop the container, and crictl gives an error.
      # The container then stops when systemd ends its own shutdown.
      node crictl stop --timeout "$GRACE" "$cid" || echo "crictl stop gave an error. The container did not stop inside $GRACE s."
      ;;
    poweroff) pod systemctl poweroff || true ;;
    *) echo "unknown restart method $how"; exit 1 ;;
  esac
  wait_node 300 "[ \"\$(${KC[*]} -n $NS get pod $NAME -o jsonpath='{.status.containerStatuses[0].restartCount}')\" -gt $before ]"
  stamp "restart-$how-new-container"
  # Exit code 137 = the runtime killed the container. 130 = systemd ended its shutdown and halted.
  say "the old container ended with: $(k -n "$NS" get pod "$NAME" -o jsonpath='{.status.containerStatuses[0].lastState.terminated}')"
  wait_readyz 300
  stamp "restart-$how-readyz-ok"
  say "$how: stop to new container $(between "restart-$how-start" "restart-$how-new-container") s, stop to /readyz ok $(between "restart-$how-start" "restart-$how-readyz-ok") s"
}

# Delete the pod and make a new pod with the same volumes. The new pod has a new IP.
cmd_recreate() {
  say "delete the pod"
  stamp recreate-start
  k -n "$NS" delete pod "$NAME" --wait=true
  stamp recreate-old-pod-gone
  say "new pod with the same volumes"
  stamp recreate-pod-create
  apply_pod
  wait_node 300 "[ \"\$(${KC[*]} -n $NS get pod $NAME -o jsonpath='{.status.phase}')\" = Running ]"
  wait_readyz 300
  stamp recreate-readyz-ok
  say "recreate: delete took $(between recreate-start recreate-old-pod-gone) s, pod create to /readyz ok $(between recreate-pod-create recreate-readyz-ok) s"
}

cmd_logs() {
  k -n "$NS" get pod "$NAME" -o yaml >"$LOG_DIR/pod.yaml"
  k -n "$NS" describe pod "$NAME" >"$LOG_DIR/pod-describe.txt"
  k -n "$NS" logs "$NAME" >"$LOG_DIR/pod-log-last.txt" 2>&1 || true
  pod journalctl --no-pager -b >"$LOG_DIR/journal.txt" 2>&1 || true
  pod sh -c 'dmesg | tail -200' >"$LOG_DIR/dmesg-tail.txt" 2>&1 || true
  cmd_versions >/dev/null
  say "logs are in $LOG_DIR"
}

cmd_down() {
  k -n "$NS" delete pod "$NAME" --ignore-not-found --wait=true
  k delete namespace "$NS" --ignore-not-found --wait=true
  k delete pv "$NS-$NAME-var" "$NS-$NAME-etcd" --ignore-not-found --wait=true
}

cmd_wipe() {
  check_devices
  if k get pv "$NS-$NAME-var" >/dev/null 2>&1 || k get pv "$NS-$NAME-etcd" >/dev/null 2>&1; then
    echo "the volumes are still in the cluster. Run 'down' first."
    exit 1
  fi
  # The kubelet holds each raw block volume with one more loop device. Wait until they are gone.
  wait_node 60 "! losetup -a | grep -q -E 'volumeDevices/$NS-$NAME-(var|etcd)/'"
  node wipefs -a "$VAR_LOOP" "$ETCD_LOOP"
  node sh -c "blkid -p $VAR_LOOP $ETCD_LOOP; echo \"blkid exit code \$? (2 = no signature)\""
}

cmd_full() {
  cmd_wipe
  cmd_up
  cmd_versions
  cmd_check 1-after-init
  cmd_restart crictl
  cmd_check 2-after-crictl-stop
  cmd_restart poweroff
  cmd_check 3-after-poweroff
  cmd_recreate
  cmd_check 4-after-new-pod
  cmd_logs
  cmd_down
  say "times (seconds)"
  for pair in pod-create:node-up pod-create:init-done pod-create:readyz-ok \
    restart-crictl-start:restart-crictl-readyz-ok restart-poweroff-start:restart-poweroff-readyz-ok \
    recreate-pod-create:recreate-readyz-ok; do
    echo "${pair%%:*} to ${pair##*:}: $(between "${pair%%:*}" "${pair##*:}")"
  done | tee "$LOG_DIR/summary-times.txt"
}

step=${1:-}
shift || true
case "$step" in
  up | check | versions | restart | recreate | logs | down | wipe | full) "cmd_$step" "$@" 2>&1 | tee -a "$LOG_DIR/run.log" ;;
  render) render "$@" ;;
  *) sed -n '2,20p' "$0"; exit 1 ;;
esac
