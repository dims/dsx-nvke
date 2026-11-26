#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Phase 1 dry run: three NVKE control plane nodes as Kata pods, with no NVKE controller.
# A client pod stands in for the controller and calls nvke-agent in the order of
# provision_cluster.go, provision_node.go and joinProvisionedNode. It combines:
#   - gate 4: one StatefulSet with 1 replica and one LoadBalancer Service for each node. The
#     LoadBalancer address is the node address. The etcd settings come from a kubeadm patch file.
#   - phase 1 step 1: OVN-Kubernetes with the userspace datapath of Open vSwitch.
# The cluster endpoint is the address of the first node. There is no shared API Service.
#
# Each kubectl, crictl and curl call runs inside the kind node (docker exec), so the host opens no
# TCP connection. A wait is one "kubectl wait" call, or a loop in the kind node that starts with
# systemd-run. The agent runs in plaintext mode.
#
# Usage: run.sh <step>
#   base              namespace, wrapper, the three Services and the client pod
#   node-up <r>       volumes and StatefulSet of node r (a, b, c)
#   units <r> [label] systemd units, addresses and Open vSwitch state of node r
#   prep <r>          agent version, preflight and the Open vSwitch step (host preparation of ProvisionNode)
#   init              kubeadm init on node a with no CNI, then the kubeconfig
#   cni               InstallCNI on node a
#   dns               the node-local-dns step and the namespace labels
#   csr               approve the kubelet serving requests of the known nodes (the tenant CSR approver)
#   postjoin <r>      the post-join steps of joinProvisionedNode: zone label, role label check, taint
#   join <r>          etcd quota check, join strings, cleanup before the join, kubeadm join as a control plane node
#   ready <r>         wait for the Node of r
#   check [label]     the pass rules
#   traffic [label]   measurement: pod traffic between nodes
#   tunnels [label]   measurement: tunnel endpoints, tunnel ports and the source address at arrival
#   replace <r>       measurement: delete the pod of node r and follow the return
#   evidence [label]  save the state of each node and of the inner cluster
#   down, wipe        remove all, and remove the filesystem signatures from the six loop devices
#   full              one full run from empty volumes. KEEP=1 leaves the cluster up
set -euo pipefail

NS=${NS:-phase1-dry}
RUNTIME_CLASS=${RUNTIME_CLASS-kata-clh-runtime-rs-fix-direct}
SNAPSHOTTER=${SNAPSHOTTER-overlayfs}
KERNEL_CONFIG=${KERNEL_CONFIG-/scratch/kata-cp/logs/kata-guest-kernel-config-6.18.62-211.txt}
STOP_TIMEOUT=${STOP_TIMEOUT-}           # empty = the systemd default, as the gate 4 runs with this class
G1_SKIP=${G1_SKIP-init-cgroup}          # the patched Kata agent needs no "init" cgroup
GRACE=${GRACE:-20}
CPU=${CPU:-2}
MEMORY=${MEMORY:-6Gi}
IMAGE=${IMAGE:-nvke-node:bcc4376f-amd64}
K8S_VERSION=${K8S_VERSION:-v1.36.4}
KIND_NODE=${KIND_NODE:-kata-cp-control-plane}
ETP=${ETP:-Cluster}                     # externalTrafficPolicy of the Service of a node
ADDR_FORM=${ADDR_FORM:-bridge}          # where the node address is in the pod: bridge, eth0, none
REPAIR=${REPAIR:-off}
ETCD_PATCH=${ETCD_PATCH:-1}
P1_OVS_DATAPATH=${P1_OVS_DATAPATH-netdev}
P1_OVS_NO_MODPROBE=${P1_OVS_NO_MODPROBE:-1}
P1_TUN=${P1_TUN:-1}
POD_CIDR=${POD_CIDR:-10.113.0.0/16}
SERVICE_CIDR=${SERVICE_CIDR:-10.112.0.0/16}
API_SVC_IP=${API_SVC_IP:-10.112.0.1}
SYSTEM_RESERVED_MEMORY=${SYSTEM_RESERVED_MEMORY:-1Gi}
KUBE_RESERVED_MEMORY=${KUBE_RESERVED_MEMORY:-512Mi}
ETCD_QUOTA=17179869184                  # kubeadmconfig.EtcdQuotaBackendBytes
JOIN_STRING_TTL=300                     # joinStringCacheTTL of the controller, seconds
READY_TIMEOUT=${READY_TIMEOUT:-600}
TEST_IMAGE=${TEST_IMAGE:-localhost/nvke/ovnkube:8af51273d52d}
LOCAL_DNS_MANIFEST=${LOCAL_DNS_MANIFEST:-/scratch/kata-cp/src/nvke/controller/internal/temporal/activities/kube_local_dns.yaml}
CLIENT_BIN=${CLIENT_BIN:-/scratch/kata-cp/work/phase1-dry/bin/nvke-lab-client}
CLIENT_BIN_DIR=${CLIENT_BIN_DIR:-/var/lib/phase1-dry/bin}   # folder in the kind node, a hostPath of the client pod
LOOP_MAP=${LOOP_MAP:-/scratch/kata-cp/disks/loop-map.txt}
LOG_DIR=${LOG_DIR:-/scratch/kata-cp/logs/phase1-dry/$(date +%Y%m%d-%H%M%S)}

# The nodes: LoadBalancer address, inner node name, devices. The node name is not the hostname of
# the pod (cp-a-0), as with NVKE, where the node name is the name of the Cluster API machine.
REPLICAS=(a b c)
declare -A IPS=([a]=172.30.255.221 [b]=172.30.255.222 [c]=172.30.255.223)
declare -A NAMES=([a]=dry-cp-1 [b]=dry-cp-2 [c]=dry-cp-3)
declare -A VAR_LOOPS=([a]=/dev/loop20 [b]=/dev/loop21 [c]=/dev/loop30)
declare -A ETCD_LOOPS=([a]=/dev/loop24 [b]=/dev/loop25 [c]=/dev/loop28)
declare -A VAR_SIZES=([a]=30Gi [b]=30Gi [c]=20Gi)
ETCD_SIZE=10Gi
declare -A EXPECT=([/dev/loop20]=var-1.img [/dev/loop24]=etcd-1.img [/dev/loop21]=var-2.img
  [/dev/loop25]=etcd-2.img [/dev/loop30]=spare-1.img [/dev/loop28]=fio-1.img)
FIRST=a

HERE="$(cd "$(dirname "$0")" && pwd)"
KC=(kubectl --kubeconfig /etc/kubernetes/admin.conf)
ETCDCTL='crictl exec "$(crictl ps --name etcd -q | head -1)" etcdctl --endpoints https://127.0.0.1:2379 --cacert /etc/kubernetes/pki/etcd/ca.crt --cert /etc/kubernetes/pki/etcd/healthcheck-client.crt --key /etc/kubernetes/pki/etcd/healthcheck-client.key'
SEC="$LOG_DIR/secrets"                  # kubeadm files, join string and kubeconfig. Never in ~/notes
mkdir -p "$LOG_DIR" "$SEC"
chmod 700 "$SEC"

node() { docker exec "$KIND_NODE" "$@"; }             # a command in the kind node
nodei() { docker exec -i "$KIND_NODE" "$@"; }         # the same, with stdin
k() { node "${KC[@]}" "$@"; }                         # kubectl of the host cluster
say() { echo "== $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
stamp() { printf '%s %s\n' "$(date +%s.%N)" "$1" >>"$LOG_DIR/times.txt"; }
between() { awk -v a="$1" -v b="$2" '$2==a {x=$1} $2==b {y=$1} END {if (x && y) printf "%.1f\n", y-x; else print "-"}' "$LOG_DIR/times.txt"; }
pn() { echo "cp-$1-0"; }                              # the pod of node r
pod() { local r=$1; shift; k -n "$NS" exec "$(pn "$r")" -- "$@"; }                      # a command in the node pod of r
podi() { local r=$1; shift; nodei "${KC[@]}" -n "$NS" exec -i "$(pn "$r")" -- "$@"; }
ik() { local r=$1; shift; pod "$r" "${KC[@]}" "$@"; }                                   # inner kubectl in the node pod of r (for diagnosis)
cpod() { k -n "$NS" exec lab-client -- "$@"; }                                          # a command in the client pod
cpodi() { nodei "${KC[@]}" -n "$NS" exec -i lab-client -- "$@"; }
# kubectl of the inner cluster from the client pod, with the kubeconfig from GetKubeconfig. This is
# the path of the tenant client of the controller: through the LoadBalancer address of the first node.
ck() { cpod kubectl --kubeconfig /lab-work/kubeconfig "$@"; }
cki() { cpodi kubectl --kubeconfig /lab-work/kubeconfig "$@"; }
# The lab client against the agent of node r, through the LoadBalancer address, as the controller dials node.IP.
client() { local r=$1; shift; cpod /lab-bin/nvke-lab-client -addr "${IPS[$r]}:15005" -plaintext "$@"; }
etcdctl() { local r=$1; shift; pod "$r" sh -c "$ETCDCTL $*"; }
uuid() { cat /proc/sys/kernel/random/uuid; }

# Fill a template for node r: put in the pod spec, remove the lines of an option that is off, set the variables.
render() {
  local tmpl=$1 r=${2:-a} inc="" line drop=()
  [ -n "$RUNTIME_CLASS" ] || drop+=(-e '/#@runtimeclass$/d')
  [ -n "$KERNEL_CONFIG" ] || drop+=(-e '/#@kernelconfig$/d')
  [ "$tmpl" = node-sts.yaml.tmpl ] && inc=$(cat "$HERE/podspec.inc")
  export NS RUNTIME_CLASS SNAPSHOTTER STOP_TIMEOUT GRACE CPU MEMORY IMAGE KIND_NODE ETP ADDR_FORM REPAIR ETCD_SIZE G1_SKIP ETCD_PATCH
  export P1_OVS_DATAPATH P1_OVS_NO_MODPROBE P1_TUN CLIENT_BIN_DIR TEST_IMAGE
  export R="$r" NAME="cp-$r" NODE_IP="${IPS[$r]}" NODE_NAME="${NAMES[$r]}" VAR_LOOP="${VAR_LOOPS[$r]}" ETCD_LOOP="${ETCD_LOOPS[$r]}" VAR_SIZE="${VAR_SIZES[$r]}"
  while IFS= read -r line; do
    if [ "$line" = "#@podspec" ]; then printf '%s\n' "$inc"; else printf '%s\n' "$line"; fi
  done <"$HERE/$tmpl" | sed "${drop[@]}" -e 's/ *#@[a-z]*$//' |
    envsubst '$NS $NAME $RUNTIME_CLASS $SNAPSHOTTER $STOP_TIMEOUT $GRACE $CPU $MEMORY $IMAGE $KIND_NODE $ETP $ADDR_FORM $REPAIR $ETCD_SIZE $NODE_IP $NODE_NAME $VAR_LOOP $ETCD_LOOP $VAR_SIZE $G1_SKIP $ETCD_PATCH $P1_OVS_DATAPATH $P1_OVS_NO_MODPROBE $P1_TUN $CLIENT_BIN_DIR $TEST_IMAGE $R'
}

# wait_node <seconds> <shell test>: repeat the test in the kind node, one time each second.
# The loop is a transient systemd unit of the kind node, not a child of docker exec.
wait_node() {
  local t=$1
  shift
  node systemd-run --quiet --wait --collect --expand-environment=no --unit="p1dry-wait-$$-$RANDOM" \
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
  say "memory of the host"
  free -g
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
  say "client pod"
  node mkdir -p "$CLIENT_BIN_DIR"
  docker cp -q "$CLIENT_BIN" "$KIND_NODE:$CLIENT_BIN_DIR/nvke-lab-client"
  render client-pod.yaml.tmpl >"$LOG_DIR/client-pod.yaml"
  nodei "${KC[@]}" apply -f - <"$LOG_DIR/client-pod.yaml"
  k -n "$NS" wait --for=condition=Ready pod/lab-client --timeout=120s
}

cmd_node_up() {
  local r=$1
  say "node $r: volumes ${VAR_LOOPS[$r]} and ${ETCD_LOOPS[$r]}, node address ${IPS[$r]}, node name ${NAMES[$r]}, address form $ADDR_FORM"
  render volumes.yaml.tmpl "$r" | nodei "${KC[@]}" apply -f -
  render node-sts.yaml.tmpl "$r" >"$LOG_DIR/sts-cp-$r.yaml"
  stamp "$r-pod-create"
  nodei "${KC[@]}" apply -f - <"$LOG_DIR/sts-cp-$r.yaml"
  k -n "$NS" wait --for=create "pod/$(pn "$r")" --timeout=60s
  k -n "$NS" wait --for=jsonpath='{.status.phase}'=Running "pod/$(pn "$r")" --timeout=300s
  wait_node 300 "${KC[*]} -n $NS exec $(pn "$r") -- systemctl is-active containerd >/dev/null 2>&1" || die "containerd is not active in the pod of node $r"
  stamp "$r-node-up"
  say "node $r: pod $(pn "$r") has the IP $(pod_ip "$r"). Pod create to node up: $(between "$r-pod-create" "$r-node-up") s"
  k -n "$NS" logs "$(pn "$r")" 2>/dev/null | grep -a 'WRAP:' | tr -d '\r' | tee "$LOG_DIR/wrapper-log-$r.txt" || true
}

# The Open vSwitch and address state of node r, as text. Each command is allowed to fail.
ovs_state() {
  pod "$1" sh -c 'echo "--- hostname $(hostname), kernel $(uname -r)"
    echo "--- units"; systemctl is-system-running; systemctl --failed --no-legend --plain
    for u in ovsdb-server ovs-vswitchd openvswitch-switch nke-container-network nke-container-cni-images nvke-agent systemd-networkd kubelet; do
      printf "%-28s active=%-12s result=%s\n" "$u" "$(systemctl is-active "$u" 2>&1 | head -1)" "$(systemctl show -p Result --value "$u" 2>&1 | head -1)"
    done
    echo "--- addresses"; ip -br -4 addr 2>&1; echo "--- routes"; ip route 2>&1; echo "--- rules"; ip rule 2>&1
    echo "--- links"; ip -br link 2>&1
    echo "--- netplan"; cat /etc/netplan/*.yaml 2>&1; echo "--- networkctl"; networkctl list 2>&1 | head -12
    echo "--- ovs-vsctl show"; ovs-vsctl --timeout=5 show 2>&1
    echo "--- Open_vSwitch external_ids and other_config"; ovs-vsctl --timeout=5 get Open_vSwitch . external_ids other_config 2>&1
    echo "--- bridges"; ovs-vsctl --timeout=5 --columns=name,datapath_type list bridge 2>&1
    echo "--- interfaces"; ovs-vsctl --timeout=5 --columns=name,type,options,ofport,error list interface 2>&1
    echo "--- dpif/show"; ovs-appctl --timeout=5 dpif/show 2>&1
    echo "--- ovs/route/show"; ovs-appctl --timeout=5 ovs/route/show 2>&1
    echo "--- tnl/ports/show"; ovs-appctl --timeout=5 tnl/ports/show -v 2>&1
    echo "--- tnl/neigh/show"; ovs-appctl --timeout=5 tnl/neigh/show 2>&1' 2>&1 || true
}

cmd_units() {
  local r=$1 label=${2:-units}
  {
    say "node $r ($label)"
    ovs_state "$r"
    say "journal of the network unit and of the Open vSwitch units"
    pod "$r" sh -c 'for u in nke-container-network ovs-vswitchd; do echo "--- $u"; journalctl --no-pager -b -u "$u" 2>&1 | tail -12; done' || true
  } >"$LOG_DIR/units-$r-$label.txt" 2>&1
  grep -E 'active=|^running|^degraded|failed|g4-node|eth0 ' "$LOG_DIR/units-$r-$label.txt" | head -24 || true
}

# Host preparation of the ProvisionNode workflow (workflows/provision_node.go:216-247): the agent
# version, the preflight, then the Open vSwitch step. The controller repeats each one with no end.
cmd_prep() {
  local r=$1
  say "node $r: wait for the agent at ${IPS[$r]}:15005, agent version"
  client "$r" -steps status -wait-for-agent 600s 2>&1 | tee "$LOG_DIR/client-agent-$r.txt" || return 1
  stamp "$r-agent-ready"
  say "node $r: preflight and Open vSwitch step"
  client "$r" -steps preflight,ovs -ovs-operation-id "open-vswitch/lab-$(basename "$LOG_DIR")/$(uuid)/$(uuid)" 2>&1 | tee "$LOG_DIR/client-ovs-$r.txt" || {
    say "FAIL: the Open vSwitch step on node $r"
    return 1
  }
  stamp "$r-ovs-done"
  say "node $r: the agent answers $(between "$r-pod-create" "$r-agent-ready") s after the pod create. Preflight and Open vSwitch step: $(between "$r-agent-ready" "$r-ovs-done") s"
}

# copy_kubeadm_files <local folder> <folder in the client pod>: the rendered files go to the client pod.
copy_kubeadm_files() {
  tar -C "$1" -cf - . | cpodi sh -c "mkdir -p -m 700 $2 && tar -C $2 -xf -"
}
file_args() { # file_args <files.txt> <folder in the client pod>: the -file arguments of the client
  local path name mode _
  while read -r path name mode _; do
    printf '%s\n' "-file" "$path=$2/$name:$mode"
  done <"$1"
}

# kubeadm init on the first node (activities/kubeadm_init.go). The endpoint is the address of the
# first node, because the cluster has no VIP (kubeadm_init.go:80-83).
cmd_init() {
  local r=$FIRST ip=${IPS[$FIRST]} readyz_pid
  local -a files
  ( umask 077; mkdir -p "$SEC/kubeadm-$r" )
  K8S_VERSION=$K8S_VERSION POD_CIDR=$POD_CIDR SERVICE_CIDR=$SERVICE_CIDR SKIP_KUBE_PROXY=true CONTAINER_MODE=false \
    SYSTEM_RESERVED_MEMORY=$SYSTEM_RESERVED_MEMORY KUBE_RESERVED_MEMORY=$KUBE_RESERVED_MEMORY \
    "$HERE/render/render.sh" "$SEC/kubeadm-$r" "$ip" "$ip" "${NAMES[$r]}" || return 1
  sed -E 's/(token: )[a-z0-9]{6}\.[a-z0-9]{16}/\1REDACTED/' "$SEC/kubeadm-$r/kubeadm-init.yaml" >"$LOG_DIR/kubeadm-init.redacted.yaml"
  copy_kubeadm_files "$SEC/kubeadm-$r" "/lab-work/kubeadm-$r"
  mapfile -t files < <(file_args "$SEC/kubeadm-$r/files.txt" "/lab-work/kubeadm-$r")
  say "files of the request: $(awk '{print $1}' "$SEC/kubeadm-$r/files.txt" | tr '\n' ' ')"
  pod "$r" sh -c 'echo "patches folder before init:"; ls -l /etc/kubernetes/patches' || true
  ( k -n "$NS" wait --for=condition=Ready "pod/$(pn "$r")" --timeout=600s && stamp "$r-readyz-ok" ) >/dev/null 2>&1 &
  readyz_pid=$!
  stamp "$r-init-start"
  client "$r" -steps init,wait,kubeconfig -init-config "/lab-work/kubeadm-$r/kubeadm-init.yaml" "${files[@]}" \
    -endpoint "$ip" -pod-cidr "$POD_CIDR" -service-cidr "$SERVICE_CIDR" \
    -kubeconfig-out /lab-work/kubeconfig 2>&1 | tee "$LOG_DIR/client-init.txt" || { say "FAIL: kubeadm init"; return 1; }
  stamp "$r-init-done"
  wait "$readyz_pid" || { say "/readyz did not answer"; return 1; }
  ( umask 077; cpod cat /lab-work/kubeconfig >"$SEC/kubeconfig" )
  say "init: $(between "$r-init-start" "$r-init-done") s (10 s poll). Pod create to /readyz: $(between "$r-pod-create" "$r-readyz-ok") s"
  say "server of the kubeconfig from GetKubeconfig: $(grep -m1 'server:' "$SEC/kubeconfig" | tr -d ' ')"
  ck get nodes -o wide || { say "FAIL: the client pod cannot reach the API through the kubeconfig"; return 1; }
  patch_evidence "$r"
}

# What kubeadm did with the patches folder on node r: the etcd patch file of the lab next to the files of NVKE.
patch_evidence() {
  local r=$1
  {
    say "node $r: patches folder"
    pod "$r" sh -c 'ls -l /etc/kubernetes/patches'
    say "node $r: etcd command (the last three arguments come from etcd+json.json)"
    pod "$r" sh -c 'grep -E -- "--(listen-(client|peer|metrics)-urls|peer-skip-client-san-verification|quota-backend-bytes|initial-advertise-peer-urls|advertise-client-urls|name)=" /etc/kubernetes/manifests/etcd.yaml'
    say "node $r: the NVKE patches are in effect"
    pod "$r" sh -c 'grep -H terminationGracePeriodSeconds /etc/kubernetes/manifests/kube-apiserver.yaml; grep -A4 -E "^(systemReserved|kubeReserved):" /var/lib/kubelet/config.yaml; grep -H -E "node-ip|hostname-override" /var/lib/kubelet/kubeadm-flags.env'
    say "node $r: sockets of etcd and of the API server"
    pod "$r" sh -c 'ss -ltnH | awk "{print \$4}" | grep -E ":(2379|2380|2381|6443|10250|15005)\$" | sort | tr "\n" " "; echo'
  } 2>&1 | tee "$LOG_DIR/patch-evidence-$r.txt" || true
}

cmd_cni() {
  local r=$FIRST
  stamp cni-start
  client "$r" -steps cni -pod-cidr "$POD_CIDR" -service-cidr "$SERVICE_CIDR" 2>&1 | tee "$LOG_DIR/client-cni.txt" || { say "FAIL: InstallCNI"; return 1; }
  stamp cni-done
  say "InstallCNI: $(between cni-start cni-done) s"
}

# The activity InstallKubeLocalDNS (install_kube_local_dns.go:53-88) and the namespace labels
# (label_system_namespaces_for_psa.go), from the client pod with the tenant kubeconfig.
cmd_dns() {
  {
    cp "$LOCAL_DNS_MANIFEST" "$LOG_DIR/kube_local_dns.yaml"
    say "1. server-side apply of kube_local_dns.yaml"
    stamp dns-start
    cki apply --server-side --force-conflicts --field-manager=nvke-controller -f - <"$LOG_DIR/kube_local_dns.yaml"
    say "2. label dns-role=cluster-dns on the CoreDNS Deployment template and on the running CoreDNS pods"
    ck -n kube-system patch deployment coredns --type merge -p '{"spec":{"template":{"metadata":{"labels":{"dns-role":"cluster-dns"}}}}}'
    ck -n kube-system label pods -l k8s-app=kube-dns dns-role=cluster-dns --overwrite
    say "3. kube-dns Service: annotations and ports"
    ck -n kube-system annotate service kube-dns prometheus.io/port- prometheus.io/scrape- k8s.ovn.org/prefer-local-with-fallback=node-local-dns --overwrite
    ck -n kube-system get service kube-dns -o json | jq -c '[.spec.ports | to_entries[] | select(.value.name=="metrics") | {op:"remove", path:("/spec/ports/" + (.key|tostring))}] | reverse' >"$LOG_DIR/.dnsports.json"
    if [ "$(cat "$LOG_DIR/.dnsports.json")" != "[]" ]; then
      ck -n kube-system patch service kube-dns --type json -p "$(cat "$LOG_DIR/.dnsports.json")"
    fi
    say "4. the check of the controller: one Ready pod with dns-role=cluster-dns (it repeats the activity until then)"
    dns_role_ready() { ck -n kube-system get pods -l dns-role=cluster-dns -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | grep -q True; }
    # The first CoreDNS pods need the pod network. Wait for them, then read the label as the controller does.
    dns_role_ready || ck -n kube-system wait --for=condition=Ready pod -l k8s-app=kube-dns --timeout="${READY_TIMEOUT}s" || true
    if dns_role_ready; then
      stamp dns-role-pod-ready
      ck -n kube-system get pods -l dns-role=cluster-dns -o wide
      echo "RESULT dns-role: PASS ($(between dns-start dns-role-pod-ready) s after the apply)"
      ck -n kube-system patch service kube-dns --type merge -p '{"spec":{"selector":{"dns-role":"cluster-dns","k8s-app":null}}}'
    else
      echo "RESULT dns-role: FAIL (no Ready pod with dns-role=cluster-dns)"
      ck -n kube-system get pods -o wide
    fi
    say "5. namespace labels for Pod Security Admission"
    ck label namespace kube-system ovn-kubernetes pod-security.kubernetes.io/enforce=privileged --overwrite
  } 2>&1 | tee "$LOG_DIR/dns-step.txt"
  ! grep -q 'RESULT.*FAIL' "$LOG_DIR/dns-step.txt"
}

# The tenant CSR approver of the controller (controllers/tenant/csr/controller.go) approves a kubelet
# serving request when the requestor is system:node:<a node of the controller>. The lab approves the
# pending requests of its three node names.
cmd_csr() {
  local names r
  ck get csr -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.signerName}{" "}{.spec.username}{" ["}{.status.conditions[*].type}{"]\n"}{end}' >"$LOG_DIR/.csr.txt"
  names=""
  for r in "${REPLICAS[@]}"; do
    names="$names $(awk -v u="system:node:${NAMES[$r]}" '$2=="kubernetes.io/kubelet-serving" && $3==u && $4=="[]" {print $1}' "$LOG_DIR/.csr.txt" | tr '\n' ' ')"
  done
  if [ -z "${names// /}" ]; then
    say "no pending kubelet serving request of a known node"
  else
    # shellcheck disable=SC2086 # one word for each request name
    ck certificate approve $names
  fi
}

# The post-join steps of joinProvisionedNode (workflows/provision_node.go:299-348) for a control plane
# node: labelNode (the OVN zone label), verifyControlPlaneRoleLabel, and the removal of the provisioning taint.
cmd_postjoin() {
  local r=$1 n=${NAMES[$1]}
  {
    say "node $r ($n): label k8s.ovn.org/zone-name=$n"
    ck label node "$n" "k8s.ovn.org/zone-name=$n" --overwrite
    say "node $r ($n): control plane role label"
    if ck get node "$n" -o jsonpath='{.metadata.labels}' | grep -q '"node-role.kubernetes.io/control-plane"'; then
      echo "RESULT role-label-$r: PASS"
    else
      echo "RESULT role-label-$r: FAIL (the controller fails the workflow after 3 tries)"
    fi
    say "node $r ($n): taints (the provisioning taint is only on workers)"
    ck get node "$n" -o jsonpath='{.spec.taints}{"\n"}'
    ck taint node "$n" nvke.nvidia.com/provisioning=true:NoSchedule- 2>&1 || true
  } 2>&1 | tee "$LOG_DIR/postjoin-$r.txt"
  ! grep -q 'RESULT.*FAIL' "$LOG_DIR/postjoin-$r.txt"
}

# validateEtcdQuota (activities/kubeadm_join.go:233-277): each joined control plane node and the
# kubeadm-config ConfigMap have the etcd quota of the controller.
etcd_quota_check() {
  local r n q fail=0
  for r in "$@"; do
    n=${NAMES[$r]}
    q=$(ck -n kube-system get pod "etcd-$n" -o jsonpath='{.spec.containers[?(@.name=="etcd")].command}' | tr ',' '\n' | sed -n 's/.*--quota-backend-bytes=\([0-9]*\).*/\1/p' | head -1)
    echo "etcd quota of etcd-$n: ${q:-not found}"
    [ "$q" = "$ETCD_QUOTA" ] || fail=1
  done
  q=$(ck -n kube-system get configmap kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' | grep -A1 'name: quota-backend-bytes' | sed -n 's/.*value: "\([0-9]*\)".*/\1/p')
  echo "etcd quota in kubeadm-config: ${q:-not found}"
  [ "$q" = "$ETCD_QUOTA" ] || fail=1
  return "$fail"
}

# The join strings from a joined control plane node (kubeadm_join.go:322-354). The controller keeps
# them for 5 minutes for each cluster. The file in the client pod is the cache of the lab.
join_strings() {
  local age=999999
  if [ -s "$SEC/join-string-time" ]; then age=$(( $(date +%s) - $(cat "$SEC/join-string-time") )); fi
  if [ "$age" -lt "$JOIN_STRING_TTL" ]; then
    say "join string: from the cache ($age s old, the controller keeps it for $JOIN_STRING_TTL s)"
    return 0
  fi
  say "join string: UpdateAndFetchKubeAdmJoinStrings on node $FIRST"
  client "$FIRST" -steps joinstrings -join-string-out /lab-work/join-string 2>&1 || return 1
  ( umask 077; cpod cat /lab-work/join-string >"$SEC/join-string"; date +%s >"$SEC/join-string-time" )
  pod "$FIRST" sh -c 'ls -l /tmp/kubeadm-init-config.yaml' || true
}

# The join of a control plane node: KubeadmJoin after cleanBeforeControlPlaneRejoin (workflows/provision_node.go:270-283).
cmd_join() {
  local r=$1 n=${NAMES[$1]} ip=${IPS[$1]} x joined=()
  local -a files
  for x in "${REPLICAS[@]}"; do [ -e "$LOG_DIR/.joined-$x" ] && joined+=("$x"); done
  say "node $r ($n): etcd quota check on the joined nodes: ${joined[*]}"
  etcd_quota_check "${joined[@]}" || { say "FAIL: etcd quota check (the controller stops the join here)"; return 1; }
  join_strings || { say "FAIL: join strings"; return 1; }
  say "node $r ($n): cleanup before the join (best effort in the controller): RemoveEtcdMember on node $FIRST, kubeadm reset on node $r"
  client "$FIRST" -steps etcdremove -etcd-target "$n" 2>&1 | tee "$LOG_DIR/client-etcdremove-$r.txt" || say "RemoveEtcdMember failed (the controller continues)"
  stamp "$r-reset-start"
  client "$r" -steps reset 2>&1 | tee "$LOG_DIR/client-reset-$r.txt" || say "kubeadm reset failed (the controller continues)"
  stamp "$r-reset-done"
  pod "$r" sh -c 'echo "after the reset:"; ls -l /etc/kubernetes/patches; ovs-vsctl --timeout=5 list-br; systemctl is-active ovs-vswitchd kubelet containerd | tr "\n" " "; echo' 2>&1 | tee "$LOG_DIR/after-reset-$r.txt" || true
  ( umask 077; mkdir -p "$SEC/kubeadm-$r" )
  MODE=join JOIN_STRING_FILE="$SEC/join-string" K8S_VERSION=$K8S_VERSION CONTAINER_MODE=false \
    SYSTEM_RESERVED_MEMORY=$SYSTEM_RESERVED_MEMORY KUBE_RESERVED_MEMORY=$KUBE_RESERVED_MEMORY \
    "$HERE/render/render.sh" "$SEC/kubeadm-$r" "$ip" unused "$n" || return 1
  sed -E 's/((token|certificateKey|tlsBootstrapToken): ).*/\1REDACTED/' "$SEC/kubeadm-$r/kubeadm-join.yaml" >"$LOG_DIR/kubeadm-join-$r.redacted.yaml"
  copy_kubeadm_files "$SEC/kubeadm-$r" "/lab-work/kubeadm-$r"
  mapfile -t files < <(file_args "$SEC/kubeadm-$r/files.txt" "/lab-work/kubeadm-$r")
  stamp "$r-join-start"
  client "$r" -steps join,waitjoin -join-config "/lab-work/kubeadm-$r/kubeadm-join.yaml" -join-string /lab-work/join-string "${files[@]}" 2>&1 |
    tee "$LOG_DIR/client-join-$r.txt" || {
    say "FAIL: kubeadm join on node $r"
    pod "$r" sh -c 'jq -r ".kubeadmErrorMessage" /var/lib/nvke/state.json | tail -40' 2>&1 | sed -E 's/[a-z0-9]{6}\.[a-z0-9]{16}/<token>/g; s/[0-9a-f]{64}/<hex64>/g' | tee "$LOG_DIR/join-error-$r.txt" || true
    return 1
  }
  stamp "$r-join-done"
  touch "$LOG_DIR/.joined-$r"
  say "node $r: reset $(between "$r-reset-start" "$r-reset-done") s, join $(between "$r-join-start" "$r-join-done") s (10 s poll)"
  patch_evidence "$r"
}

cmd_ready() {
  local r=$1 n=${NAMES[$1]}
  if ck wait --for=condition=Ready "node/$n" --timeout="${READY_TIMEOUT}s"; then
    stamp "$r-node-ready"
    say "node $r ($n) Ready: $(between "$r-pod-create" "$r-node-ready") s after the pod create"
  else
    say "FAIL: node $r ($n) is not Ready"
    ck get nodes -o wide || true
    ck get pods -A -o wide || true
    return 1
  fi
}

# The pass rules: three Ready control plane nodes, three started etcd members with the LoadBalancer
# addresses as peer URLs, and one Ready pod with dns-role=cluster-dns.
cmd_check() {
  local label=${1:-check} out fail=0 r
  out="$LOG_DIR/check-$label.txt"
  {
    say "check $label at $(date -u +%FT%TZ)"
    k -n "$NS" get pods -o wide
    say "1. nodes of the inner cluster (from the client pod, through ${IPS[$FIRST]}:6443)"
    ck get nodes -o wide | tee "$LOG_DIR/.nodes" || true
    for r in "${REPLICAS[@]}"; do
      grep -q -E "^${NAMES[$r]} +Ready +control-plane .* ${IPS[$r]} " "$LOG_DIR/.nodes" || { echo "FAIL node ${NAMES[$r]} is not a Ready control plane node with the address ${IPS[$r]}"; fail=1; }
    done
    say "2. etcd members (etcdctl in the etcd container of node $FIRST)"
    etcdctl "$FIRST" member list -w simple | tee "$LOG_DIR/.members" || true
    [ "$(grep -c ', started, ' "$LOG_DIR/.members")" = 3 ] || { echo "FAIL not three started members"; fail=1; }
    for r in "${REPLICAS[@]}"; do
      grep -q -E ", started, ${NAMES[$r]}, https://${IPS[$r]}:2380, https://${IPS[$r]}:2379, false" "$LOG_DIR/.members" || { echo "FAIL member ${NAMES[$r]} has not the peer URL https://${IPS[$r]}:2380"; fail=1; }
    done
    etcdctl "$FIRST" endpoint health --cluster 2>&1 | tee "$LOG_DIR/.health" || true
    [ "$(grep -c 'is healthy' "$LOG_DIR/.health")" = 3 ] || { echo "FAIL not three healthy etcd endpoints"; fail=1; }
    etcdctl "$FIRST" endpoint status --cluster -w table 2>&1 || true
    say "3. a Ready pod with dns-role=cluster-dns"
    ck -n kube-system get pods -l dns-role=cluster-dns -o wide | tee "$LOG_DIR/.dnsrole" || true
    grep -q -E ' 1/1 +Running ' "$LOG_DIR/.dnsrole" || { echo "FAIL no Ready pod with dns-role=cluster-dns"; fail=1; }
    say "4. /readyz of each node through its LoadBalancer address, from the kind node"
    for r in "${REPLICAS[@]}"; do
      echo "${IPS[$r]}: $(node curl -sk --max-time 5 -w ' (http %{http_code})' "https://${IPS[$r]}:6443/readyz" || true)"
    done | tee "$LOG_DIR/.readyz"
    [ "$(grep -c '^.*: ok (http 200)' "$LOG_DIR/.readyz")" = 3 ] || { echo "FAIL readyz"; fail=1; }
    say "5. pods of the inner cluster"
    ck get pods -A -o wide || true
    say "6. etcd peer check: lines \"rejected connection on peer endpoint\" in the etcd log of each node"
    for r in "${REPLICAS[@]}"; do
      echo "node $r: $(pod "$r" sh -c 'crictl logs "$(crictl ps --name etcd -q | head -1)" 2>&1 | grep -c "rejected connection on peer endpoint"' 2>/dev/null || true)"
    done
    say "7. memory and restarts of the node pods"
    for r in "${REPLICAS[@]}"; do pod_memory "$r" || true; done
    [ "$fail" = 0 ] && echo "RESULT $label: PASS" || echo "RESULT $label: FAIL"
  } 2>&1 | tee "$out"
  grep -q "RESULT $label: PASS" "$out"
}

cmd_evidence() {
  local label=${1:-final} d r c
  d="$LOG_DIR/evidence-$label"
  mkdir -p "$d"
  for r in "${REPLICAS[@]}"; do
    ovs_state "$r" >"$d/ovs-state-$r.txt" 2>&1
    pod "$r" sh -c 'cat /var/log/openvswitch/ovs-vswitchd.log' >"$d/ovs-vswitchd-$r.log" 2>&1 || true
    pod "$r" journalctl --no-pager -b -u nvke-agent >"$d/journal-nvke-agent-$r.txt" 2>&1 || true
    pod "$r" journalctl --no-pager -b -u kubelet >"$d/journal-kubelet-$r.txt" 2>&1 || true
    pod "$r" journalctl --no-pager -b -u ovs-vswitchd -u ovsdb-server -u openvswitch-switch -u nke-container-network -u nke-container-cni-images >"$d/journal-ovs-units-$r.txt" 2>&1 || true
    pod "$r" dmesg >"$d/dmesg-$r.txt" 2>&1 || true
    pod "$r" nft list ruleset >"$d/nft-ruleset-$r.txt" 2>&1 || true
    pod "$r" sh -c 'ip -d addr; echo; ip route show table all; echo; ip rule; echo; ip neigh' >"$d/ip-$r.txt" 2>&1 || true
    for c in ovnkube-controller ovn-controller ovn-northd nb-ovsdb sb-ovsdb etcd kube-apiserver; do
      pod "$r" sh -c "crictl logs \"\$(crictl ps -a --name '^$c\$' -q | head -1)\" 2>&1 | tail -3000" >"$d/log-$c-$r.txt" 2>&1 || true
    done
    pod "$r" sh -c 'jq -c "{name, role, phase, status, currentMessage, kubeadmStatus, cniPlugin, cniPluginStatus, completedPhases}" /var/lib/nvke/state.json' >"$d/agent-state-$r.json" 2>&1 || true
    k -n "$NS" get pod "$(pn "$r")" -o yaml >"$d/outer-pod-$r.yaml" 2>&1 || true
    k -n "$NS" describe pod "$(pn "$r")" >"$d/outer-pod-describe-$r.txt" 2>&1 || true
  done
  ck get nodes -o wide >"$d/inner-nodes.txt" 2>&1 || true
  ck get nodes -o json | jq '[.items[] | {name: .metadata.name, labels: .metadata.labels, annotations: .metadata.annotations, addresses: .status.addresses, taints: .spec.taints, allocatable: .status.allocatable}]' >"$d/inner-nodes.json" 2>&1 || true
  ck get pods -A -o wide >"$d/inner-pods.txt" 2>&1 || true
  ck get events -A --sort-by=.lastTimestamp >"$d/inner-events.txt" 2>&1 || true
  ck get csr >"$d/inner-csr.txt" 2>&1 || true
  ck -n ovn-kubernetes logs deployment/ovnkube-control-plane --all-containers --tail=-1 >"$d/log-ovnkube-control-plane.txt" 2>&1 || true
  k -n "$NS" get all,pvc,endpointslices -o wide >"$d/outer-objects.txt" 2>&1 || true
  say "evidence is in $d"
}

cmd_down() {
  local r
  for r in "${REPLICAS[@]}"; do k -n "$NS" delete statefulset "cp-$r" --ignore-not-found --wait=true; done
  k -n "$NS" delete pod --all --ignore-not-found --wait=true
  k delete namespace "$NS" --ignore-not-found --wait=true
  for r in "${REPLICAS[@]}"; do k delete pv "$NS-cp-$r-var" "$NS-cp-$r-etcd" --ignore-not-found --wait=true; done
  node sh -c "test ! -d $CLIENT_BIN_DIR || find $(dirname "$CLIENT_BIN_DIR") -depth -delete"
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
    for r in "${REPLICAS[@]}"; do
      echo "node $r: pod create to node up $(between "$r-pod-create" "$r-node-up"), to agent $(between "$r-pod-create" "$r-agent-ready"), preflight and Open vSwitch step $(between "$r-agent-ready" "$r-ovs-done")"
    done
    echo "node a: init $(between a-init-start a-init-done), pod create to /readyz $(between a-pod-create a-readyz-ok), InstallCNI $(between cni-start cni-done), InstallCNI to Node Ready $(between cni-done a-node-ready), DNS apply to dns-role pod Ready $(between dns-start dns-role-pod-ready)"
    for r in b c; do
      echo "node $r: reset $(between "$r-reset-start" "$r-reset-done"), join $(between "$r-join-start" "$r-join-done"), join done to Node Ready $(between "$r-join-done" "$r-node-ready")"
    done
    echo "whole flow: first pod create to the last Node Ready $(between a-pod-create c-node-ready)"
  } | tee "$LOG_DIR/summary-times.txt"
}

# The whole flow in the order of the controller. Each step must pass.
flow() {
  local r
  # The cluster request: the three hosts exist, the controller prepares a host and then the first one runs init.
  cmd_prep "$FIRST" || return 1
  cmd_init || return 1
  cmd_cni || return 1
  touch "$LOG_DIR/.joined-$FIRST" # markInitialNodeAsJoined
  cmd_dns || return 1
  cmd_csr || return 1
  cmd_ready "$FIRST" || return 1
  # The cluster is "provisioned" now. The control plane controller starts JoinNode for one node at a time.
  cmd_postjoin "$FIRST" || return 1
  for r in b c; do
    cmd_prep "$r" || return 1
    cmd_join "$r" || return 1
    cmd_csr || return 1
    cmd_postjoin "$r" || return 1
    cmd_ready "$r" || return 1
    cmd_csr || return 1
  done
  cmd_check final || return 1
}

cmd_full() {
  local rc=0 r
  cmd_wipe
  cmd_base
  for r in "${REPLICAS[@]}"; do cmd_node_up "$r"; done
  for r in "${REPLICAS[@]}"; do cmd_units "$r" after-boot || true; done
  flow || rc=1
  times || true
  cmd_evidence final || true
  if [ "$rc" = 0 ]; then echo "RESULT full: PASS"; else echo "RESULT full: FAIL"; fi
  if [ "${KEEP:-0}" = 1 ]; then
    say "KEEP=1: the cluster stays up"
  else
    cmd_down
    cmd_wipe
  fi
  return "$rc"
}

step=${1:-}
shift || true
case "$step" in
  base | node-up | units | prep | init | cni | dns | csr | postjoin | join | ready | check | evidence | down | wipe | full)
    "cmd_${step//-/_}" "$@" 2>&1 | tee -a "$LOG_DIR/run.log"
    exit "${PIPESTATUS[0]}"
    ;;
  traffic | tunnels | replace)
    # The measurements are in measure.sh, which uses the functions of this file.
    # shellcheck source=/dev/null
    . "$HERE/measure.sh"
    "cmd_$step" "$@" 2>&1 | tee -a "$LOG_DIR/run.log"
    exit "${PIPESTATUS[0]}"
    ;;
  times) times ;;
  render) render "$@" ;;
  *) sed -n '2,33p' "$0"; exit 1 ;;
esac
