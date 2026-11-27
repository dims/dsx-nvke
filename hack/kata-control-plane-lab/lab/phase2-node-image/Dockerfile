# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# The node image for pods (phase 2, step 3): the NVKE node image plus what the pod of the podvm
# provider needs (design note, sections 5a and 6). With no command and no arguments in the pod
# spec, the container comes up as an NVKE node.
#
# Build (on the lab machine, by build.sh): the context has this file, bootstrap/, units/,
# podvm-entrypoint, ovs-datapath-check, kernel-config (the config of the guest kernel) and
# images/*.tar (container images that a node of this lab cannot pull).
# The Docker of the lab machine has the legacy builder only, so no RUN --mount here.
ARG BASE=nvke-node:bcc4376f-amd64
ARG GO_IMAGE=golang:1.27.4

# --- the bootstrap program: a static binary, with its tests and the test data -----------------
FROM ${GO_IMAGE} AS build
ENV CGO_ENABLED=0 GOFLAGS="-buildvcs=false -mod=mod" GOTOOLCHAIN=local
WORKDIR /src
COPY bootstrap/ ./
RUN go vet ./... && \
    go test -count=1 . && \
    go build -trimpath -ldflags "-s -w" -o /out/podvm-bootstrap . && \
    go run ./genfixture -out /out/fixtures

# --- the node image ---------------------------------------------------------------------------
FROM ${BASE}
# The release of the guest kernel (uname -r) that kernel-config belongs to.
ARG KERNEL_RELEASE=6.18.62

# 1. The entry point: volumes, node state, kernel settings, then the entry point of the base image.
COPY podvm-entrypoint /usr/local/bin/podvm-entrypoint

# 2. The bootstrap data of NVKE: one program, two units (files before the SPIRE agent, commands
#    after multi-user.target). The cloud-init answer comes from the shim of the base image.
COPY --from=build /out/podvm-bootstrap /usr/local/bin/podvm-bootstrap
COPY units/podvm-bootstrap.service units/podvm-bootstrap-final.service /etc/systemd/system/

# 3. Open vSwitch accepts a datapath that is built into the kernel.
COPY ovs-datapath-check /usr/local/lib/podvm/ovs-datapath-check
COPY units/zz-podvm-builtin-datapath.conf /etc/systemd/system/ovs-vswitchd.service.d/zz-podvm-builtin-datapath.conf

# 4. The kernel config for the system check of kubeadm. The guest kernel has no /proc/config.gz.
COPY kernel-config /boot/config-${KERNEL_RELEASE}

# 5. Container images from files. The tar files stay in this layer (the legacy builder has no
#    bind mount for a RUN step); the next step imports them and removes the copies.
COPY images/ /tmp/podvm-images/

RUN set -eu; \
    chmod 0755 /usr/local/bin/podvm-entrypoint /usr/local/bin/podvm-bootstrap /usr/local/lib/podvm/ovs-datapath-check; \
    chmod 0644 /etc/systemd/system/podvm-bootstrap.service /etc/systemd/system/podvm-bootstrap-final.service \
      /etc/systemd/system/ovs-vswitchd.service.d/zz-podvm-builtin-datapath.conf "/boot/config-${KERNEL_RELEASE}"; \
    mkdir -p /etc/systemd/system/multi-user.target.wants; \
    ln -s ../podvm-bootstrap.service /etc/systemd/system/multi-user.target.wants/podvm-bootstrap.service; \
    ln -s ../podvm-bootstrap-final.service /etc/systemd/system/multi-user.target.wants/podvm-bootstrap-final.service; \
    # The agent settings live on the /var volume. /etc/default/nke-agent is a link to
    # /etc/default/nvke-agent in the base image, and NVKE writes through it.
    mkdir -p /var/lib/podvm/agent /var/lib/podvm/bootstrap; \
    mv /etc/default/nvke-agent /var/lib/podvm/agent/nvke-agent; \
    ln -s /var/lib/podvm/agent/nvke-agent /etc/default/nvke-agent; \
    # The base image has a D-Bus machine ID file in /var, and systemd-machine-id-setup (in the kind
    # entry point) takes it first, so each node of the base image has the same machine ID. A link
    # (the Debian form) is not taken, and the ID comes from the UUID that the entry point keeps on
    # the /var volume of the Machine (container_uuid).
    ln -sf /etc/machine-id /var/lib/dbus/machine-id; \
    # The images go into the containerd store of the image, not unpacked, as kind does it for a
    # node image. containerd unpacks an image at its first use.
    containerd >/tmp/podvm-build-containerd.log 2>&1 & pid=$!; \
    i=0; until ctr version >/dev/null 2>&1; do i=$((i + 1)); if [ "$i" -gt 30 ]; then cat /tmp/podvm-build-containerd.log; exit 1; fi; sleep 1; done; \
    for f in /tmp/podvm-images/*.tar; do ctr -n k8s.io images import --no-unpack --platform linux/amd64 "$f"; done; \
    # The DNS cache DaemonSet of NVKE names its image by digest.
    ctr -n k8s.io images tag --force registry.k8s.io/dns/k8s-dns-node-cache:1.26.8 \
      registry.k8s.io/dns/k8s-dns-node-cache@sha256:bc6e64e2c85956af2fcc0aa720086410d41b4f31f378c9a92646fecc85cd4739; \
    ctr -n k8s.io images ls -q | grep -E 'registry.k8s.io/pause:3.10.2$'; \
    ctr -n k8s.io images ls -q | grep -E 'k8s-dns-node-cache'; \
    kill "$pid"; wait "$pid" || true; \
    rm -rf /tmp/podvm-images /tmp/podvm-build-containerd.log /run/containerd

LABEL podvm.contract="phase2-design 5a version 1" podvm.kernel-release="${KERNEL_RELEASE}"
ENTRYPOINT ["/usr/local/bin/podvm-entrypoint"]
