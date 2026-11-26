#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Gate 5: run one test script detached from the session that starts it. A test then runs to
# its end and writes its record and its line in progress.txt also when that session ends.
#
#   bg.sh <name> <script> [arguments]     start. Example: bg.sh t1-1 ./t1-containerd.sh 1
#   bg.sh --wait <name> [lines]           print the output and wait until the test ends
#
# Files in /scratch/kata-cp/logs/gate5/console/: <name>.out (output), <name>.pid, <name>.rc
# (exit code, written at the end). Variables of the caller (FORCE_RESTART, TEST, ...) reach the
# test through the environment.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
C=${LOG_ROOT:-/scratch/kata-cp/logs/gate5}/console
mkdir -p "$C"

case "${1:-}" in
  --child)
    name=$2
    shift 2
    echo $$ >"$C/$name.pid"
    cd "$HERE" || exit 1
    "$@" >"$C/$name.out" 2>&1
    echo $? >"$C/$name.rc"
    ;;
  --wait)
    name=${2:?name}
    [ -s "$C/$name.pid" ] || { echo "no test with the name $name"; exit 1; }
    # tail ends when the process of the test ends.
    tail --pid="$(cat "$C/$name.pid")" -n "${3:-+1}" -f "$C/$name.out"
    if [ -s "$C/$name.rc" ]; then echo "exit code of $name: $(cat "$C/$name.rc")"; else echo "$name has no exit code yet"; fi
    ;;
  "")
    sed -n '2,/^set -u/p' "$0" | sed '$d'
    exit 1
    ;;
  *)
    name=$1
    shift
    [ ! -e "$C/$name.out" ] || { echo "the name $name is in use ($C/$name.out)"; exit 1; }
    : >"$C/$name.out"
    setsid -f "$0" --child "$name" "$@"
    # Wait for the pid file, so that --wait can follow at once.
    for _ in $(seq 1 50); do [ -s "$C/$name.pid" ] && break; sleep 0.1; done
    echo "started $name: pid $(cat "$C/$name.pid" 2>/dev/null), output $C/$name.out"
    ;;
esac
