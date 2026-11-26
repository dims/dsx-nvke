#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Attach each sparse file of the lab to its fixed loop device, with direct I/O.
# The table has one line for each device: <loop device> <file>.
# The unit vm-restart-loops.service runs this script at each boot, before Docker starts.
set -euo pipefail
TABLE=/var/lib/vm-restart/disks/loop-table
MAP=/var/lib/vm-restart/disks/loop-map.txt
while read -r dev file; do
  [ -n "$dev" ] || continue
  n=${dev#/dev/loop}
  now=$(cat "/sys/block/loop$n/loop/backing_file" 2>/dev/null || true)
  if [ "$now" = "$file" ]; then
    echo "$dev is attached to $file"
  elif [ -n "$now" ]; then
    echo "ERROR: $dev is attached to $now, not to $file" >&2
    exit 1
  else
    # losetup adds the device with this number if the kernel does not have it.
    losetup --direct-io=on "$dev" "$file"
    echo "$dev: attached $file"
  fi
  [ "$(cat "/sys/block/loop$n/loop/dio")" = 1 ] || { echo "ERROR: $dev has no direct I/O" >&2; exit 1; }
done <"$TABLE"
losetup -l -n -O NAME,BACK-FILE,DIO | awk 'index($2, "/var/lib/vm-restart/disks/") == 1' | sort -k2 >"$MAP"
mkdir -p /run/vm-restart
echo "$(cut -d' ' -f1 /proc/uptime) loops-attached" >>/run/vm-restart/boot-times
echo "loop devices attached at $(cut -d' ' -f1 /proc/uptime) s after kernel boot: $(wc -l <"$MAP")"
