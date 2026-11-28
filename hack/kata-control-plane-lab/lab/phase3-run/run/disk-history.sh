#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Read-only: the recorded history of the disk of the machine (sysstat), and the look of now.
# Times of sar are the local time of the machine. This script prints UTC beside them.
# Usage: disk-history.sh [from, local HH:MM:SS] [sysstat file]
export LC_ALL=C
from=${1:-12:50:00}
f=${2:-/var/log/sysstat/sa$(date +%d)}
off=$(( ($(date -u +%s) - $(date -u -d "$(date '+%F %T')" +%s)) / 3600 ))   # hours to add for UTC
utc() { awk -v o="$off" '{split($1, t, ":"); h=(t[1] + o) % 24; printf "%02d:%s:%s", h, t[2], t[3]; $1=""; print}'; }
echo "== disk vda, 10 minute windows (end of the window, UTC): requests/s, MB written/s, time for a request in ms, busy %"
sar -d -p -f "$f" -s "$from" 2>/dev/null | awk '$NF=="vda" {printf "%s %s %.1f %s %s\n", $1, $2, $4/1024, $8, $9}' | utc
echo "== I/O pressure (some), 10 minute windows (end of the window, UTC): mean of the window in %"
sar -q IO -f "$f" -s "$from" 2>/dev/null | awk 'NR>3 && $1 != "Average:" {print $1, $5}' | utc | tr '\n' ';'; echo
echo "== now, $(date -u +%FT%TZ): $(head -1 /proc/pressure/io)"
