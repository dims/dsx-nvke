#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Gate 5: one table row for each run that has loop data, from the files of the run. It reads
# only /scratch/kata-cp/logs/gate5/.
#
#   table.sh [run folder names...]      default: each folder with an analysis.txt
#
# Columns: run, action time, longest time between two good calls of each address (shared, a,
# b, c), failed calls (shared+a+b+c), etcd leader and raft term before and after, pod restart
# counts before and after, guest boot IDs that stayed, values of kv.txt that differ, the main
# PID of containerd and of the kubelet before and after, files of /opt/kata that were written again (new change time).
set -uo pipefail
export LC_ALL=C
LOG_ROOT=${LOG_ROOT:-/scratch/kata-cp/logs/gate5}
cd "$LOG_ROOT" || exit 1
if [ $# -gt 0 ]; then runs=("$@"); else
  runs=()
  for d in */; do [ -s "$d/analysis.txt" ] && runs+=("${d%/}"); done
fi
kv() { grep "^cp-$3-0 $4=" "$1/state-$2/kv.txt" 2>/dev/null | cut -d= -f2-; }
pid() { sed -n '/^== SUMMARY/,/^== END SUMMARY/p' "$1/state-$2/node.txt" 2>/dev/null | awk -v u="$3: MainPID=" 'index($0, u) == 1 {split(substr($0, length(u) + 1), x, " "); print x[1]}'; }
short() { # the replica name of an etcd member ID, from the member list of the state
  local id=$2 n
  n=$(kv "$1" before a etcd_members | tr '{' '\n' | grep "\"ID\":\"$id\"" | sed -E 's/.*"name":"([^"]+)".*/\1/')
  echo "${n:-$id}"
}
echo "run | started (UTC) | gap shared | gap a | gap b | gap c | failed calls | leader/term before | leader/term after | restarts before | restarts after | boot IDs kept | values that differ | containerd PID | kubelet PID | /opt/kata files written again"
for d in "${runs[@]}"; do
  [ -d "$d" ] || continue
  t0=$(awk '$2=="action-start" {x=$1} END {print x}' "$d/times.txt" 2>/dev/null)
  [ -n "$t0" ] || t0=$(awk '$2=="loops-started" {x=$1} END {print x}' "$d/times.txt" 2>/dev/null)
  when=$(date -u -d "@${t0%.*}" +%H:%M:%S 2>/dev/null)
  gaps=$(awk '/^(shared|a|b|c): [0-9]+ calls/ {for (i = 1; i <= NF; i++) if ($i == "calls:") printf "%s | ", $(i + 1)}' "$d/analysis.txt" 2>/dev/null)
  failed=$(awk '/^(shared|a|b|c): [0-9]+ calls/ {f += $4; n += $2} END {printf "%d of %d", f, n}' "$d/analysis.txt" 2>/dev/null)
  same=0
  for r in a b c; do [ -n "$(kv "$d" before "$r" boot_id)" ] && [ "$(kv "$d" before "$r" boot_id)" = "$(kv "$d" after "$r" boot_id)" ] && same=$((same + 1)); done
  ndiff=$(diff <(grep -v ' ready_since=' "$d/state-before/kv.txt" 2>/dev/null) <(grep -v ' ready_since=' "$d/state-after/kv.txt" 2>/dev/null) | grep -c '^[<>]')
  # The change time (field 6 of the list) shows that a file was written again. Lists of the
  # first runs have no such field.
  if cmp -s "$d/state-before/opt-kata.lst" "$d/state-after/opt-kata.lst"; then
    inodes=0 # each file has the same inode, size and times as before
  elif [ "$(awk 'NF >= 6' "$d/state-before/opt-kata.lst" 2>/dev/null | wc -l)" -gt 0 ]; then
    inodes=$(join -j2 <(awk '{print $6, $5}' "$d/state-before/opt-kata.lst" | sort -k2) <(awk '{print $6, $5}' "$d/state-after/opt-kata.lst" | sort -k2) | awk '$2 != $3 {n++} END {print n + 0}')
  elif [ -s "$d/opt-kata-ctime-taken-after-run.lst" ]; then
    inodes=$(awk -v a="$t0" '$1 >= a {n++} END {print n + 0}' "$d/opt-kata-ctime-taken-after-run.lst")
  else
    inodes="not recorded"
  fi
  echo "$d | $when | ${gaps}$failed | $(short "$d" "$(kv "$d" before a etcd_leader)")/$(kv "$d" before a etcd_raft_term) | $(short "$d" "$(kv "$d" after a etcd_leader)")/$(kv "$d" after a etcd_raft_term) | $(kv "$d" before a restarts),$(kv "$d" before b restarts),$(kv "$d" before c restarts) | $(kv "$d" after a restarts),$(kv "$d" after b restarts),$(kv "$d" after c restarts) | $same of 3 | $((ndiff / 2)) | $(pid "$d" before containerd) -> $(pid "$d" after containerd) | $(pid "$d" before kubelet) -> $(pid "$d" after kubelet) | $inodes of $(wc -l <"$d/state-after/opt-kata.lst" 2>/dev/null)"
done
