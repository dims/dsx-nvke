#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Pass rule 2: the key rotation of the etcd encryption (the operator start of the product page).
# The rotation needs encryption on. If the cluster has it off, the chain turns it on first through
# the NVKE API, with the same two watches.
# Usage (detached): setsid nohup p2-gaps/p2gaps-t2.sh <label> >logs/p2gaps/<label>-t2.out 2>&1 &
label=${1:?label}
. /root/kata-cp/bin/env.sh
export LOG_DIR=$W/logs/p2gaps/$label DISK_LOG=$W/logs/p2gaps/disk.txt
cd "$W/p2-gaps" || exit 1
exec </dev/null
echo "== $(utc) pass rule 2 in $label"
./run.sh gate-facts before-t2; rc=$?; echo "gate-facts exit code: $rc"
if [ "$rc" != 0 ]; then echo "== $(utc) the gate is not in place on each node. Stop"; exit 1; fi
if ./run.sh line | grep -q '"etcdEncrypted":true'; then
  echo "the cluster has etcd encryption on"
else
  ./run.sh enc enc; rc=$?; echo "enc exit code: $rc"
  ./run.sh health after-enc; echo "health exit code: $?"
  if [ "$rc" != 0 ]; then echo "== $(utc) encryption is not on. Stop"; exit 1; fi
fi
./run.sh t2 t2; echo "t2 exit code: $?"
./run.sh health after-t2; echo "health exit code: $?"
./run.sh w2 after-t2; echo "w2 exit code: $?"
./run.sh facts after-t2 >/dev/null; echo "facts exit code: $?"
echo "== $(utc) end of pass rule 2 in $label"
