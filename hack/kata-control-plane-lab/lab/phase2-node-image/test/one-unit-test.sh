#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Why the image has two bootstrap units: a test with ONE unit that is ordered before the SPIRE agent
# and runs the files and the commands. The pod gets a command (test only) that changes the unit of
# the image and then runs the entry point of the image. The data is "full": its last command is the
# command of NVKE, "systemctl restart nke-agent.service".
# Usage: one-unit-test.sh        (slot t1 of t123.sh must be free)
set -euo pipefail
. /root/kata-cp/bin/env.sh
HERE="$(cd "$(dirname "$0")" && pwd)"
T=$HERE/t123.sh
OUT=$W/logs/p2/t123/one-unit-test.txt
M=p2t-cp-1a2b3c4d
k() { docker exec kata-bb-control-plane kubectl --kubeconfig /etc/kubernetes/admin.conf "$@"; }
"$T" base >/dev/null
"$T" wipe t1 >/dev/null
"$T" render volumes.yaml.tmpl t1 | docker exec -i kata-bb-control-plane kubectl --kubeconfig /etc/kubernetes/admin.conf apply -f - >/dev/null
docker exec -i kata-bb-control-plane kubectl --kubeconfig /etc/kubernetes/admin.conf -n p2 create secret generic "$M-bootstrap-data" --from-file=value=/dev/stdin <"$W/p2-image/out/fixtures/full.userdata.yaml" >/dev/null
"$T" render pod.yaml.tmpl t1 | awk '{print} /^      image: / {
  print "      # TEST ONLY: one unit in place of two.";
  print "      command: [\"/bin/sh\", \"-c\"]";
  print "      args:";
  print "        - |";
  print "          sed -i \"s|^ExecStart=.*|&\\nExecStart=/usr/local/bin/podvm-bootstrap -phase commands|\" /etc/systemd/system/podvm-bootstrap.service";
  print "          rm -f /etc/systemd/system/multi-user.target.wants/podvm-bootstrap-final.service";
  print "          exec /usr/local/bin/podvm-entrypoint" }' >"$W/logs/p2/t123/pod-one-unit.yaml"
docker exec -i kata-bb-control-plane kubectl --kubeconfig /etc/kubernetes/admin.conf apply -f - <"$W/logs/p2/t123/pod-one-unit.yaml"
k -n p2 wait --for=jsonpath='{.status.phase}'=Running "pod/$M" --timeout=120s
look() {
  echo "== $1: $(date -u +%T), pod age $(( $(date +%s) - t0 )) s"
  k -n p2 exec "$M" -- sh -c 'echo "system state: $(systemctl is-system-running)"; echo "cloud-init: $(cloud-init status | head -1)"
    systemctl cat podvm-bootstrap | grep -E "^(Before|After|ExecStart)="
    echo "unit: active=$(systemctl is-active podvm-bootstrap) sub=$(systemctl show -p SubState --value podvm-bootstrap) since $(systemctl show -p ExecMainStartTimestamp --value podvm-bootstrap)"
    echo "--- jobs"; systemctl list-jobs --no-pager | head -12
    echo "--- processes of the unit"; systemd-cgls --no-pager -u podvm-bootstrap.service 2>/dev/null | tail -4
    echo "--- agent units: spire-agent $(systemctl is-active spire-agent), nvke-agent $(systemctl is-active nvke-agent), port 15005 listeners $(ss -ltnH | grep -c ":15005 ")"
    echo "--- journal of the unit"; journalctl -b --no-pager -o short-precise -u podvm-bootstrap | grep -E "RESULT|podvm-bootstrap:" | cut -c1-220
    echo "--- command output"; cat /var/lib/podvm/bootstrap/output.log 2>/dev/null | cut -c1-160; echo "commands marker: $(cat /var/lib/podvm/bootstrap/commands 2>/dev/null)"' 2>&1
}
t0=$(date +%s)
{
  echo "== one unit test at $(date -u +%FT%TZ): podvm-bootstrap.service runs the files phase and the commands phase, Before=spire-agent.service"
  sleep 100
  look "first look"
  sleep 60
  look "second look"
} 2>&1 | tee "$OUT"
"$T" down >/dev/null 2>&1
echo "== test pod and volumes removed" | tee -a "$OUT"
