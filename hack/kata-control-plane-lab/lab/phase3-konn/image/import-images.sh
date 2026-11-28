#!/bin/sh
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Image build step: import each image archive of /tmp/p3konn-images into the containerd store
# of the image, not unpacked, as kind does it for a node image. containerd unpacks an image at
# its first use. It is the step of p2-image/Dockerfile and of p3/image/worker-setup.sh.
# Arguments: each image name that must be in the store after the import.
set -eu
IMAGES=/tmp/p3konn-images
fail() { echo "ERROR: $*"; exit 1; }
count=0
for f in "$IMAGES"/*.tar; do if [ -e "$f" ]; then count=$((count + 1)); fi; done
[ "$count" -gt 0 ] || fail "no image archive in $IMAGES"
containerd >/tmp/p3konn-build-containerd.log 2>&1 &
pid=$!
i=0
until ctr version >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -gt 30 ]; then cat /tmp/p3konn-build-containerd.log; fail "containerd did not start in the build container"; fi
  sleep 1
done
for f in "$IMAGES"/*.tar; do ctr -n k8s.io images import --no-unpack --platform linux/amd64 "$f"; done
for want in "$@"; do
  ctr -n k8s.io images ls -q | grep -x -F "$want" || fail "no image $want in the store after the import"
done
echo "== images of the store with kas-network-proxy in the name"
ctr -n k8s.io images ls | grep -F kas-network-proxy | awk '{print $1, $3, $4, $5}'
kill "$pid"
wait "$pid" || true
rm -rf /run/containerd /tmp/p3konn-build-containerd.log "$IMAGES"
