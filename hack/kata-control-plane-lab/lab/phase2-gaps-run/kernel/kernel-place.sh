#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Put the guest kernel with INET_DIAG_DESTROY into each kind node, beside the kernel of the class
# kata-clh-runtime-rs-fix-direct-ovs, under a new file name. Nothing names the new file after this
# step: the class keeps its kernel. kernel-switch.sh changes the class.
# Removal: in each kind node unlink /opt/kata-fix/vmlinux-6.18.62-211-ovs-sockdiag and
#          /opt/kata-fix/config-6.18.62-211-ovs-sockdiag
set -euo pipefail
. /root/kata-cp/bin/env.sh
SRC=$W/kbuild/out-sockdiag/opt/kata/share/kata-containers
D=/opt/kata-fix
NEW=vmlinux-6.18.62-211-ovs-sockdiag
CFG=config-6.18.62-211-ovs-sockdiag
grep -q '^CONFIG_INET_DIAG_DESTROY=y' "$SRC/config-6.18.62-211" || { echo "the new config has no INET_DIAG_DESTROY"; exit 1; }
grep -q '^CONFIG_OPENVSWITCH=y' "$SRC/config-6.18.62-211" || { echo "the new config has no Open vSwitch"; exit 1; }
want=$(sha256sum "$SRC/vmlinux-6.18.62-211" | cut -d' ' -f1)
echo "new kernel: $want  $SRC/vmlinux-6.18.62-211"
for NODE in $NODES; do
  docker cp -q "$SRC/vmlinux-6.18.62-211" "$NODE:$D/$NEW"
  docker cp -q "$SRC/config-6.18.62-211" "$NODE:$D/$CFG"
  docker exec "$NODE" sh -c "chown root:root $D/$NEW $D/$CFG; chmod 644 $D/$NEW $D/$CFG"
  got=$(docker exec "$NODE" sha256sum "$D/$NEW" | cut -d' ' -f1)
  [ "$got" = "$want" ] || { echo "$NODE: checksum differs"; exit 1; }
  echo "$NODE: $D/$NEW ($got), the class uses: $(docker exec "$NODE" grep -E '^kernel = ' $D/configuration-clh-runtime-rs-fix-direct-ovs.toml)"
done
echo "KERNEL PLACE DONE"
