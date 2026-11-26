#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Run a command on the second machine (the-second-machine) over ONE multiplexed SSH connection.
# Usage:
#   bb.sh <command...>          run a command there
#   bb.sh < script              run a script from stdin there (bash -s)
#   bb.sh --put <local> <remote>    copy one file or folder to the machine (scp -r)
#   bb.sh --get <remote> <local>    copy one file or folder from the machine (scp -r)
#   bb.sh --rsync-get <remote dir/> <local dir/>   rsync a folder from the machine
# The VPN agent of the workstation holds each new TCP connection, so every call uses the same
# control socket. Never put the bash network socket device path form into a command here.
set -euo pipefail
HOST=root@SECOND_MACHINE_ADDRESS
OPTS=(-o BatchMode=yes -o ControlMaster=auto -o ControlPersist=30m -o ControlPath=/scratch/kata-cp/tmp/ssh/%C)
case "${1:-}" in
  --put) exec scp -q -r "${OPTS[@]}" "$2" "$HOST:$3" ;;
  --get) exec scp -q -r "${OPTS[@]}" "$HOST:$2" "$3" ;;
  --rsync-get) exec rsync -a --exclude secrets --exclude "*.tar" -e "ssh ${OPTS[*]}" "$HOST:$2" "$3" ;;
  --rsync-put) exec rsync -rlptD --chown=root:root -e "ssh ${OPTS[*]}" "$2" "$HOST:$3" ;;
  "") exec ssh "${OPTS[@]}" "$HOST" bash -s ;;
  *) exec ssh "${OPTS[@]}" "$HOST" "$@" ;;
esac
