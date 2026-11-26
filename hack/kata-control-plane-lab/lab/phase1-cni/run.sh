#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Phase 1 step 1: OVN-Kubernetes with the userspace datapath of Open vSwitch in ONE NVKE control
# plane node that runs as a pod (runc or Kata). The base is lab/gate1-nvke/run.sh.
# A client pod stands in for the NVKE controller and calls nvke-agent in the order of the
# controller: GetKubeadmStatus, ExecuteNodePreflight, StartOpenVSwitchReconciliation with a status
# poll, ExecuteKubeadmInit with no_cni_install, GetKubeconfig, InstallCNI. Then the script waits for
# the Node and for pods on the pod network, and imitates the node-local-dns step of the controller.
#
# Each kubectl, crictl and curl call runs inside the kind node (docker exec), so the host opens no
# TCP connection. A wait is one "kubectl wait" call, or a loop in the kind node that starts with
# systemd-run. The agent runs in plaintext mode (--disable-mtls). Identity is not under test.
#
# Usage: run.sh <step>
#   up            make the volumes, the client pod, the Service and the node pod
#   units [label] record the systemd units, the network and the Open vSwitch state of the node
#   agent         wait for the agent (one client call with the gRPC wait-for-ready option)
#   ovs           preflight, then the Open vSwitch step of the controller
#   init          render the NVKE kubeadm configuration and start kubeadm init through nvke-agent
#   cni           InstallCNI through nvke-agent
#   ready         wait for the Node, for CoreDNS and for the OVN pods
#   csr           approve the kubelet serving certificate request of the node (the controller has an approver for it)
#   testpod       one pod on the pod network: the API Service address and a name lookup
#   dns           the node-local-dns step of the controller (kube_local_dns.yaml, labels, kube-dns Service)
#   check [label] /readyz, etcd, nodes
#   restart       extra test: stop the container, then the pod network test again (use it after "full" with KEEP=1)
#   evidence      save the Open vSwitch, OVN, netfilter and kernel state
#   logs          save the pod spec, the journals and the versions
#   down          delete the pods, the Service, the claims, the volumes and the namespace
#   wipe          remove the filesystem signatures from the two loop devices (after "down")
#   full          one full run from empty volumes. KEEP=1 leaves the pod up at the end
#
# Variables for Kata (the class of record):
#   RUNTIME_CLASS=kata-clh-runtime-rs-fix-direct G1_SKIP=init-cgroup STOP_TIMEOUT= VAR_LOOP=/dev/loop21 ETCD_LOOP=/dev/loop25 \
#   KERNEL_CONFIG=/scratch/kata-cp/logs/kata-guest-kernel-config-6.18.62-211.txt P1_OVS_NO_MODPROBE=1 P1_TUN=1 LOG_DIR=... run.sh full
set -euo pipefail

NS=${NS:-phase1-cni}                    # namespace of the node pod and the client pod
NAME=${NAME:-nvke-cp}                   # pod, Service and inner node name
RUNTIME_CLASS=${RUNTIME_CLASS:-}        # empty = default runtime (runc)
SNAPSHOTTER=${SNAPSHOTTER:-overlayfs}   # KIND_EXPERIMENTAL_CONTAINERD_SNAPSHOTTER
VAR_LOOP=${VAR_LOOP:-/dev/loop20}       # runc: /dev/loop20 and /dev/loop24. Kata: /dev/loop21 and /dev/loop25
ETCD_LOOP=${ETCD_LOOP:-/dev/loop24}
VAR_SIZE=${VAR_SIZE:-30Gi}
ETCD_SIZE=${ETCD_SIZE:-10Gi}
CPU=${CPU:-4}
MEMORY=${MEMORY:-8Gi}
IMAGE=${IMAGE:-nvke-node:bcc4376f-amd64}
K8S_VERSION=${K8S_VERSION:-v1.36.4}
KIND_NODE=${KIND_NODE:-kata-cp-control-plane}
GRACE=${GRACE:-20}                      # terminationGracePeriodSeconds of the pod
STOP_TIMEOUT=${STOP_TIMEOUT-10}         # DefaultTimeoutStopSec of systemd in the node. Empty = the systemd default
KERNEL_CONFIG=${KERNEL_CONFIG:-}        # kernel config file for the kubeadm check (Kata guest)
G1_SKIP=${G1_SKIP:-}                    # test switch of the gate 1 wrapper (init-cgroup for the patched Kata agent)
SKIP_UNITS=${SKIP_UNITS:-}
POD_CIDR=${POD_CIDR:-10.113.0.0/16}     # not the ranges of the host cluster
SERVICE_CIDR=${SERVICE_CIDR:-10.112.0.0/16}
API_SVC_IP=${API_SVC_IP:-10.112.0.1}    # first address of SERVICE_CIDR: the Service "kubernetes"
DNS_SVC_IP=${DNS_SVC_IP:-10.112.0.10}   # the Service kube-dns
SYSTEM_RESERVED_MEMORY=${SYSTEM_RESERVED_MEMORY:-1Gi}
KUBE_RESERVED_MEMORY=${KUBE_RESERVED_MEMORY:-512Mi}
# The switches of section 6 of the wrapper.
P1_OVS_DATAPATH=${P1_OVS_DATAPATH-netdev}       # NKE_OVS_DATAPATH_TYPE. Empty = the image value (system)
P1_OVS_NO_MODPROBE=${P1_OVS_NO_MODPROBE:-0}     # 1 = no modprobe step in ovs-vswitchd.service
P1_TUN=${P1_TUN:-0}                             # 1 = make /dev/net/tun
P1_KMOD_NOOP=${P1_KMOD_NOOP:-0}                 # 1 = ovs-kmod-ctl does nothing (runc guard)
READY_TIMEOUT=${READY_TIMEOUT:-600}             # seconds for the Node and for the pods
TEST_IMAGE=${TEST_IMAGE:-localhost/nvke/ovnkube:8af51273d52d}   # in the node from the image package, no pull
LOCAL_DNS_MANIFEST=${LOCAL_DNS_MANIFEST:-/scratch/kata-cp/src/nvke/controller/internal/temporal/activities/kube_local_dns.yaml}
CLIENT_BIN=${CLIENT_BIN:-/scratch/kata-cp/work/phase1-cni/bin/nvke-lab-client}
CLIENT_BIN_DIR=${CLIENT_BIN_DIR:-/var/lib/phase1-cni/bin}   # folder in the kind node, a hostPath of the client pod
LOOP_MAP=${LOOP_MAP:-/scratch/kata-cp/disks/loop-map.txt}
LOG_DIR=${LOG_DIR:-/scratch/kata-cp/logs/phase1-cni/$(date +%Y%m%d-%H%M%S)}

HERE="$(cd "$(dirname "$0")" && pwd)"
KC=(kubectl --kubeconfig /etc/kubernetes/admin.conf)
ETCDCTL='crictl exec "$(crictl ps --name etcd -q)" etcdctl --endpoints https://127.0.0.1:2379 --cacert /etc/kubernetes/pki/etcd/ca.crt --cert /etc/kubernetes/pki/etcd/healthcheck-client.crt --key /etc/kubernetes/pki/etcd/healthcheck-client.key'
AGENT_ADDR="$NAME.$NS.svc.cluster.local:15005"
SEC="$LOG_DIR/secrets"                  # the kubeadm files and the kubeconfig. Never in ~/notes
mkdir -p "$LOG_DIR" "$SEC"
chmod 700 "$SEC"
# This test never mounts /lib/modules of the kind node, so modprobe in the pod has no module files.
LIB_MODULES=0
MODE=plaintext
AGENT_PLAINTEXT=1

case "$VAR_LOOP $ETCD_LOOP" in
  "/dev/loop20 /dev/loop24" | "/dev/loop21 /dev/loop25") ;;
  *) echo "this test may use only /dev/loop20 with /dev/loop24, or /dev/loop21 with /dev/loop25"; exit 1 ;;
esac

node() { docker exec "$KIND_NODE" "$@"; }             # a command in the kind node
nodei() { docker exec -i "$KIND_NODE" "$@"; }         # the same, with stdin
k() { node "${KC[@]}" "$@"; }                         # kubectl of the host cluster
pod() { k -n "$NS" exec "$NAME" -- "$@"; }            # a command in the node pod
podi() { nodei "${KC[@]}" -n "$NS" exec -i "$NAME" -- "$@"; }   # the same, with stdin
cpod() { k -n "$NS" exec lab-client -- "$@"; }        # a command in the client pod
ik() { pod "${KC[@]}" "$@"; }                         # kubectl of the inner cluster, in the node pod
client() { cpod /lab-bin/nvke-lab-client -addr "$AGENT_ADDR" -plaintext "$@"; }
say() { echo "== $*"; }
stamp() { printf '%s %s\n' "$(date +%s.%N)" "$1" >>"$LOG_DIR/times.txt"; }
between() { awk -v a="$1" -v b="$2" '$2==a {x=$1} $2==b {y=$1} END {if (x && y) printf "%.1f\n", y-x; else print "-"}' "$LOG_DIR/times.txt"; }

# Fill a template: remove the lines of an option that is off, then set the variables.
render() {
  local drop=()
  [ -n "$RUNTIME_CLASS" ] || drop+=(-e '/#@runtimeclass$/d')
  [ "$LIB_MODULES" = 1 ] || drop+=(-e '/#@modules$/d')
  [ -n "$KERNEL_CONFIG" ] || drop+=(-e '/#@kernelconfig$/d')
  [ "$MODE" = mtls ] || drop+=(-e '/#@mtls$/d')
  export NS NAME RUNTIME_CLASS SNAPSHOTTER VAR_LOOP ETCD_LOOP VAR_SIZE ETCD_SIZE CPU MEMORY IMAGE KIND_NODE GRACE G1_SKIP STOP_TIMEOUT
  export AGENT_PLAINTEXT SKIP_UNITS CLIENT_BIN_DIR P1_OVS_DATAPATH P1_OVS_NO_MODPROBE P1_TUN P1_KMOD_NOOP TEST_IMAGE
  sed "${drop[@]}" -e 's/ *#@[a-z]*$//' "$HERE/$1" |
    envsubst '$NS $NAME $RUNTIME_CLASS $SNAPSHOTTER $VAR_LOOP $ETCD_LOOP $VAR_SIZE $ETCD_SIZE $CPU $MEMORY $IMAGE $KIND_NODE $GRACE $G1_SKIP $STOP_TIMEOUT $AGENT_PLAINTEXT $SKIP_UNITS $CLIENT_BIN_DIR $P1_OVS_DATAPATH $P1_OVS_NO_MODPROBE $P1_TUN $P1_KMOD_NOOP $TEST_IMAGE'
}

# wait_node <seconds> <shell test>: repeat the test in the kind node, one time each second.
# The loop is a transient systemd unit of the kind node, not a child of docker exec.
wait_node() {
  local t=$1
  shift
  node systemd-run --quiet --wait --collect --expand-environment=no --unit="p1cni-wait-$$-$RANDOM" \
    bash -c "for i in \$(seq 1 $t); do if $*; then exit 0; fi; sleep 1; done; exit 1"
}
svc_ip() { k -n "$NS" get svc "$NAME" -o jsonpath='{.spec.clusterIP}'; }
pod_ip() { k -n "$NS" get pod "$NAME" -o jsonpath='{.status.podIP}'; }
restarts() { k -n "$NS" get pod "$NAME" -o jsonpath='{.status.containerStatuses[0].restartCount}'; }
pod_cgroup() {
  local uid
  uid=$(k -n "$NS" get pod "$NAME" -o jsonpath='{.metadata.uid}')
  node find /sys/fs/cgroup/kubelet.slice -maxdepth 3 -type d -name "*pod${uid//-/_}.slice"
}
check_devices() {
  local d
  for d in "$VAR_LOOP" "$ETCD_LOOP"; do
    grep -q "^$d " "$LOOP_MAP" || { echo "$d is not in $LOOP_MAP"; exit 1; }
  done
}
sandbox_id() { node crictl pods -q --namespace "$NS" --name "$NAME" --state ready; }
sandbox_procs() {
  node sh -c "ps -eo pid=,rss=,args= | grep -E 'cloud-hypervisor|qemu-system|virtiofsd|containerd-shim-kata' | grep '$(sandbox_id)' | awk '{n=split(\$3,a,\"/\"); print \$1, \$2, a[n]}'" || true
}
ensure_ns() { k create namespace "$NS" --dry-run=client -o yaml | nodei "${KC[@]}" apply -f - >/dev/null; }

cmd_up() {
  check_devices
  say "memory of the host"
  free -g
  say "namespace, volumes, wrapper script and client pod"
  ensure_ns
  render volumes.yaml.tmpl | nodei "${KC[@]}" apply -f -
  nodei "${KC[@]}" -n "$NS" create configmap "$NAME-wrapper" --from-file=wrapper.sh=/dev/stdin --dry-run=client -o yaml <"$HERE/wrapper.sh" |
    nodei "${KC[@]}" apply -f -
  if [ -n "$KERNEL_CONFIG" ]; then
    # No "apply" here: a kernel config can be larger than the limit of the apply annotation.
    k -n "$NS" delete configmap "$NAME-kernel-config" --ignore-not-found >/dev/null
    nodei "${KC[@]}" -n "$NS" create configmap "$NAME-kernel-config" --from-file=config=/dev/stdin <"$KERNEL_CONFIG"
  fi
  node mkdir -p "$CLIENT_BIN_DIR"
  docker cp -q "$CLIENT_BIN" "$KIND_NODE:$CLIENT_BIN_DIR/nvke-lab-client"
  render client-pod.yaml.tmpl >"$LOG_DIR/client-pod.yaml"
  nodei "${KC[@]}" apply -f - <"$LOG_DIR/client-pod.yaml"
  k -n "$NS" wait --for=condition=Ready pod/lab-client --timeout=120s

  say "Service and node pod"
  render node-pod.yaml.tmpl >"$LOG_DIR/node-pod.yaml"
  stamp pod-create
  nodei "${KC[@]}" apply -f - <"$LOG_DIR/node-pod.yaml"
  k -n "$NS" wait --for=jsonpath='{.status.phase}'=Running "pod/$NAME" --timeout=300s
  wait_node 300 "${KC[*]} -n $NS exec $NAME -- systemctl is-active containerd >/dev/null 2>&1"
  stamp node-up
  say "pod IP $(pod_ip), Service IP $(svc_ip). systemd and containerd run in the pod after $(between pod-create node-up) s."
  k -n "$NS" logs "$NAME" 2>&1 | grep -E 'WRAP:' | tee "$LOG_DIR/wrapper-log.txt" || true
}

# The Open vSwitch state of the node, as text. Each command is allowed to fail.
ovs_state() {
  pod sh -c 'echo "--- units"
    for u in ovsdb-server ovs-vswitchd openvswitch-switch nke-container-network nke-container-cni-images nvke-agent systemd-networkd; do
      printf "%-28s enabled=%-10s active=%-12s result=%s\n" "$u" "$(systemctl is-enabled "$u" 2>&1 | head -1)" "$(systemctl is-active "$u" 2>&1 | head -1)" "$(systemctl show -p Result --value "$u" 2>&1 | head -1)"
    done
    echo "--- drop-in files"; systemctl cat ovs-vswitchd.service 2>&1 | grep -E "^# /|ExecStartPre"; systemctl show nvke-agent -p Environment
    echo "--- /dev/net/tun"; ls -l /dev/net/tun 2>&1
    echo "--- kernel"; uname -r; ls -d /proc/modules /sys/module/openvswitch 2>&1
    echo "--- ovs-vsctl show"; ovs-vsctl --timeout=5 show 2>&1
    echo "--- Open_vSwitch external_ids and other_config"; ovs-vsctl --timeout=5 get Open_vSwitch . external_ids other_config datapath_types iface_types 2>&1
    echo "--- bridges"; ovs-vsctl --timeout=5 --columns=name,datapath_type,fail_mode,external_ids list bridge 2>&1
    echo "--- interfaces"; ovs-vsctl --timeout=5 --columns=name,type,ofport,error,admin_state,link_state,mtu list interface 2>&1
    echo "--- dpif/show"; ovs-appctl --timeout=5 dpif/show 2>&1
    echo "--- dpctl/dump-dps"; ovs-appctl --timeout=5 dpctl/dump-dps 2>&1
    echo "--- links"; ip -br link 2>&1; echo "--- addresses"; ip -br -4 addr 2>&1; echo "--- routes"; ip route 2>&1; echo "--- rules"; ip rule 2>&1' 2>&1 || true
}

cmd_units() {
  local label=${1:-units}
  {
    say "systemd state ($label)"
    pod sh -c 'systemctl is-system-running; echo "failed units:"; systemctl --failed --no-legend --plain' || true
    ovs_state
    say "netplan, resolv.conf, mounts"
    pod sh -c 'cat /etc/netplan/*.yaml 2>/dev/null; echo "--- networkctl:"; networkctl list 2>&1 | head; echo "--- resolv.conf:"; cat /etc/resolv.conf
      for m in / /var /var/lib/etcd /etc/kubernetes /run /tmp; do findmnt -n -o TARGET,SOURCE,FSTYPE "$m"; done
      grep -H . /etc/default/nvke-agent /etc/default/kubelet; cloud-init status' || true
    say "journal of the Open vSwitch units and of the network unit"
    pod sh -c 'for u in ovsdb-server ovs-vswitchd openvswitch-switch nke-container-network nke-container-cni-images; do echo "--- $u"; journalctl --no-pager -b -u "$u" 2>&1 | tail -15; done' || true
  } 2>&1 | tee "$LOG_DIR/units-$label.txt"
}

cmd_agent() {
  say "wait for the agent through the Service ($AGENT_ADDR)"
  client -steps status -wait-for-agent 600s 2>&1 | tee "$LOG_DIR/client-agent.txt" || return 1
  stamp agent-ready
  say "the agent answers $(between pod-create agent-ready) s after the pod create"
}

# The step ConfigureOpenVSwitch of the node workflow. The operation ID has the form of the controller:
# open-vswitch/<workflow ID>/<run ID>/<node ID>.
cmd_ovs() {
  local opid
  opid="open-vswitch/lab-$(basename "$LOG_DIR")/$(cat /proc/sys/kernel/random/uuid)/$(cat /proc/sys/kernel/random/uuid)"
  stamp ovs-start
  client -steps preflight,ovs -ovs-operation-id "$opid" 2>&1 | tee "$LOG_DIR/client-ovs.txt" || {
    say "FAIL: the Open vSwitch step"
    ovs_state >"$LOG_DIR/ovs-state-after-failed-reconcile.txt" 2>&1
    return 1
  }
  stamp ovs-done
  say "Open vSwitch step: $(between ovs-start ovs-done) s"
  ovs_state >"$LOG_DIR/ovs-state-after-reconcile.txt" 2>&1
  grep -E 'datapath_type|ovn-bridge-datapath-type|userspace-tso|Bridge|active=' "$LOG_DIR/ovs-state-after-reconcile.txt" | head -30 || true
}

# Render the configuration and the four files with the renderer of the NVKE controller, for this pod IP.
render_kubeadm() {
  local ip
  ip=$(pod_ip)
  ( umask 077; mkdir -p "$SEC/kubeadm" )
  K8S_VERSION=$K8S_VERSION POD_CIDR=$POD_CIDR SERVICE_CIDR=$SERVICE_CIDR SKIP_KUBE_PROXY=true CONTAINER_MODE=false \
    SYSTEM_RESERVED_MEMORY=$SYSTEM_RESERVED_MEMORY KUBE_RESERVED_MEMORY=$KUBE_RESERVED_MEMORY \
    "$HERE/render/render.sh" "$SEC/kubeadm" "$ip" "$ip" "$NAME"
  # A copy with no bootstrap token, for the report.
  sed -E 's/(token: )[a-z0-9]{6}\.[a-z0-9]{16}/\1REDACTED/' "$SEC/kubeadm/kubeadm-init.yaml" >"$LOG_DIR/kubeadm-init.redacted.yaml"
}

cmd_init() {
  local files=() path name mode ip readyz_pid
  ip=$(pod_ip)
  [ -f "$SEC/kubeadm/kubeadm-init.yaml" ] || render_kubeadm || return 1
  stamp render-done
  tar -C "$SEC/kubeadm" -cf - . | nodei "${KC[@]}" -n "$NS" exec -i lab-client -- sh -c 'mkdir -p -m 700 /lab-work/kubeadm && tar -C /lab-work/kubeadm -xf -'
  while read -r path name mode _; do
    files+=(-file "$path=/lab-work/kubeadm/$name:$mode")
  done <"$SEC/kubeadm/files.txt"
  # The pod is ready when /readyz of the inner API server answers (readiness probe, each 2 s).
  # Its output does not go to the pipe of this script, so a failed run does not wait for it.
  ( k -n "$NS" wait --for=condition=Ready "pod/$NAME" --timeout=600s && stamp readyz-ok ) >/dev/null 2>&1 &
  readyz_pid=$!
  stamp init-start
  client -steps init,wait,kubeconfig -init-config /lab-work/kubeadm/kubeadm-init.yaml "${files[@]}" \
    -endpoint "$ip" -pod-cidr "$POD_CIDR" -service-cidr "$SERVICE_CIDR" \
    -kubeconfig-out /lab-work/kubeconfig 2>&1 | tee "$LOG_DIR/client-init.txt" || { say "FAIL: kubeadm init"; return 1; }
  stamp init-done
  wait "$readyz_pid" || { say "/readyz did not answer"; return 1; }
  ( umask 077; cpod cat /lab-work/kubeconfig >"$SEC/kubeconfig" )
  say "client start to init ready: $(between init-start init-done) s. Pod create to /readyz ok: $(between pod-create readyz-ok) s."
}

# The activity InstallCNI of the cluster workflow: one synchronous call.
cmd_cni() {
  stamp cni-start
  client -steps cni -pod-cidr "$POD_CIDR" -service-cidr "$SERVICE_CIDR" 2>&1 | tee "$LOG_DIR/client-cni.txt" || { say "FAIL: InstallCNI"; return 1; }
  stamp cni-done
  say "InstallCNI: $(between cni-start cni-done) s"
  pod sh -c 'KUBECONFIG=/etc/kubernetes/admin.conf helm list -A 2>&1; KUBECONFIG=/etc/kubernetes/admin.conf helm get values ovn-kubernetes 2>&1' | tee "$LOG_DIR/helm-release.txt" || true
}

# The tenant CSR approver of the controller approves the kubelet serving request of a node that it manages
# (controller/internal/controllers/tenant/csr/controller.go, docs/tenant-clusters/kubelet-serving-certificates.md).
# The lab has no controller, so it approves the request of this node. Without the certificate the API server
# cannot call the kubelet, and "kubectl exec" and "kubectl logs" fail. The CNI does not depend on it.
cmd_csr() {
  local names
  ik get csr -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.signerName}{" "}{.spec.username}{" ["}{.status.conditions[*].type}{"]\n"}{end}' | tee "$LOG_DIR/csr-before.txt"
  names=$(awk -v u="system:node:$NAME" '$2=="kubernetes.io/kubelet-serving" && $3==u && $4=="[]" {print $1}' "$LOG_DIR/csr-before.txt")
  if [ -z "$names" ]; then
    say "no pending kubelet serving request of system:node:$NAME"
  else
    # shellcheck disable=SC2086 # one word for each request name
    ik certificate approve $names
  fi
  pod sh -c 'for i in $(seq 1 90); do if [ -e /var/lib/kubelet/pki/kubelet-server-current.pem ]; then echo "kubelet serving certificate: present after $i tries"; exit 0; fi; sleep 1; done; echo "kubelet serving certificate: absent"; exit 1'
  stamp kubelet-serving-cert
}

inner_state() {
  ik get nodes -o wide 2>&1 || true
  ik get pods -A -o wide 2>&1 || true
}

# Wait for the Node, for CoreDNS (a pod on the pod network) and for the OVN pods.
cmd_ready() {
  local rc=0
  say "wait for the Node $NAME (limit $READY_TIMEOUT s)"
  if ik wait --for=condition=Ready "node/$NAME" --timeout="${READY_TIMEOUT}s"; then
    stamp node-ready
    say "Node Ready: $(between pod-create node-ready) s after the pod create, $(between cni-done node-ready) s after InstallCNI returned"
  else
    say "FAIL: the Node is not Ready"; rc=1
  fi
  say "wait for CoreDNS (limit $READY_TIMEOUT s)"
  if ik -n kube-system wait --for=condition=Ready pod -l k8s-app=kube-dns --timeout="${READY_TIMEOUT}s"; then
    stamp coredns-ready
    say "CoreDNS Ready: $(between pod-create coredns-ready) s after the pod create, $(between cni-done coredns-ready) s after InstallCNI returned"
  else
    say "FAIL: CoreDNS is not Ready"; rc=1
  fi
  say "wait for the OVN pods (limit 300 s)"
  if ik -n ovn-kubernetes wait --for=condition=Ready pod --all --timeout=300s; then
    stamp ovn-pods-ready
  else
    say "the OVN pods are not all Ready"; rc=1
  fi
  inner_state | tee "$LOG_DIR/inner-state-after-ready.txt"
  {
    echo "outer pod created: $(k -n "$NS" get pod "$NAME" -o jsonpath='{.metadata.creationTimestamp}')"
    echo "inner Node Ready since: $(ik get node "$NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].lastTransitionTime}')"
    ik -n kube-system get pods -l k8s-app=kube-dns -o jsonpath='{range .items[*]}{.metadata.name}{" podIP="}{.status.podIP}{" Ready since "}{.status.conditions[?(@.type=="Ready")].lastTransitionTime}{"\n"}{end}'
  } 2>&1 | tee "$LOG_DIR/api-timestamps.txt" || true
  return "$rc"
}

# One pod on the pod network. It uses the OVN image of the node, so the node pulls nothing.
cmd_testpod() {
  local rc=0
  render test-pod.yaml.tmpl >"$LOG_DIR/test-pod.yaml"
  podi "${KC[@]}" apply -f - <"$LOG_DIR/test-pod.yaml"
  if ik -n default wait --for=condition=Ready pod/p1-net-test --timeout=300s; then
    stamp testpod-ready
  else
    say "FAIL: the test pod is not Ready"
    ik -n default describe pod p1-net-test | tail -25 || true
    return 1
  fi
  net_test first || rc=1
  return "$rc"
}

# net_test <label>: from the test pod, call the API Service address and resolve names through the cluster DNS.
net_test() {
  local label=$1 out fail=0
  out="$LOG_DIR/net-test-$label.txt"
  {
    say "test pod ($label) at $(date -u +%FT%TZ)"
    ik -n default get pod p1-net-test -o wide
    ik -n default exec p1-net-test -- sh -c 'echo "--- address"; ip -br -4 addr show; ip route; echo "--- resolv.conf"; cat /etc/resolv.conf' || true
    say "1. the API Service address https://$API_SVC_IP:443/version"
    ik -n default exec p1-net-test -- curl -sk --max-time 10 -o /dev/null -w 'http_code=%{http_code} remote=%{remote_ip}:%{remote_port} time=%{time_total}\n' "https://$API_SVC_IP:443/version" | tee "$LOG_DIR/.api" || true
    grep -q -E 'http_code=(200|401|403)' "$LOG_DIR/.api" || { echo "FAIL api service"; fail=1; }
    say "2. name lookup through the cluster DNS (getent, the resolver of the pod)"
    ik -n default exec p1-net-test -- getent hosts kubernetes.default.svc.cluster.local | tee "$LOG_DIR/.dns" || true
    grep -q "^$API_SVC_IP " "$LOG_DIR/.dns" || { echo "FAIL dns lookup"; fail=1; }
    ik -n default exec p1-net-test -- getent hosts kube-dns.kube-system.svc.cluster.local || true
    say "3. the API Service by name"
    ik -n default exec p1-net-test -- curl -sk --max-time 10 -o /dev/null -w 'http_code=%{http_code} remote=%{remote_ip}:%{remote_port} time=%{time_total}\n' "https://kubernetes.default.svc.cluster.local/version" | tee "$LOG_DIR/.apiname" || true
    grep -q -E 'http_code=(200|401|403)' "$LOG_DIR/.apiname" || { echo "FAIL api service by name"; fail=1; }
    say "4. ten lookups in a row (count of answers)"
    ik -n default exec p1-net-test -- sh -c "n=0; for i in 1 2 3 4 5 6 7 8 9 10; do if getent hosts kubernetes.default.svc.cluster.local >/dev/null; then n=\$((n+1)); fi; done; echo \"answers: \$n of 10\"" | tee "$LOG_DIR/.dns10" || true
    grep -q 'answers: 10 of 10' "$LOG_DIR/.dns10" || { echo "FAIL repeated dns lookup"; fail=1; }
    [ "$fail" = 0 ] && echo "RESULT net-test-$label: PASS" || echo "RESULT net-test-$label: FAIL"
  } 2>&1 | tee "$out"
  grep -q "RESULT net-test-$label: PASS" "$out"
}

# The activity InstallKubeLocalDNS of the controller (install_kube_local_dns.go:53-88), with kubectl in the node:
# 1. server-side apply of kube_local_dns.yaml with force, 2. the label dns-role=cluster-dns on the CoreDNS template
# and on the running CoreDNS pods, 3. the annotation and the port change of the kube-dns Service, 4. when one pod
# with dns-role=cluster-dns is Ready, the selector of kube-dns becomes dns-role=cluster-dns only.
cmd_dns() {
  local rc=0
  {
    cp "$LOCAL_DNS_MANIFEST" "$LOG_DIR/kube_local_dns.yaml"
    say "1. server-side apply of kube_local_dns.yaml"
    stamp dns-start
    podi "${KC[@]}" apply --server-side --force-conflicts --field-manager=nvke-controller -f - <"$LOG_DIR/kube_local_dns.yaml"
    say "2. label dns-role=cluster-dns on the CoreDNS Deployment template and on the running CoreDNS pods"
    ik -n kube-system patch deployment coredns --type merge -p '{"spec":{"template":{"metadata":{"labels":{"dns-role":"cluster-dns"}}}}}'
    ik -n kube-system label pods -l k8s-app=kube-dns dns-role=cluster-dns --overwrite
    say "3. kube-dns Service: annotations and ports"
    ik -n kube-system annotate service kube-dns prometheus.io/port- prometheus.io/scrape- k8s.ovn.org/prefer-local-with-fallback=node-local-dns --overwrite
    ik -n kube-system get service kube-dns -o json | jq -c '[.spec.ports | to_entries[] | select(.value.name=="metrics") | {op:"remove", path:("/spec/ports/" + (.key|tostring))}] | reverse' >"$LOG_DIR/.dnsports.json"
    if [ "$(cat "$LOG_DIR/.dnsports.json")" != "[]" ]; then
      ik -n kube-system patch service kube-dns --type json -p "$(cat "$LOG_DIR/.dnsports.json")"
    fi
    say "4. the check of the controller: one Ready pod with dns-role=cluster-dns"
    ik -n kube-system get pods -l dns-role=cluster-dns -o wide
    ik -n kube-system get pods -l dns-role=cluster-dns -o jsonpath='{range .items[*]}{.metadata.name}{" hostNetwork="}{.spec.hostNetwork}{" podIP="}{.status.podIP}{" Ready="}{.status.conditions[?(@.type=="Ready")].status}{" since "}{.status.conditions[?(@.type=="Ready")].lastTransitionTime}{"\n"}{end}' | tee "$LOG_DIR/.dnsrole"
    if grep -q 'Ready=True' "$LOG_DIR/.dnsrole"; then
      stamp dns-role-pod-ready
      echo "RESULT dns-role: PASS (a Ready pod with dns-role=cluster-dns exists, so the controller would change the selector now)"
      ik -n kube-system patch service kube-dns --type merge -p '{"spec":{"selector":{"dns-role":"cluster-dns","k8s-app":null}}}'
      stamp dns-selector-changed
    else
      echo "RESULT dns-role: FAIL (no Ready pod with dns-role=cluster-dns)"
    fi
    say "5. wait for the CoreDNS rollout (the template changed) and for the node-local-dns pod (one image pull in the node)"
    ik -n kube-system rollout status deployment/coredns --timeout=300s || echo "RESULT coredns-rollout: FAIL"
    if ik -n kube-system wait --for=condition=Ready pod -l k8s-app=node-local-dns --timeout=600s; then
      stamp node-local-dns-ready
      echo "RESULT node-local-dns: PASS (Ready $(between dns-start node-local-dns-ready) s after the apply)"
    else
      echo "RESULT node-local-dns: FAIL"
      ik -n kube-system describe pod -l k8s-app=node-local-dns | tail -30 || true
    fi
    ik -n kube-system get pods -l dns-role=cluster-dns -o wide
    ik -n kube-system get service kube-dns kube-dns-upstream -o wide
    ik -n kube-system get endpointslices -l kubernetes.io/service-name=kube-dns -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{" ready="}{.conditions.ready}{" "}{.targetRef.name}{"\n"}{end}'
    ik -n kube-system get service kube-dns -o jsonpath='{"selector: "}{.spec.selector}{"\nannotations: "}{.metadata.annotations}{"\nports: "}{.spec.ports[*].name}{"\n"}'
    ik -n kube-system logs -l k8s-app=node-local-dns --tail=30 2>&1 || true
  } 2>&1 | tee "$LOG_DIR/dns-step.txt"
  grep -q 'RESULT.*FAIL' "$LOG_DIR/dns-step.txt" && rc=1
  # The same test from the test pod, now with node-local-dns behind the kube-dns Service.
  net_test after-dns-step || rc=1
  return "$rc"
}

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
    say "3. nodes and pods of the inner cluster"
    ik get nodes -o wide | tee "$LOG_DIR/.nodes" || true
    grep -q -E "^$NAME +Ready " "$LOG_DIR/.nodes" || { echo "FAIL node not Ready"; fail=1; }
    ik get pods -A -o wide || true
    say "4. state of nvke-agent, kernel, VM and memory"
    pod sh -c 'jq -c "{role, phase, status, currentMessage, kubeadmStatus, cniPlugin, cniPluginVersion, cniPluginStatus}" /var/lib/nvke/state.json 2>/dev/null || head -c 400 /var/lib/nvke/state.json' || true
    echo "kernel $(pod uname -r) restarts $(restarts)"
    local cg
    cg=$(pod_cgroup)
    node sh -c "echo memory.current \$(cat $cg/memory.current); echo memory.peak \$(cat $cg/memory.peak); echo memory.events \$(tr '\n' ' ' <$cg/memory.events)" || true
    sandbox_procs
    pod free -m
    pod sh -c 'ps -eo pid,rss,pcpu,etimes,comm --sort=-rss | head -15' || true
    [ "$fail" = 0 ] && echo "RESULT $label: PASS" || echo "RESULT $label: FAIL"
  } 2>&1 | tee "$out"
  grep -q "RESULT $label: PASS" "$out"
}

# The state of Open vSwitch, OVN, netfilter and the kernel, for the report.
cmd_evidence() {
  local d="$LOG_DIR/evidence" c
  mkdir -p "$d"
  ovs_state >"$d/ovs-state.txt" 2>&1
  pod sh -c 'ovs-appctl --timeout=5 dpif/show; echo; ovs-appctl --timeout=5 dpctl/show; echo; ovs-appctl --timeout=5 dpif/show-dp-features br-int; echo; ovs-ofctl --timeout=5 dump-ports-desc br-int; echo; ovs-ofctl --timeout=5 dump-ports-desc br-ex; echo "flows br-int: $(ovs-ofctl --timeout=5 dump-flows br-int | wc -l)"; echo "flows br-ex: $(ovs-ofctl --timeout=5 dump-flows br-ex | wc -l)"; echo "datapath flows: $(ovs-appctl --timeout=5 dpctl/dump-flows | wc -l)"; ovs-appctl --timeout=5 dpctl/dump-conntrack | wc -l' >"$d/ovs-datapath.txt" 2>&1 || true
  pod sh -c 'ip -d link show; echo; ip addr; echo; ip route show table all; echo; ip rule; echo; ip neigh' >"$d/ip.txt" 2>&1 || true
  pod nft list ruleset >"$d/nft-ruleset.txt" 2>&1 || true
  pod iptables-save >"$d/iptables-save.txt" 2>&1 || true
  pod sh -c 'cat /var/log/openvswitch/ovs-vswitchd.log' >"$d/ovs-vswitchd.log" 2>&1 || true
  pod sh -c 'cat /var/log/openvswitch/ovsdb-server.log' >"$d/ovsdb-server.log" 2>&1 || true
  pod sh -c 'ls -la /var/log/openvswitch /var/log/ovn /var/log/ovn-kubernetes 2>&1; for f in /var/log/ovn/ovn-controller.log /var/log/ovn/ovn-northd.log; do echo "=== $f"; tail -100 "$f"; done' >"$d/ovn-logs.txt" 2>&1 || true
  pod sh -c 'tail -400 /var/log/ovn-kubernetes/ovnkube-controller*.log 2>/dev/null' >"$d/ovnkube-controller-file-log-tail.txt" 2>&1 || true
  pod journalctl --no-pager -b -u ovs-vswitchd -u ovsdb-server -u openvswitch-switch -u nke-container-network -u nke-container-cni-images >"$d/journal-ovs-units.txt" 2>&1 || true
  pod journalctl --no-pager -b -u nvke-agent >"$d/journal-nvke-agent.txt" 2>&1 || true
  pod journalctl --no-pager -b -u kubelet >"$d/journal-kubelet.txt" 2>&1 || true
  pod journalctl --no-pager -b -u containerd >"$d/journal-containerd.txt" 2>&1 || true
  pod dmesg >"$d/dmesg.txt" 2>&1 || true
  pod sh -c 'systemctl is-system-running; systemctl --failed --no-legend --plain' >"$d/systemd-failed.txt" 2>&1 || true
  pod crictl images >"$d/crictl-images.txt" 2>&1 || true
  ik get nodes -o wide >"$d/inner-nodes.txt" 2>&1 || true
  ik describe node "$NAME" >"$d/inner-node-describe.txt" 2>&1 || true
  ik get node "$NAME" -o jsonpath='{.metadata.annotations}' >"$d/inner-node-annotations.json" 2>&1 || true
  ik get pods -A -o wide >"$d/inner-pods.txt" 2>&1 || true
  ik get events -A --sort-by=.lastTimestamp >"$d/inner-events.txt" 2>&1 || true
  ik -n ovn-kubernetes get all,cm -o wide >"$d/ovn-objects.txt" 2>&1 || true
  ik -n ovn-kubernetes describe pods >"$d/ovn-pods-describe.txt" 2>&1 || true
  for c in nb-ovsdb sb-ovsdb ovn-northd ovnkube-controller ovn-controller; do
    ik -n ovn-kubernetes logs -l app=ovnkube-node -c "$c" --tail=-1 >"$d/ovn-log-$c.txt" 2>&1 || true
    ik -n ovn-kubernetes logs -l app=ovnkube-node -c "$c" --previous --tail=200 >"$d/ovn-log-$c-previous.txt" 2>&1 || true
  done
  ik -n ovn-kubernetes logs deployment/ovnkube-control-plane --all-containers --tail=-1 >"$d/ovn-log-control-plane.txt" 2>&1 || true
  ik -n kube-system logs -l k8s-app=kube-dns --tail=100 >"$d/coredns-log.txt" 2>&1 || true
  say "evidence is in $d"
}

# Extra test, not a pass rule: stop the container of the node pod. The kubelet of the kind node makes a new
# container in the same sandbox (with Kata: the same guest VM and the same network namespace), on the same volumes.
# Then wait for the API server, for the Node and for the pods, and repeat the pod network test with a new test pod.
cmd_restart() {
  local before cid fail=0
  {
    before=$(restarts)
    cid=$(node crictl ps -q --label io.kubernetes.pod.namespace="$NS" --label io.kubernetes.pod.name="$NAME" --label io.kubernetes.container.name=node)
    say "restart of the container with crictl stop (restart count now: $before)"
    pod sh -c 'echo "system-id before: $(cat /etc/openvswitch/system-id.conf) $(ovs-vsctl get Open_vSwitch . external_ids:system-id)"' || true
    ik get node "$NAME" -o jsonpath='{"chassis annotation before: "}{.metadata.annotations.k8s\.ovn\.org/node-chassis-id}{"\n"}' || true
    stamp restart-start
    node crictl stop --timeout "$GRACE" "$cid" || echo "crictl stop gave an error. The container did not stop inside $GRACE s."
    wait_node 300 "[ \"\$(${KC[*]} -n $NS get pod $NAME -o jsonpath='{.status.containerStatuses[0].restartCount}')\" -gt $before ]" || { echo "RESULT restart: FAIL (no new container)"; exit 0; }
    stamp restart-new-container
    say "the old container ended with: $(k -n "$NS" get pod "$NAME" -o jsonpath='{.status.containerStatuses[0].lastState.terminated}')"
    if k -n "$NS" wait --for=condition=Ready "pod/$NAME" --timeout=300s; then stamp restart-readyz-ok; else echo "FAIL /readyz after the restart"; fail=1; fi
    say "stop to new container $(between restart-start restart-new-container) s, stop to /readyz ok $(between restart-start restart-readyz-ok) s"
    k -n "$NS" logs "$NAME" 2>&1 | grep -E 'WRAP: P1' || true
    # The Node object keeps its old Ready state until the new kubelet reports. Wait for containers that started after the restart.
    say "wait for the OVN pods and for CoreDNS after the restart"
    wait_node 300 "${KC[*]} -n $NS exec $NAME -- sh -c 'test \$(crictl ps --state running --name ovnkube-controller -q | wc -l) -ge 1 && test \$(crictl ps --state running --name coredns -q | wc -l) -ge 1' >/dev/null 2>&1" || { echo "FAIL the OVN or CoreDNS containers did not start"; fail=1; }
    stamp restart-containers-running
    ik wait --for=condition=Ready "node/$NAME" --timeout=300s || fail=1
    ik -n ovn-kubernetes wait --for=condition=Ready pod --all --timeout=300s || fail=1
    ik -n kube-system wait --for=condition=Ready pod -l k8s-app=kube-dns --timeout=300s || fail=1
    stamp restart-pods-ready
    say "stop to pods Ready: $(between restart-start restart-pods-ready) s"
    pod sh -c 'echo "system-id after: $(cat /etc/openvswitch/system-id.conf) $(ovs-vsctl get Open_vSwitch . external_ids:system-id)"' || true
    ik get node "$NAME" -o jsonpath='{"chassis annotation after: "}{.metadata.annotations.k8s\.ovn\.org/node-chassis-id}{"\n"}' || true
    inner_state
    ovs_state >"$LOG_DIR/ovs-state-after-restart.txt" 2>&1
    grep -E 'active=|datapath_type|Bridge' "$LOG_DIR/ovs-state-after-restart.txt" || true
    # A new test pod, so the test uses a pod that the CNI plugged after the restart.
    ik -n default delete pod p1-net-test --ignore-not-found --wait=true || true
    podi "${KC[@]}" apply -f - <"$LOG_DIR/test-pod.yaml" || fail=1
    ik -n default wait --for=condition=Ready pod/p1-net-test --timeout=300s || fail=1
    [ "$fail" = 0 ] && echo "RESULT restart: PASS" || echo "RESULT restart: FAIL"
  } 2>&1 | tee "$LOG_DIR/restart.txt"
  net_test after-restart || echo "RESULT restart-net-test: FAIL" | tee -a "$LOG_DIR/restart.txt"
  ! grep -q 'RESULT.*FAIL' "$LOG_DIR/restart.txt"
}

cmd_logs() {
  k -n "$NS" get pod "$NAME" -o yaml >"$LOG_DIR/pod.yaml" 2>&1 || true
  k -n "$NS" describe pod "$NAME" >"$LOG_DIR/pod-describe.txt" 2>&1 || true
  k -n "$NS" logs "$NAME" 2>&1 | head -c 400000 >"$LOG_DIR/pod-log-last.txt" || true
  # The whole journal can hold tokens of kubeadm, so it stays with the secrets.
  pod journalctl --no-pager -b >"$SEC/journal.txt" 2>&1 || true
  pod cat /var/log/nvke-agent-audit.log >"$LOG_DIR/nvke-agent-audit.log" 2>&1 || true
  {
    say "kind node"
    k version | grep -v '^Client'
    node containerd --version
    node uname -r
    say "node pod"
    pod sh -c '/usr/bin/kubeadm.real version -o short; kubelet --version; containerd --version; runc --version | head -1; systemctl --version | head -1; uname -r; /usr/local/bin/nvke-agent --version; ovs-vswitchd --version | head -1; helm version --short; grep MemTotal /proc/meminfo; nproc'
    say "runtime class of the pod: ${RUNTIME_CLASS:-default (runc)}"
    if [ -n "$RUNTIME_CLASS" ]; then
      node sh -c '/opt/kata/bin/kata-runtime --version | head -2; /opt/kata/bin/cloud-hypervisor --version'
      pod sh -c 'echo "guest command line: $(cat /proc/cmdline)"'
    fi
  } >"$LOG_DIR/versions.txt" 2>&1 || true
  say "logs are in $LOG_DIR"
}

cmd_down() {
  k -n "$NS" delete pod "$NAME" lab-client --ignore-not-found --wait=true
  k delete namespace "$NS" --ignore-not-found --wait=true
  k delete pv "$NS-$NAME-var" "$NS-$NAME-etcd" --ignore-not-found --wait=true
}

cmd_wipe() {
  check_devices
  if k get pv "$NS-$NAME-var" >/dev/null 2>&1 || k get pv "$NS-$NAME-etcd" >/dev/null 2>&1; then
    echo "the volumes are still in the cluster. Run 'down' first."
    exit 1
  fi
  wait_node 60 "! losetup -a | grep -q -E 'volumeDevices/$NS-$NAME-(var|etcd)/'"
  node wipefs -a "$VAR_LOOP" "$ETCD_LOOP"
  node sh -c "blkid -p $VAR_LOOP $ETCD_LOOP; echo \"blkid exit code \$? (2 = no signature)\""
}

times() {
  say "times (seconds)"
  for pair in pod-create:node-up pod-create:agent-ready ovs-start:ovs-done init-start:init-done pod-create:readyz-ok cni-start:cni-done \
    pod-create:node-ready cni-done:node-ready pod-create:coredns-ready cni-done:coredns-ready pod-create:testpod-ready \
    dns-start:dns-role-pod-ready dns-start:node-local-dns-ready; do
    echo "${pair%%:*} to ${pair##*:}: $(between "${pair%%:*}" "${pair##*:}")"
  done | tee "$LOG_DIR/summary-times.txt"
}

# The steps of one run, in the order of the controller. Each step must pass.
flow() {
  cmd_agent || return 1
  cmd_ovs || return 1
  cmd_init || return 1
  cmd_cni || return 1
  cmd_ready || return 1
  cmd_csr || return 1
  cmd_testpod || return 1
  # SKIP_DNS=1 leaves out the node-local-dns step, so the node pulls no image (for the extra restart test).
  if [ "${SKIP_DNS:-0}" != 1 ]; then cmd_dns || return 1; fi
  cmd_check final || return 1
}

# One full run from empty volumes.
cmd_full() {
  local rc=0
  cmd_wipe
  cmd_up
  cmd_units after-boot || true
  flow || rc=1
  times || true
  cmd_evidence || true
  cmd_logs || true
  if [ "$rc" = 0 ]; then echo "RESULT full: PASS"; else echo "RESULT full: FAIL"; fi
  if [ "${KEEP:-0}" = 1 ]; then
    say "KEEP=1: the pod stays up"
  else
    cmd_down
    cmd_wipe
  fi
  return "$rc"
}

step=${1:-}
shift || true
case "$step" in
  up | units | agent | ovs | init | cni | ready | csr | testpod | dns | check | restart | evidence | logs | down | wipe | full)
    "cmd_$step" "$@" 2>&1 | tee -a "$LOG_DIR/run.log"
    exit "${PIPESTATUS[0]}"
    ;;
  nettest) net_test "${1:-manual}" ;;
  times) times ;;
  render) render "$@" ;;
  *) sed -n '2,32p' "$0"; exit 1 ;;
esac
