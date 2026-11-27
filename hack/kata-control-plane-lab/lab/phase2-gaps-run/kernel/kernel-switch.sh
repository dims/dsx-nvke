#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Switch the guest kernel of the class kata-clh-runtime-rs-fix-direct-ovs, in each kind node.
# Usage: kernel-switch.sh status | new | old
#   new   the kernel with INET_DIAG_DESTROY (vmlinux-6.18.62-211-ovs-sockdiag)
#   old   the kernel of block C3 (vmlinux-6.18.62-211-ovs)
# It changes one line ("kernel = ...") of the handler configuration file of the class. The Kata
# shim reads that file when it makes a sandbox, so containerd does not restart and a running guest
# keeps its kernel. A pod that starts after the switch gets the kernel of the file.
set -euo pipefail
. /root/kata-cp/bin/env.sh
D=/opt/kata-fix
F=$D/configuration-clh-runtime-rs-fix-direct-ovs.toml
OLD=$D/vmlinux-6.18.62-211-ovs
NEW=$D/vmlinux-6.18.62-211-ovs-sockdiag
case "${1:-status}" in
  new) K=$NEW ;;
  old) K=$OLD ;;
  status) K="" ;;
  *) sed -n '2,9p' "$0"; exit 1 ;;
esac
for NODE in $NODES; do
  if [ -n "$K" ]; then
    docker exec "$NODE" test -s "$K" || { echo "$NODE: no file $K. Nothing changed in this node"; exit 1; }
    docker exec "$NODE" sh -c "cp -p $F $F.before-switch && sed -i 's|^kernel = .*|kernel = \"$K\"|' $F"
    [ "$(docker exec "$NODE" grep -c -E "^kernel = \"$K\"\$" "$F")" = 1 ] || { echo "$NODE: the kernel line was not changed"; exit 1; }
  fi
  echo "$NODE: $(docker exec "$NODE" grep -E '^kernel = ' "$F") sha256 $(docker exec "$NODE" sh -c "sha256sum \$(sed -n 's/^kernel = \"\\(.*\\)\"/\\1/p' $F)" | cut -c1-16)"
done
