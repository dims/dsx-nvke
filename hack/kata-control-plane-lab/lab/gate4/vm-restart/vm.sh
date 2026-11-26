#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Run a command in the Lima VM kata-restart. Usage: vm.sh <command...>   or   vm.sh < script
# It sets the Lima folders of this test, so that nothing goes to ~/.lima or ~/.cache.
export LIMA_HOME=/scratch/kata-cp/lima
export XDG_CACHE_HOME=/scratch/kata-cp/lima-install/cache
LIMACTL=/scratch/kata-cp/lima-install/lima-2.3.0/bin/limactl
if [ "$#" -eq 0 ]; then
  exec "$LIMACTL" shell --workdir / kata-restart sudo bash -s
fi
exec "$LIMACTL" shell --workdir / kata-restart "$@"
