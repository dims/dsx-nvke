#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# stack-image.sh <image reference>: bring one registry image of the NVKE stack into each kind node.
# A kind node cannot pull here (firewall of the machine), so the machine pulls with ctr (namespace
# kata-lab), exports a file, and each node imports it. A reference with a digest gets its name in
# the node, so that the kubelet finds it and does not try a pull.
set -euo pipefail
. /root/kata-cp/bin/env.sh
ref=$1
d=$W/dl/img/stack
mkdir -p "$d"
f=$d/$(echo "$ref" | tr '/:@' '___').tar
missing=""
for n in $NODES; do docker exec "$n" crictl inspecti "$ref" >/dev/null 2>&1 || missing="$missing $n"; done
[ -n "$missing" ] || { echo "present in each node: $ref"; exit 0; }
if [ ! -s "$f" ]; then
  if ! ctr -n kata-lab images pull --platform linux/amd64 "$ref" >/dev/null 2>"$f.err"; then
    case "$ref" in
      mirror.gcr.io/*)
        # The Docker Hub mirror refused the pull (its upstream quota). Take the image from Docker Hub and give
        # it the mirror name, which is the name in the chart values.
        hub="docker.io/${ref#mirror.gcr.io/}"
        echo "pull of $ref failed: $(tail -1 "$f.err" | cut -c1-120). Second way: $hub"
        ctr -n kata-lab images pull --platform linux/amd64 "$hub" >/dev/null
        ctr -n kata-lab images tag --force "$hub" "$ref" >/dev/null
        ;;
      *) cat "$f.err"; exit 1 ;;
    esac
  fi
  rm -f "$f.err"
  if ! ctr -n kata-lab images export --platform linux/amd64 "$f" "$ref" 2>"$f.err"; then
    # Third way. containerd of the machine did not fetch a layer that another of its namespaces has already
    # ("content digest not found" at the export). skopeo in a throwaway container with the host network
    # copies the image from the registry into a file, with no containerd store in the path.
    echo "ctr export of $ref failed: $(tail -1 "$f.err" | cut -c1-120). Third way: skopeo"
    rm -f "$f" "$f.err"
    docker run --rm --network host -v "$d:/out" quay.io/skopeo/stable:latest copy --override-os linux --override-arch amd64 \
      "docker://$ref" "docker-archive:/out/$(basename "$f"):$ref" >/dev/null
  fi
  rm -f "$f.err"
fi
for n in $missing; do
  docker exec -i "$n" ctr -n k8s.io images import - <"$f" >/dev/null
  if ! docker exec "$n" crictl inspecti "$ref" >/dev/null 2>&1; then
    case "$ref" in
      *@*)
        repo=${ref%%@*}
        repo=${repo%:*}
        docker exec "$n" ctr -n k8s.io images tag --force "$ref" "$repo@${ref#*@}" >/dev/null 2>&1 || true
        ;;
    esac
  fi
  docker exec "$n" crictl inspecti "$ref" >/dev/null 2>&1 || { echo "ERROR: $n does not have $ref after the import"; exit 1; }
done
echo "loaded into$missing: $ref"
