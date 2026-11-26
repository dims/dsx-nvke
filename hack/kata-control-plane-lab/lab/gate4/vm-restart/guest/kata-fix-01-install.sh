#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Add four RuntimeClasses: kata-clh-runtime-rs-fix and kata-clh-fix use the Kata
# guest image with the patched kata-agent. kata-clh-runtime-rs-direct (stock
# image) and kata-clh-runtime-rs-fix-direct (patched image) use direct I/O for
# block volumes (block_device_cache_direct = true). The stock RuntimeClasses,
# the stock handlers and /opt/kata stay as they are. All new files in the node
# are in /opt/kata-fix. The only other change is one more entry in the
# `imports` line of /etc/containerd/config.toml.
#
# Run at a quiet time: step 5 restarts containerd in the kind node one time.
# Running pods and their shims continue through this restart.
set -euo pipefail
NODE=${NODE:-kata-cp-control-plane}
SRC=/scratch/kata-cp/vm-share/kata-fix
D=/opt/kata-fix
STOCK=/opt/kata/share/defaults/kata-containers
n() { docker exec "$NODE" "$@"; }

echo "== 1. copy the images"
n mkdir -p "$D"
for i in kata-ubuntu-resolute-killfix-execfix.image kata-ubuntu-resolute-killfix.image; do
  docker cp "$SRC/image/$i" "$NODE:$D/$i"
done
docker cp "$SRC/image/SHA256SUMS" "$NODE:$D/SHA256SUMS"
n sh -c "cd $D && chown root:root *.image SHA256SUMS && chmod 644 *.image && sha256sum -c SHA256SUMS"
# The configuration files use this link. Default: the image with the two fixes.
n ln -sfn kata-ubuntu-resolute-killfix-execfix.image "$D/kata-containers-fix.img"

echo "== 2. make the Kata configuration files (stock files with another image path)"
n sh -c "sed 's|^image = .*|image = \"$D/kata-containers-fix.img\"|' $STOCK/runtime-rs/runtimes/clh-runtime-rs/configuration-clh-runtime-rs.toml >$D/configuration-clh-runtime-rs-fix.toml"
n sh -c "sed 's|^image = .*|image = \"$D/kata-containers-fix.img\"|' $STOCK/runtimes/clh/configuration-clh.toml >$D/configuration-clh-fix.toml"
# Direct I/O for block volumes (Rust runtime): the stock image, and the patched image.
n sh -c "sed 's|^block_device_cache_direct = .*|block_device_cache_direct = true|' $STOCK/runtime-rs/runtimes/clh-runtime-rs/configuration-clh-runtime-rs.toml >$D/configuration-clh-runtime-rs-direct.toml"
n sh -c "sed 's|^block_device_cache_direct = .*|block_device_cache_direct = true|' $D/configuration-clh-runtime-rs-fix.toml >$D/configuration-clh-runtime-rs-fix-direct.toml"
echo "-- difference to the stock files (the image line, the block_device_cache_direct line, or both):"
n sh -c "for f in clh-runtime-rs-fix clh-runtime-rs-direct clh-runtime-rs-fix-direct; do echo \"-- \$f\"; diff $STOCK/runtime-rs/runtimes/clh-runtime-rs/configuration-clh-runtime-rs.toml $D/configuration-\$f.toml; done; echo '-- clh-fix'; diff $STOCK/runtimes/clh/configuration-clh.toml $D/configuration-clh-fix.toml; true"

echo "== 3. add the containerd handlers"
docker cp "$SRC/plan/containerd-kata-fix.toml" "$NODE:$D/containerd-kata-fix.toml"
n sh -c "[ -e $D/containerd-config.toml.before ] || cp -p /etc/containerd/config.toml $D/containerd-config.toml.before"
n sh -c "grep -q '$D/containerd-kata-fix.toml' /etc/containerd/config.toml || sed -i 's|^imports = \[\"/opt/kata/containerd/config.d/kata-deploy.toml\"\]|imports = [\"/opt/kata/containerd/config.d/kata-deploy.toml\", \"$D/containerd-kata-fix.toml\"]|' /etc/containerd/config.toml"
n grep -n '^imports' /etc/containerd/config.toml
n grep -q "$D/containerd-kata-fix.toml" /etc/containerd/config.toml || { echo "the imports line was not changed"; exit 1; }

echo "== 4. check the merged containerd configuration before the restart"
n sh -c "containerd config dump 2>/dev/null | grep -E 'runtimes.kata-clh(-runtime-rs)?(-fix)?(-direct)?\]$'"
[ "$(n sh -c "containerd config dump 2>/dev/null | grep -c -E 'runtimes.kata-clh(-runtime-rs)?(-fix)?(-direct)?\]$'")" = 6 ] || { echo "expected the two stock clh handlers and the four new handlers"; exit 1; }

echo "== 5. restart containerd"
n systemctl restart containerd
for _ in $(seq 60); do n crictl info >/dev/null 2>&1 && break; sleep 1; done
n sh -c "crictl info | grep -o '\"kata-clh[a-z-]*-\(fix\|direct\)\"' | sort -u"

echo "== 6. make the RuntimeClasses"
docker exec -i "$NODE" kubectl --kubeconfig /etc/kubernetes/admin.conf apply -f - <"$SRC/plan/runtimeclasses-fix.yaml"
n kubectl --kubeconfig /etc/kubernetes/admin.conf get runtimeclass
