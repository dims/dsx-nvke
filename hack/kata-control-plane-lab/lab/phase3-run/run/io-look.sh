# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Read-only: write latency of the disk and of the lab loop devices over 10 s, and the top writers.
snap() { awk '$3 ~ /^(vd[a-z]|loop6[0-9]|loop7[01])$/ {print $3, $8, $10, $11, $13, $16, $17}' /proc/diskstats; }
procs() { for p in /proc/[0-9]*; do [ -r "$p/io" ] || continue; echo "${p#/proc/} $(awk '/^write_bytes/ {w=$2} /^syscw/ {s=$2} END {print w, s}' "$p/io" 2>/dev/null) $(cat "$p/comm" 2>/dev/null | tr ' ' '_')"; done | sort -k1,1; }
procs >/tmp/.p1; snap >/tmp/.io1; t1=$(date +%s.%N); sleep 10; snap >/tmp/.io2; t2=$(date +%s.%N); procs >/tmp/.p2
echo "== $(date -u +%T) devices over $(echo "$t2 $t1" | awk '{printf "%.1f", $1-$2}') s"
join /tmp/.io1 /tmp/.io2 | awk '{w=$8-$2; mb=($9-$3)*512/1e6; wt=$10-$4; busy=$11-$5; fl=$12-$6; flt=$13-$7; if (w > 0) printf "%s: %d writes, %.1f MB, mean write time %.0f ms, busy %d ms, %d flushes with mean %.0f ms\n", $1, w, mb, wt/w, busy, fl, (fl > 0 ? flt/fl : 0)}'
echo "== top writers over the interval (MB written to storage, write calls), without processes that count their ended children"
join /tmp/.p1 /tmp/.p2 | awk '{w=($5-$2)/1e6; s=$6-$3; if (w > 0.3 && w < 500) printf "%.1f MB %d calls %s pid %s\n", w, s, $7, $1}' | sort -k1,1nr | head -10
echo "io pressure: $(head -1 /proc/pressure/io)"
for f in /tmp/.io1 /tmp/.io2 /tmp/.p1 /tmp/.p2; do unlink $f; done
