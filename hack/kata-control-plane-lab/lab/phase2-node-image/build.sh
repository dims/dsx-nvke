#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Build the node image for pods on the lab machine, take the test data out of the build stage,
# and load the image into the host nodes (a host node cannot pull here).
# Usage: p2-image/build.sh            (TAG=... for another tag)
set -euo pipefail
. /root/kata-cp/bin/env.sh
HERE="$(cd "$(dirname "$0")" && pwd)"
BASE=${BASE:-nvke-node:bcc4376f-amd64}
TAG=${TAG:-nvke-node-podvm:bcc4376f-p2}
KERNEL_CONFIG=${KERNEL_CONFIG:-$W/kbuild/out/opt/kata/share/kata-containers/config-6.18.62-211}
KERNEL_RELEASE=${KERNEL_RELEASE:-6.18.62}
INNER_IMAGES=${INNER_IMAGES:-$W/dl/img/inner}
CTX=$W/work/p2-image-ctx
OUT=$W/p2-image/out
LOG=$W/logs/p2/build
mkdir -p "$LOG" "$OUT"

rm -rf "$CTX"
mkdir -p "$CTX/images"
cp -a "$HERE/Dockerfile" "$HERE/bootstrap" "$HERE/units" "$HERE/podvm-entrypoint" "$HERE/ovs-datapath-check" "$CTX/"
cp "$KERNEL_CONFIG" "$CTX/kernel-config"
cp "$INNER_IMAGES/pause-3.10.2.tar" "$INNER_IMAGES/k8s-dns-node-cache.tar" "$CTX/images/"
grep -q '^CONFIG_OPENVSWITCH=y' "$CTX/kernel-config" || { echo "the kernel config has no built in Open vSwitch"; exit 1; }
echo "== $(utc) build context: $(du -sh "$CTX" | cut -f1)"
( cd "$CTX" && find . -type f | sort | xargs sha256sum ) >"$LOG/context.sha256"

# The build containers use the network of the machine: the Go stage downloads modules from
# proxy.golang.org. The second stage needs no network.
t0=$(date +%s)
docker build --network host --build-arg BASE="$BASE" --build-arg KERNEL_RELEASE="$KERNEL_RELEASE" \
  ${NO_CACHE:+--no-cache} --target build -t "${TAG%%:*}-build:${TAG##*:}" "$CTX" >"$LOG/build-stage.log" 2>&1 || { tail -40 "$LOG/build-stage.log"; exit 1; }
docker build --network host --build-arg BASE="$BASE" --build-arg KERNEL_RELEASE="$KERNEL_RELEASE" \
  -t "$TAG" "$CTX" >"$LOG/build.log" 2>&1 || { tail -40 "$LOG/build.log"; exit 1; }
echo "== $(utc) image $TAG built in $(( $(date +%s) - t0 )) s"
grep -E '^(ok|FAIL|---|PASS)[[:space:]]' "$LOG/build-stage.log" | head -20 || true

# The test data (fake values) and the program, out of the build stage.
rm -rf "$OUT/fixtures"
docker run --rm --network none --entrypoint tar "${TAG%%:*}-build:${TAG##*:}" -C /out -c fixtures | tar -x -C "$OUT"
ls -l "$OUT/fixtures"

docker image inspect "$TAG" | jq -c '.[0] | {id: .Id, size: .Size, entrypoint: .Config.Entrypoint, cmd: .Config.Cmd, stopSignal: .Config.StopSignal, labels: .Config.Labels, env: .Config.Env}' | tee "$LOG/image.txt"
docker image inspect "$BASE" | jq -c '.[0] | {base: true, id: .Id, size: .Size, entrypoint: .Config.Entrypoint, cmd: .Config.Cmd, stopSignal: .Config.StopSignal, env: .Config.Env}' | tee -a "$LOG/image.txt"
docker history --no-trunc --format '{{.Size}}\t{{.CreatedBy}}' "$TAG" | head -12 | cut -c1-200 | tee "$LOG/history.txt"

# Into the host nodes. img-load.sh keeps an archive by image name, so remove an old one first.
f=$W/dl/img/$(echo "$TAG" | tr '/:' '__').tar
if [ -e "$f" ]; then mv "$f" "$f.old"; fi
for n in $WORKERS; do docker exec "$n" ctr -n k8s.io images rm "docker.io/library/$TAG" >/dev/null 2>&1 || true; done
"$W/bin/img-load.sh" "$TAG" $WORKERS
if [ -e "$f.old" ]; then unlink "$f.old"; fi
for n in $WORKERS; do echo "$n: $(docker exec "$n" crictl inspecti -o go-template --template '{{.status.id}} {{.status.size}}' "docker.io/library/$TAG" 2>&1 | cut -c1-120)"; done
echo "== $(utc) done"
