#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Build the node image for pod machines on top of the container node image of
# this repository. The base image must be in the local image store: this script
# pulls nothing, and the image build uses no network.
#
#   BASE_IMAGE  the container node image (controller/hack/capd-kindest-node)
#   IMAGE       the name of the new image

set -euo pipefail

: "${BASE_IMAGE:=cwe-capd-kindest-node:local}"
: "${IMAGE:=podvm-node:local}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
arch="$(docker image inspect --format '{{.Architecture}}' "${BASE_IMAGE}")"

build_context="$(mktemp -d)"
trap 'rm -rf "${build_context}"' EXIT
cp -R "${script_dir}/." "${build_context}/"

# The bootstrap program is a static binary for the architecture of the base image.
(cd "${script_dir}/bootstrap" &&
  CGO_ENABLED=0 GOOS=linux GOARCH="${arch}" go build -trimpath -ldflags '-s -w' -o "${build_context}/podvm-bootstrap" .)

docker build --network none --build-arg "BASE_IMAGE=${BASE_IMAGE}" -t "${IMAGE}" "${build_context}"
