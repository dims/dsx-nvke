# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Tool image of gate 2: fio for the sync write test, and the patch generator.
# Build context: /scratch/kata-cp/gate2-build (it holds the patcher binary).
FROM debian:trixie-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends fio e2fsprogs util-linux jq \
 && rm -rf /var/lib/apt/lists/*
COPY patcher /usr/local/bin/patcher
