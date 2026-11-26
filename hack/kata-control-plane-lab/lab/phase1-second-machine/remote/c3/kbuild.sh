#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Build a Kata guest kernel 6.18.62 with Open vSwitch and Geneve built in. It uses the kernel build
# files of Kata 4.4.0 with one added config fragment (c3/ovs.conf), and the same options as the
# stock x86_64 kernel of the release (kata-deploy-binaries.sh install_kernel: -x -m).
# The build runs in a container with the host network of the machine (downloads only), on 24 CPUs.
# Output: /root/kata-cp/kbuild/out. Nothing is installed here.
# Removal: rm -rf /root/kata-cp/kbuild; docker rmi kata-kernel-builder:lab ubuntu:22.04
set -euo pipefail
. /root/kata-cp/bin/env.sh
K=$W/kbuild
SRC=$K/kata-containers
OUT=$K/out
mkdir -p "$K" "$OUT"
t0=$(date +%s)
echo "== $(utc) Kata source, tag 4.4.0"
[ -d "$SRC/.git" ] || git clone -q --depth 1 --branch 4.4.0 https://github.com/kata-containers/kata-containers.git "$SRC"
echo "commit $(git -C "$SRC" rev-parse HEAD), kata_config_version $(cat "$SRC/tools/packaging/kernel/kata_config_version"), kernel $(grep -A3 '^  kernel:' "$SRC/versions.yaml" | awk '/version:/ {print $2}')"
cp "$W/c3/ovs.conf" "$SRC/tools/packaging/kernel/configs/fragments/common/ovs.conf"
sha256sum "$SRC/tools/packaging/kernel/configs/fragments/common/ovs.conf"
echo "== $(utc) builder image (Dockerfile of Kata, host network for apt and yq)"
cp "$SRC/ci/install_yq.sh" "$SRC/tools/packaging/static-build/kernel/install_yq.sh"
docker build -q --network host -t kata-kernel-builder:lab "$SRC/tools/packaging/static-build/kernel"
KB=$SRC/tools/packaging/kernel/build-kernel.sh
ARGS="-a x86_64 -v v6.18.62 -f -u https://cdn.kernel.org/pub/linux/kernel/v6.x/ -x -m"
run() { docker run --rm --network host --cpuset-cpus 40-63 -v "$SRC:$SRC" -w "$K/work" -e DESTDIR="$OUT" -e PREFIX=/opt/kata -e HOME=/tmp kata-kernel-builder:lab bash -c "$*"; }
mkdir -p "$K/work"
echo "== $(utc) setup: $KB $ARGS"
docker run --rm --network host --cpuset-cpus 40-63 -v "$SRC:$SRC" -v "$K/work:$K/work" -v "$OUT:$OUT" -w "$K/work" -e DESTDIR="$OUT" -e PREFIX=/opt/kata -e HOME=/tmp kata-kernel-builder:lab bash -c "$KB $ARGS setup"
t1=$(date +%s)
echo "== $(utc) build"
docker run --rm --network host --cpuset-cpus 40-63 -v "$SRC:$SRC" -v "$K/work:$K/work" -v "$OUT:$OUT" -w "$K/work" -e DESTDIR="$OUT" -e PREFIX=/opt/kata -e HOME=/tmp kata-kernel-builder:lab bash -c "$KB $ARGS build"
t2=$(date +%s)
echo "== $(utc) install into $OUT"
docker run --rm --network host --cpuset-cpus 40-63 -v "$SRC:$SRC" -v "$K/work:$K/work" -v "$OUT:$OUT" -w "$K/work" -e DESTDIR="$OUT" -e PREFIX=/opt/kata -e HOME=/tmp kata-kernel-builder:lab bash -c "$KB $ARGS install"
echo "== $(utc) result"
find "$OUT" -type f -o -type l | xargs ls -la
find "$K" -name 'linux-6.18.62.tar.xz*' | xargs ls -la 2>/dev/null
find "$K" -name 'linux-6.18.62.tar.xz' | xargs sha256sum 2>/dev/null
find "$K" -name 'linux-6.18.62.tar.xz.sha256' | xargs cat 2>/dev/null
cfg=$(find "$OUT" -name 'config-6.18.62*' | head -1)
grep -E '^CONFIG_(OPENVSWITCH|OPENVSWITCH_GENEVE|OPENVSWITCH_VXLAN|GENEVE|MPLS|NET_NSH|NF_CONNTRACK_OVS|NF_NAT_OVS|NET_MPLS_GSO|NF_CONNTRACK_ZONES|NF_NAT|MODULES)=' "$cfg" | tr '\n' ' '
echo
echo "times: setup $((t1 - t0)) s (clone, image, source download, config), build $((t2 - t1)) s, total $(( $(date +%s) - t0 )) s"
echo "KBUILD DONE"
