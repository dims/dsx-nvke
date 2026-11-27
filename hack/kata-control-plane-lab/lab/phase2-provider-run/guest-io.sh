#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Runs inside a node pod (kubectl exec -i ... bash -s). Read only: which block device of the guest
# is busy, how long a sync write takes on each volume, and which process writes.
echo "--- $(hostname) at $(date -u +%T), uptime $(cut -d' ' -f1 /proc/uptime) s"
echo "devices: var $(stat -c '%t:%T' /dev/podvm-var) etcd $(stat -c '%t:%T' /dev/podvm-etcd); mounts: $(findmnt -n -o SOURCE,TARGET /var | tr -s ' '), $(findmnt -n -o SOURCE,TARGET /var/lib/etcd | tr -s ' ')"
awk '$3 ~ /^vd[a-z]$/ {print $3, $1 ":" $2}' /proc/diskstats | tr '\n' ' '; echo
snap() { awk '$3 ~ /^vd[a-z]$/ {print $3, $4, $8, $10, $11, $13, $15, $16, $17}' /proc/diskstats | sort; }
a=$(snap); sleep 5; b=$(snap)
join <(echo "$a") <(echo "$b") | awk '{printf "%s in 5 s: reads %d, writes %d, MB written %.1f, ms in writes %d, io ms %d (busy %d%%), discards %d\n", $1, $10-$2, $11-$3, ($12-$4)/2048, $13-$5, $14-$6, ($14-$6)/50, $15-$7}'
for t in /var/lib/etcd /var/lib/podvm; do
  s=$(date +%s.%N)
  dd if=/dev/zero of="$t/.p2s4-sync-test" bs=8k count=20 oflag=dsync 2>/dev/null
  e=$(date +%s.%N)
  unlink "$t/.p2s4-sync-test"
  awk -v s="$s" -v e="$e" -v t="$t" 'BEGIN {printf "sync write on %s: %.0f ms for each of 20 writes\n", t, (e-s)*1000/20}'
done
for p in /proc/[0-9]*; do w=$(awk '/^write_bytes/ {print $2}' "$p/io" 2>/dev/null); [ -n "$w" ] && echo "${p#/proc/} $w"; done | sort >/run/.p2s4-i1
sleep 5
for p in /proc/[0-9]*; do w=$(awk '/^write_bytes/ {print $2}' "$p/io" 2>/dev/null); [ -n "$w" ] && echo "${p#/proc/} $w"; done | sort >/run/.p2s4-i2
join /run/.p2s4-i1 /run/.p2s4-i2 | awk '{d=($3-$2)/1024; if (d>20) print $1, d}' | sort -k2 -n -r | head -6 | while read -r pid kb; do echo "pid $pid wrote $kb KB in 5 s: $(tr '\0' ' ' <"/proc/$pid/cmdline" | cut -c1-80)"; done
unlink /run/.p2s4-i1; unlink /run/.p2s4-i2
echo "kernel threads: $(ps -eo comm,stat,time | grep -E 'ext4lazyinit|jbd2' | tr -s ' ' | tr '\n' ';')"
echo "etcd: $(curl -s -m 3 http://127.0.0.1:2381/metrics | awk '/^etcd_disk_wal_fsync_duration_seconds_sum/ {s=$2} /^etcd_disk_wal_fsync_duration_seconds_count/ {c=$2} /^etcd_server_leader_changes_seen_total/ {l=$2} /^etcd_server_heartbeat_send_failures_total/ {h=$2} END {printf "WAL fsync mean %.0f ms over %d, leader changes %d, heartbeat send failures %d", s*1000/c, c, l, h}')"
