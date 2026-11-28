#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Render the cluster request of the Konnectivity prototype. It sends nothing. It needs envsubst
# and jq, and it runs on the machine and on the workstation.
#
# The base is the mixed request of phase 3, made by the render script of the lab as it is at
# that moment (p3/requests/render.sh cluster). This script only adds to its output:
#
#   direct        nothing. The request of phase 3: no flag, no file. The API server calls a
#                 kubelet directly. It is the request for pass rule 1
#   proxy         one API server flag and two files for each control plane node:
#                   controlPlaneConfig.apiServer.extraArgs["egress-selector-config-file"]
#                   controlPlaneConfig.infra.bootstrapFiles: the egress selector config and
#                   the static pod manifest of the proxy server (the two files of ../files)
#   direct-route  as direct, with the fallback of the design: one command for each control
#   proxy-route   plane node, "ip route replace blackhole <worker block>", in
#                 controlPlaneConfig.infra.preKubeadmCommands. Only when the NetworkPolicy has
#                 no effect on a Kata pod
#
# Usage: render.sh <variant> <out folder> [workers]
# Settings: P3_REQUESTS (the requests folder of phase 3, default /root/kata-cp/p3/requests),
#   NODE_IMAGE_REF (the pod image with the proxy server image inside), WORKER_BLOCK,
#   REQUEST_FORM=nowait (remove the lab wait for systemd from the pool commands, as p3ab.sh does),
#   and each setting of the render script of phase 3 (CLUSTER_NAME, IP_API, ...).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
FILES=$HERE/../files
P3_REQUESTS=${P3_REQUESTS:-/root/kata-cp/p3/requests}
export NODE_IMAGE_REF=${NODE_IMAGE_REF:-docker.io/library/nvke-node-podvm:bcc4376f-p11}
WORKER_BLOCK=${WORKER_BLOCK:-172.29.2.0/24}
# The paths on a control plane node. The first two are also in the two files of ../files.
EGRESS_FILE=/etc/kubernetes/policies/egress-selector-configuration.yaml
SOCKET=/etc/kubernetes/policies/konnectivity/konnectivity-server.socket
MANIFEST=/etc/kubernetes/manifests/konnectivity-server.yaml

variant=${1:-}
out=${2:-}
workers=${3:-2}
case "$variant" in direct | proxy | proxy-ds | direct-route | proxy-route) ;; *) sed -n '2,24p' "$0"; exit 1 ;; esac
[ -n "$out" ] || { echo "no out folder"; exit 1; }
[ -x "$P3_REQUESTS/render.sh" ] || { echo "no render script of phase 3 at $P3_REQUESTS/render.sh"; exit 1; }
mkdir -p "$out"

# The base request, by the lab script. It writes <out>/cluster-request.json.
"$P3_REQUESTS/render.sh" cluster "$out" "$workers" >"$out/base-render.txt" || { cat "$out/base-render.txt"; exit 1; }
mv "$out/cluster-request.json" "$out/base-request.json"
req=$out/cluster-request-$variant.json
cp "$out/base-request.json" "$req.tmp"

if [ "${REQUEST_FORM:-wait}" = nowait ]; then
  jq '(.nodePools[].infra.preKubeadmCommands) |= map(select(test("lab wait for systemd") | not))' "$req.tmp" >"$req.tmp2"
  mv "$req.tmp2" "$req.tmp"
fi

case "$variant" in
  proxy | proxy-route)
    # The two files must name the same socket as this script, and the file size limit of the
    # API is 10240 characters for one file (CloudInitFile in controller/api/openapi.yaml).
    grep -q -F "udsName: $SOCKET" "$FILES/egress-selector-configuration.yaml" || { echo "the egress selector config does not name $SOCKET"; exit 1; }
    grep -q -F -- "--uds-name=$SOCKET" "$FILES/konnectivity-server.yaml" || { echo "the static pod manifest does not name $SOCKET"; exit 1; }
    for f in egress-selector-configuration.yaml konnectivity-server.yaml; do
      [ "$(wc -m <"$FILES/$f")" -le 10240 ] || { echo "$f has more than 10240 characters"; exit 1; }
    done
    jq --arg flag "$EGRESS_FILE" --arg manifest "$MANIFEST" \
      --rawfile egress "$FILES/egress-selector-configuration.yaml" --rawfile pod "$FILES/konnectivity-server.yaml" '
      .controlPlaneConfig.apiServer.extraArgs["egress-selector-config-file"] = $flag
      | .controlPlaneConfig.infra.bootstrapFiles = ((.controlPlaneConfig.infra.bootstrapFiles // []) + [
          {path: $flag, owner: "root:root", permissions: "0644", content: $egress},
          {path: $manifest, owner: "root:root", permissions: "0600", content: $pod}
        ])' "$req.tmp" >"$req.tmp2"
    mv "$req.tmp2" "$req.tmp"
    ;;
esac
case "$variant" in
  proxy-ds)
    # The flag and the egress selector file only. The proxy server comes as a DaemonSet of the
    # new cluster (manifests/konnectivity-server-ds.yaml.tmpl), not as a static pod of the request.
    grep -q -F "udsName: $SOCKET" "$FILES/egress-selector-configuration.yaml" || { echo "the egress selector config does not name $SOCKET"; exit 1; }
    jq --arg flag "$EGRESS_FILE" --rawfile egress "$FILES/egress-selector-configuration.yaml" '
      .controlPlaneConfig.apiServer.extraArgs["egress-selector-config-file"] = $flag
      | .controlPlaneConfig.infra.bootstrapFiles = ((.controlPlaneConfig.infra.bootstrapFiles // []) + [
          {path: $flag, owner: "root:root", permissions: "0644", content: $egress}
        ])' "$req.tmp" >"$req.tmp2"
    mv "$req.tmp2" "$req.tmp"
    ;;
esac
case "$variant" in
  direct-route | proxy-route)
    jq --arg cmd "ip route replace blackhole $WORKER_BLOCK" '
      .controlPlaneConfig.infra.preKubeadmCommands = ((.controlPlaneConfig.infra.preKubeadmCommands // []) + [$cmd])' "$req.tmp" >"$req.tmp2"
    mv "$req.tmp2" "$req.tmp"
    ;;
esac
mv "$req.tmp" "$req"
jq -e . "$req" >/dev/null || { echo "the request is not JSON"; exit 1; }

echo "$req: $(jq -c '{name, endpoint: .controlPlaneEndpoint, cluster: .infra.cluster.kind,
  controlPlane: "\(.controlPlaneConfig.desiredCount) x \(.controlPlaneConfig.infra.machineTemplate.kind)",
  image: .controlPlaneConfig.infra.machineTemplate.spec.template.spec.image,
  apiServerExtraArgs: (.controlPlaneConfig.apiServer.extraArgs // {}),
  bootstrapFiles: [(.controlPlaneConfig.infra.bootstrapFiles // [])[] | "\(.path) \(.permissions) \(.owner) \(.content | length) characters"],
  controlPlaneCommands: (.controlPlaneConfig.infra.preKubeadmCommands // []),
  pools: [.nodePools[]? | "\(.name): \(.desiredNodeCount) x \(.infra.machineTemplate.kind), \(.infra.preKubeadmCommands | length) commands"]}' "$req")"
echo "difference to the request of phase 3 (paths that are new or changed): $(jq -n --slurpfile a "$out/base-request.json" --slurpfile b "$req" -r '[$b[0] | paths(scalars)] - [$a[0] | paths(scalars)] | map(map(tostring) | join(".")) | join(" ")')"
