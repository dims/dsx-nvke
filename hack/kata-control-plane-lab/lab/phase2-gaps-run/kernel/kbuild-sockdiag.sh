#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Build the Kata guest kernel 6.18.62 again: the kernel of block C3 (Open vSwitch and Geneve built
# in, fragment ovs.conf) plus one more fragment (sockdiag.conf: INET_DIAG, INET_TCP_DIAG,
# INET_DIAG_DESTROY). The method is the method of c3/kbuild.sh: the kernel build files of Kata 4.4.0,
# the same builder image, the same options (-x -m), 24 CPUs.
# Differences, so that the first build stays as it is:
#   - a new work folder (kbuild/work-sockdiag) and a new output folder (kbuild/out-sockdiag),
#   - the kernel source file comes from the first work folder (no download). The build files check
#     its sha256 against the checksum file of kernel.org.
# Output: /root/kata-cp/kbuild/out-sockdiag. Nothing is installed here.
# Removal: rm -rf /root/kata-cp/kbuild/work-sockdiag /root/kata-cp/kbuild/out-sockdiag
#          unlink <kata tree>/tools/packaging/kernel/configs/fragments/common/sockdiag.conf
set -euo pipefail
. /root/kata-cp/bin/env.sh
HERE="$(cd "$(dirname "$0")" && pwd)"
K=$W/kbuild
SRC=$K/kata-containers
WORK=$K/work-sockdiag
OUT=$K/out-sockdiag
FRAG=$SRC/tools/packaging/kernel/configs/fragments/common
[ -d "$SRC/.git" ] || { echo "no Kata source tree in $SRC"; exit 1; }
[ ! -e "$WORK" ] && [ ! -e "$OUT" ] || { echo "$WORK or $OUT exists already. Remove it first"; exit 1; }
docker image inspect kata-kernel-builder:lab >/dev/null || { echo "no builder image kata-kernel-builder:lab"; exit 1; }
mkdir -p "$WORK" "$OUT"
t0=$(date +%s)
echo "== $(utc) Kata source: commit $(git -C "$SRC" rev-parse HEAD), kata_config_version $(cat "$SRC/tools/packaging/kernel/kata_config_version")"
cp "$HERE/sockdiag.conf" "$FRAG/sockdiag.conf"
sha256sum "$FRAG/ovs.conf" "$FRAG/sockdiag.conf"
cp "$K/work/linux-6.18.62.tar.xz" "$K/work/linux-6.18.62.tar.xz.sha256" "$WORK/"
sha256sum "$WORK/linux-6.18.62.tar.xz"
cat "$WORK/linux-6.18.62.tar.xz.sha256"
KB=$SRC/tools/packaging/kernel/build-kernel.sh
ARGS="-a x86_64 -v v6.18.62 -f -u https://cdn.kernel.org/pub/linux/kernel/v6.x/ -x -m"
run() { docker run --rm --network host --cpuset-cpus 40-63 -v "$SRC:$SRC" -v "$WORK:$WORK" -v "$OUT:$OUT" -w "$WORK" -e DESTDIR="$OUT" -e PREFIX=/opt/kata -e HOME=/tmp kata-kernel-builder:lab bash -c "$KB $ARGS $1"; }
echo "== $(utc) setup: $KB $ARGS"
run setup
t1=$(date +%s)
echo "== $(utc) build"
run build
t2=$(date +%s)
echo "== $(utc) install into $OUT"
run install
echo "== $(utc) result"
find "$OUT" -type f -o -type l | xargs ls -la
cfg=$(find "$OUT" -name 'config-6.18.62*' | head -1)
echo "options of the two fragments in $cfg:"
grep -E '^(# )?CONFIG_(INET_DIAG|INET_TCP_DIAG|INET_UDP_DIAG|INET_RAW_DIAG|INET_DIAG_DESTROY|INET_MPTCP_DIAG|OPENVSWITCH|OPENVSWITCH_GENEVE|OPENVSWITCH_VXLAN|GENEVE|MPLS|NET_NSH|NF_CONNTRACK_OVS|NF_NAT_OVS|MODULES)[= ]' "$cfg" | tr '\n' ' '
echo
echo "difference of the config against the first build (kbuild/out):"
diff "$K/out/opt/kata/share/kata-containers/config-6.18.62-211" "$cfg" || true
( cd "$(dirname "$cfg")" && sha256sum vmlinux-6.18.62-211 config-6.18.62-211 )
echo "times: setup $((t1 - t0)) s (source unpack, config), build $((t2 - t1)) s, total $(( $(date +%s) - t0 )) s"
echo "KBUILD DONE"
