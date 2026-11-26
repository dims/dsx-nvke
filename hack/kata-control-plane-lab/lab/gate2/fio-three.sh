#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Gate 2, extra test: the fio sync write test in three places at the same time, each on its own
# loop device. The three backing files are on the same disk, as the three etcd members of the
# gate 4 cluster are. The test shows what three sync streams on one disk do to each stream.
# Usage: fio-three.sh <place> <run number>     (place: host-loop, runc-block or kata-block)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PLACE=${1:?place}
RUN=${2:?run number}
BASE=${BASE:-/scratch/kata-cp/logs/gate2/fio3}
# stream: image file, loop device
STREAMS=("fio-1 /dev/loop28" "spare-1 /dev/loop30" "etcd-2 /dev/loop25")
if [ "$PLACE" != host-loop ]; then
  for i in 0 1 2; do
    set -- ${STREAMS[$i]}
    NS=gate2-fio-s$i IMG=$1 LOOP=$2 "$HERE/fio-run.sh" setup >/dev/null
  done
fi
for i in 0 1 2; do
  set -- ${STREAMS[$i]}
  NS=gate2-fio-s$i IMG=$1 LOOP=$2 LOG_DIR=$BASE/s$i "$HERE/fio-run.sh" "$PLACE" "$RUN" 2>&1 | grep -v 'Operation forced' | sed "s/^/stream $i /" &
done
wait
