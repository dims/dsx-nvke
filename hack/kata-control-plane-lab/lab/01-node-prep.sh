#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Changes to the kind node that make it equal to a real node for Kata and for raw block volumes.
# Run it after lab/00-host-setup.sh, and again after each restart of the node container.
set -euo pipefail
NODE=${NODE:-kata-cp-control-plane}

# 1. D-Bus system bus. The Rust runtime of Kata asks systemd over D-Bus for the cgroup of each sandbox.
docker exec "$NODE" sh -c 'command -v dbus-daemon >/dev/null || { export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq --no-install-recommends dbus; }; systemctl start dbus.socket dbus.service; ls -l /run/dbus/system_bus_socket'

# 2. Loop device nodes. The kubelet attaches one loop device for each raw block volume (losetup -f).
#    The kernel makes a new loop device on request, but the /dev of a container does not get its node.
docker exec "$NODE" sh -c 'for i in $(seq 0 127); do [ -e /dev/loop$i ] || { mknod -m 660 /dev/loop$i b 7 $i && chgrp disk /dev/loop$i; }; done; ls /dev/loop[0-9]* | wc -l'
