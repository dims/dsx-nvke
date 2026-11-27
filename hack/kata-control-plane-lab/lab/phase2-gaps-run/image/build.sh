#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Build the forms p6 and p7 of the node image for pods and load them into the host nodes.
# p6 = p5 plus the health gate of the shared address (Dockerfile.p6). p7 = p6 with another marker.
# With WITH_P8=1 also p8-nogate (the proposal for pass rule 4).
#
# Before the build, copy the new agent binary beside this script (the file nvke-agent):
#   on the workstation:  ws-sync.sh agent     (it copies /scratch/kata-cp/work/phase2-gaps/bin/nvke-agent)
# Usage: AGENT_SHA256=<sha256 of the binary on the workstation> p2-gaps/image/build.sh
set -euo pipefail
. /root/kata-cp/bin/env.sh
HERE="$(cd "$(dirname "$0")" && pwd)"
WANT=${AGENT_SHA256:?the sha256 of the new agent binary, as the workstation gives it}
P5=nvke-node-podvm:bcc4376f-p5
P6=nvke-node-podvm:bcc4376f-p6
P7=nvke-node-podvm:bcc4376f-p7
P8=nvke-node-podvm:bcc4376f-p8-nogate
KERNEL_CONFIG=${KERNEL_CONFIG:-$W/kbuild/out-sockdiag/opt/kata/share/kata-containers/config-6.18.62-211}
CTX=$W/work/p6-image-ctx
LOG=$W/logs/p2gaps/build
mkdir -p "$LOG"
[ -s "$HERE/nvke-agent" ] || { echo "no file $HERE/nvke-agent. Copy the new agent binary first"; exit 1; }
echo "$WANT  $HERE/nvke-agent" | sha256sum -c -
grep -q '^CONFIG_INET_DIAG_DESTROY=y' "$KERNEL_CONFIG" || { echo "the kernel config $KERNEL_CONFIG has no INET_DIAG_DESTROY"; exit 1; }
rm -rf "$CTX"
mkdir -p "$CTX"
# The copy step of the agent binary and of the rest of the build context.
cp "$HERE/nvke-agent" "$HERE/Dockerfile.p6" "$HERE/Dockerfile.p7" "$HERE/Dockerfile.p8-nogate" "$HERE/endpoint-gate.env" "$HERE/podvm-endpoint-ready.in" "$HERE/gate-setup.sh" "$CTX/"
cp "$KERNEL_CONFIG" "$CTX/kernel-config"
( cd "$CTX" && find . -type f | sort | xargs sha256sum ) | tee "$LOG/context.sha256"
t0=$(date +%s)
docker build --network none --build-arg P5="$P5" --build-arg AGENT_SHA256="$WANT" -f "$CTX/Dockerfile.p6" -t "$P6" "$CTX" >"$LOG/build-p6.log" 2>&1 || { tail -30 "$LOG/build-p6.log"; exit 1; }
docker build --network none --build-arg P6="$P6" -f "$CTX/Dockerfile.p7" -t "$P7" "$CTX" >"$LOG/build-p7.log" 2>&1 || { tail -30 "$LOG/build-p7.log"; exit 1; }
TAGS="$P6 $P7"
if [ "${WITH_P8:-0}" = 1 ]; then
  docker build --network none --build-arg P7="$P7" -f "$CTX/Dockerfile.p8-nogate" -t "$P8" "$CTX" >"$LOG/build-p8.log" 2>&1 || { tail -30 "$LOG/build-p8.log"; exit 1; }
  TAGS="$TAGS $P8"
fi
echo "== $(utc) build of [$TAGS] took $(( $(date +%s) - t0 )) s"
sed -n '/^== \/usr\/local\/bin\/podvm-endpoint-ready/,$p' "$LOG/build-p6.log" | grep -v -E '^( ---> |Removing|Successfully|Step )' | head -30
for t in $P5 $TAGS; do
  docker image inspect "$t" | jq -c --arg t "$t" '.[0] | {image: $t, id: .Id[7:19], size: .Size, labels: .Config.Labels}'
  echo "  in $t: agent sha256 $(docker run --rm --network none --entrypoint sha256sum "$t" /usr/local/bin/nvke-agent | cut -d' ' -f1), version [$(docker run --rm --network none --entrypoint /usr/local/bin/nvke-agent "$t" --version 2>&1 | head -1)], marker [$(docker run --rm --network none --entrypoint cat "$t" /usr/share/podvm/image-form 2>/dev/null || true)]"
  echo "  in $t: $(docker run --rm --network none --entrypoint sh "$t" -c 'f=/usr/local/bin/podvm-endpoint-ready; if [ -e $f ]; then echo "probe program: mode $(stat -c %a $f), $(stat -c %s $f) bytes, reads the gate file: $(grep -c -e "-e \"" $f)"; else echo "probe program: none"; fi; d=/etc/systemd/system/nvke-agent.service.d/zz-podvm-endpoint-gate.conf; if [ -e $d ]; then grep -E "^(Environment|ExecStart)" $d | tr "\n" ";"; else echo "drop-in for the gate: none"; fi; echo; echo "kernel config: $(grep -c -E "^CONFIG_(INET_DIAG|INET_TCP_DIAG|INET_DIAG_DESTROY)=y" /boot/config-6.18.62) of 3 socket options, ss with -K: $(ss --help 2>&1 | grep -c -- "-K, --kill"), gate folder: $(ls -ld /var/lib/nvke | cut -c1-10)"')"
done | tee "$LOG/images.txt"
for t in $TAGS; do
  f=$W/dl/img/$(echo "$t" | tr '/:' '__').tar
  if [ -e "$f" ]; then unlink "$f"; fi
  for n in $WORKERS; do docker exec "$n" ctr -n k8s.io images rm "docker.io/library/$t" >/dev/null 2>&1 || true; done
  t0=$(date +%s)
  "$W/bin/img-load.sh" "$t" $WORKERS
  echo "== $(utc) save and load of $t took $(( $(date +%s) - t0 )) s"
  for n in $WORKERS; do echo "$n: $(docker exec "$n" crictl inspecti -o json "docker.io/library/$t" 2>/dev/null | jq -r '.status.id + " " + (.status.size|tostring)' | cut -c8-40)"; done
done
echo "== $(utc) done"
