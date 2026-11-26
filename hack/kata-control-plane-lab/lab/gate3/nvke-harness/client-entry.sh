#!/bin/sh
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Container command of the client pod: run a SPIRE agent with the files from the Secret.
# The client reads its identity from the default socket, /tmp/spire-agent/public/api.sock.
set -eu
install -d -m 0755 /etc/spire-agent
install -m 0644 /lab-spire/agent.conf /lab-spire/initial-trust-bundle.pem /etc/spire-agent/
exec /usr/local/bin/spire-agent run -config /etc/spire-agent/agent.conf
