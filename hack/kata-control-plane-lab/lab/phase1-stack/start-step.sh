#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Start one install step detached from the terminal and from the session, so that it runs
# to its end when the session breaks.
#
# Use:
#   ./start-step.sh NN         start step NN of install.sh, print the PID and the output file
#
# The step writes its own log and one line into progress.txt (see run_step in install.sh).
# The output file run-NN-<time>.out has the same text as the step log, plus errors of the
# shell. To wait for the end with no polling: tail --pid=<PID> -f /dev/null
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
. "$HERE/env.sh"

n="${1:-}"
case "$n" in
  [0-9][0-9]) ;;
  *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac

mkdir -p "$LOG_DIR"
out="$LOG_DIR/run-${n}-$(date +%Y%m%d-%H%M%S).out"
setsid nohup "$HERE/install.sh" "$n" > "$out" 2>&1 < /dev/null &
pid="$!"
echo "$pid" > "$LOG_DIR/run-${n}.pid"
echo "step $n started: pid $pid, output $out"
