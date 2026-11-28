# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# The node image for the pods of cluster-api-provider-podvm: the container node
# image of this repository (controller/hack/capd-kindest-node) plus what the pod
# contract needs. build-image.sh makes the build context: the files of this
# folder and the program podvm-bootstrap. The build uses no network.

ARG BASE_IMAGE=cwe-capd-kindest-node:local
FROM ${BASE_IMAGE}

COPY podvm-entrypoint podvm-bootstrap podvm-endpoint-ready /usr/local/bin/
COPY format-if-empty ovs-datapath-check build-ctr /usr/local/lib/podvm/
COPY units/podvm-bootstrap.service units/podvm-bootstrap-final.service /etc/systemd/system/
COPY units/zz-podvm-builtin-datapath.conf /etc/systemd/system/ovs-vswitchd.service.d/
COPY units/zz-podvm-endpoint-gate.conf /etc/systemd/system/nvke-agent.service.d/

# The node agent settings move to the /var volume, behind a link: the bootstrap
# data writes them through the link, and they stay through a new pod.
#
# The base image carries a D-Bus machine ID file, and systemd takes that file
# first, so each node of the base image has the same machine ID. With a link in
# its place the ID comes from the UUID that the entry point keeps on the volume.
RUN set -eu; \
    chmod 0755 /usr/local/bin/podvm-* /usr/local/lib/podvm/*; \
    chmod 0644 /etc/systemd/system/podvm-bootstrap*.service /etc/systemd/system/*.service.d/zz-podvm-*.conf; \
    SYSTEMD_OFFLINE=1 systemctl enable podvm-bootstrap.service podvm-bootstrap-final.service; \
    test -x /usr/bin/curl; \
    command -v blkid >/dev/null; command -v mkfs.ext4 >/dev/null; \
    mkdir -p /var/lib/podvm/agent; \
    mv /etc/default/nvke-agent /var/lib/podvm/agent/nvke-agent; \
    ln -s /var/lib/podvm/agent/nvke-agent /etc/default/nvke-agent; \
    ln -sf /etc/machine-id /var/lib/dbus/machine-id

# zz-podvm-endpoint-gate.conf gives the node agent the flags of the health gate.
# An agent stops at a flag that it does not know, so the drop-in stays only
# when the agent of the base image knows each flag of the drop-in.
RUN set -eu; \
    dropin=/etc/systemd/system/nvke-agent.service.d/zz-podvm-endpoint-gate.conf; \
    help="$(/usr/local/bin/nvke-agent --help 2>&1 || true)"; \
    for flag in $(grep -o -e '--control-plane-endpoint-[a-z-]*' "$dropin"); do \
      case "$help" in \
        *" ${flag#-} "*) ;; \
        *) echo "NOTICE: nvke-agent has no flag $flag. This image sets no health gate flags."; rm "$dropin"; break ;; \
      esac; \
    done; \
    [ ! -e "$dropin" ] || grep -q -x 'ExecStart=/usr/local/bin/nvke-agent \$AGENT_ARGS' /etc/systemd/system/nvke-agent.service \
      || { echo "ERROR: nvke-agent.service has another ExecStart line than the drop-in replaces"; exit 1; }

# A base image with a CNI image package installs it at each start, before the
# agents (nke-container-cni-images.service). Install it here, one time. That
# unit does not run when the package file is gone.
RUN set -eu; \
    deb=/usr/lib/nvke/e2e/cni-images.deb; \
    if [ -f "$deb" ]; then \
      containerd >/tmp/containerd.log 2>&1 & \
      NKE_CTR_BIN=/usr/local/lib/podvm/build-ctr dpkg --ignore-depends=containerd,nvke-kubeadm-distro -i "$deb" \
        || { cat /tmp/containerd.log; exit 1; }; \
      kill "$!"; wait "$!" || true; \
      rm -rf "$deb" /tmp/containerd.log /run/containerd; \
    fi; \
    rm /usr/local/lib/podvm/build-ctr

ENTRYPOINT ["/usr/local/bin/podvm-entrypoint"]
