#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Phase 2 step 3, tests T1 to T3: one pod in the form of section 5a, made by hand, with test
# bootstrap data (fake values from the test generator of the lab bootstrap helper).
#
# Usage: t123.sh <step> [slot] [label]
#   base                namespace, network attachment
#   wipe <slot>         remove the filesystem signatures of the two devices of the slot
#   up <slot> <label>   volumes, claims, Secret and pod of the slot; wait for systemd
#   check <slot> <label> <first|repeat> [written]   the pass rules, inside the pod
#   delete-pod <slot>   delete the pod. The claims and the Secret stay
#   restart <slot>      stop systemd in the container, so that the kubelet starts a new container in the same pod
#   compare <slot> <label1> <label2>   the markers of two checks must be equal
#   down                remove the namespace and the volumes
# Slots:  t1  = the data "full" (each feature of the format), status done
#         t1b = the data "fail" (the second command fails), status error
set -euo pipefail
. /root/kata-cp/bin/env.sh
HERE="$(cd "$(dirname "$0")" && pwd)"
NS=${NS:-p2}
IMAGE=${IMAGE:-nvke-node-podvm:bcc4376f-p2}
RUNTIME_CLASS=${RUNTIME_CLASS:-kata-clh-runtime-rs-fix-direct-ovs}
CPU=${CPU:-2}
MEMORY=${MEMORY:-6Gi}
CLUSTER=p2t
KIND_NODE=${KIND_NODE:-kata-bb-control-plane}
FIX=${FIX:-$W/p2-image/out/fixtures}
LOG_DIR=${LOG_DIR:-$W/logs/p2/t123}
LOOP_MAP=$W/disks/loop-map.txt
NAD_TMPL=$W/d/endpoint-run/nad.yaml.tmpl
mkdir -p "$LOG_DIR"

declare -A MACHINES=([t1]=p2t-cp-1a2b3c4d [t1b]=p2t-cp-5e6f7a8b)
declare -A DATA=([t1]=full [t1b]=fail)
declare -A STATUS=([t1]=done [t1b]=error)
declare -A VAR_LOOPS=([t1]=/dev/loop60 [t1b]=/dev/loop61)
declare -A ETCD_LOOPS=([t1]=/dev/loop63 [t1b]=/dev/loop64)
declare -A EXPECT=([/dev/loop60]=var-0.img [/dev/loop63]=etcd-0.img [/dev/loop61]=var-1.img [/dev/loop64]=etcd-1.img)
declare -A HOST_NODES=([t1]=kata-bb-worker [t1b]=kata-bb-worker2)
declare -A ADDRS=([t1]=172.28.1.41 [t1b]=172.28.1.42)
# Not in the contract. T1 leaves the defaults of Kubernetes (a service account token and the
# service links in the pod), to show that the image works with them.
EXTRA_SPEC=${EXTRA_SPEC-  terminationGracePeriodSeconds: 20}

KC=(kubectl --kubeconfig /etc/kubernetes/admin.conf)
node() { docker exec "$KIND_NODE" "$@"; }
nodei() { docker exec -i "$KIND_NODE" "$@"; }
k() { node "${KC[@]}" "$@"; }
say() { echo "== $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
stamp() { printf '%s %s\n' "$(date +%s.%N)" "$1" >>"$LOG_DIR/times.txt"; }
between() { awk -v a="$1" -v b="$2" '$2==a {x=$1} $2==b {y=$1} END {if (x && y) printf "%.1f\n", y-x; else print "-"}' "$LOG_DIR/times.txt"; }
mac_of() { local IFS=.; set -- $1; printf '02:00:%02x:%02x:%02x:%02x' "$1" "$2" "$3" "$4"; }
wait_node() {
  local t=$1
  shift
  node systemd-run --quiet --wait --collect --expand-environment=no --unit="p2-wait-$$-$RANDOM" \
    bash -c "for i in \$(seq 1 $t); do if $*; then exit 0; fi; sleep 1; done; exit 1"
}

render() { # render <template> <slot>
  local s=$2
  export NS IMAGE RUNTIME_CLASS CPU MEMORY CLUSTER EXTRA_SPEC
  export SLOT="$s" MACHINE="${MACHINES[$s]}" ADDRESS="${ADDRS[$s]}/16" VAR_LOOP="${VAR_LOOPS[$s]}" ETCD_LOOP="${ETCD_LOOPS[$s]}" HOST_NODE="${HOST_NODES[$s]}"
  export MAC; MAC=$(mac_of "${ADDRS[$s]}")
  export SECRET="${MACHINES[$s]}-bootstrap-data"
  envsubst '$NS $IMAGE $RUNTIME_CLASS $CPU $MEMORY $CLUSTER $EXTRA_SPEC $SLOT $MACHINE $ADDRESS $MAC $VAR_LOOP $ETCD_LOOP $HOST_NODE $SECRET' <"$HERE/$1"
}

check_devices() {
  local d la
  la=$(node losetup -a)
  for d in "${!EXPECT[@]}"; do
    grep -q "^$d .*/${EXPECT[$d]} " "$LOOP_MAP" || die "$d is not ${EXPECT[$d]} in $LOOP_MAP"
    grep -q "^$d: .*/${EXPECT[$d]})" <<<"$la" || die "$d is not ${EXPECT[$d]} in the kind node"
  done
  if k get pv -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.local.path}{"\n"}{end}' | grep -v "^$NS-" | grep -E "$(IFS='|'; echo "${!EXPECT[*]}")\$"; then
    die "a volume of another test uses a device of this test"
  fi
}

cmd_base() {
  check_devices
  k create namespace "$NS" --dry-run=client -o yaml | nodei "${KC[@]}" apply -f -
  NS=$NS envsubst '$NS' <"$NAD_TMPL" | nodei "${KC[@]}" apply -f -
  k get runtimeclass "$RUNTIME_CLASS" -o jsonpath='{"runtime class "}{.metadata.name}{" handler "}{.handler}{"\n"}'
  for n in $WORKERS; do echo "$n: image $(docker exec "$n" crictl inspecti -o json "docker.io/library/$IMAGE" 2>/dev/null | jq -r '.status.id' | cut -c1-19)"; done
}

cmd_wipe() {
  local s=$1
  check_devices
  if k get pv "$NS-$s-var" >/dev/null 2>&1; then die "the volumes of slot $s are still in the cluster"; fi
  node wipefs -a "${VAR_LOOPS[$s]}" "${ETCD_LOOPS[$s]}"
  node sh -c "blkid -p ${VAR_LOOPS[$s]} ${ETCD_LOOPS[$s]}; echo \"blkid exit code \$? (2 = no signature)\""
}

cmd_up() {
  local s=$1 label=$2 m=${MACHINES[$1]}
  say "slot $s, label $label: Machine $m, data ${DATA[$s]}, address ${ADDRS[$s]}/16 $(mac_of "${ADDRS[$s]}"), devices ${VAR_LOOPS[$s]} ${ETCD_LOOPS[$s]} on ${HOST_NODES[$s]}"
  render volumes.yaml.tmpl "$s" | nodei "${KC[@]}" apply -f - | tr '\n' ' '; echo
  # The Secret has the form of the Secret of NVKE: the key "value" with the cloud-config text.
  nodei "${KC[@]}" -n "$NS" create secret generic "$m-bootstrap-data" --type=cluster.x-k8s.io/secret --from-file=value=/dev/stdin --dry-run=client -o yaml <"$FIX/${DATA[$s]}.userdata.yaml" |
    nodei "${KC[@]}" apply -f - | tr '\n' ' '; echo
  render pod.yaml.tmpl "$s" >"$LOG_DIR/pod-$s-$label.yaml"
  stamp "$s-$label-pod-create"
  nodei "${KC[@]}" apply -f - <"$LOG_DIR/pod-$s-$label.yaml"
  k -n "$NS" wait --for=jsonpath='{.status.phase}'=Running "pod/$m" --timeout=300s
  stamp "$s-$label-running"
  wait_node 300 "${KC[*]} -n $NS exec $m -- systemctl is-active containerd >/dev/null 2>&1" || die "containerd is not active in the pod $m"
  stamp "$s-$label-containerd"
  say "pod $m: create to Running $(between "$s-$label-pod-create" "$s-$label-running") s, to containerd active $(between "$s-$label-pod-create" "$s-$label-containerd") s"
  k -n "$NS" get pod "$m" -o wide
}

cmd_check() {
  local s=$1 label=$2 mode=$3 written=${4:-0} m=${MACHINES[$1]} out
  out="$LOG_DIR/check-$s-$label.txt"
  {
    say "check of slot $s, label $label, mode $mode, at $(date -u +%FT%TZ)"
    k -n "$NS" get pod "$m" -o json | jq -r '"pod \(.metadata.name) uid \(.metadata.uid) node \(.spec.nodeName) class \(.spec.runtimeClassName) command \(.spec.containers[0].command // "none") args \(.spec.containers[0].args // "none") hostname field \(.spec.hostname // "none")",
      "container \(.status.containerStatuses[0].name) image \(.status.containerStatuses[0].image) restarts \(.status.containerStatuses[0].restartCount) started \(.status.containerStatuses[0].state.running.startedAt) pod start \(.status.startTime) created \(.metadata.creationTimestamp)",
      "volumes: \([.spec.volumes[] | .name + "=" + (.persistentVolumeClaim.claimName // .secret.secretName // (.projected | if . then "projected" else "other" end))] | join(" "))",
      "labels: \(.metadata.labels | to_entries | map(.key + "=" + .value) | join(" "))",
      "networks: \(.metadata.annotations["k8s.v1.cni.cncf.io/networks"])",
      "network status: \(.metadata.annotations["k8s.v1.cni.cncf.io/network-status"] | fromjson | map(.name + " " + (.interface // "-") + " " + ((.ips // []) | join(",")) + " " + (.mac // "-")) | join("; "))"'
    say "the log of the entry point (PID 1 before systemd)"
    k -n "$NS" logs "$m" 2>/dev/null | grep -a 'PODVM:' | tr -d '\r' | tail -12
    say "inside the pod"
    nodei "${KC[@]}" -n "$NS" exec -i "$m" -- env MACHINE="$m" MODE="$mode" EXPECT_STATUS="${STATUS[$s]}" EXPECTED="$(cat "$FIX/${DATA[$s]}.expected")" \
      ADDRESS="${ADDRS[$s]}/16" MAC="$(mac_of "${ADDRS[$s]}")" WANT_COUNT=1 WANT_WRITTEN="$written" bash -s <"$HERE/incheck.sh" || true
    stamp "$s-$label-checked"
  } >"$out" 2>&1
  cat "$out"
  local n f
  n=$(grep -c '^CHECK ' "$out" || true)
  f=$(grep -c '^CHECK .* FAIL ' "$out" || true)
  if [ "$n" -ge 15 ] && [ "$f" = 0 ]; then echo "RESULT $s $label: PASS ($n rules)" | tee -a "$out"; else echo "RESULT $s $label: FAIL ($n rules, $f failed)" | tee -a "$out"; fi
  grep '^MARKER ' "$out" >"$LOG_DIR/marker-$s-$label.txt" || true
  grep -q "RESULT $s $label: PASS" "$out"
}

cmd_delete_pod() {
  local s=$1 m=${MACHINES[$1]}
  stamp "$s-delete-start"
  k -n "$NS" delete pod "$m" --wait=true
  stamp "$s-delete-done"
  say "pod $m deleted in $(between "$s-delete-start" "$s-delete-done") s. Claims and Secret that stay:"
  k -n "$NS" get pvc,secret -o name | grep "$m" | tr '\n' ' '; echo
}

cmd_restart() {
  local s=$1 m=${MACHINES[$1]} rc
  rc=$(k -n "$NS" get pod "$m" -o jsonpath='{.status.containerStatuses[0].restartCount}')
  say "restart in place of $m (restart count $rc): systemd in the container gets 'poweroff' at $(date -u +%T)"
  stamp "$s-restart-start"
  k -n "$NS" exec "$m" -- systemctl --no-block poweroff || true
  wait_node 240 "[ \"\$(${KC[*]} -n $NS get pod $m -o jsonpath='{.status.containerStatuses[0].restartCount}')\" -gt $rc ] && ${KC[*]} -n $NS exec $m -- systemctl is-active containerd >/dev/null 2>&1" || die "no new container in the pod $m"
  stamp "$s-restart-containerd"
  say "new container: restart count $(k -n "$NS" get pod "$m" -o jsonpath='{.status.containerStatuses[0].restartCount}'), last exit: $(k -n "$NS" get pod "$m" -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}{" code "}{.status.containerStatuses[0].lastState.terminated.exitCode}{" at "}{.status.containerStatuses[0].lastState.terminated.finishedAt}'), poweroff to containerd active $(between "$s-restart-start" "$s-restart-containerd") s"
}

cmd_compare() {
  local s=$1 a=$2 b=$3
  say "markers of slot $s: $a against $b"
  if diff "$LOG_DIR/marker-$s-$a.txt" "$LOG_DIR/marker-$s-$b.txt"; then
    sed 's/^/  /' "$LOG_DIR/marker-$s-$b.txt"
    echo "RESULT compare $s $a $b: PASS (the markers, the command output and the counter are the same)"
  else
    echo "RESULT compare $s $a $b: FAIL"
    return 1
  fi
}

cmd_down() {
  k delete namespace "$NS" --ignore-not-found --wait=true
  local s
  for s in "${!MACHINES[@]}"; do k delete pv "$NS-$s-var" "$NS-$s-etcd" --ignore-not-found --wait=true; done
}

step=${1:-}
shift || true
case "$step" in
  base | wipe | up | check | delete-pod | restart | compare | down)
    "cmd_${step//-/_}" "$@" 2>&1 | tee -a "$LOG_DIR/run.log"
    exit "${PIPESTATUS[0]}"
    ;;
  render) render "$@" ;;
  *) sed -n '2,16p' "$0"; exit 1 ;;
esac
