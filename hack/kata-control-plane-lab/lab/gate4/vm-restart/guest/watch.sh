#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Boot unit of the restart test (vm-restart-watch.service). It runs at each boot of the VM.
# When a test is pending (the file /var/lib/vm-restart/pending holds the label of the run), it
# writes the time of each event in seconds after the kernel boot, from /proc/uptime.
# It only reads: Docker (inspect), the API server of the host cluster, and one etcdctl health
# call in a replica. It does no step that helps the cluster to return.
# It does not use "docker exec" before the cluster is back: a process of "docker exec" is in the
# root cgroup of the kind node, and the kubelet of a kind node does not start while that cgroup
# holds a process. It calls the cluster from the VM, which is the Docker host of the kind node.
set -u
STATE=/var/lib/vm-restart
[ -s "$STATE/pending" ] || { echo "no restart test is pending"; exit 0; }
label=$(cat "$STATE/pending")
D=$STATE/runs/$label
mkdir -p "$D"
. /opt/vm-restart/env.sh
export LOG_DIR=$D
NODE=$KIND_NODE
NODE_IP=172.31.0.2
IP_API=172.31.255.210
declare -A IPS=([a]=172.31.255.211 [b]=172.31.255.212 [c]=172.31.255.213)
TIMEOUT=${TIMEOUT:-1500} # seconds after the start of this script
T=$D/times.txt
KC=(kubectl --request-timeout=5s)
ETCDCTL='crictl exec "$(crictl ps --name etcd -q | head -1)" etcdctl --endpoints https://127.0.0.1:2379 --cacert /etc/kubernetes/pki/etcd/ca.crt --cert /etc/kubernetes/pki/etcd/healthcheck-client.crt --key /etc/kubernetes/pki/etcd/healthcheck-client.key'

up() { cut -d' ' -f1 /proc/uptime; }
stamp() { printf '%s %s %s\n' "$(up)" "$(date -u +%T.%3N)" "$1" >>"$T"; }
seen() { grep -q " $1\$" "$T" 2>/dev/null; }
# The first call of a probe loop with the answer 200: its time after the kernel boot.
first200() { awk '$3 == 200 {print $1; exit}' "$D/loop-$1.log" 2>/dev/null; }
# A lab address is reachable only through the Docker bridge. Without the bridge, do not call.
route_ok() { ip route get "$1" 2>/dev/null | grep -q 'dev br-katavm'; }

[ ! -e "$D/boot.txt" ] || { echo "the run $label has a boot record already. Stop."; exit 0; }
{
  echo "label $label"
  echo "boot-id-after $(cat /proc/sys/kernel/random/boot_id)"
  echo "watch-start-uptime $(up)"
  echo "watch-start-time $(date -u +%FT%T.%3NZ)"
  echo "kernel $(uname -r)"
} >"$D/boot.txt"
cp /run/vm-restart/docker-state-at-boot.txt "$D/docker-state-at-boot.txt" 2>/dev/null || echo "no record" >"$D/docker-state-at-boot.txt"
cp "$STATE/docker-state/last-shutdown.txt" "$D/docker-state-last-shutdown.txt" 2>/dev/null || echo "no record" >"$D/docker-state-last-shutdown.txt"
stamp watch-start

# One loop for each address: /readyz one time each second.
probe_loop() {
  local name=$1 ip=$2
  while [ ! -e "$D/.stop" ]; do
    if route_ok "$ip"; then
      printf '%s %s %s\n' "$(up)" "$name" "$(curl -sk --connect-timeout 1 --max-time 2 -o /dev/null -w '%{http_code} %{time_total}' "https://$ip:6443/readyz" 2>/dev/null)" >>"$D/loop-$name.log"
    else
      printf '%s %s no-route\n' "$(up)" "$name" >>"$D/loop-$name.log"
    fi
    sleep 1
  done
}
# The DNS of the host cluster, asked from the kind node: the name of the headless Service that
# the etcd peer check needs (ETCD_PEER_DNS=1). One query each second. The loop starts when the
# API server of the host cluster answers, so the kubelet of the kind node runs already.
PEER_NAME="cp-peer.$NS.svc.cluster.local"
DNS_IP=10.96.0.10
DNSQ=$(cat /opt/vm-restart/dnsq.sh)
dns_loop() {
  while [ ! -e "$D/.stop" ]; do
    if [ -n "$(first200 host)" ]; then
      printf '%s dns %s\n' "$(up)" "$(timeout 5 docker exec "$NODE" bash -c "$DNSQ" dnsq "$DNS_IP" "$PEER_NAME" 2>&1 | tr '\n' ' ')" >>"$D/loop-dns.log"
    fi
    sleep 1
  done
}
[ "${ETCD_PEER_DNS:-0}" = 1 ] && dns_loop &
probe_loop host "$NODE_IP" &
probe_loop shared "$IP_API" &
for r in a b c; do probe_loop "$r" "${IPS[$r]}" & done

start_s=$(date +%s)
while :; do
  if [ "$(date +%s)" -ge "$((start_s + TIMEOUT))" ]; then
    stamp timeout
    break
  fi
  if ! seen docker-active && systemctl is-active -q docker.service; then stamp docker-active; fi
  if seen docker-active && ! seen kind-node-running &&
    [ "$(docker inspect -f '{{.State.Running}}' "$NODE" 2>/dev/null)" = true ]; then
    stamp kind-node-running
    # The events that Docker has in memory since its start in this boot, and all containers.
    timeout 5 docker events --since "$(date -u -d "@$(awk -v n="$(date +%s)" -v u="$(up)" 'BEGIN {printf "%d", n-u}')" +%FT%TZ)" --until "$(date -u +%FT%TZ)" \
      --format '{{.Time}} {{.Type}} {{.Action}} {{.Actor.Attributes.name}} exitCode={{.Actor.Attributes.exitCode}}' >"$D/docker-events-early.txt" 2>&1
    docker ps -a --no-trunc --format '{{.Names}} | {{.Status}} | {{.Command}}' >"$D/docker-ps-early.txt" 2>&1
  fi
  if [ -n "$(first200 host)" ]; then
    seen host-api-ready || stamp host-api-ready
    # The kubelet of the kind node runs again when it renews its node lease in this boot.
    if ! seen host-kubelet-lease; then
      rt=$("${KC[@]}" -n kube-node-lease get lease "$NODE" -o jsonpath='{.spec.renewTime}' 2>/dev/null || true)
      if [ -n "$rt" ] && [ "$(date -d "$rt" +%s)" -gt "$(awk -v n="$(date +%s)" -v u="$(up)" 'BEGIN {printf "%d", n-u+1}')" ]; then stamp host-kubelet-lease; fi
    fi
    # CoreDNS of the host cluster: all its pods are ready, with a container of this boot.
    if ! seen coredns-ready; then
      cd_out=$("${KC[@]}" -n kube-system get pods -l k8s-app=kube-dns -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{" "}{.status.containerStatuses[0].state.running.startedAt}{"\n"}{end}' 2>/dev/null || true)
      boot_s=$(awk -v n="$(date +%s)" -v u="$(up)" 'BEGIN {printf "%d", n-u}')
      if [ -n "$cd_out" ] && ! awk -v b="$boot_s" '{cmd="date -d " $2 " +%s"; t=0; if ($2 != "") {cmd | getline t; close(cmd)}; if ($1 != "True" || t < b) bad=1} END {exit bad ? 0 : 1}' <<<"$cd_out"; then stamp coredns-ready; fi
    fi
    if ! seen replica-containers-new; then
      n=0
      for r in a b c; do
        # A pod runs again when its container is new and runs.
        new=$("${KC[@]}" -n "$NS" get pod "cp-$r-0" -o jsonpath='{.status.containerStatuses[0].containerID} {.status.containerStatuses[0].state.running.startedAt}' 2>/dev/null || true)
        if [ -n "${new##* }" ] && [ -n "${new%% *}" ] && [ "${new%% *}" != "$(cat "$D/.container-$r-before" 2>/dev/null)" ]; then n=$((n + 1)); fi
      done
      if [ "$n" = 3 ]; then stamp replica-containers-new; fi
    fi
    if seen replica-containers-new && ! seen etcd-quorum; then
      for r in a b c; do
        if timeout 40 kubectl --request-timeout=20s -n "$NS" exec "cp-$r-0" -- sh -c "$ETCDCTL endpoint health" 2>&1 | grep -q 'is healthy'; then
          stamp etcd-quorum
          break
        fi
      done
    fi
    if seen etcd-quorum && ! seen etcd-three-healthy; then
      n=$(timeout 60 kubectl --request-timeout=30s -n "$NS" exec cp-a-0 -- sh -c "$ETCDCTL endpoint health --cluster" 2>&1 | grep -c 'is healthy')
      if [ "$n" = 3 ]; then stamp etcd-three-healthy; fi
    fi
  fi
  if [ -n "$(first200 a)" ] && [ -n "$(first200 b)" ] && [ -n "$(first200 c)" ] && [ -n "$(first200 shared)" ] && seen etcd-three-healthy; then
    stamp all-checks-seen
    break
  fi
  sleep 1
done

# All pods of the host cluster: wait up to 300 s more. The two install pods of kata-deploy are "Completed".
if seen all-checks-seen; then
  for _ in $(seq 1 300); do
    if out=$("${KC[@]}" get pods -A --no-headers 2>/dev/null) && [ -n "$out" ]; then
      x=$(awk '$4 != "Completed" {split($3,a,"/"); if ($4 != "Running" || a[1] != a[2]) print $2}' <<<"$out")
      if [ -z "$x" ]; then
        stamp all-host-pods-ready
        break
      fi
    fi
    sleep 1
  done
fi
sleep 3
touch "$D/.stop"
wait

# The times of the units come from systemd (monotonic clock, zero at the kernel boot).
unit_time() { systemctl show -p "$2" --value "$1" | awk '{if ($1 > 0) printf "%.1f", $1/1e6; else printf "not reached"}'; }
ev() { awk -v n="$1" '$3 == n {printf "%.1f", $1; f=1} END {if (!f) printf "not reached"}' "$T"; }
f200() { x=$(first200 "$1"); if [ -n "$x" ]; then printf '%.1f' "$x"; else printf 'not reached'; fi; }
{
  echo "run $label: seconds after the kernel boot (/proc/uptime)"
  echo "modules loaded (systemd-modules-load.service active): $(unit_time systemd-modules-load.service ActiveEnterTimestampMonotonic)"
  echo "loop devices attached (attach-loops.sh at its end): $(awk '$2=="loops-attached" {printf "%.1f", $1}' /run/vm-restart/boot-times 2>/dev/null || echo "no record")"
  echo "containerd of the VM active: $(unit_time containerd.service ActiveEnterTimestampMonotonic)"
  echo "Docker starts (docker.service start job): $(unit_time docker.service InactiveExitTimestampMonotonic)"
  echo "Docker active: $(unit_time docker.service ActiveEnterTimestampMonotonic)"
  echo "kind node container runs (docker inspect, 1 s steps): $(ev kind-node-running)"
  echo "API server of the host cluster answers /readyz: $(f200 host)"
  echo "kubelet of the kind node renews its node lease: $(ev host-kubelet-lease)"
  echo "containers of the three replicas are new and run: $(ev replica-containers-new)"
  echo "etcd of the inner cluster has quorum (first etcdctl call that commits): $(ev etcd-quorum)"
  echo "three healthy etcd endpoints: $(ev etcd-three-healthy)"
  for r in a b c; do echo "/readyz of replica $r through its Service: $(f200 "$r")"; done
  echo "/readyz through the shared address: $(f200 shared)"
  echo "all pods of the host cluster ready: $(ev all-host-pods-ready)"
  if [ "${ETCD_PEER_DNS:-0}" = 1 ]; then
    now_ips=$("${KC[@]}" -n "$NS" get pods -l g4-role=control-plane -o jsonpath='{range .items[*]}{.status.podIP}{"\n"}{end}' 2>/dev/null | sort -t. -k4n | paste -sd,)
    echo "CoreDNS pods of the host cluster ready: $(ev coredns-ready)"
    echo "first DNS query from the kind node (the loop starts when the API server of the host cluster answers): $(awk 'NR==1 {printf "%.1f", $1}' "$D/loop-dns.log" 2>/dev/null)"
    echo "the name $PEER_NAME first resolves (kind node to $DNS_IP): $(awk '$3=="rcode=0" && $4!="an=0" {printf "%.1f (%s)", $1, $5; f=1; exit} END {if (!f) printf "not reached"}' "$D/loop-dns.log" 2>/dev/null)"
    echo "the name first resolves to the three pod IPs of this boot ($now_ips): $(awk -v w="ips=$now_ips" '$5==w {printf "%.1f", $1; f=1; exit} END {if (!f) printf "not reached"}' "$D/loop-dns.log" 2>/dev/null)"
    echo "DNS answers in order (first time of each different answer): $(awk '{a=$3 " " $4 " " $5; if (a != last) {printf "%.1f:[%s] ", $1, a; last=a}}' "$D/loop-dns.log" 2>/dev/null)"
  fi
  echo "timeout of the watch: $(ev timeout)"
  echo "calls of each loop (all, not 200): $(for w in host shared a b c; do printf '%s %s/%s  ' "$w" "$(grep -c . "$D/loop-$w.log")" "$(awk '$3 != 200' "$D/loop-$w.log" | grep -c .)"; done)"
} >"$D/summary-times.txt" 2>&1
cat "$D/summary-times.txt"

# Records of this boot of the VM.
{
  systemd-analyze 2>&1
  systemctl show -p ActiveEnterTimestamp,ActiveEnterTimestampMonotonic,InactiveExitTimestampMonotonic,Result systemd-modules-load.service vm-restart-guard.service vm-restart-loops.service vm-restart-record.service containerd.service docker.service 2>&1
  cat /run/vm-restart/boot-times 2>&1
} >"$D/vm-units.txt" 2>&1
journalctl --no-pager -b -u docker.service >"$D/vm-docker-journal.txt" 2>&1
journalctl --no-pager -b -u containerd.service >"$D/vm-containerd-journal.txt" 2>&1
journalctl --no-pager -b -u vm-restart-loops.service -u systemd-modules-load.service -u vm-restart-guard.service -u vm-restart-record.service >"$D/vm-boot-units-journal.txt" 2>&1
journalctl --no-pager -b -1 -n 150 >"$D/vm-previous-boot-journal-tail.txt" 2>&1
journalctl --no-pager -b -1 -u docker.service -n 60 >"$D/vm-previous-boot-docker-journal-tail.txt" 2>&1
journalctl --no-pager --list-boots >"$D/vm-boots.txt" 2>&1
journalctl --no-pager -b -k | grep -i -E 'kvm|vhost|loop[0-9]|EXT4-fs|recover|journal|Linux version|Command line' | head -80 >"$D/vm-kernel-lines.txt" 2>&1
docker inspect "$NODE" | jq '.[0] | {State, RestartCount, RestartPolicy: .HostConfig.RestartPolicy, Created}' >"$D/docker-inspect-after.json" 2>&1
docker ps -a --format '{{.Names}}' | while read -r c; do
  docker inspect -f '{{.Name}} policy={{.HostConfig.RestartPolicy.Name}}:{{.HostConfig.RestartPolicy.MaximumRetryCount}} status={{.State.Status}} exit={{.State.ExitCode}} started={{.State.StartedAt}} finished={{.State.FinishedAt}} restarts={{.RestartCount}}' "$c"
done >"$D/docker-containers-after.txt" 2>&1

# The comparison with the state before the restart. It reads only.
/opt/vm-restart/post.sh "$label" >"$D/post.out" 2>&1
tail -5 "$D/post.out"

mv "$STATE/pending" "$D/pending.done"
# A copy for the host, without waiting for an SSH session.
S=/scratch/kata-cp/vm-share
if mountpoint -q "$S"; then
  mkdir -p "$S/results" "$S/status"
  cp -r "$D" "$S/results/" 2>/dev/null
  date -u +%FT%TZ >"$S/status/$label.done"
fi
echo "WATCH DONE $label"
