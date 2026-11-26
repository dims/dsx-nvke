#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Gate 2, part 2: the node load and the patch load for one control plane, and the sample loop.
#
# The load runs in pods of the host cluster (runc), in the namespace gate2-load:
#   - KWOK controllers hold the fake nodes of the inner cluster (leases and node status).
#   - The patcher sends merge patches to ConfigMaps of the inner cluster.
# Their connections go from a pod to the Service of the control plane. The host opens no TCP
# connection: each kubectl call runs in the kind node (docker exec), and the sample loop too.
#
# Usage: TARGET=<kata|runc|g4> load.sh <step>
#   creds               copy the admin kubeconfig of the inner cluster to a Secret of the host cluster
#   kwok-up             start the KWOK controllers (one for each API server of the target)
#   patcher-up          start the patcher (RATE patches each second)
#   nodes <from> <to>   make the fake nodes kwok-node-<from> to kwok-node-<to> in the inner cluster
#   sampler-start, sampler-stop   the sample loop in the kind node (one sample each INTERVAL seconds)
#   mark <label>        write a time mark, with the load and the memory of the machine
#   status              the state of the load pods and the node count of the inner cluster
#   cleanup             delete the load pods, the fake nodes and the ConfigMaps of the inner cluster
#   run                 the full test: idle, 355 nodes, 756 nodes. Then cleanup
set -euo pipefail

TARGET=${TARGET:?set TARGET to kata, runc or g4}
KIND_NODE=${KIND_NODE:-kata-cp-control-plane}
LOAD_NS=${LOAD_NS:-gate2-load} # in the host cluster, and for the ConfigMaps in the inner cluster
RATE=${RATE:-23}
OBJECTS=${OBJECTS:-200}
PAYLOAD=${PAYLOAD:-2048}
INTERVAL=${INTERVAL:-30}
LEVELS=${LEVELS:-"355 756"}
IDLE=${IDLE:-180}     # seconds of the idle window before the load
SETTLE=${SETTLE:-120} # seconds between the last new node and the start of a window
WINDOW=${WINDOW:-635} # seconds of a window. It must hold 21 samples (600 s)
SECRET_DIR=${SECRET_DIR:-/scratch/kata-cp/gate2-secrets/$TARGET}
LOG_DIR=${LOG_DIR:-/scratch/kata-cp/logs/gate2/etcd-$TARGET}
KWOK_IMAGE=${KWOK_IMAGE:-registry.k8s.io/kwok/kwok:v0.7.0}
TOOLS_IMAGE=${TOOLS_IMAGE:-gate2-tools:1}
HERE="$(cd "$(dirname "$0")" && pwd)"
KC=(kubectl --kubeconfig /etc/kubernetes/admin.conf)

# The control plane pods of the target, the URL that a load pod uses for each API server,
# and the URL that kubectl in the pod uses for its own API server.
case "$TARGET" in
  kata | runc)
    CP_NS=gate2-$TARGET
    PODS=(cp)
    SERVERS=("https://cp.$CP_NS.svc:6443")
    LOCAL=("https://cp:6443")
    ;;
  g4)
    CP_NS=gate4
    PODS=(cp-a-0 cp-b-0 cp-c-0)
    SERVERS=(https://172.30.255.211:6443 https://172.30.255.212:6443 https://172.30.255.213:6443)
    LOCAL=("${SERVERS[@]}")
    ;;
  *) echo "unknown target $TARGET"; exit 1 ;;
esac
GROUPS_N=${#PODS[@]}
mkdir -p "$LOG_DIR"

node() { docker exec "$KIND_NODE" "$@"; }
nodei() { docker exec -i "$KIND_NODE" "$@"; }
k() { node "${KC[@]}" "$@"; }
ki() { nodei "${KC[@]}" "$@"; }
# kubectl of the inner cluster, in the first control plane pod.
ik() { k -n "$CP_NS" exec "${PODS[0]}" -- "${KC[@]}" "$@"; }
iki() { ki -n "$CP_NS" exec -i "${PODS[0]}" -- "${KC[@]}" "$@"; }
say() { echo "== $(date +%T) $*"; }

cmd_mark() {
  printf '%s %s\n' "$(date +%s.%N)" "$1" >>"$LOG_DIR/marks.txt"
  {
    echo "== mark $1 at $(date -u +%FT%TZ)"
    uptime
    free -m | sed -n '1,2p'
  } >>"$LOG_DIR/host.txt"
}

cmd_creds() {
  local i
  mkdir -p "$SECRET_DIR"
  chmod 700 "$SECRET_DIR"
  (
    umask 077
    k -n "$CP_NS" exec "${PODS[0]}" -- cat /etc/kubernetes/admin.conf >"$SECRET_DIR/admin.conf"
    yq -r '.clusters[0].cluster."certificate-authority-data"' "$SECRET_DIR/admin.conf" | base64 -d >"$SECRET_DIR/ca.crt"
    yq -r '.users[0].user."client-certificate-data"' "$SECRET_DIR/admin.conf" | base64 -d >"$SECRET_DIR/tls.crt"
    yq -r '.users[0].user."client-key-data"' "$SECRET_DIR/admin.conf" | base64 -d >"$SECRET_DIR/tls.key"
    for i in "${!SERVERS[@]}"; do
      sed "s#^\( *server: \).*#\1${SERVERS[$i]}#" "$SECRET_DIR/admin.conf" >"$SECRET_DIR/kubeconfig-$i"
    done
  )
  k create namespace "$LOAD_NS" --dry-run=client -o yaml | ki apply -f - >/dev/null
  # The Secret goes to kubectl on stdin. It is not in a log.
  {
    printf 'apiVersion: v1\nkind: Secret\nmetadata: {name: %s-creds, namespace: %s}\ndata:\n' "$TARGET" "$LOAD_NS"
    for f in ca.crt tls.crt tls.key $(cd "$SECRET_DIR" && ls kubeconfig-*); do
      printf '  %s: %s\n' "$f" "$(base64 -w0 "$SECRET_DIR/$f")"
    done
  } | ki apply -f - >/dev/null
  say "Secret $TARGET-creds is in $LOAD_NS. Files: $(ls "$SECRET_DIR" | tr '\n' ' ')"
}

cmd_kwok_up() {
  local i
  for i in "${!SERVERS[@]}"; do
    ki apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: kwok-$TARGET-$i, namespace: $LOAD_NS, labels: {gate2-target: $TARGET}}
spec:
  replicas: 1
  selector: {matchLabels: {app: kwok-$TARGET-$i}}
  template:
    metadata: {labels: {app: kwok-$TARGET-$i, gate2-target: $TARGET}}
    spec:
      automountServiceAccountToken: false
      enableServiceLinks: false
      terminationGracePeriodSeconds: 5
      containers:
        - name: kwok
          image: $KWOK_IMAGE
          imagePullPolicy: Never
          args:
            - --kubeconfig=/creds/kubeconfig-$i
            - --manage-all-nodes=false
            - --manage-nodes-with-label-selector=gate2-kwok=g$i
            - --node-lease-duration-seconds=40
            - --node-ip=\$(POD_IP)
            - --node-port=10247
            - --cidr=10.200.0.1/16
          env:
            - {name: POD_IP, valueFrom: {fieldRef: {fieldPath: status.podIP}}}
          resources:
            limits: {cpu: "2", memory: 1Gi}
          volumeMounts:
            - {name: creds, mountPath: /creds, readOnly: true}
      volumes:
        - name: creds
          secret: {secretName: $TARGET-creds}
EOF
  done
  k -n "$LOAD_NS" rollout status deployment -l gate2-target="$TARGET" --timeout=120s
}

cmd_patcher_up() {
  local servers
  servers=$(IFS=,; echo "${SERVERS[*]}")
  ki apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: patcher-$TARGET, namespace: $LOAD_NS, labels: {gate2-target: $TARGET}}
spec:
  replicas: 1
  selector: {matchLabels: {app: patcher-$TARGET}}
  template:
    metadata: {labels: {app: patcher-$TARGET, gate2-target: $TARGET}}
    spec:
      automountServiceAccountToken: false
      enableServiceLinks: false
      terminationGracePeriodSeconds: 5
      containers:
        - name: patcher
          image: $TOOLS_IMAGE
          imagePullPolicy: Never
          command: [patcher, "-servers=$servers", "-rate=$RATE", "-objects=$OBJECTS", "-payload=$PAYLOAD", "-namespace=$LOAD_NS"]
          resources:
            limits: {cpu: "1", memory: 256Mi}
          volumeMounts:
            - {name: creds, mountPath: /creds, readOnly: true}
      volumes:
        - name: creds
          secret: {secretName: $TARGET-creds}
EOF
  k -n "$LOAD_NS" rollout status deployment "patcher-$TARGET" --timeout=120s
}

# The fake nodes, as in the KWOK documents. The taint keeps the pods of the inner cluster off them.
cmd_nodes() {
  local from=$1 to=$2 i
  for i in $(seq "$from" "$to"); do
    cat <<EOF
---
apiVersion: v1
kind: Node
metadata:
  name: kwok-node-$i
  annotations: {node.alpha.kubernetes.io/ttl: "0", kwok.x-k8s.io/node: fake}
  labels:
    kubernetes.io/arch: arm64
    kubernetes.io/hostname: kwok-node-$i
    kubernetes.io/os: linux
    node-role.kubernetes.io/dpu: ""
    type: kwok
    gate2-kwok: g$((i % GROUPS_N))
spec:
  taints:
    - {effect: NoSchedule, key: kwok.x-k8s.io/node, value: fake}
status:
  allocatable: {cpu: "16", memory: 32Gi, pods: "110"}
  capacity: {cpu: "16", memory: 32Gi, pods: "110"}
  nodeInfo:
    architecture: arm64
    kubeletVersion: fake
    kubeProxyVersion: fake
    operatingSystem: linux
    osImage: fake
    kernelVersion: fake
    containerRuntimeVersion: fake
    bootID: ""
    machineID: ""
    systemUUID: ""
  phase: Running
EOF
  done | iki create -f - | tail -1
}

cmd_sampler_start() {
  local pairs=() i
  for i in "${!PODS[@]}"; do pairs+=("${PODS[$i]}=${LOCAL[$i]}"); done
  node mkdir -p /tmp/gate2
  nodei sh -c 'cat >/tmp/gate2/sampler.sh' <"$HERE/sampler.sh"
  nodei sh -c 'cat >/tmp/gate2/sample-once.sh' <"$HERE/sample-once.sh"
  node rm -rf "/tmp/gate2/out-$TARGET"
  docker exec -d "$KIND_NODE" bash /tmp/gate2/sampler.sh "/tmp/gate2/out-$TARGET" "$CP_NS" "$INTERVAL" "${pairs[@]}"
  say "sample loop started for ${pairs[*]}"
}

cmd_sampler_stop() {
  node touch "/tmp/gate2/out-$TARGET/stop"
  node bash -c "for i in \$(seq 1 90); do grep -q '^stopped' /tmp/gate2/out-$TARGET/pods.txt && exit 0; sleep 1; done; exit 1" || echo "the sample loop did not stop"
  # /tmp of the kind node is a memory filesystem, and "docker cp" does not read it. Use tar.
  rm -rf "$LOG_DIR/samples" "$LOG_DIR/out-$TARGET"
  node tar -C /tmp/gate2 -cf - "out-$TARGET" | tar -C "$LOG_DIR" -xf -
  mv "$LOG_DIR/out-$TARGET" "$LOG_DIR/samples"
  node rm -rf "/tmp/gate2/out-$TARGET"
  say "samples are in $LOG_DIR/samples: $(ls "$LOG_DIR/samples" | wc -l) files"
}

cmd_status() {
  k -n "$LOAD_NS" get pods -l gate2-target="$TARGET" -o wide
  echo "inner cluster nodes: $(ik get nodes --no-headers | awk '{n[$2]++} END {for (s in n) printf "%s=%d ", s, n[s]}')"
  echo "inner cluster leases in kube-node-lease: $(ik -n kube-node-lease get leases --no-headers | wc -l)"
  k -n "$LOAD_NS" logs "deployment/patcher-$TARGET" --tail=3 2>/dev/null || true
}

cmd_cleanup() {
  say "save the logs of the load pods"
  local p
  for p in $(k -n "$LOAD_NS" get pods -l gate2-target="$TARGET" -o name 2>/dev/null); do
    k -n "$LOAD_NS" logs "$p" >"$LOG_DIR/$(basename "$p").log" 2>&1 || true
  done
  k -n "$LOAD_NS" get pods -l gate2-target="$TARGET" -o wide >"$LOG_DIR/load-pods.txt" 2>&1 || true
  say "delete the load pods and the Secret"
  k -n "$LOAD_NS" delete deployment -l gate2-target="$TARGET" --wait=true
  k -n "$LOAD_NS" delete secret "$TARGET-creds" --ignore-not-found
  k -n "$LOAD_NS" wait --for=delete pod -l gate2-target="$TARGET" --timeout=60s || true
  # A single node pod of gate 2 goes away after its test, so its inner cluster needs no cleanup.
  if [ "${INNER_CLEANUP:-1}" != 1 ]; then
    say "no cleanup of the inner cluster (INNER_CLEANUP=$INNER_CLEANUP)"
    return 0
  fi
  say "delete the fake nodes and the ConfigMaps of the inner cluster"
  ik delete nodes -l type=kwok --wait=true | tail -1
  ik delete namespace "$LOAD_NS" --ignore-not-found --wait=true
  # A lease of a fake node has the node as its owner. Delete each lease that stays.
  sleep 10
  ik -n kube-node-lease get leases -o name | grep 'kwok-node-' | xargs -r docker exec "$KIND_NODE" "${KC[@]}" -n "$CP_NS" exec "${PODS[0]}" -- "${KC[@]}" -n kube-node-lease delete || true
  # The events of the fake nodes stay for one hour (the event TTL of the API server). Delete them.
  # kubectl sends about 5 requests each second, so 2,000 events need some minutes.
  ik -n default get events -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.involvedObject.name}{"\n"}{end}' | awk '$2 ~ /^kwok-node-/ {print $1}' |
    ki -n "$CP_NS" exec -i "${PODS[0]}" -- sh -c "xargs -r -n 500 ${KC[*]} -n default delete event --wait=false >/dev/null" || true
  echo "inner cluster nodes after cleanup: $(ik get nodes --no-headers | wc -l). Leases: $(ik -n kube-node-lease get leases --no-headers | wc -l). Namespaces: $(ik get ns --no-headers | awk '{print $1}' | tr '\n' ' ')"
}

# Make the nodes of one level in four parts, 15 seconds apart.
ramp() {
  local from=$1 to=$2 step a b
  step=$(((to - from + 4) / 4))
  for a in $(seq "$from" "$step" "$to"); do
    b=$((a + step - 1))
    [ "$b" -le "$to" ] || b=$to
    cmd_nodes "$a" "$b"
    sleep 15
  done
}

cmd_run() {
  local have=0 level
  say "target $TARGET: pods ${PODS[*]} in $CP_NS"
  cmd_mark start
  cmd_creds
  cmd_kwok_up
  cmd_sampler_start
  sleep 20
  cmd_mark idle-start
  sleep "$IDLE"
  cmd_mark idle-end
  cmd_patcher_up
  for level in $LEVELS; do
    say "ramp to $level nodes"
    cmd_mark "ramp-$level-start"
    ramp $((have + 1)) "$level"
    have=$level
    sleep "$SETTLE"
    cmd_status | tee "$LOG_DIR/status-$level-start.txt"
    cmd_mark "w$level-start"
    sleep "$WINDOW"
    cmd_mark "w$level-end"
    cmd_status | tee "$LOG_DIR/status-$level-end.txt"
  done
  sleep 5
  cmd_sampler_stop
  cmd_cleanup
  cmd_mark end
  say "done"
}

step=${1:-}
shift || true
case "$step" in
  creds | kwok-up | patcher-up | nodes | sampler-start | sampler-stop | mark | status | cleanup | run) "cmd_${step//-/_}" "$@" ;;
  *) sed -n '2,22p' "$0"; exit 1 ;;
esac
