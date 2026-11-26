#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Gate 5: read the loop logs of one run and print the numbers of the run.
#
#   analyze.sh <log folder of the run>
#
# Time 0 is the stamp "action-start" of times.txt (the last one), or the start of the loops when
# the run has no action. A time "+3.20 s" is 3.2 s after time 0. The guest logs have the clock
# of the guest. The script moves them to the clock of the host with clock-offsets.txt (error
# about 0.1 s).
#
# Lines that start with FAIL are faults against the pass rule:
#   - a node pod has a new UID, pod IP, container or restart count,
#   - the etcd leader or the raft term changed,
#   - the time between two good calls of one address is longer than GAP_LIMIT (default 5 s),
#   - the guest heartbeat has a hole longer than HOLE_LIMIT (default 2 s).
# Failed calls inside a shorter gap are printed with their count and their error text.
set -uo pipefail
export LC_ALL=C # one sort order for sort, comm and join
OUT=${1:?log folder}
GAP_LIMIT=${GAP_LIMIT:-5}
HOLE_LIMIT=${HOLE_LIMIT:-2}
T0=$(awk '$2=="action-start" {x=$1} END {print x}' "$OUT/times.txt" 2>/dev/null)
T1=$(awk '$2=="action-returned" || $2=="rollout-done" || $2=="action-end" {x=$1} END {print x}' "$OUT/times.txt" 2>/dev/null)
ZERO="the action start"
if [ -z "$T0" ]; then
  # A run with no action (the control run): time 0 is the start of the loops.
  T0=$(awk '$2=="loops-started" {x=$1} END {print x}' "$OUT/times.txt" 2>/dev/null)
  ZERO="the start of the loops (the run has no action)"
fi

{
  echo "== analysis of $(basename "$OUT")"
  if [ -n "$T0" ]; then
    echo "time 0 is $ZERO: $(date -u -d "@${T0%.*}" +%FT%TZ) ($T0). ${T1:+Action end: $(awk -v a="$T0" -v b="$T1" 'BEGIN {printf "%+.2f s", b-a}')}"
  else
    echo "no stamp for time 0. Times are clock values."
  fi
  echo "stamps of the run, in seconds after time 0:"
  sort -n "$OUT/times.txt" | awk -v t0="$T0" '{printf "   %s %s\n", (t0 == "" ? $1 : sprintf("%+9.2f", $1 - t0)), $2}'

  echo
  echo "== 1. /readyz from the kind node, through the Services (a new connection for each call)"
  for w in shared a b c; do
    f="$OUT/readyz-$w.log"
    [ -s "$f" ] || { echo "$w: no data"; continue; }
    awk -v name="$w" -v t0="$T0" -v lim="$GAP_LIMIT" '
      function rel(t) { return t0 == "" ? sprintf("%.2f", t) : sprintf("%+.2f s", t - t0) }
      { n++
        if ($3 == "200") {
          if (last != "") { g = $1 - last; gs[++ng] = g; if (g > maxg) { maxg = g; ga = last; gb = $1 } }
          last = $1
        } else {
          bad++
          m = "http " $3 ", curl exit " $5 ","
          for (i = 6; i <= NF; i++) m = m " " $i
          err[m]++
          if (fb == "") fb = $1
          lb = $1
        }
      }
      END {
        asort(gs)
        med = ng ? gs[int((ng + 1) / 2)] : 0
        printf "%s: %d calls, %d failed. Longest time between two good calls: %.3f s (from %s to %s). Median: %.3f s\n", name, n, bad, maxg, rel(ga), rel(gb), med
        if (bad) {
          printf "   failed calls from %s to %s:\n", rel(fb), rel(lb)
          for (m in err) printf "   %d x %s\n", err[m], m
        }
        if (maxg > lim) printf "FAIL: %s: %.2f s between two good calls (limit %s s)\n", name, maxg, lim
        if ($3 != "200") printf "FAIL: %s: the last call of the log failed. No good call after %s\n", name, rel(last)
      }' "$f"
  done

  echo
  echo "== 2. In each guest (unit g5-guest of the node pod)"
  for r in a b c; do
    off=$(awk -v p="cp-$r" '$1==p {split($2,a,"="); split($3,g,"="); split($4,b,"="); o = sprintf("%.3f", g[2] - (a[2] + b[2]) / 2)} END {print o}' "$OUT/clock-offsets.txt" 2>/dev/null)
    off=${off:-0}
    echo "-- cp-$r (guest clock minus host clock: $off s)"
    f="$OUT/guest-$r-heartbeat.log"
    if [ -s "$f" ]; then
      awk -v t0="$T0" -v off="$off" -v lim="$HOLE_LIMIT" '
        function rel(t) { return t0 == "" ? sprintf("%.2f", t) : sprintf("%+.2f s", t - off - t0) }
        { n++; if (last != "") { g = $1 - last; gs[++ng] = g; if (g > maxg) { maxg = g; at = last; ug = $2 - lastu } } last = $1; lastu = $2 }
        END {
          asort(gs)
          printf "   heartbeat: %d samples (a sleep of 0.2 s between two). Time between two samples: median %.3f s, 99 percent below %.3f s, longest %.3f s at %s (guest uptime moved %.2f s in it)\n", n, (ng ? gs[int((ng + 1) / 2)] : 0), (ng ? gs[int(ng * 0.99) > 0 ? int(ng * 0.99) : 1] : 0), maxg, rel(at), ug
          if (maxg > lim) printf "FAIL: the guest heartbeat has a hole of %.2f s (limit %s s)\n", maxg, lim
        }' "$f"
    else
      echo "   heartbeat: no data"
    fi
    f="$OUT/guest-$r-local-readyz.log"
    if [ -s "$f" ]; then
      awk -v t0="$T0" -v off="$off" '
        function rel(t) { return t0 == "" ? sprintf("%.2f", t) : sprintf("%+.2f s", t - off - t0) }
        { n++; if ($3 != "200") { bad++; if (fb == "") fb = $1; lb = $1; m = "http " $3 ", curl exit " $5; err[m]++ } }
        END {
          printf "   /readyz on 127.0.0.1 in the guest: %d calls, %d failed", n, bad
          if (bad) { printf " (from %s to %s:", rel(fb), rel(lb); for (m in err) printf " %d x %s;", err[m], m; printf ")" }
          printf "\n"
        }' "$f"
    else
      echo "   /readyz in the guest: no data"
    fi
    f="$OUT/guest-$r-etcd.log"
    if [ -s "$f" ]; then
      awk -v t0="$T0" -v off="$off" '
        function rel(t) { return t0 == "" ? sprintf("%.2f", t) : sprintf("%+.2f s", t - off - t0) }
        $2 == "status" {
          n++
          if ($3 == "ERR") { err++; if (fe == "") fe = $1; le = $1; next }
          l = ""; tm = ""
          if (match($0, /"leader":"[0-9]+"/)) l = substr($0, RSTART + 10, RLENGTH - 11)
          if (match($0, /"term":"[0-9]+"/)) tm = substr($0, RSTART + 8, RLENGTH - 9)
          v = "leader " l ", raft term " tm
          if (v != prev) { ch++; line[ch] = sprintf("      %s: %s", rel($1), v); prev = v }
        }
        $2 == "members" {
          if ($3 == "ERR") next
          if ($3 != pm) { mc++; mline[mc] = sprintf("      %s: %s", rel($1), $3); pm = $3 }
        }
        END {
          printf "   etcd status: %d samples, %d with no answer", n, err
          if (err) printf " (from %s to %s)", rel(fe), rel(le)
          printf ". Values of leader and raft term: %d\n", ch
          for (i = 1; i <= ch; i++) print line[i]
          printf "   etcd member list: %d different values\n", mc
          if (mc > 1) for (i = 1; i <= mc; i++) print mline[i]
          if (ch > 1) print "FAIL: the etcd leader or the raft term changed"
          if (mc > 1) print "FAIL: the etcd member list changed"
        }' "$f"
    else
      echo "   etcd: no data"
    fi
  done

  echo
  echo "== 3. The kind node and the host cluster (one sample each second, a line for each change)"
  if [ -s "$OUT/k8s.log" ]; then
    awk -v t0="$T0" '
      function rel(t) { return t0 == "" ? sprintf("%.2f", t) : sprintf("%+.2f s", t - t0) }
      function podid(v,    i, k, f, s, p) {
        s = ""
        k = split(v, p, " ")
        for (i = 1; i <= k; i++) { split(p[i], f, "|"); s = s f[1] "|" f[2] "|" f[3] "|" f[4] "|" f[6] " " }
        return s
      }
      {
        kind = $2; t = $1
        v = $0; sub(/^[^ ]+ [^ ]+ ?/, "", v)
        if (!(kind in prev)) printf "   %s %s: %s\n", rel(t), kind, v
        else if (v != prev[kind]) {
          printf "   %s %s changed: %s\n", rel(t), kind, v
          nch[kind]++
          if (kind == "pods" && podid(v) != podid(prev[kind])) bad = 1
        }
        prev[kind] = v
      }
      END {
        printf "   changes: pods %d, endpoints of the shared Service %d, node %d, handlers %d, units %d, Kata processes %d, kata-deploy objects %d\n", nch["pods"], nch["eps"], nch["node"], nch["handlers"], nch["units"], nch["kata"], nch["kd"]
        if (bad) print "FAIL: a node pod has a new UID, pod IP, container or restart count"
        if (nch["kata"]) print "NOTE: the list of Kata processes changed (a new program path with \"(deleted)\" is normal after an install)"
      }' "$OUT/k8s.log"
  else
    echo "no data"
  fi
} 2>&1 | tee "$OUT/analysis.txt"
