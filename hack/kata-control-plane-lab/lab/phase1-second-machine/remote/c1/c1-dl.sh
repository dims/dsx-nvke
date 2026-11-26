#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Block C1, downloads on the machine itself (no cluster change): the CNI plugins release (for the
# plugins "bridge" and "static", which a kind node does not have), the Multus manifest and image,
# and a small python image for the test pods.
# Removal: rm -rf /root/kata-cp/dl/c1; docker rmi <the two images>
set -euo pipefail
. /root/kata-cp/bin/env.sh
D=$W/dl/c1
mkdir -p "$D" && cd "$D"
latest() { curl -fsSI -o /dev/null -w '%{redirect_url}' "https://github.com/$1/releases/latest" | sed 's#.*/tag/##'; }
CNI_VERSION=$(latest containernetworking/plugins)
MULTUS_VERSION=$(latest k8snetworkplumbingwg/multus-cni)
echo "CNI plugins $CNI_VERSION, Multus $MULTUS_VERSION"
echo "$CNI_VERSION" >cni-version; echo "$MULTUS_VERSION" >multus-version
f=cni-plugins-linux-amd64-$CNI_VERSION.tgz
curl -fsSL -o "$f" "https://github.com/containernetworking/plugins/releases/download/$CNI_VERSION/$f"
curl -fsSL -o "$f.sha256" "https://github.com/containernetworking/plugins/releases/download/$CNI_VERSION/$f.sha256"
cat "$f.sha256"; sha256sum -c "$f.sha256"
mkdir -p cni-bin && tar -xzf "$f" -C cni-bin ./bridge ./static
ls -la cni-bin
curl -fsSL -o multus-daemonset.yml "https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/$MULTUS_VERSION/deployments/multus-daemonset.yml"
sha256sum multus-daemonset.yml
grep -n -E 'image:|imagePullPolicy|multus-conf-file|args:|command:' multus-daemonset.yml
for img in "ghcr.io/k8snetworkplumbingwg/multus-cni:$MULTUS_VERSION" python:3.13-alpine; do
  docker pull -q "$img"
  docker image inspect "$img" --format '{{.RepoDigests}} {{.Size}}'
done
echo "C1 DL DONE"
