#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Build the worker image of phase 3 on the machine: nvke-node-nico:bcc4376f-w1 = the lab base
# image nvke-node:bcc4376f-amd64 plus the lab agent, two images from files and one drop-in
# (Dockerfile.worker). The simulator starts this image with docker, so the image stays in Docker
# of the machine. It does NOT go into the kind nodes, and no archive is made.
#
# Before the build, copy the agent binary beside this script (the file nvke-agent):
#   on the workstation:  ws-sync.sh agent
# Usage: AGENT_SHA256=<sha256 of the binary on the workstation> p3/image/build-worker.sh
set -euo pipefail
. /root/kata-cp/bin/env.sh
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../env-p3.sh
. "$HERE/../env-p3.sh"
WANT=${AGENT_SHA256:?the sha256 of the agent binary, as the workstation gives it}
BASE=${BASE:-nvke-node:bcc4376f-amd64}
TAG=${TAG:-$WORKER_IMAGE}
INNER_IMAGES=${INNER_IMAGES:-$W/dl/img/inner}
CTX=$W/work/p3-worker-image-ctx
LOG=$P3_LOGS/build-worker
mkdir -p "$LOG"
[ -s "$HERE/nvke-agent" ] || { echo "no file $HERE/nvke-agent. Copy the agent binary first"; exit 1; }
echo "$WANT  $HERE/nvke-agent" | sha256sum -c -
docker image inspect "$BASE" >/dev/null || { echo "no base image $BASE in Docker"; exit 1; }
for f in pause-3.10.2.tar k8s-dns-node-cache.tar; do [ -s "$INNER_IMAGES/$f" ] || { echo "no file $INNER_IMAGES/$f"; exit 1; }; done
rm -rf "$CTX"
mkdir -p "$CTX/images"
cp "$HERE/nvke-agent" "$HERE/Dockerfile.worker" "$HERE/worker-setup.sh" "$CTX/"
cp "$INNER_IMAGES/pause-3.10.2.tar" "$INNER_IMAGES/k8s-dns-node-cache.tar" "$CTX/images/"
echo "== $(utc) build context: $(du -sh "$CTX" | cut -f1)"
( cd "$CTX" && find . -type f | sort | xargs sha256sum ) | tee "$LOG/context.sha256"
t0=$(date +%s)
# No network in the build: each input is a file of the context or a part of the base image.
docker build --network none --build-arg BASE="$BASE" --build-arg AGENT_SHA256="$WANT" \
  -f "$CTX/Dockerfile.worker" -t "$TAG" "$CTX" >"$LOG/build.log" 2>&1 || { tail -40 "$LOG/build.log"; exit 1; }
echo "== $(utc) build of $TAG took $(( $(date +%s) - t0 )) s"
sed -n '/^== facts of the worker image/,$p' "$LOG/build.log" | grep -v -E '^( ---> |Removing|Successfully|Step )' | head -20
for t in "$BASE" "$TAG"; do
  docker image inspect "$t" | jq -c --arg t "$t" '.[0] | {image: $t, id: .Id[7:19], size: .Size, entrypoint: .Config.Entrypoint, cmd: .Config.Cmd, stopSignal: .Config.StopSignal, labels: .Config.Labels}'
done | tee "$LOG/images.txt"
# Reads of the new image, each in a container that ends at once, with no network.
{
  echo "agent in $TAG: sha256 $(docker run --rm --network none --entrypoint sha256sum "$TAG" /usr/local/bin/nvke-agent | cut -d' ' -f1), version [$(docker run --rm --network none --entrypoint /usr/local/bin/nvke-agent "$TAG" --version 2>&1 | head -1)], marker [$(docker run --rm --network none --entrypoint cat "$TAG" /usr/local/lib/p3/image-form)]"
  echo "drop-in: $(docker run --rm --network none --entrypoint grep "$TAG" -c -x 'ExecStart=/usr/local/bin/nvke-agent $AGENT_ARGS --disable-mlx5-rescan' /etc/systemd/system/nvke-agent.service.d/zz-p3-no-mlx5-rescan.conf) line with the flag"
} | tee -a "$LOG/images.txt"
echo "== $(utc) done. The simulator setting is NICO_CONTAINERS_NODE_IMAGE=$TAG (env-p3.sh)"
