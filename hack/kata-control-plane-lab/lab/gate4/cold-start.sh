#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Gate 4, step 5: cold start of the host cluster.
#
# The script records the state of the three control plane replicas, stops the kind node
# container with "docker stop", starts it with "docker start", and measures the time until
# etcd has quorum and all three API servers answer. It does no step by hand after the start:
# it only reads. Then it compares the identity of each replica with the state before, runs the
# checks of steps 3 and 6, and checks the kind node itself.
#
# WARNING. "docker stop" stops the host control plane, containerd, the kubelet and each Kata VM
# of the kind node. That includes the pods of every other agent. Run it at a quiet time only.
#
# Before the first run, install the unit g4-loop-nodes.service in the kind node (the install
# command is in the unit file). A stop of the container loses the loop device nodes that
# lab/01-node-prep.sh made by hand. Without the nodes, the kubelet cannot attach a new loop
# device for a raw block volume.
#
# Usage: cold-start.sh --stop-the-kind-node
#        cold-start.sh --dry-run     all steps but the stop and the start (a test of this script)
#   ALLOW_NO_UNIT=1    run also when the unit is not installed (to record what fails without it)
#   NODE_TIMEOUT=600   seconds to wait for the API server of the host cluster after "docker start".
#                      After that time the script saves "docker logs" and "docker inspect" and stops.
#   TIMEOUT=900        seconds to wait for the replicas after "docker start"
#   NODE_CHECKS=1      run the checks of the kind node also in a dry run
set -euo pipefail

NS=${NS:-gate4}
KIND_NODE=${KIND_NODE:-kata-cp-control-plane}
NODE_IP=${NODE_IP:-172.30.0.2}
NODE_TIMEOUT=${NODE_TIMEOUT:-600}
TIMEOUT=${TIMEOUT:-900}
IP_API=172.30.255.210
declare -A IPS=([a]=172.30.255.211 [b]=172.30.255.212 [c]=172.30.255.213)
HERE="$(cd "$(dirname "$0")" && pwd)"
export LOG_DIR=${LOG_DIR:-/scratch/kata-cp/logs/gate4/cold-start-$(date +%Y%m%d-%H%M%S)}
export NS KIND_NODE OWNER=sts
KC=(kubectl --kubeconfig /etc/kubernetes/admin.conf)
LOOP_DIR=/tmp/g4-loop # in the kind node
mkdir -p "$LOG_DIR"

node() { docker exec "$KIND_NODE" "$@"; }
k() { node "${KC[@]}" "$@"; }
say() { echo "== $*"; }
die() {
  echo "ERROR: $*" >&2
  exit 1
}
now() { date +%s.%N; }
stamp() { printf '%s %s\n' "$(now)" "$1" >>"$LOG_DIR/times.txt"; }
seen() { grep -q " $1\$" "$LOG_DIR/times.txt"; }
since_start() { awk -v n="$1" '$2=="docker-start-done" {s=$1} $2==n {x=$1} END {if (x) printf "%.1f", x-s; else printf "not reached"}' "$LOG_DIR/times.txt"; }
# One line for each node pod: name, UID, pod IP, restart count, container ID.
pod_lines() {
  k -n "$NS" get pods -o jsonpath='{range .items[*]}{.metadata.name}{" uid="}{.metadata.uid}{" ip="}{.status.podIP}{" restarts="}{.status.containerStatuses[0].restartCount}{" container="}{.status.containerStatuses[0].containerID}{"\n"}{end}'
}
# The state of the kind node and of the pods, for the record.
snapshot() {
  local label=$1
  {
    say "snapshot $label at $(date -u +%FT%TZ)"
    docker inspect -f 'container: status {{.State.Status}}, started {{.State.StartedAt}}, restarts {{.RestartCount}}, address {{range .NetworkSettings.Networks}}{{.IPAddress}} mac {{.MacAddress}}{{end}}' "$KIND_NODE"
    k get nodes -o wide || true
    k get pods -A -o wide || true
    k -n "$NS" get statefulset,svc,pvc,endpointslices -o wide || true
    pod_lines || true
    say "sandboxes and containers of the node pods in containerd (crictl)"
    node crictl pods --namespace "$NS" || true
    node crictl ps -a --label io.kubernetes.pod.namespace="$NS" || true
    say "Kata processes in the kind node (PID, start time, name)"
    node sh -c "ps -eo pid=,lstart=,args= | grep -E 'cloud-hypervisor|virtiofsd|containerd-shim-kata' | grep -v grep | awk '{n=split(\$7,a,\"/\"); print \$1, \$3, \$4, \$5, a[n]}'" || true
    say "loop devices in the kind node: number of device nodes, then the devices that the kubelet holds"
    node sh -c 'ls /dev/loop[0-9]* | wc -l; losetup -a | grep volumeDevices | sort' || true
  } >"$LOG_DIR/snapshot-$label.txt" 2>&1
}

# Checks of the kind node itself after a start. Each line starts with OK or FAIL.
node_checks() {
  local x mac ok handlers
  {
    say "node checks at $(date -u +%FT%TZ)"
    x=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$KIND_NODE")
    if [ "$x" = "$NODE_IP" ]; then echo "OK address of the kind node: $x"; else echo "FAIL address of the kind node: $x, not $NODE_IP"; fi
    x=$(node sh -c 'ls /dev/loop[0-9]* | wc -l')
    if [ "$x" -ge 128 ]; then echo "OK loop device nodes: $x"; else echo "FAIL loop device nodes: $x"; fi
    echo "   g4-loop-nodes.service: $(node systemctl is-active g4-loop-nodes.service || true), $(node sh -c 'journalctl --no-pager -b -u g4-loop-nodes.service | grep "loop device nodes" | tail -1' || true)"
    x=$(node sh -c 'systemctl is-active dbus.socket dbus.service | tr "\n" " "; [ -S /run/dbus/system_bus_socket ] && echo socket-present' || true)
    if [ "$x" = "active active socket-present" ]; then echo "OK D-Bus: $x"; else echo "FAIL D-Bus: $x"; fi
    handlers=$(k get node -o jsonpath='{.items[0].status.runtimeHandlers[*].name}')
    echo "$handlers" | tr ' ' '\n' | sort >"$LOG_DIR/handlers-after.txt"
    if diff "$LOG_DIR/handlers-before.txt" "$LOG_DIR/handlers-after.txt" >/dev/null; then
      echo "OK runtime handlers, the same $(grep -c . "$LOG_DIR/handlers-after.txt") as before: $handlers"
    else
      echo "FAIL runtime handlers changed: $(diff "$LOG_DIR/handlers-before.txt" "$LOG_DIR/handlers-after.txt" | tr '\n' ' ')"
    fi
    node sh -c 'grep -n imports /etc/containerd/config.toml' | sed 's/^/   /'
    # MetalLB. The status objects name the node that answers. Then one ping from the host to each
    # address. A ping gets no echo answer from a Service address, but the host must first ask
    # for the hardware address (ARP). The neighbor entry shows if MetalLB answered. No TCP.
    k -n metallb-system get servicel2statuses 2>&1 | sed 's/^/   /'
    # An old entry that gets no answer goes to FAILED after about 8 s, so wait before the read.
    # REACHABLE means that an answer came in the last seconds.
    mac=$(node cat /sys/class/net/eth0/address)
    echo "   neighbor entries of the host before the ping: $(ip neigh show | grep -E "^172\.30\.255\.21[0-3] " | awk '{print $1 "=" $NF}' | tr '\n' ' ')"
    for x in "$IP_API" "${IPS[a]}" "${IPS[b]}" "${IPS[c]}"; do
      ping -c 1 -W 1 "$x" >/dev/null 2>&1 || true
    done
    sleep 7
    for x in "$IP_API" "${IPS[a]}" "${IPS[b]}" "${IPS[c]}"; do
      ok=$(ip neigh show "$x" | head -1)
      case "$ok" in
        *"lladdr $mac "*REACHABLE*) echo "OK MetalLB answers for $x: $ok" ;;
        *) echo "FAIL MetalLB for $x: neighbor entry '$ok', the kind node has $mac" ;;
      esac
    done
    x=$(docker port "$KIND_NODE")
    if echo "$x" | grep -v -- '-> 127\.0\.0\.1:' | grep -q .; then echo "FAIL published ports: $x"; else echo "OK published ports, 127.0.0.1 only: $x"; fi
    x=$(k -n gate1-nvke-spire get pods --no-headers 2>&1 | awk '{print $1, $2, $3}')
    case "$x" in *"1/1 Running"*) echo "OK SPIRE server of the other agent: $x" ;; *) echo "FAIL SPIRE server of the other agent: $x" ;; esac
    x=$(k get pods -A --no-headers 2>/dev/null | awk '{split($3,a,"/"); if ($4 != "Running" || a[1] != a[2]) print $1 "/" $2 " " $3 " " $4}')
    if [ -z "$x" ]; then echo "OK all $(k get pods -A --no-headers | grep -c .) pods of the host cluster run and are ready"; else echo "FAIL pods of the host cluster that do not run: $x"; fi
  } 2>&1 | tee "$LOG_DIR/node-checks-after.txt"
}

# What the kubelet and containerd did with the dead Kata sandboxes and the old loop devices.
after_start_record() {
  {
    say "sandboxes and containers of the node pods after the start (crictl, all states)"
    node crictl pods --namespace "$NS" || true
    node crictl ps -a --label io.kubernetes.pod.namespace="$NS" || true
    say "the old container of each pod, from the pod status"
    k -n "$NS" get pods -o jsonpath='{range .items[*]}{.metadata.name}{" lastState="}{.status.containerStatuses[0].lastState}{"\n"}{end}' || true
    say "events of the node pods"
    k -n "$NS" get events --sort-by=.lastTimestamp 2>&1 | tail -40 || true
    say "containerd journal of this boot: number of lines, then lines about the old sandboxes and containers"
    node sh -c 'journalctl --no-pager -b -u containerd | grep -c .' || true
    node sh -c 'journalctl --no-pager -b -u containerd | grep -i -E "fail|error|warn|recover|cleanup|dead|load (sandbox|container)|StopPodSandbox|RemovePodSandbox" | cut -c1-420 | head -80' || true
    say "kubelet journal of this boot: lines about sandboxes, block volumes and loop devices"
    node sh -c 'journalctl --no-pager -b -u kubelet | grep -i -E "losetup|loop|MapVolume|MapBlockVolume|volumeDevices|SandboxChanged|sandbox.*(not ready|changed|dead)|orphan|killing" | cut -c1-420 | head -80' || true
    say "loop devices of the kubelet after the start (compare with snapshot-before.txt and host-kubelet-loops-while-stopped.txt)"
    node sh -c 'losetup -a | grep volumeDevices | sort' || true
    node sh -c 'for l in $(losetup -a | grep volumeDevices | cut -d: -f1); do n=${l#/dev/}; echo "$n backing_file=$(cat /sys/block/$n/loop/backing_file)"; done' || true
  } >"$LOG_DIR/after-start-record.txt" 2>&1
}

DRY_RUN=0
case "${1:-}" in
  --stop-the-kind-node) ;;
  --dry-run) DRY_RUN=1 ;;
  *)
    sed -n '2,/^set -euo/p' "$0" | sed '$d'
    exit 1
    ;;
esac

say "checks before the stop"
free -g
if [ "$(node systemctl is-enabled g4-loop-nodes.service 2>/dev/null || true)" != enabled ]; then
  [ "${ALLOW_NO_UNIT:-0}" = 1 ] || [ "$DRY_RUN" = 1 ] || die "g4-loop-nodes.service is not installed in the kind node. See the unit file for the install command."
  echo "WARNING: the unit is not installed. The run records what fails without it."
fi
for r in a b c; do
  [ "$(k -n "$NS" get pod "cp-$r-0" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] ||
    die "the pod cp-$r-0 is not ready. Start from three ready replicas (StatefulSets)."
done
snapshot before
k get node -o jsonpath='{.items[0].status.runtimeHandlers[*].name}' | tr ' ' '\n' | sort >"$LOG_DIR/handlers-before.txt"
"$HERE/run.sh" identity before
"$HERE/run.sh" check 5-before-stop | tail -1
pod_lines >"$LOG_DIR/pods-before.txt"
# The container ID of each node pod. A new ID after the start shows a new container.
for r in a b c; do
  k -n "$NS" get pod "cp-$r-0" -o jsonpath='{.status.containerStatuses[0].containerID}' >"$LOG_DIR/.container-$r-before"
done

if [ "$DRY_RUN" = 1 ]; then
  say "dry run: no stop and no start. The containers of the pods stay, so do not compare their IDs."
  for r in a b c; do echo none >"$LOG_DIR/.container-$r-before"; done
  stamp docker-start-done
else
  say "docker stop $KIND_NODE"
  stamp docker-stop-start
  docker stop "$KIND_NODE" >/dev/null
  stamp docker-stop-done
  [ "$(docker inspect -f '{{.State.Status}}' "$KIND_NODE")" = exited ] || die "the container did not stop"
  echo "stop took $(awk '$2=="docker-stop-start" {a=$1} $2=="docker-stop-done" {b=$1} END {printf "%.1f", b-a}' "$LOG_DIR/times.txt") s. Exit code of the container: $(docker inspect -f '{{.State.ExitCode}}' "$KIND_NODE")"
  # What stays on the host while the node is down. Read only.
  {
    echo "== loop devices of the old kubelet that stay attached in the kernel"
    losetup -a | grep volumeDevices | sort || true
    echo "== Kata processes of the lab that stay (must be none)"
    ps -eo pid=,args= | grep -E 'cloud-hypervisor|virtiofsd|containerd-shim-kata' | grep -v grep | grep -E 'gate4|/run/kata|/opt/kata' || true
  } >"$LOG_DIR/host-kubelet-loops-while-stopped.txt" 2>&1
  echo "loop devices that the old kubelet left attached: $(grep -c volumeDevices "$LOG_DIR/host-kubelet-loops-while-stopped.txt" || true)"

  say "docker start $KIND_NODE. No manual step from here."
  docker start "$KIND_NODE" >/dev/null
  stamp docker-start-done
fi

# The loops in the kind node call /readyz of the shared Service and of each replica each second.
for i in $(seq 1 60); do
  if node true 2>/dev/null; then break; fi
  sleep 1
done
"$HERE/run.sh" loop-start || true

# Watch. Each stamp is the first time that a state was seen. The /readyz times come from the
# loops in the kind node, which call each address one time each second.
start_s=$(date +%s)
while [ "$(date +%s)" -lt "$((start_s + TIMEOUT))" ]; do
  if ! seen host-api-ready && [ "$(k get --raw /readyz 2>/dev/null || true)" = ok ]; then stamp host-api-ready; fi
  if ! seen host-api-ready && [ "$(date +%s)" -ge "$((start_s + NODE_TIMEOUT))" ]; then
    # The kind node did not come back. Save the facts and stop. No other Docker command.
    docker logs --tail 100 "$KIND_NODE" >"$LOG_DIR/docker-logs-tail.txt" 2>&1 || true
    docker inspect "$KIND_NODE" >"$LOG_DIR/docker-inspect.json" 2>&1 || true
    docker inspect -f 'state: {{json .State}}' "$KIND_NODE" || true
    echo "RESULT cold-start: FAIL (the API server of the host cluster did not answer inside $NODE_TIMEOUT s)"
    exit 2
  fi
  if seen host-api-ready && ! seen host-node-ready &&
    [ "$(k get node "$KIND_NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)" = True ]; then stamp host-node-ready; fi
  if seen host-api-ready && ! seen pods-running-again; then
    n=0
    for r in a b c; do
      # A pod runs again when its container is new and runs.
      new=$(k -n "$NS" get pod "cp-$r-0" -o jsonpath='{.status.containerStatuses[0].containerID} {.status.containerStatuses[0].state.running.startedAt}' 2>/dev/null || true)
      if [ -n "${new##* }" ] && [ -n "${new%% *}" ] && [ "${new%% *}" != "$(cat "$LOG_DIR/.container-$r-before")" ]; then n=$((n + 1)); fi
    done
    if [ "$n" = 3 ]; then stamp pods-running-again; fi
  fi
  if seen pods-running-again && ! seen etcd-quorum && "$HERE/run.sh" quorum >/dev/null 2>&1; then stamp etcd-quorum; fi
  # The first call with the answer 200 of each target: "<time> <target> 200 <seconds>".
  node sh -c "for w in shared a b c; do cat $LOOP_DIR/shared.log $LOOP_DIR/replicas.log 2>/dev/null | grep -m1 \" \$w 200 \"; done" 2>/dev/null >"$LOG_DIR/.first-200" || true
  while read -r t w _; do
    seen "readyz-$w" || printf '%s %s\n' "$t" "readyz-$w" >>"$LOG_DIR/times.txt"
  done <"$LOG_DIR/.first-200"
  if seen readyz-a && seen readyz-b && seen readyz-c && seen readyz-shared && seen etcd-quorum; then
    stamp all-api-servers-ready
    break
  fi
  sleep 1
done
# All pods of the host cluster, also the pods of other namespaces: wait up to 120 s more.
for i in $(seq 1 120); do
  x=$(k get pods -A --no-headers 2>/dev/null | awk '{split($3,a,"/"); if ($4 != "Running" || a[1] != a[2]) print $2}' || echo unknown)
  if [ -z "$x" ] && seen host-api-ready; then
    stamp all-host-pods-ready
    break
  fi
  sleep 1
done

say "times after docker start (s)"
{
  for s in host-api-ready host-node-ready pods-running-again etcd-quorum readyz-a readyz-b readyz-c readyz-shared all-host-pods-ready; do
    echo "$s: $(since_start "$s")"
  done
  # The last of the three API servers. The stamp all-api-servers-ready is only the time of the check.
  echo "all three API servers answer: $(awk '$2=="docker-start-done" {s=$1} $2 ~ /^readyz-[abc]$/ {n++; if ($1>m) m=$1} END {if (n>=3) printf "%.1f", m-s; else printf "not reached"}' "$LOG_DIR/times.txt")"
  echo "etcd-quorum is the time of the first etcdctl call that committed a proposal, after all three pods ran. The call needs some seconds, so the first /readyz answer can be earlier."
} | tee "$LOG_DIR/summary-times.txt"

"$HERE/run.sh" loop-stop || true
snapshot after
pod_lines >"$LOG_DIR/pods-after.txt" || true
say "node pods before and after (UID, pod IP, restart count)"
paste -d'\n' <(sed 's/ container=.*//; s/^/before: /' "$LOG_DIR/pods-before.txt") <(sed 's/ container=.*//; s/^/after:  /' "$LOG_DIR/pods-after.txt") | tee "$LOG_DIR/pods-before-after.txt"
after_start_record
node sh -c 'journalctl --no-pager -b -u containerd' >"$LOG_DIR/node-containerd-journal.txt" 2>&1 || true
node sh -c 'journalctl --no-pager -b -u kubelet' >"$LOG_DIR/node-kubelet-journal.txt" 2>&1 || true

fail=0
seen all-api-servers-ready || {
  echo "FAIL: not all API servers answered inside $TIMEOUT s"
  fail=1
  "$HERE/run.sh" diag cold-start-failed || true
}
say "identity of each replica (only pod-ip and boot-id may differ)"
"$HERE/run.sh" identity after
for r in a b c; do
  if diff "$LOG_DIR/identity-$r-before.txt" "$LOG_DIR/identity-$r-after.txt" >"$LOG_DIR/.diff"; then
    echo "cp-$r: no difference (the pod IP did not change)"
  else
    cat "$LOG_DIR/.diff"
    if grep -E '^[<>]' "$LOG_DIR/.diff" | grep -v -E '^[<>] (pod-ip|boot-id) ' | grep -q .; then
      echo "FAIL: the identity of cp-$r changed"
      fail=1
    else
      echo "cp-$r: only the pod IP and the boot ID changed"
    fi
  fi
done
"$HERE/run.sh" check 5-after-cold-start | tail -1 || fail=1
"$HERE/run.sh" reach 5-after-cold-start | tail -1 || fail=1
if [ "$DRY_RUN" = 0 ] || [ -n "${NODE_CHECKS:-}" ]; then
  node_checks
  if grep -q '^FAIL' "$LOG_DIR/node-checks-after.txt"; then fail=1; fi
fi
if [ "$fail" = 0 ]; then echo "RESULT cold-start: PASS"; else echo "RESULT cold-start: FAIL"; fi
say "logs are in $LOG_DIR"
