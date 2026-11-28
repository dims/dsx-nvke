#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Build the two image tags of the Konnectivity prototype on the machine:
#   nvke-node-podvm:bcc4376f-p11   p10 with the proxy server image (Dockerfile.pod). It goes into
#                                  the three host nodes, as each pod image of the lab
#   nvke-node-nico:bcc4376f-w2     w1 with the proxy agent image (Dockerfile.worker). It stays in
#                                  Docker of the machine, where the simulator starts it
# The two archives come from the workstation (ws-sync.sh images) into /root/kata-cp/dl/img/.
# Usage: p3-konn/image/build-konn-images.sh [pod|worker|all]     (default: all)
set -euo pipefail
. /root/kata-cp/bin/env.sh
. /root/kata-cp/p3/env-p3.sh
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../env-konn.sh
. "$HERE/../env-konn.sh"
what=${1:-all}
LOG=$P3_LOGS/konn-build
mkdir -p "$LOG"

build() { # <pod|worker> <base tag> <new tag> <archive> <sha256> <image name> <Dockerfile> <base build argument> <marker file> [second archive] [its sha256] [its image name]
  local kind=$1 base=$2 tag=$3 archive=$4 want=$5 image=$6 dockerfile=$7 arg=$8 marker=$9 archive2=${10:-} want2=${11:-} image2=${12:-} ctx t0 extra=()
  ctx=$W/work/p3konn-$kind-image-ctx
  [ -s "$W/dl/img/$archive" ] || { echo "no archive $W/dl/img/$archive. Copy it from the workstation first (ws-sync.sh images)"; return 1; }
  echo "$want  $W/dl/img/$archive" | sha256sum -c -
  docker image inspect "$base" >/dev/null || { echo "no image $base in Docker of the machine"; return 1; }
  rm -rf "$ctx"
  mkdir -p "$ctx/images"
  cp "$HERE/$dockerfile" "$HERE/import-images.sh" "$ctx/"
  cp "$W/dl/img/$archive" "$ctx/images/"
  if [ -n "$archive2" ]; then
    [ -s "$W/dl/img/$archive2" ] || { echo "no archive $W/dl/img/$archive2"; return 1; }
    echo "$want2  $W/dl/img/$archive2" | sha256sum -c -
    cp "$W/dl/img/$archive2" "$ctx/images/"
    extra=(--build-arg "KONN_IMAGE2=$image2")
  fi
  ( cd "$ctx" && find . -type f | sort | xargs sha256sum ) >"$LOG/context-$kind.sha256"
  t0=$(date +%s)
  # No network in the build: each input is a file of the context or a part of the base image.
  docker build --network none --build-arg "$arg=$base" --build-arg KONN_IMAGE="$image" "${extra[@]}" -f "$ctx/$dockerfile" -t "$tag" "$ctx" >"$LOG/build-$kind.log" 2>&1 || { tail -40 "$LOG/build-$kind.log"; return 1; }
  echo "== $(utc) build of $tag took $(( $(date +%s) - t0 )) s"
  grep -F 'kas-network-proxy/proxy-' "$LOG/build-$kind.log" | grep -F sha256 | tail -2 || true
  for t in "$base" "$tag"; do
    docker image inspect "$t" | jq -c --arg t "$t" '.[0] | {image: $t, id: .Id[7:19], size: .Size, entrypoint: .Config.Entrypoint, labels: .Config.Labels}'
  done | tee "$LOG/images-$kind.txt"
  echo "marker of $tag: [$(docker run --rm --network none --entrypoint cat "$tag" "$marker" 2>&1)]" | tee -a "$LOG/images-$kind.txt"
}

if [ "$what" = pod ] || [ "$what" = all ]; then
  build pod "$KONN_POD_BASE" "$KONN_POD_IMAGE" "$KONN_SERVER_ARCHIVE" "$KONN_SERVER_ARCHIVE_SHA256" "$KONN_SERVER_IMAGE" Dockerfile.pod P10 /usr/share/podvm/image-form "$KONN_AGENT_ARCHIVE" "$KONN_AGENT_ARCHIVE_SHA256" "$KONN_AGENT_IMAGE"
  # Into the host nodes, as build-encfix.sh of phase 2 does it. img-load.sh keeps an archive by
  # image name, so an old one goes first.
  f=$W/dl/img/$(echo "$KONN_POD_IMAGE" | tr '/:' '__').tar
  if [ -e "$f" ]; then unlink "$f"; fi
  for n in $WORKERS; do docker exec "$n" ctr -n k8s.io images rm "docker.io/library/$KONN_POD_IMAGE" >/dev/null 2>&1 || true; done
  t0=$(date +%s)
  # shellcheck disable=SC2086  # one argument for each host node
  "$W/bin/img-load.sh" "$KONN_POD_IMAGE" $WORKERS >/dev/null
  echo "== $(utc) save and load of $KONN_POD_IMAGE took $(( $(date +%s) - t0 )) s: $(for n in $WORKERS; do docker exec "$n" crictl inspecti -o json "docker.io/library/$KONN_POD_IMAGE" 2>/dev/null | jq -r '.status.id' | cut -c8-19; done | sort -u | tr '\n' ' ')"
fi
if [ "$what" = worker ] || [ "$what" = all ]; then
  build worker "$KONN_WORKER_BASE" "$KONN_WORKER_IMAGE" "$KONN_AGENT_ARCHIVE" "$KONN_AGENT_ARCHIVE_SHA256" "$KONN_AGENT_IMAGE" Dockerfile.worker W1 /usr/local/lib/p3/image-form
fi
echo "== $(utc) done"
