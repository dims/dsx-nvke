#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Build the form p3 of the node image for pods from the form p2, and load it into the host nodes.
# Usage: p2-image/build-p3.sh
set -euo pipefail
. /root/kata-cp/bin/env.sh
HERE="$(cd "$(dirname "$0")" && pwd)"
P2=${P2:-nvke-node-podvm:bcc4376f-p2}
TAG=${TAG:-nvke-node-podvm:bcc4376f-p3}
CTX=$W/work/p3-image-ctx
LOG=$W/logs/p2s6/build-p3
mkdir -p "$LOG"
rm -rf "$CTX"
mkdir -p "$CTX"
cp "$HERE/Dockerfile.p3" "$CTX/Dockerfile"
cp "$HERE/build-ctr" "$CTX/build-ctr"
t0=$(date +%s)
docker build --network none --build-arg P2="$P2" -t "$TAG" "$CTX" >"$LOG/build.log" 2>&1 || { tail -40 "$LOG/build.log"; exit 1; }
echo "== $(utc) image $TAG built in $(( $(date +%s) - t0 )) s"
grep -E 'new image:|import complete|Status: install' "$LOG/build.log" | cut -c1-160
docker image inspect "$TAG" | jq -c '.[0] | {id: .Id, size: .Size, entrypoint: .Config.Entrypoint, labels: .Config.Labels}' | tee "$LOG/image.txt"
docker image inspect "$P2" | jq -c '.[0] | {p2: true, id: .Id, size: .Size}' | tee -a "$LOG/image.txt"
f=$W/dl/img/$(echo "$TAG" | tr '/:' '__').tar
if [ -e "$f" ]; then unlink "$f"; fi
for n in $WORKERS; do docker exec "$n" ctr -n k8s.io images rm "docker.io/library/$TAG" >/dev/null 2>&1 || true; done
t0=$(date +%s)
"$W/bin/img-load.sh" "$TAG" $WORKERS
echo "== $(utc) save and load took $(( $(date +%s) - t0 )) s"
for n in $WORKERS; do echo "$n: $(docker exec "$n" crictl inspecti -o json "docker.io/library/$TAG" 2>/dev/null | jq -r '.status.id + " " + (.status.size|tostring)' | cut -c8-40)"; done
echo "== $(utc) done"
