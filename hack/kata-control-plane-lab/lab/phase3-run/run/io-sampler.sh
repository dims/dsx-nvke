#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Read-only: one line each 10 s with the I/O pressure of the machine. Detached, with a time limit.
# Usage (detached): io-sampler.sh <out file> [seconds]     Stop: touch <out file>.stop
OUT=${1:?out file}
SECS=${2:-7200}
end=$(( $(date +%s) + SECS ))
while [ "$(date +%s)" -lt "$end" ] && [ ! -e "$OUT.stop" ]; do
  echo "$(date -u +%T) $(head -1 /proc/pressure/io | cut -d' ' -f2-4)" >>"$OUT"
  sleep 10
done
