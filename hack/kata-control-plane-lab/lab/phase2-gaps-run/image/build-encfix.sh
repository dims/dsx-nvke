#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Build the forms p9 and p10 of the node image for pods and load them into the host nodes.
# p9 = the content of p6 (p5 plus the health gate) with another agent binary: the binary that also
# has the fix of the encryption join defect (the file nvke-agent-encfix beside this script).
# p10 = p9 with another marker. Nothing else differs from p6 and p7.
# Usage: AGENT_SHA256=<sha256 of the binary on the workstation> p2-gaps/image/build-encfix.sh
set -euo pipefail
. /root/kata-cp/bin/env.sh
HERE="$(cd "$(dirname "$0")" && pwd)"
WANT=${AGENT_SHA256:?the sha256 of the agent binary with the fix, as the workstation gives it}
P5=nvke-node-podvm:bcc4376f-p5
P9=nvke-node-podvm:bcc4376f-p9
P10=nvke-node-podvm:bcc4376f-p10
KERNEL_CONFIG=${KERNEL_CONFIG:-$W/kbuild/out-sockdiag/opt/kata/share/kata-containers/config-6.18.62-211}
CTX=$W/work/p9-image-ctx
LOG=$W/logs/p2gaps/build-encfix
mkdir -p "$LOG"
[ -s "$HERE/nvke-agent-encfix" ] || { echo "no file $HERE/nvke-agent-encfix. Copy the agent binary with the fix first"; exit 1; }
echo "$WANT  $HERE/nvke-agent-encfix" | sha256sum -c -
rm -rf "$CTX"
mkdir -p "$CTX"
cp "$HERE/nvke-agent-encfix" "$CTX/nvke-agent"
cp "$HERE/Dockerfile.p9" "$HERE/Dockerfile.p10" "$HERE/endpoint-gate.env" "$HERE/podvm-endpoint-ready.in" "$HERE/gate-setup.sh" "$CTX/"
cp "$KERNEL_CONFIG" "$CTX/kernel-config"
( cd "$CTX" && find . -type f | sort | xargs sha256sum ) >"$LOG/context.sha256"
t0=$(date +%s)
docker build --network none --build-arg P5="$P5" --build-arg AGENT_SHA256="$WANT" -f "$CTX/Dockerfile.p9" -t "$P9" "$CTX" >"$LOG/build-p9.log" 2>&1 || { tail -30 "$LOG/build-p9.log"; exit 1; }
docker build --network none --build-arg P9="$P9" -f "$CTX/Dockerfile.p10" -t "$P10" "$CTX" >"$LOG/build-p10.log" 2>&1 || { tail -30 "$LOG/build-p10.log"; exit 1; }
echo "== $(utc) build of [$P9 $P10] took $(( $(date +%s) - t0 )) s"
for t in $P9 $P10; do
  echo "$t: id $(docker image inspect "$t" | jq -r '.[0].Id[7:19]'), agent sha256 $(docker run --rm --network none --entrypoint sha256sum "$t" /usr/local/bin/nvke-agent | cut -d' ' -f1), version [$(docker run --rm --network none --entrypoint /usr/local/bin/nvke-agent "$t" --version 2>&1 | head -1)], marker [$(docker run --rm --network none --entrypoint cat "$t" /usr/share/podvm/image-form)], $(docker run --rm --network none --entrypoint sh "$t" -c 'echo "probe reads the gate file: $(grep -c -F "[ -e " /usr/local/bin/podvm-endpoint-ready), settle: $(grep -o "gate-settle=[0-9a-z]*" /etc/systemd/system/nvke-agent.service.d/zz-podvm-endpoint-gate.conf | head -1)"')"
done | tee "$LOG/images.txt"
for t in $P9 $P10; do
  f=$W/dl/img/$(echo "$t" | tr '/:' '__').tar
  if [ -e "$f" ]; then unlink "$f"; fi
  for n in $WORKERS; do docker exec "$n" ctr -n k8s.io images rm "docker.io/library/$t" >/dev/null 2>&1 || true; done
  t0=$(date +%s)
  "$W/bin/img-load.sh" "$t" $WORKERS >/dev/null
  echo "== $(utc) save and load of $t took $(( $(date +%s) - t0 )) s: $(for n in $WORKERS; do docker exec "$n" crictl inspecti -o json "docker.io/library/$t" 2>/dev/null | jq -r '.status.id' | cut -c8-19; done | sort -u | tr '\n' ' ')"
done
echo "== $(utc) done"
