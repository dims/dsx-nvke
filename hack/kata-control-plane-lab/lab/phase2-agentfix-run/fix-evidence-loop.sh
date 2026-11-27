#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# In the background during the tests: each 15 s read, from the agent journal of each node pod, the
# lines of the fix ("wrote the kubeadm config for upload-certs") and keep each new line with the
# node name. A node that NVKE deletes takes its journal with it, so the lines are saved here.
# The first time a node has such a line, its config file is saved too (it has no secret).
# Usage (detached): LOG_DIR=<run folder> setsid nohup p2-agentfix/fix-evidence-loop.sh >/dev/null 2>&1 &
# Stop: touch /root/kata-cp/work/.fix-evidence-stop
. /root/kata-cp/bin/env.sh
LOG_DIR=${LOG_DIR:?}
STOP=$W/work/.fix-evidence-stop
OUT=$LOG_DIR/fix-lines.txt
mkdir -p "$LOG_DIR/upload-certs-config"
[ -e "$STOP" ] && unlink "$STOP"
touch "$OUT"
# The time limit runs inside the kind node, so a call that hangs leaves no process behind.
k() { docker exec kata-bb-control-plane timeout 25 kubectl --kubeconfig /etc/kubernetes/admin.conf "$@"; }
while [ ! -e "$STOP" ]; do
  for m in $(k -n d get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    k -n d exec "$m" -- sh -c 'journalctl --no-pager -u nvke-agent 2>/dev/null | grep "wrote the kubeadm config for upload-certs" | sed -E "s/.*\"time\":\"([^\"]*)\".*\"path\":\"([^\"]*)\".*\"localAPIEndpoint\":\"([^\"]*)\".*/\\1 wrote \\2 localAPIEndpoint=\\3/"' 2>/dev/null | while read -r line; do
      grep -q -F "$m $line" "$OUT" || echo "$m $line" >>"$OUT"
    done
    if grep -q "^$m " "$OUT" && [ ! -s "$LOG_DIR/upload-certs-config/$m.yaml" ]; then
      k -n d exec "$m" -- cat /var/lib/nvke/kubeadm-upload-certs-config.yaml >"$LOG_DIR/upload-certs-config/$m.yaml" 2>/dev/null || true
    fi
  done
  sleep 15
done
unlink "$STOP"
