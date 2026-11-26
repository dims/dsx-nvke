#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# After a restart test: compare the three replicas with the state before the restart, and run
# the checks of steps 3 and 6 and the node checks. From lab/gate4/cold-start.sh (the part after
# the start). It only reads. watch.sh calls it when the cluster is back or after its timeout.
# Usage: post.sh <label>
set -uo pipefail
label=${1:?label}
. /opt/vm-restart/env.sh
STATE=/var/lib/vm-restart
D=$STATE/runs/$label
export LOG_DIR=$D
. /opt/vm-restart/lib.sh
R=/opt/vm-restart/gate4/run.sh
T=$D/times.txt
seen() { grep -q " $1\$" "$T" 2>/dev/null; }

say "post $label at $(date -u +%FT%TZ), $(cut -d' ' -f1 /proc/uptime) s after kernel boot"
snapshot after
pod_lines >"$D/pods-after.txt" || true
say "node pods before and after (UID, pod IP, restart count)"
paste -d'\n' <(sed 's/ container=.*//; s/^/before: /' "$D/pods-before.txt") <(sed 's/ container=.*//; s/^/after:  /' "$D/pods-after.txt") | tee "$D/pods-before-after.txt"
after_start_record
node sh -c 'journalctl --no-pager -b -u containerd' >"$D/node-containerd-journal.txt" 2>&1 || true
node sh -c 'journalctl --no-pager -b -u kubelet' >"$D/node-kubelet-journal.txt" 2>&1 || true
node sh -c 'systemd-analyze 2>&1; systemctl show -p ActiveEnterTimestamp g4-loop-nodes.service dbus.service containerd.service kubelet.service' >"$D/node-units.txt" 2>&1 || true

# More times of this boot, as wall clock times. boot.txt has the wall clock time of the kernel boot.
{
  say "pod Ready condition of each replica: time of its last change (the kubelet calls /readyz of the API server through the pod IP)"
  k -n "$NS" get pods -o jsonpath='{range .items[*]}{.metadata.name}{" ready="}{.status.conditions[?(@.type=="Ready")].status}{" since="}{.status.conditions[?(@.type=="Ready")].lastTransitionTime}{" container-started="}{.status.containerStatuses[0].state.running.startedAt}{"\n"}{end}' || true
  say "etcd of each replica in this boot: start of the member, leader election, ready to serve"
  for r in a b c; do
    k -n "$NS" exec "cp-$r-0" -- sh -c 'c=$(crictl ps --name etcd -q | head -1); crictl logs $c 2>&1 | grep -E "restarting local member|elected leader|became leader|ready to serve client requests|serving client traffic securely" | head -8 | cut -c1-330' 2>&1 | sed "s/^/cp-$r: /" || true
    k -n "$NS" exec "cp-$r-0" -- sh -c 'crictl ps -a --name "etcd|kube-apiserver" | cut -c1-150' 2>&1 | sed "s/^/cp-$r: /" || true
  done
  if [ "${ETCD_PEER_DNS:-0}" = 1 ]; then
    say "CoreDNS pods of the host cluster: Ready since, container started"
    k -n kube-system get pods -l k8s-app=kube-dns -o jsonpath='{range .items[*]}{.metadata.name}{" ready="}{.status.conditions[?(@.type=="Ready")].status}{" since="}{.status.conditions[?(@.type=="Ready")].lastTransitionTime}{" container-started="}{.status.containerStatuses[0].state.running.startedAt}{" restarts="}{.status.containerStatuses[0].restartCount}{" ip="}{.status.podIP}{"\n"}{end}' || true
    say "EndpointSlice of the headless Service cp-peer, and the pod IPs"
    k -n "$NS" get endpointslices -l kubernetes.io/service-name=cp-peer -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{" ready="}{.conditions.ready}{" pod="}{.targetRef.name}{"\n"}{end}' || true
    say "etcd peer check: lines \"rejected connection on peer endpoint\" in the etcd log of each replica (all etcd containers of this boot)"
    for r in a b c; do
      k -n "$NS" exec "cp-$r-0" -- sh -c 'for c in $(crictl ps -a --name etcd -q); do crictl inspect -o go-template --template "{{.status.metadata.attempt}} {{.status.state}} {{.status.createdAt}}" $c | sed "s/^/etcd container attempt, state, created: /"; done; c=$(crictl ps --name etcd -q | head -1); crictl logs $c >/tmp/etcd-now.log 2>&1; echo "rejected lines: $(grep -c "rejected connection on peer endpoint" /tmp/etcd-now.log)"; grep "rejected connection on peer endpoint" /tmp/etcd-now.log | head -1 | cut -c1-900 | sed "s/^/first: /"; grep "rejected connection on peer endpoint" /tmp/etcd-now.log | tail -1 | cut -c1-200 | sed "s/^/last: /"; echo "by remote address and error:"; grep "rejected connection on peer endpoint" /tmp/etcd-now.log | sed -E "s/.*\"remote-addr\":\"([0-9.]+):[0-9]+\".*\"error\":\"(.*)\"\}.*/\1 | \2/" | cut -c1-260 | sort | uniq -c; echo "peer lines:"; grep -E "peer became active|established TCP streaming connection with remote peer|initial corruption checking passed|failed hash kv request|prober detected unhealthy status" /tmp/etcd-now.log | sed -E "s/.*\"ts\":\"([^\"]+)\".*\"msg\":\"([^\"]+)\".*/\1 \2/" | awk "{k=\$2 \" \" \$3 \" \" \$4; c[k]++; if (c[k] <= 2) print}" | head -12' 2>&1 | sed "s/^/cp-$r: /" || true
    done
  fi
  say "MetalLB speaker containers of this boot"
  k -n metallb-system get pods -l app.kubernetes.io/component=speaker -o jsonpath='{range .items[*].status.containerStatuses[*]}{.name}{" restarts="}{.restartCount}{" last: exit="}{.lastState.terminated.exitCode}{" started="}{.lastState.terminated.startedAt}{" finished="}{.lastState.terminated.finishedAt}{" now: started="}{.state.running.startedAt}{"\n"}{end}' || true
  k -n metallb-system logs -l app.kubernetes.io/component=speaker --previous --tail=3 2>&1 | cut -c1-330 || true
} >"$D/more-times.txt" 2>&1

fail=0
seen all-checks-seen || {
  echo "FAIL: the cluster did not return inside the time of the watch"
  fail=1
  "$R" diag restart-failed || true
}
say "pod UIDs (must be the same)"
for r in a b c; do
  b=$(awk -v n="cp-$r-0" '$1==n {print $2}' "$D/pods-before.txt")
  a=$(awk -v n="cp-$r-0" '$1==n {print $2}' "$D/pods-after.txt")
  if [ -n "$b" ] && [ "$a" = "$b" ]; then echo "cp-$r-0: same pod, $a"; else
    echo "FAIL: cp-$r-0 has another UID: before $b, after $a"
    fail=1
  fi
done
say "identity of each replica (only pod-ip and boot-id may differ)"
"$R" identity after
for r in a b c; do
  if diff "$D/identity-$r-before.txt" "$D/identity-$r-after.txt" >"$D/.diff"; then
    echo "cp-$r: no difference (the pod IP did not change)"
  else
    cat "$D/.diff"
    if grep -E '^[<>]' "$D/.diff" | grep -v -E '^[<>] (pod-ip|boot-id) ' | grep -q .; then
      echo "FAIL: the identity of cp-$r changed"
      fail=1
    else
      echo "cp-$r: only the pod IP and the boot ID changed"
    fi
  fi
  [ "$(grep -c . "$D/identity-$r-after.txt")" = "$(grep -c . "$D/identity-$r-before.txt")" ] && [ "$(grep -c . "$D/identity-$r-after.txt")" -ge 30 ] ||
    { echo "FAIL: the identity file of cp-$r is not complete"; fail=1; }
  echo "cp-$r: lines of the pod log with \"regenerating the certificate\": $(k -n "$NS" logs "cp-$r-0" 2>/dev/null | grep -a -c 'regenerating the certificate' || true)"
done
"$R" check 5-after-restart | tail -1 || fail=1
"$R" reach 5-after-restart | tail -1 || fail=1
if [ "${ETCD_PEER_DNS:-0}" = 1 ]; then "$R" peercheck 5-after-restart | tail -1 || fail=1; fi
node_checks
if grep -q '^FAIL' "$D/node-checks-after.txt"; then fail=1; fi
free -m | sed -n 1,2p
if [ "$fail" = 0 ]; then echo "RESULT restart $label: PASS"; else echo "RESULT restart $label: FAIL"; fi
