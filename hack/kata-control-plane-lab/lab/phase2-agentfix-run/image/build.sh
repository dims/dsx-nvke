#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Build the forms p4 and p5 of the node image for pods and load them into the host nodes.
# p4 = p3 plus the fixed agent binary (the file nvke-agent beside this script). p5 = p4 plus a marker.
# Usage: p2-agentfix/image/build.sh
set -euo pipefail
. /root/kata-cp/bin/env.sh
HERE="$(cd "$(dirname "$0")" && pwd)"
WANT=${AGENT_SHA256:-e465d46ad7a578b1634ca129dc2b0303c76bc6146fc346e937e18371affe8770}
P3=nvke-node-podvm:bcc4376f-p3
P4=nvke-node-podvm:bcc4376f-p4
P5=nvke-node-podvm:bcc4376f-p5
CTX=$W/work/p4-image-ctx
LOG=$W/logs/p2s6b/build
mkdir -p "$LOG"
echo "$WANT  $HERE/nvke-agent" | sha256sum -c -
rm -rf "$CTX"
mkdir -p "$CTX"
cp "$HERE/Dockerfile.p4" "$HERE/Dockerfile.p5" "$HERE/nvke-agent" "$CTX/"
docker build --network none --build-arg P3="$P3" --build-arg AGENT_SHA256="$WANT" -f "$CTX/Dockerfile.p4" -t "$P4" "$CTX" >"$LOG/build-p4.log" 2>&1 || { tail -30 "$LOG/build-p4.log"; exit 1; }
docker build --network none --build-arg P4="$P4" -f "$CTX/Dockerfile.p5" -t "$P5" "$CTX" >"$LOG/build-p5.log" 2>&1 || { tail -30 "$LOG/build-p5.log"; exit 1; }
for t in "$P3" "$P4" "$P5"; do
  docker image inspect "$t" | jq -c --arg t "$t" '.[0] | {image: $t, id: .Id[7:19], size: .Size, labels: .Config.Labels}'
  echo "  agent in $t: sha256 $(docker run --rm --network none --entrypoint sha256sum "$t" /usr/local/bin/nvke-agent | cut -d' ' -f1), version [$(docker run --rm --network none --entrypoint /usr/local/bin/nvke-agent "$t" --version 2>&1 | head -2 | tr '\n' ' ')], marker [$(docker run --rm --network none --entrypoint cat "$t" /usr/share/podvm/image-form 2>/dev/null || true)]"
done | tee "$LOG/images.txt"
for t in "$P4" "$P5"; do
  f=$W/dl/img/$(echo "$t" | tr '/:' '__').tar
  if [ -e "$f" ]; then unlink "$f"; fi
  for n in $WORKERS; do docker exec "$n" ctr -n k8s.io images rm "docker.io/library/$t" >/dev/null 2>&1 || true; done
  t0=$(date +%s)
  "$W/bin/img-load.sh" "$t" $WORKERS
  echo "== $(utc) save and load of $t took $(( $(date +%s) - t0 )) s"
  for n in $WORKERS; do echo "$n: $(docker exec "$n" crictl inspecti -o json "docker.io/library/$t" 2>/dev/null | jq -r '.status.id + " " + (.status.size|tostring)' | cut -c8-40)"; done
done
echo "== $(utc) done"
