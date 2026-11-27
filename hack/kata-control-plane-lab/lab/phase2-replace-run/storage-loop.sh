#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Lab plumbing in the place of a storage driver, in the background during a test: each 10 s make
# each Released volume again (delete the volume, wipe the device, make the volume).
# Usage (detached): setsid nohup p2-replace/storage-loop.sh >logs/p2s6/storage-loop.out 2>&1 &
# Stop: touch /root/kata-cp/work/.storage-loop-stop
. /root/kata-cp/bin/env.sh
STOP=$W/work/.storage-loop-stop
[ -e "$STOP" ] && unlink "$STOP"
echo "== $(utc) storage loop start"
while [ ! -e "$STOP" ]; do
  out=$("$W/p2-provider/storage.sh" reset 2>&1 | grep -E 'made again|ERROR' | grep -v 'volumes made again: 0' || true)
  [ -n "$out" ] && echo "$out" | sed "s/^/$(date -u +%T) /"
  sleep 10
done
unlink "$STOP"
echo "== $(utc) storage loop stop"
