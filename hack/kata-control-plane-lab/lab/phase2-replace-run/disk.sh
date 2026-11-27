#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# The write time of the disk of the machine, from /proc/diskstats over 10 s. No write test.
# Usage: disk.sh <label>        prints one line and adds it to logs/p2s6/disk.txt
# With WAIT=1: if a write takes more than 15 ms, measure again each minute for up to 20 minutes.
. /root/kata-cp/bin/env.sh
label=${1:-now}
mkdir -p "$W/logs/p2s6"
one() {
  local a b
  a=$(awk '$3=="vda" {print $8, $10, $11, $13}' /proc/diskstats)
  sleep 10
  b=$(awk '$3=="vda" {print $8, $10, $11, $13}' /proc/diskstats)
  echo "$a $b" | awk '{w=$5-$1; printf "%.1f %d %.2f %d", (w ? ($7-$3)/w : 0), w/10, ($6-$2)/2048/10, ($8-$4)/100}'
}
i=0
while :; do
  read -r ms wps mbs busy <<<"$(one)"
  line="$(date -u +%FT%TZ) $label: write time $ms ms, $wps writes each second, $mbs MB each second, busy $busy %, io pressure $(head -1 /proc/pressure/io | cut -d' ' -f2-3)"
  echo "$line" | tee -a "$W/logs/p2s6/disk.txt"
  [ "${WAIT:-0}" = 1 ] || break
  awk -v m="$ms" 'BEGIN {exit !(m > 15)}' || break
  i=$((i + 1))
  [ "$i" -ge 20 ] && { echo "$(date -u +%FT%TZ) $label: still above 15 ms after 20 minutes, go on" | tee -a "$W/logs/p2s6/disk.txt"; break; }
  sleep 50
done
