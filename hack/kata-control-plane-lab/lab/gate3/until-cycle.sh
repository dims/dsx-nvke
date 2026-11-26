#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Wait until the p3-cycle.sh run ends (at most the given number of seconds), then print its log.
t=${1:-170}
for i in $(seq 1 "$t"); do pgrep -f p3-cycle.sh >/dev/null || break; sleep 1; done
date -u +%T
pgrep -f p3-cycle.sh >/dev/null && echo "cycle still runs" || echo "cycle ended"
