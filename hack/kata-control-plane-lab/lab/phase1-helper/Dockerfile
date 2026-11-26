# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# nvke-lab-bootstrap-helper: a static Go binary on a distroless image.
#
# The two base images are the ones that the NVKE controller image of the lab uses
# (controller/Dockerfile:17-18 at commit bcc4376f). The Go image comes through mirror.gcr.io.
# Both are in the local Docker store, so the build pulls no image. The build container
# downloads the Go modules from proxy.golang.org.
#
#   go.mod and go.sum:  docker build --target tidy --output type=local,dest=. .
#   test fixtures:      docker build --target fixtures --output type=local,dest=test/fixtures .
#   the image:          docker build -t nvke-lab-bootstrap-helper:dev .
ARG GOLANG_IMAGE=mirror.gcr.io/library/golang:1.27.4@sha256:fe517acaa580cc7915457080f850c37e618b3c1e750f98b58fc6429b605147a1
ARG RUNTIME_IMAGE=gcr.io/distroless/static-debian12:debug-nonroot@sha256:d5563cc7f2f44313f332e91138cc8c6a158899afeeeab2fce3b0f9ccdb3cf9ee

FROM ${GOLANG_IMAGE} AS source
ENV GOPROXY=https://proxy.golang.org|direct CGO_ENABLED=0 GOFLAGS=-buildvcs=false GOTOOLCHAIN=local
WORKDIR /src
COPY . .

FROM source AS tidy-run
RUN --mount=type=cache,target=/go/pkg/mod go mod tidy

FROM scratch AS tidy
COPY --from=tidy-run /src/go.mod /src/go.sum /

# The tests run the apply script with sh in this container, as root.
FROM source AS build
RUN --mount=type=cache,target=/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    go vet ./... && \
    go test -count=1 -v . && \
    go build -trimpath -ldflags "-s -w" -o /out/nvke-lab-bootstrap-helper . && \
    go run ./test/genfixture -out /out/fixtures

FROM scratch AS fixtures
COPY --from=build /out/fixtures/ /

FROM ${RUNTIME_IMAGE}
COPY --from=build /out/nvke-lab-bootstrap-helper /usr/local/bin/nvke-lab-bootstrap-helper
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/nvke-lab-bootstrap-helper"]
