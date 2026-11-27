#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# The delete of the cluster of T4, with the operator procedure of block D (d/endpoint-run/delete.sh).
# Its step "hosts-down" knows the StatefulSet pods of block D only, so this script takes the pods,
# the namespace and the volumes of T4 away with t4.sh. The other three steps are the steps of delete.sh.
# NOT RUN in step 3: the cluster of T4 stays up.
# Usage: p2-image/test/t4-delete.sh <label>        (label = the run folder under logs/p2, for example t4-run-1)
label=${1:?label}
. /root/kata-cp/bin/env.sh
export LOG_DIR=$W/logs/p2/$label CLUSTER_NAME=kata-cp1 NS=p2c
cd "$W" || exit 1
d/endpoint-run/delete.sh api-delete || exit 1
p2-image/test/t4.sh down || exit 1
p2-image/test/t4.sh wipe || exit 1
d/endpoint-run/delete.sh release || exit 1
d/endpoint-run/delete.sh wait-gone
