#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Build the node image for pods with another Kubernetes version and load it into the host nodes.
# Usage: p2-gate/image/build-k8s.sh <kindest tag> <image tag> [extra image ...]
#   for example  v1.35.5 nvke-node-podvm:bcc4376f-p5-k1355 registry.k8s.io/pause:3.10.1
set -euo pipefail
. /root/kata-cp/bin/env.sh
HERE="$(cd "$(dirname "$0")" && pwd)"
KTAG=${1:?kindest tag}
TAG=${2:?image tag}
P5=${P5:-nvke-node-podvm:bcc4376f-p5}
CTX=$W/work/k8s-image-ctx
LOG=$W/logs/p2g/build-$KTAG
mkdir -p "$LOG"
echo "== $(utc) pull of kindest/node:$KTAG on the machine (a public image)"
t0=$(date +%s)
docker image inspect "kindest/node:$KTAG" >/dev/null 2>&1 || docker pull -q "kindest/node:$KTAG"
echo "kindest/node:$KTAG: $(docker image inspect "kindest/node:$KTAG" | jq -r '.[0] | "\(.Id[7:19]) \(.Size) bytes, digest \(.RepoDigests[0] // "-")"'), pull took $(( $(date +%s) - t0 )) s"
rm -rf "$CTX"
mkdir -p "$CTX/images"
cp "$HERE/Dockerfile.k8s" "$CTX/Dockerfile"
# Extra images (third argument and on): a public image that kubeadm of that version asks for and
# that the kindest/node image does not carry. The machine pulls it and saves it for the build.
shift 2
for extra in "$@"; do
  ef=$W/dl/img/inner/$(echo "${extra##*/}" | tr ':' '-').tar
  if [ ! -s "$ef" ]; then
    docker image inspect "$extra" >/dev/null 2>&1 || docker pull -q --platform linux/amd64 "$extra"
    docker save --platform linux/amd64 "$extra" -o "$ef"
  fi
  cp "$ef" "$CTX/images/"
  echo "extra image for the build: $extra ($(stat -c %s "$ef") bytes)"
done
t0=$(date +%s)
docker build --network none --build-arg KIND="kindest/node:$KTAG" --build-arg P5="$P5" --build-arg FORM="${TAG##*:}" -t "$TAG" "$CTX" >"$LOG/build.log" 2>&1 || { tail -40 "$LOG/build.log"; exit 1; }
echo "== $(utc) image $TAG built in $(( $(date +%s) - t0 )) s"
grep -a -E 'kubeadm asks for:|present:|MISSING|export:|^#[0-9]+ [0-9.]+ kubeadm v' "$LOG/build.log" | sed -E 's/^#[0-9]+ [0-9.]+ //' | cut -c1-220
docker image inspect "$TAG" | jq -c '.[0] | {id: .Id[7:19], size: .Size, labels: .Config.Labels}' | tee "$LOG/image.txt"
echo "in the image: kubeadm $(docker run --rm --network none --entrypoint /usr/bin/kubeadm.real "$TAG" version -o short), $(docker run --rm --network none --entrypoint /usr/bin/kubelet "$TAG" --version), agent sha256 $(docker run --rm --network none --entrypoint sha256sum "$TAG" /usr/local/bin/nvke-agent | cut -c1-16), marker [$(docker run --rm --network none --entrypoint cat "$TAG" /usr/share/podvm/image-form)]" | tee -a "$LOG/image.txt"
f=$W/dl/img/$(echo "$TAG" | tr '/:' '__').tar
if [ -e "$f" ]; then unlink "$f"; fi
for n in $WORKERS; do docker exec "$n" ctr -n k8s.io images rm "docker.io/library/$TAG" >/dev/null 2>&1 || true; done
t0=$(date +%s)
"$W/bin/img-load.sh" "$TAG" $WORKERS
echo "== $(utc) save and load took $(( $(date +%s) - t0 )) s"
for n in $WORKERS; do echo "$n: $(docker exec "$n" crictl inspecti -o json "docker.io/library/$TAG" 2>/dev/null | jq -r '.status.id + " " + (.status.size|tostring)' | cut -c8-40)"; done
echo "== $(utc) done"
