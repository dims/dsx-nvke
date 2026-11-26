#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Driver on the host for the machine restart test with the etcd DNS option (ETCD_PEER_DNS=1).
# It runs detached from the Claude session and writes its own log, so a session break does not
# stop it. The VM kata-restart must be up, with the inner cluster ready.
#
# Usage: setsid nohup ./drive-dns.sh >/scratch/kata-cp/logs/vm-restart/dns-driver.log 2>&1 &
#
# Runs: three clean restarts (systemctl reboot in the VM) and two power loss runs (limactl stop
# --force, then limactl start). For each run: pre.sh in the VM saves the state, the boot unit
# vm-restart-watch.service measures and compares after the boot, collect.sh copies the record.
# This script has no network code. It calls limactl, ss and the scripts of the first test.
set -uo pipefail
W=/scratch/kata-cp/work/vm-restart
LOGS=/scratch/kata-cp/logs/vm-restart
STATUS=/scratch/kata-cp/vm-share/status
export LIMA_HOME=/scratch/kata-cp/lima XDG_CACHE_HOME=/scratch/kata-cp/lima-install/cache
L=/scratch/kata-cp/lima-install/lima-2.3.0/bin/limactl

say() { echo "== $(date -u +%FT%TZ) $*"; }
vm() { "$W/vm.sh" "$@"; }

# Samples of the QEMU sockets on the host whose peer is a private address, one each second.
socks() {
  local out=$1 n=$2 i
  for i in $(seq 1 "$n"); do
    ss -tnpH 2>/dev/null | grep 'qemu-system' | awk '$5 ~ /^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)/ {print $1, $4, "->", $5}' >>"$out"
    sleep 1
  done
}

wait_done() { # wait_done <label> <seconds>
  local t0
  t0=$(date +%s)
  until [ -e "$STATUS/$1.done" ] || [ $(($(date +%s) - t0)) -ge "$2" ]; do sleep 3; done
  echo "waited $(($(date +%s) - t0)) s for $1"
  [ -e "$STATUS/$1.done" ]
}

pre() { # pre <label>: two tries, 60 s apart
  local label=$1 i
  for i in 1 2; do
    if vm sudo /opt/vm-restart/pre.sh "$label" >"$LOGS/dns-pre-$label.txt" 2>&1 && grep -q "PRE DONE $label" "$LOGS/dns-pre-$label.txt"; then
      tail -3 "$LOGS/dns-pre-$label.txt"
      return 0
    fi
    tail -5 "$LOGS/dns-pre-$label.txt"
    sleep 60
  done
  return 1
}

result() { # result <label>
  local label=$1
  "$W/collect.sh" "$label" >"$LOGS/dns-result-$label.txt" 2>&1
  sed -n '/^-- times/,$p' "$LOGS/dns-result-$label.txt" | grep -v -E '^(before|after):|^[<>]|^---|^[0-9,c]+$|lines in|same pod|regenerating|^   |OK ' | cut -c1-300
  echo "QEMU sockets to a private address during the boot of $label: $(sort "$LOGS/dns-host-qemu-sockets-$label.txt" 2>/dev/null | uniq -c | wc -l) different, $(wc -l <"$LOGS/dns-host-qemu-sockets-$label.txt" 2>/dev/null) samples"
}

clean() { # clean <label>
  local label=$1
  say "clean restart $label"
  pre "$label" || { say "ABORT: pre.sh failed for $label"; return 1; }
  : >"$LOGS/dns-host-qemu-sockets-$label.txt"
  socks "$LOGS/dns-host-qemu-sockets-$label.txt" 120 &
  say "systemctl reboot"
  vm sudo systemctl reboot 2>&1 | tail -2
  wait_done "$label" 600 || say "TIMEOUT: no result file for $label"
  wait
  result "$label"
}

power() { # power <label>
  local label=$1
  say "power loss $label"
  pre "$label" || { say "ABORT: pre.sh failed for $label"; return 1; }
  vm sudo sh -c 'sleep 30; echo "30 s after the state record: uptime $(cut -d" " -f1 /proc/uptime)"'
  : >"$LOGS/dns-host-qemu-sockets-$label.txt"
  say "limactl stop --force (qemu pid $(cat "$LIMA_HOME/kata-restart/qemu.pid" 2>/dev/null))"
  "$L" stop --force kata-restart 2>&1 | grep -E 'SIGKILL'
  "$L" list 2>&1 | tail -1
  socks "$LOGS/dns-host-qemu-sockets-$label.txt" 150 &
  say "limactl start"
  "$L" start --tty=false kata-restart 2>&1 | grep -E 'READY|SSH Local Port|fatal|error' | tail -5
  say "limactl start returned"
  wait_done "$label" 600 || say "TIMEOUT: no result file for $label"
  wait
  result "$label"
}

say "driver start. VM: $("$L" list 2>&1 | tail -1)"
vm sudo sh -c '. /opt/vm-restart/env.sh; echo "ETCD_PEER_DNS=$ETCD_PEER_DNS ETCD_SAN_SKIP=$ETCD_SAN_SKIP ETP=$ETP"; systemctl is-active vm-restart-guard.service; cat /var/lib/vm-restart/pending 2>/dev/null; ls /var/lib/vm-restart/runs | tail -3'
for label in dns-clean-1 dns-clean-2 dns-clean-3; do clean "$label" || break; done
for label in dns-power-1 dns-power-2; do power "$label" || break; done
say "driver end. VM stays up: $("$L" list 2>&1 | tail -1)"
