#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Gate 1 step 4 and gate 3 (join token): run the NVKE node image as one pod, start kubeadm init
# through nvke-agent from a client pod, and check the SPIFFE identity of the agent.
# The base is lab/gate1/run.sh. Each kubectl, crictl and curl call runs inside the kind node
# (docker exec), so the host opens no TCP connection. Each wait loop runs in the kind node and
# sleeps one second between tries.
#
# Usage: run.sh <step>
#   identities         make the join tokens, the registration entries and the two Secrets (a new node UUID for each LOG_DIR)
#   up                 make the volumes, the client pod, the Service and the node pod
#   units              record the systemd units, the network and the mounts of the node
#   preflight          run "kubeadm.real init phase preflight" by hand with the NVKE configuration and no ignore flag
#   init               render the NVKE kubeadm configuration and start kubeadm init through nvke-agent with the client
#   check [label]      test the pass rules of gate 1
#   spire [label]      record the SPIRE identity of the node and make one authenticated call (MODE=mtls)
#   negative           the negative tests (MODE=mtls)
#   newfiles           list the files that the node wrote outside the volumes
#   restart [how]      restart the container. how = crictl (default) or poweroff
#   recreate           delete the node pod and make a new pod with the same volumes
#   logs               save the pod spec and the logs
#   down               delete the pods, the Service, the claims, the volumes and the namespace
#   wipe               remove the filesystem signatures from the two loop devices (after "down")
#   full               one full run from empty volumes
#
# Variables. Example for Kata with Cloud Hypervisor and the Rust runtime:
#   MODE=mtls RUNTIME_CLASS=kata-clh-runtime-rs LIB_MODULES=0 VAR_LOOP=/dev/loop21 ETCD_LOOP=/dev/loop25 \
#   KERNEL_CONFIG=/scratch/kata-cp/logs/kata-guest-kernel-config-6.18.62-211.txt LOG_DIR=... run.sh full
set -euo pipefail

NS=${NS:-gate1-nvke}                    # namespace of the node pod and the client pod
NAME=${NAME:-nvke-cp}                   # pod, Service and inner node name
MODE=${MODE:-mtls}                      # mtls = SPIFFE mTLS with a join token. plaintext = nvke-agent with --disable-mtls
RUNTIME_CLASS=${RUNTIME_CLASS:-}        # empty = default runtime (runc). Example: kata-clh-runtime-rs
LIB_MODULES=${LIB_MODULES:-1}           # 1 = mount /lib/modules of the kind node read-only, as nico-sim does. 0 for Kata
SNAPSHOTTER=${SNAPSHOTTER:-overlayfs}   # KIND_EXPERIMENTAL_CONTAINERD_SNAPSHOTTER
VAR_LOOP=${VAR_LOOP:-/dev/loop20}       # var-1 in /scratch/kata-cp/disks/loop-map.txt (runc). Kata: var-2, /dev/loop21
ETCD_LOOP=${ETCD_LOOP:-/dev/loop24}     # etcd-1 (runc). Kata: etcd-2, /dev/loop25
VAR_SIZE=${VAR_SIZE:-30Gi}
ETCD_SIZE=${ETCD_SIZE:-10Gi}
CPU=${CPU:-4}
MEMORY=${MEMORY:-8Gi}
IMAGE=${IMAGE:-nvke-node:bcc4376f-amd64}
K8S_VERSION=${K8S_VERSION:-v1.36.4}
KIND_NODE=${KIND_NODE:-kata-cp-control-plane}
GRACE=${GRACE:-20}                      # terminationGracePeriodSeconds of the pod, and the timeout of crictl stop
STOP_TIMEOUT=${STOP_TIMEOUT:-10}        # seconds for DefaultTimeoutStopSec of systemd in the node (the Kata runs of gate 1 use 10)
KERNEL_CONFIG=${KERNEL_CONFIG:-}        # kernel config file on this machine for the manual preflight. Empty = none
G1_SKIP=${G1_SKIP:-}                    # test switch of the gate 1 wrapper
SKIP_UNITS=${SKIP_UNITS:-}              # test switch: image units to leave out (cni-images)
POD_CIDR=${POD_CIDR:-10.113.0.0/16}     # not the ranges of the host cluster
SERVICE_CIDR=${SERVICE_CIDR:-10.112.0.0/16}
# Kubelet reservations for the patch file. The NVKE defaults are 16Gi and 2Gi, which is more than the pod has.
SYSTEM_RESERVED_MEMORY=${SYSTEM_RESERVED_MEMORY:-1Gi}
KUBE_RESERVED_MEMORY=${KUBE_RESERVED_MEMORY:-512Mi}
TRUST_DOMAIN=${TRUST_DOMAIN:-lab.nvke.test}
SPIRE_NS=${SPIRE_NS:-gate1-nvke-spire}
SPIRE_SERVER_ADDRESS=${SPIRE_SERVER_ADDRESS:-spire-server.$SPIRE_NS.svc.cluster.local}
SPIRE_SERVER_PORT=${SPIRE_SERVER_PORT:-8081}
JOIN_TOKEN_TTL=${JOIN_TOKEN_TTL:-3600}  # seconds. The NVKE default is 1 hour
CLIENT_BIN=${CLIENT_BIN:-/scratch/kata-cp/bin/nvke-lab-client}
CLIENT_BIN_DIR=${CLIENT_BIN_DIR:-/var/lib/gate1-nvke/bin}   # folder in the kind node, a hostPath of the client pod
LOOP_MAP=${LOOP_MAP:-/scratch/kata-cp/disks/loop-map.txt}
LOG_DIR=${LOG_DIR:-/scratch/kata-cp/logs/gate1-nvke/$(date +%Y%m%d-%H%M%S)}

HERE="$(cd "$(dirname "$0")" && pwd)"
KC=(kubectl --kubeconfig /etc/kubernetes/admin.conf)
ETCDCTL='crictl exec "$(crictl ps --name etcd -q)" etcdctl --endpoints https://127.0.0.1:2379 --cacert /etc/kubernetes/pki/etcd/ca.crt --cert /etc/kubernetes/pki/etcd/healthcheck-client.crt --key /etc/kubernetes/pki/etcd/healthcheck-client.key'
AGENT_ADDR="$NAME.$NS.svc.cluster.local:15005"
SEC="$LOG_DIR/secrets"                  # tokens, agent.conf files and the kubeconfig. Never in ~/notes
mkdir -p "$LOG_DIR" "$SEC"
chmod 700 "$SEC"
if [ "$MODE" = plaintext ]; then AGENT_PLAINTEXT=1; else AGENT_PLAINTEXT=0; fi

node() { docker exec "$KIND_NODE" "$@"; }             # a command in the kind node
nodei() { docker exec -i "$KIND_NODE" "$@"; }         # the same, with stdin
k() { node "${KC[@]}" "$@"; }                         # kubectl of the host cluster
pod() { k -n "$NS" exec "$NAME" -- "$@"; }            # a command in the node pod
cpod() { k -n "$NS" exec lab-client -- "$@"; }        # a command in the client pod
ik() { pod "${KC[@]}" "$@"; }                         # kubectl of the inner cluster, in the node pod
spire() { k -n "$SPIRE_NS" exec spire-server-0 -- /opt/spire/bin/spire-server "$@"; }
say() { echo "== $*"; }
stamp() { printf '%s %s\n' "$(date +%s.%N)" "$1" >>"$LOG_DIR/times.txt"; }
between() { awk -v a="$1" -v b="$2" '$2==a {x=$1} $2==b {y=$1} END {printf "%.1f\n", y-x}' "$LOG_DIR/times.txt"; }
# A join token is part of the SPIFFE ID of a SPIRE agent. Remove it from output that a person reads.
mask() { sed -E 's#(join_token/)[0-9a-f-]+#\1TOKEN#g; s#(join_token = ")[^"]*#\1TOKEN#g'; }
node_uuid() { cat "$LOG_DIR/node-uuid.txt"; }
agent_id() { echo "spiffe://$TRUST_DOMAIN/host/$(node_uuid)"; }

# Fill a template: remove the lines of an option that is off, then set the variables.
render() {
  local drop=()
  [ -n "$RUNTIME_CLASS" ] || drop+=(-e '/#@runtimeclass$/d')
  [ "$LIB_MODULES" = 1 ] || drop+=(-e '/#@modules$/d')
  [ -n "$KERNEL_CONFIG" ] || drop+=(-e '/#@kernelconfig$/d')
  [ "$MODE" = mtls ] || drop+=(-e '/#@mtls$/d')
  export NS NAME RUNTIME_CLASS SNAPSHOTTER VAR_LOOP ETCD_LOOP VAR_SIZE ETCD_SIZE CPU MEMORY IMAGE KIND_NODE GRACE G1_SKIP STOP_TIMEOUT
  export AGENT_PLAINTEXT SKIP_UNITS CLIENT_BIN_DIR TRUST_DOMAIN SPIRE_SERVER_ADDRESS SPIRE_SERVER_PORT JOIN_TOKEN=${JOIN_TOKEN:-}
  sed "${drop[@]}" -e 's/ *#@[a-z]*$//' "$HERE/$1" |
    envsubst '$NS $NAME $RUNTIME_CLASS $SNAPSHOTTER $VAR_LOOP $ETCD_LOOP $VAR_SIZE $ETCD_SIZE $CPU $MEMORY $IMAGE $KIND_NODE $GRACE $G1_SKIP $STOP_TIMEOUT $AGENT_PLAINTEXT $SKIP_UNITS $CLIENT_BIN_DIR $TRUST_DOMAIN $SPIRE_SERVER_ADDRESS $SPIRE_SERVER_PORT $JOIN_TOKEN'
}

# wait_node <seconds> <shell test>: repeat the test in the kind node, one time each second.
wait_node() {
  local t=$1
  shift
  node bash -c "for i in \$(seq 1 $t); do if $*; then exit 0; fi; sleep 1; done; exit 1"
}
svc_ip() { k -n "$NS" get svc "$NAME" -o jsonpath='{.spec.clusterIP}'; }
pod_ip() { k -n "$NS" get pod "$NAME" -o jsonpath='{.status.podIP}'; }
wait_readyz() { wait_node "${1:-300}" "[ \"\$(curl -sk --max-time 2 https://$(svc_ip):6443/readyz)\" = ok ]"; }
# The agent port through the Service. In mTLS mode the port opens only when the agent has its SVID.
wait_agent_port() { wait_node "${1:-300}" "timeout 2 bash -c '</dev/tcp/$(svc_ip)/15005' 2>/dev/null"; }
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
  [ "$VAR_LOOP" != "$ETCD_LOOP" ] || { echo "the two devices are the same"; exit 1; }
}
container_id() {
  node crictl ps -q --label io.kubernetes.pod.namespace="$NS" --label io.kubernetes.pod.name="$NAME" --label io.kubernetes.container.name=node
}
sandbox_id() { node crictl pods -q --namespace "$NS" --name "$NAME" --state ready; }
sandbox_procs() {
  node sh -c "ps -eo pid=,rss=,args= | grep -E 'cloud-hypervisor|qemu-system|virtiofsd|containerd-shim-kata' | grep '$(sandbox_id)' | awk '{n=split(\$3,a,\"/\"); print \$1, \$2, a[n]}'" || true
}
apply_pod() {
  render node-pod.yaml.tmpl >"$LOG_DIR/node-pod.yaml"
  nodei "${KC[@]}" apply -f - <"$LOG_DIR/node-pod.yaml"
}
ensure_ns() { k create namespace "$NS" --dry-run=client -o yaml | nodei "${KC[@]}" apply -f - >/dev/null; }

# The arguments of the client for the transport: plaintext, or SPIFFE mTLS with the expected agent ID.
# In plaintext mode the node has no SPIRE configuration, so GetSpireAgentStatus is not in the list.
client_auth() {
  if [ "$MODE" = plaintext ]; then
    echo "-plaintext -steps status,preflight,init,wait,kubeconfig"
  else
    echo "-expect-id $(agent_id)"
  fi
}

# make_identity <name> <path of the alternate agent ID> <Secret>: one join token, and the Secret with
# agent.conf and the trust bundle. NVKE makes the token with the same alternate ID form
# (controller/internal/spiffe/join_token.go) and puts the two files in the bootstrap Secret.
make_identity() {
  local name=$1 alt=$2 secret=$3
  ( umask 077
    spire token generate -spiffeID "spiffe://$TRUST_DOMAIN/$alt" -ttl "$JOIN_TOKEN_TTL" >"$SEC/$name-token.txt"
    JOIN_TOKEN=$(awk '/^Token:/ {print $2}' "$SEC/$name-token.txt") render spire-agent.conf.tmpl >"$SEC/$name-agent.conf"
    {
      printf 'apiVersion: v1\nkind: Secret\nmetadata: {name: %s, namespace: %s}\ntype: Opaque\ndata:\n' "$secret" "$NS"
      printf '  agent.conf: %s\n' "$(base64 -w0 "$SEC/$name-agent.conf")"
      printf '  initial-trust-bundle.pem: %s\n' "$(base64 -w0 "$SEC/initial-trust-bundle.pem")"
    } >"$SEC/$name-secret.yaml" )
  [ -n "$(awk '/^Token:/ {print $2}' "$SEC/$name-token.txt")" ] || { echo "no join token for $name"; exit 1; }
  k -n "$NS" delete secret "$secret" --ignore-not-found >/dev/null
  nodei "${KC[@]}" create -f - <"$SEC/$name-secret.yaml"
  say "join token for $name: alternate ID spiffe://$TRUST_DOMAIN/$alt, TTL $JOIN_TOKEN_TTL s, Secret $secret"
}

cmd_identities() {
  ensure_ns
  [ -s "$LOG_DIR/node-uuid.txt" ] || cat /proc/sys/kernel/random/uuid >"$LOG_DIR/node-uuid.txt"
  local uuid td="spiffe://$TRUST_DOMAIN"
  uuid=$(node_uuid)
  say "node UUID $uuid (the lab chooses it. In NVKE it is the ID of the node row)"
  spire bundle show -format pem >"$SEC/initial-trust-bundle.pem"
  if [ "$MODE" = mtls ]; then
    make_identity node "join-token-spire-agent/host-id/$uuid" "$NAME-spire"
    # The ID that the controller expects from the agent: spiffe://<td>/host/<node UUID>, for root processes of the node.
    spire entry create -parentID "$td/join-token-spire-agent/host-id/$uuid" -spiffeID "$td/host/$uuid" -selector unix:uid:0
  fi
  # The client has its own SPIRE agent. Root in the client pod gets an ID that nvke-agent accepts.
  make_identity client "join-token-spire-agent/lab-client/$uuid" lab-client-spire
  spire entry create -parentID "$td/join-token-spire-agent/lab-client/$uuid" -spiffeID "$td/nvke-service/lab-client" -selector unix:uid:0
  # User 1001 in the client pod gets an ID outside the prefixes of nvke-agent, for the negative test.
  spire entry create -parentID "$td/join-token-spire-agent/lab-client/$uuid" -spiffeID "$td/other-service/lab-client" -selector unix:uid:1001
}

cmd_up() {
  check_devices
  say "memory of the host"
  free -g
  say "namespace, volumes, wrapper script and client pod"
  ensure_ns
  render volumes.yaml.tmpl | nodei "${KC[@]}" apply -f -
  nodei "${KC[@]}" -n "$NS" create configmap "$NAME-wrapper" --from-file=wrapper.sh=/dev/stdin --dry-run=client -o yaml <"$HERE/wrapper.sh" |
    nodei "${KC[@]}" apply -f -
  nodei "${KC[@]}" -n "$NS" create configmap lab-client-entry --from-file=client-entry.sh=/dev/stdin --dry-run=client -o yaml <"$HERE/client-entry.sh" |
    nodei "${KC[@]}" apply -f -
  if [ -n "$KERNEL_CONFIG" ]; then
    # No "apply" here: the config of the host kernel is larger than the limit of the apply annotation (262144 bytes).
    k -n "$NS" delete configmap "$NAME-kernel-config" --ignore-not-found >/dev/null
    nodei "${KC[@]}" -n "$NS" create configmap "$NAME-kernel-config" --from-file=config=/dev/stdin <"$KERNEL_CONFIG"
  fi
  node mkdir -p "$CLIENT_BIN_DIR"
  docker cp -q "$CLIENT_BIN" "$KIND_NODE:$CLIENT_BIN_DIR/nvke-lab-client"
  render client-pod.yaml.tmpl >"$LOG_DIR/client-pod.yaml"
  nodei "${KC[@]}" apply -f - <"$LOG_DIR/client-pod.yaml"
  wait_node 120 "[ \"\$(${KC[*]} -n $NS get pod lab-client -o jsonpath='{.status.phase}')\" = Running ]"

  say "Service and node pod"
  stamp pod-create
  apply_pod
  wait_node 300 "${KC[*]} -n $NS exec $NAME -- systemctl is-active containerd >/dev/null 2>&1"
  stamp node-up
  say "pod IP $(pod_ip), Service IP $(svc_ip). systemd and containerd run in the pod after $(between pod-create node-up) s."
}

cmd_units() {
  local label=${1:-units}
  {
    say "systemd state ($label)"
    pod sh -c 'systemctl is-system-running; echo "failed units:"; systemctl --failed --no-legend --plain; echo "---"
      for u in nvke-agent spire-agent containerd kubelet etcd-data-dir nke-container-cni-images ovsdb-server ovs-vswitchd nke-container-network systemd-networkd systemd-udevd dbus swtpm-local nke-attestation; do
        printf "%-28s enabled=%-10s active=%-12s result=%s\n" "$u" "$(systemctl is-enabled "$u" 2>&1 | head -1)" "$(systemctl is-active "$u" 2>&1 | head -1)" "$(systemctl show -p Result --value "$u" 2>&1 | head -1)"
      done' || true
    say "network of the node"
    pod sh -c 'ip -4 addr show; ip route; echo "--- netplan:"; cat /etc/netplan/*.yaml 2>/dev/null; echo "--- networkctl:"; networkctl list 2>&1 | head; echo "--- resolv.conf:"; cat /etc/resolv.conf' || true
    say "mounts and snapshotter"
    pod sh -c 'for m in / /var /var/lib/etcd /etc/kubernetes /kind /run /tmp; do findmnt -n -o TARGET,SOURCE,FSTYPE "$m"; done; grep -E "snapshotter = " /etc/containerd/config.toml; grep -H . /etc/default/nvke-agent /etc/default/kubelet; cloud-init status' || true
    say "journal of the units that are not active"
    pod sh -c 'for u in ovs-vswitchd nke-container-network nke-container-cni-images spire-agent; do echo "--- $u"; journalctl --no-pager -b -u "$u" 2>&1 | tail -8; done' | mask || true
  } 2>&1 | tee "$LOG_DIR/units-$label.txt"
  # The journal is in /run, so a new container starts with an empty journal. Save it for each label.
  pod journalctl --no-pager -b -u nvke-agent >"$LOG_DIR/journal-nvke-agent-$label.txt" 2>&1 || true
}

# Render the configuration and the four files with the renderer of the NVKE controller, for this pod IP.
render_kubeadm() {
  local ip
  ip=$(pod_ip)
  ( umask 077; mkdir -p "$SEC/kubeadm" )
  K8S_VERSION=$K8S_VERSION POD_CIDR=$POD_CIDR SERVICE_CIDR=$SERVICE_CIDR SKIP_KUBE_PROXY=true CONTAINER_MODE=false \
    SYSTEM_RESERVED_MEMORY=$SYSTEM_RESERVED_MEMORY KUBE_RESERVED_MEMORY=$KUBE_RESERVED_MEMORY \
    "$HERE/render/render.sh" "$SEC/kubeadm" "$ip" "$ip" "$NAME"
  # A copy with no bootstrap token, for the notes and the report.
  sed -E 's/(token: )[a-z0-9]{6}\.[a-z0-9]{16}/\1REDACTED/' "$SEC/kubeadm/kubeadm-init.yaml" >"$LOG_DIR/kubeadm-init.redacted.yaml"
}

# The gate 1 method asks for the preflight check with no ignore of SystemVerification. The kubeadm
# shim of the image always adds the ignore flag, so call the real binary. This step is evidence only.
cmd_preflight() {
  [ -f "$SEC/kubeadm/kubeadm-init.yaml" ] || render_kubeadm
  nodei "${KC[@]}" -n "$NS" exec -i "$NAME" -- sh -c 'umask 077; cat >/run/g1n-preflight.yaml' <"$SEC/kubeadm/kubeadm-init.yaml"
  local rc=0
  pod /usr/bin/kubeadm.real init phase preflight --config /run/g1n-preflight.yaml >"$LOG_DIR/preflight.txt" 2>&1 || rc=$?
  echo "exit code: $rc" >>"$LOG_DIR/preflight.txt"
  pod rm -f /run/g1n-preflight.yaml
  say "manual preflight with kubeadm.real and no ignore flag:"
  grep -E 'WARNING|ERROR|exit code' "$LOG_DIR/preflight.txt" || true
}

cmd_init() {
  local files=() path name mode ip
  ip=$(pod_ip)
  [ -f "$SEC/kubeadm/kubeadm-init.yaml" ] || render_kubeadm
  stamp render-done
  tar -C "$SEC/kubeadm" -cf - . | nodei "${KC[@]}" -n "$NS" exec -i lab-client -- sh -c 'rm -rf /lab-work/kubeadm && mkdir -m 700 /lab-work/kubeadm && tar -C /lab-work/kubeadm -xf -'
  while read -r path name mode _; do
    files+=(-file "$path=/lab-work/kubeadm/$name:$mode")
  done <"$SEC/kubeadm/files.txt"

  say "wait for the agent port through the Service ($AGENT_ADDR)"
  wait_agent_port 600 || { say "the agent port did not open"; return 1; }
  stamp agent-port-open
  say "agent port open $(between pod-create agent-port-open) s after the pod create. Start the client (MODE=$MODE)."
  # The client polls each 10 seconds, as the controller does. Watch /readyz at the same time, each second.
  local readyz_pid
  ( wait_readyz 600 && stamp readyz-ok ) &
  readyz_pid=$!
  stamp init-start
  # shellcheck disable=SC2046 # client_auth gives more than one word
  cpod /lab-bin/nvke-lab-client -addr "$AGENT_ADDR" $(client_auth) \
    -init-config /lab-work/kubeadm/kubeadm-init.yaml "${files[@]}" \
    -endpoint "$ip" -pod-cidr "$POD_CIDR" -service-cidr "$SERVICE_CIDR" \
    -kubeconfig-out /lab-work/kubeconfig 2>&1 | tee "$LOG_DIR/client-init.txt"
  stamp init-done
  wait "$readyz_pid" || { say "/readyz did not answer"; return 1; }
  ( umask 077; cpod cat /lab-work/kubeconfig >"$SEC/kubeconfig" )
  ik -n default create configmap g1-marker --from-literal=made="$(date -u +%FT%TZ)" >/dev/null
  ik -n default get configmap g1-marker -o jsonpath='{.metadata.uid}' >"$LOG_DIR/marker-uid.txt"
  say "pod create to agent port: $(between pod-create agent-port-open) s. Client start to init ready: $(between init-start init-done) s. Pod create to /readyz ok: $(between pod-create readyz-ok) s."
}

# Test the pass rules of gate 1. The first check of a run saves the identity of the node.
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
    say "nodes, with the kubeconfig from GetKubeconfig, from the client pod"
    cpod sh -c 'test -s /lab-work/kubeconfig && kubectl --kubeconfig /lab-work/kubeconfig get nodes' 2>&1 || true

    say "4. identity of the node (compare with the first check of this run)"
    {
      pod sh -c 'cd /etc/kubernetes/pki && sha256sum ca.crt sa.pub front-proxy-ca.crt etcd/ca.crt etcd/server.crt etcd/peer.crt apiserver-kubelet-client.crt apiserver.crt'
      pod sh -c "$ETCDCTL member list -w simple" | awk -F', ' '{print "etcd-member-id " $1}'
      echo "marker-configmap-uid $(ik -n default get configmap g1-marker -o jsonpath='{.metadata.uid}')"
      echo "machine-id $(pod cat /etc/machine-id)"
      echo "node-uid $(ik get node "$NAME" -o jsonpath='{.metadata.uid}')"
      echo "pod-ip $(pod_ip)"
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

    say "5. state of nvke-agent, kernel, VM and memory"
    pod sh -c 'jq -c "{Role, Phase, Status, CurrentMessage, ListenStatus}" /var/lib/nvke/state.json 2>/dev/null || head -c 400 /var/lib/nvke/state.json' || true
    echo "boot-id $(pod cat /proc/sys/kernel/random/boot_id) kernel $(pod uname -r) container-id $(container_id)"
    local cg
    cg=$(pod_cgroup)
    node sh -c "echo memory.current \$(cat $cg/memory.current); echo memory.peak \$(cat $cg/memory.peak); echo memory.events \$(tr '\n' ' ' <$cg/memory.events)"
    sandbox_procs
    pod free -m
    say "container restarts: $(restarts)"
    [ "$fail" = 0 ] && echo "RESULT $label: PASS" || echo "RESULT $label: FAIL"
  } 2>&1 | tee "$out"
  k -n "$NS" logs "$NAME" 2>&1 | head -c 300000 >"$LOG_DIR/pod-log-$label.txt"
  grep -q "RESULT $label: PASS" "$out"
}

# The identity of the node from three sides: the files of the SPIRE agent, the SVID that a root
# process of the node gets, and one authenticated call of the client that checks the agent ID.
cmd_spire() {
  local label=${1:-spire} out fail=0
  out="$LOG_DIR/spire-$label.txt"
  {
    say "SPIRE identity ($label) at $(date -u +%FT%TZ). Expected agent ID $(agent_id)"
    pod sh -c 'echo "spire-agent: $(systemctl is-active spire-agent), since $(systemctl show -p ActiveEnterTimestamp --value spire-agent), restarts $(systemctl show -p NRestarts --value spire-agent)"
      echo "nvke-agent: $(systemctl is-active nvke-agent), since $(systemctl show -p ActiveEnterTimestamp --value nvke-agent)"
      ls -la --time-style=full-iso /var/lib/spire-agent; sha256sum /var/lib/spire-agent/keys.json' || true
    say "SVID of a root process in the node (spire-agent api fetch x509)"
    pod /usr/local/bin/spire-agent api fetch x509 -socketPath /tmp/spire-agent/public/api.sock 2>&1 | grep -E 'SPIFFE ID|SVID Valid|CA #1 Valid|Received' || true
    say "the SPIRE agent of the node, as the server knows it (the join token is part of its ID and is masked)"
    spire agent show -spiffeID "spiffe://$TRUST_DOMAIN/spire/agent/join_token/$(awk '/^Token:/ {print $2}' "$SEC/node-token.txt")" 2>&1 | mask || true
    echo "agents on the server: $(spire agent count 2>&1 | tr -d '\n')"
    say "agent port through the Service, and one authenticated call from the client pod"
    if wait_agent_port 180; then echo "agent port: open"; else echo "FAIL agent port closed"; fail=1; fi
    cpod /lab-bin/nvke-lab-client -addr "$AGENT_ADDR" -expect-id "$(agent_id)" -steps status,spire 2>&1 | tee "$LOG_DIR/.spirecall" || true
    grep -q "peer_id=$(agent_id)" "$LOG_DIR/.spirecall" || { echo "FAIL authenticated call"; fail=1; }
    say "join token use in the journal of spire-agent (count of attestation lines since the first start)"
    pod sh -c 'journalctl --no-pager -u spire-agent 2>/dev/null | grep -c -i "node attestation was successful" || true'
    [ "$fail" = 0 ] && echo "RESULT spire-$label: PASS" || echo "RESULT spire-$label: FAIL"
  } 2>&1 | tee "$out"
  grep -q "RESULT spire-$label: PASS" "$out"
}

# Each negative test must fail. The script reports PASS when the call fails.
cmd_negative() {
  local out="$LOG_DIR/negative.txt" rc
  {
    say "negative 1: the client expects a wrong agent ID (same trust domain, other node UUID)"
    rc=0
    cpod /lab-bin/nvke-lab-client -addr "$AGENT_ADDR" -expect-id "spiffe://$TRUST_DOMAIN/host/00000000-0000-0000-0000-000000000000" -steps status 2>&1 || rc=$?
    [ "$rc" != 0 ] && echo "RESULT negative-1: PASS (the call failed, exit $rc)" || echo "RESULT negative-1: FAIL (the call passed)"

    say "negative 2: a client ID outside the prefixes of the agent (user 1001 gets spiffe://$TRUST_DOMAIN/other-service/lab-client)"
    rc=0
    cpod setpriv --reuid=1001 --regid=1001 --clear-groups /lab-bin/nvke-lab-client -addr "$AGENT_ADDR" -expect-id "$(agent_id)" -steps status 2>&1 || rc=$?
    [ "$rc" != 0 ] && echo "RESULT negative-2: PASS (the call failed, exit $rc)" || echo "RESULT negative-2: FAIL (the call passed)"

    say "negative 3: a plaintext client against the mTLS port"
    rc=0
    cpod /lab-bin/nvke-lab-client -addr "$AGENT_ADDR" -plaintext -steps status -wait 20s 2>&1 || rc=$?
    [ "$rc" != 0 ] && echo "RESULT negative-3: PASS (the call failed, exit $rc)" || echo "RESULT negative-3: FAIL (the call passed)"

    say "control: the correct client and the correct expected ID pass"
    cpod /lab-bin/nvke-lab-client -addr "$AGENT_ADDR" -expect-id "$(agent_id)" -steps status 2>&1 || echo "RESULT control: FAIL"
    say "journal of nvke-agent for the refused calls"
    pod sh -c 'journalctl --no-pager -u nvke-agent --since "-2min" 2>/dev/null | grep -i -E "unauthorized|handshake|bad certificate" | cut -c1-300 | tail -10; echo "lines about a refused call: $(journalctl --no-pager -u nvke-agent --since "-2min" 2>/dev/null | grep -c -i -E "unauthorized|handshake|bad certificate")"' || true
  } 2>&1 | tee "$out"
  ! grep -q 'RESULT.*FAIL' "$out"
}

cmd_newfiles() {
  pod sh -c 'find / -xdev -cnewer /.g1n-start \( -type f -o -type l \) 2>/dev/null | grep -v -E "^/(proc|sys|dev)/" | sort' >"$LOG_DIR/newfiles-root.txt" || true
  say "files that the node wrote on the root filesystem after start (outside the volumes): $(wc -l <"$LOG_DIR/newfiles-root.txt")"
  sed -E 's#/[^/]+$##' "$LOG_DIR/newfiles-root.txt" | sort | uniq -c | sort -rn | head -40
}

cmd_restart() {
  local how=${1:-crictl} before cid
  before=$(restarts)
  say "restart of the container with $how (restart count now: $before)"
  stamp "restart-$how-start"
  case "$how" in
    crictl)
      cid=$(container_id)
      node crictl stop --timeout "$GRACE" "$cid" || echo "crictl stop gave an error. The container did not stop inside $GRACE s."
      ;;
    poweroff) pod systemctl poweroff || true ;;
    *) echo "unknown restart method $how"; exit 1 ;;
  esac
  wait_node 300 "[ \"\$(${KC[*]} -n $NS get pod $NAME -o jsonpath='{.status.containerStatuses[0].restartCount}')\" -gt $before ]"
  stamp "restart-$how-new-container"
  say "the old container ended with: $(k -n "$NS" get pod "$NAME" -o jsonpath='{.status.containerStatuses[0].lastState.terminated}')"
  if wait_readyz 300; then stamp "restart-$how-readyz-ok"; else stamp "restart-$how-readyz-ok"; say "/readyz did not return in 300 s"; fi
  say "$how: stop to new container $(between "restart-$how-start" "restart-$how-new-container") s, stop to /readyz ok $(between "restart-$how-start" "restart-$how-readyz-ok") s"
}

# Delete the node pod and make a new pod with the same volumes and the same Secret. The new pod has a new IP.
cmd_recreate() {
  say "delete the node pod (old pod IP $(pod_ip))"
  stamp recreate-start
  k -n "$NS" delete pod "$NAME" --wait=true
  stamp recreate-old-pod-gone
  stamp recreate-pod-create
  apply_pod
  wait_node 300 "[ \"\$(${KC[*]} -n $NS get pod $NAME -o jsonpath='{.status.phase}')\" = Running ]"
  wait_node 300 "${KC[*]} -n $NS exec $NAME -- systemctl is-active containerd >/dev/null 2>&1"
  stamp recreate-node-up
  say "new pod IP $(pod_ip). Delete took $(between recreate-start recreate-old-pod-gone) s. Node up $(between recreate-pod-create recreate-node-up) s after the pod create."
  # The advertise address of this lab is the pod IP, which is new. Gate 4 gives the node a fixed address.
  if wait_readyz "${1:-90}"; then
    stamp recreate-readyz-ok
    say "new pod: /readyz ok $(between recreate-pod-create recreate-readyz-ok) s after the pod create"
  else
    say "new pod: /readyz did not return in ${1:-90} s (the node address changed)"
  fi
}

cmd_logs() {
  k -n "$NS" get pod "$NAME" -o yaml >"$LOG_DIR/pod.yaml" 2>&1 || true
  k -n "$NS" describe pod "$NAME" >"$LOG_DIR/pod-describe.txt" 2>&1 || true
  k -n "$NS" logs "$NAME" >"$LOG_DIR/pod-log-last.txt" 2>&1 || true
  # The journal of spire-agent has the join token in the agent ID, so the journals stay with the secrets.
  pod journalctl --no-pager -b >"$SEC/journal.txt" 2>&1 || true
  pod journalctl --no-pager -b -u nvke-agent >"$LOG_DIR/journal-nvke-agent.txt" 2>&1 || true
  pod journalctl --no-pager -b -u spire-agent 2>&1 | mask >"$LOG_DIR/journal-spire-agent.masked.txt" || true
  pod sh -c 'dmesg | tail -200' >"$LOG_DIR/dmesg-tail.txt" 2>&1 || true
  # The audit log of nvke-agent is on the /var volume, so it has each call since the first start.
  pod cat /var/log/nvke-agent-audit.log >"$LOG_DIR/nvke-agent-audit.log" 2>&1 || true
  k -n "$NS" logs lab-client 2>&1 | mask >"$LOG_DIR/client-spire-agent.masked.txt" || true
  k -n "$SPIRE_NS" logs spire-server-0 --since=30m 2>&1 | mask >"$LOG_DIR/spire-server.masked.txt" || true
  {
    say "kind node"
    k version | grep -v '^Client'
    node containerd --version
    node uname -r
    say "node pod"
    pod sh -c '/usr/bin/kubeadm.real version -o short; kubelet --version; containerd --version; runc --version | head -1; systemctl --version | head -1; uname -r; /usr/local/bin/nvke-agent --version; /usr/local/bin/spire-agent --version 2>&1; grep MemTotal /proc/meminfo; nproc'
    say "SPIRE server"
    spire --version 2>&1
    say "runtime class of the pod: ${RUNTIME_CLASS:-default (runc)}"
    if [ -n "$RUNTIME_CLASS" ]; then
      node sh -c '/opt/kata/bin/kata-runtime --version | head -2; /opt/kata/runtime-rs/bin/containerd-shim-kata-v2 --version | head -1; /opt/kata/bin/cloud-hypervisor --version'
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
  for pair in pod-create:node-up pod-create:agent-port-open init-start:init-done pod-create:readyz-ok \
    restart-crictl-start:restart-crictl-readyz-ok recreate-pod-create:recreate-node-up; do
    if grep -q " ${pair##*:}\$" "$LOG_DIR/times.txt"; then echo "${pair%%:*} to ${pair##*:}: $(between "${pair%%:*}" "${pair##*:}")"; fi
  done | tee "$LOG_DIR/summary-times.txt"
}

# One full run from empty volumes. PREFLIGHT=1 adds the manual preflight (it adds time before init).
cmd_full() {
  cmd_wipe
  cmd_identities
  cmd_up
  [ "${PREFLIGHT:-0}" = 1 ] && cmd_preflight
  cmd_init
  cmd_units after-init
  cmd_check 1-after-init
  if [ "$MODE" = mtls ]; then
    cmd_spire 1-after-init
    cmd_negative
  fi
  cmd_newfiles
  cmd_restart crictl
  cmd_check 2-after-crictl-stop
  [ "$MODE" = mtls ] && cmd_spire 2-after-crictl-stop
  cmd_recreate
  [ "$MODE" = mtls ] && cmd_spire 3-after-new-pod
  cmd_units after-new-pod
  cmd_logs
  cmd_down
  times
}

step=${1:-}
shift || true
case "$step" in
  identities | up | units | preflight | init | check | spire | negative | newfiles | restart | recreate | logs | down | wipe | full)
    "cmd_$step" "$@" 2>&1 | tee -a "$LOG_DIR/run.log"
    exit "${PIPESTATUS[0]}"
    ;;
  times) times ;;
  render) render "$@" ;;
  *) sed -n '2,26p' "$0"; exit 1 ;;
esac
