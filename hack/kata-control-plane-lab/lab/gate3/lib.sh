# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Helper functions for the gate 3 scripts (paths 2 and 3). Source this file.
# Each kubectl call runs inside the kind node (docker exec), so the host opens no TCP connection.
KIND_NODE=${KIND_NODE:-kata-cp-control-plane}
G3=/scratch/kata-cp/work/gate3
LOGS=/scratch/kata-cp/logs/gate3
SEC=/scratch/kata-cp/work/gate3/secrets     # trust bundle, tokens. Never in ~/notes
SPIRE_NS=gate3-spire
NS=gate3
TD=gate3.lab.test
KC=(kubectl --kubeconfig /etc/kubernetes/admin.conf)

node() { docker exec "$KIND_NODE" "$@"; }
nodei() { docker exec -i "$KIND_NODE" "$@"; }
k() { node "${KC[@]}" "$@"; }
ki() { nodei "${KC[@]}" "$@"; }
spire() { k -n "$SPIRE_NS" exec spire-server-0 -- /opt/spire/bin/spire-server "$@"; }
say() { echo "== $*"; }
# wait_node <seconds> <shell test>: repeat the test in the kind node, one time each second.
wait_node() {
  local t=$1
  shift
  node bash -c "for i in \$(seq 1 $t); do if $*; then exit 0; fi; sleep 1; done; exit 1"
}
# A join token is part of the SPIFFE ID of a join token agent. Remove it from output that a person reads.
mask() { sed -E 's#(join_token/)[0-9a-f-]+#\1TOKEN#g; s#(join_token = ")[^"]*#\1TOKEN#g; s#(Token: )[0-9a-f-]+#\1TOKEN#g'; }
