#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Identity test for a node that is down for longer than the life of its SPIRE agent SVID.
# A join token works one time, and the server cannot attest the agent again ("Can re-attest: false").
# So the question is: what happens when the agent SVID expires while the node pod is absent?
#
# The test uses a second SPIRE server with a short agent SVID life (agent_ttl), in its own
# namespace, so the main server keeps the SPIRE default of 1 hour. The node pod uses runc.
# Steps:
#   1. node pod with mTLS, kubeadm init through the agent, one authenticated call (must pass)
#   2. delete the node pod, wait longer than agent_ttl, make a new pod on the same volumes
#   3. record the state of spire-agent and nvke-agent, and one client call (expected: no identity)
#   4. repair in the running pod: a new join token in /etc/spire-agent/agent.conf and a restart of
#      spire-agent only. Record if the agent port opens with no restart of nvke-agent.
# Usage: ttl-test.sh        Variables: AGENT_TTL (default 2m), GAP (seconds with no pod, default 170)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
AGENT_TTL=${AGENT_TTL:-2m}
GAP=${GAP:-170}
export MODE=mtls NS=${NS:-gate1-nvke} NAME=${NAME:-nvke-cp}
export SPIRE_NS=gate1-nvke-spire-ttl TRUST_DOMAIN=lab.nvke.test
export LOG_DIR=${LOG_DIR:-/scratch/kata-cp/logs/gate1-nvke/b-runc-agent-svid-expiry}
KIND_NODE=kata-cp-control-plane
KC=(kubectl --kubeconfig /etc/kubernetes/admin.conf)
SEC="$LOG_DIR/secrets"
mkdir -p "$SEC"
chmod 700 "$SEC"

node() { docker exec "$KIND_NODE" "$@"; }
nodei() { docker exec -i "$KIND_NODE" "$@"; }
k() { node "${KC[@]}" "$@"; }
pod() { k -n "$NS" exec "$NAME" -- "$@"; }
cpod() { k -n "$NS" exec lab-client -- "$@"; }
spire() { k -n "$SPIRE_NS" exec spire-server-0 -- /opt/spire/bin/spire-server "$@"; }
say() { echo "== $*"; }
mask() { sed -E 's#(join_token/)[0-9a-f-]+#\1TOKEN#g; s#(join_token = ")[^"]*#\1TOKEN#g'; }
agent_id() { echo "spiffe://$TRUST_DOMAIN/host/$(cat "$LOG_DIR/node-uuid.txt")"; }
# The state of the two agents in the node, and one call of the client. No step here stops the script.
observe() {
  say "state ($1) at $(date -u +%FT%TZ)"
  pod sh -c 'echo "spire-agent: $(systemctl is-active spire-agent), restarts $(systemctl show -p NRestarts --value spire-agent)"
    echo "nvke-agent: $(systemctl is-active nvke-agent), since $(systemctl show -p ActiveEnterTimestamp --value nvke-agent), restarts $(systemctl show -p NRestarts --value nvke-agent), main PID $(systemctl show -p MainPID --value nvke-agent)"
    echo "listeners on port 15005: $(ss -ltn | grep -c ":15005 ")"
    journalctl --no-pager -b -u spire-agent | grep -v level=debug | grep -i -E "expired|attest|SVID loaded|error" | cut -c1-360 | tail -6
    journalctl --no-pager -b -u nvke-agent | grep -o "\"msg\":\"[^\"]*\"" | tail -3' 2>&1 | mask || true
  cpod /lab-bin/nvke-lab-client -addr "$NAME.$NS.svc.cluster.local:15005" -expect-id "$(agent_id)" -steps status,spire -wait 20s 2>&1 | cut -c1-420 || true
}

{
  say "second SPIRE server with agent_ttl = $AGENT_TTL in the namespace $SPIRE_NS"
  sed -e "s/gate1-nvke-spire/$SPIRE_NS/g" -e "s/default_x509_svid_ttl = \"1h\"/&\n      agent_ttl = \"$AGENT_TTL\"/" "$HERE/spire-server.yaml" >"$LOG_DIR/spire-server-ttl.yaml"
  nodei "${KC[@]}" apply -f - <"$LOG_DIR/spire-server-ttl.yaml"
  node bash -c "for i in \$(seq 1 90); do [ \"\$(${KC[*]} -n $SPIRE_NS get pod spire-server-0 -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)\" = true ] && exit 0; sleep 1; done; exit 1"

  say "1. node pod, kubeadm init through the agent, one authenticated call"
  "$HERE/run.sh" wipe | tail -1
  "$HERE/run.sh" identities | grep -E '^== (node|join)'
  "$HERE/run.sh" up | tail -1
  "$HERE/run.sh" init | grep -E '^==|client failed'
  "$HERE/run.sh" spire 1-after-init | grep -E 'RESULT|Expiration|Serial|peer_id' | cut -c1-260
  date -u +%s >"$LOG_DIR/pod-delete-time.txt"

  say "2. delete the node pod, wait $GAP s (agent_ttl is $AGENT_TTL), then make a new pod on the same volumes"
  k -n "$NS" delete pod "$NAME" --wait=true
  sleep "$GAP"
  nodei "${KC[@]}" apply -f - <"$LOG_DIR/node-pod.yaml" | tail -1
  node bash -c "for i in \$(seq 1 120); do ${KC[*]} -n $NS exec $NAME -- systemctl is-active containerd >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1"
  sleep 20
  say "the pod was absent for $(($(date -u +%s) - $(cat "$LOG_DIR/pod-delete-time.txt"))) s"

  say "3. the node after the life of its agent SVID"
  observe after-expiry
  spire agent show -spiffeID "spiffe://$TRUST_DOMAIN/spire/agent/join_token/$(awk '/^Token:/ {print $2}' "$SEC/node-token.txt")" 2>&1 | mask || true

  say "4. repair in the running pod: a new join token, a new agent.conf, a restart of spire-agent only"
  ( umask 077
    spire token generate -spiffeID "spiffe://$TRUST_DOMAIN/join-token-spire-agent/host-id/$(cat "$LOG_DIR/node-uuid.txt")" -ttl 3600 >"$SEC/node-token-2.txt"
    sed "s/^\(    join_token = \"\)[^\"]*/\1$(awk '/^Token:/ {print $2}' "$SEC/node-token-2.txt")/" "$SEC/node-agent.conf" >"$SEC/node-agent-2.conf" )
  nodei "${KC[@]}" -n "$NS" exec -i "$NAME" -- sh -c 'cat >/etc/spire-agent/agent.conf && systemctl restart spire-agent' <"$SEC/node-agent-2.conf"
  sleep 15
  observe after-new-token
  say "the agents of the node on the server (old token, then new token)"
  for t in node-token.txt node-token-2.txt; do
    spire agent show -spiffeID "spiffe://$TRUST_DOMAIN/spire/agent/join_token/$(awk '/^Token:/ {print $2}' "$SEC/$t")" 2>&1 | mask | grep -E 'Found|Expiration|Serial|re-attest|rror' || true
  done

  "$HERE/run.sh" logs | tail -1
  "$HERE/run.sh" down | tail -1
  say "remove the second SPIRE server"
  k delete namespace "$SPIRE_NS" --wait=true
} 2>&1 | tee "$LOG_DIR/ttl-test.txt"
