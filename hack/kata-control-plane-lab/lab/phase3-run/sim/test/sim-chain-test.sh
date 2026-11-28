#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# The chain nico-sim -> docker-two-nets -> docker on the workstation, with the real simulator
# binary and with fake-docker in the place of docker. No container, no network, no daemon.
# The simulator listens on 127.0.0.1 only, for the time of the test, and this script ends it
# by its process ID.
#
# It answers three questions that the unit test cannot:
#   1. Does the simulator start with the settings of run-sim.sh (step B)?
#   2. What does the simulator pass to its Docker program for one instance request?
#   3. Which address does the simulator report for a container with two networks?
# Usage: sim-chain-test.sh <nico-sim binary> <seed file> [port]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN=${1:?the nico-sim binary}
SEED=${2:?the seed file}
PORT=${3:-38080}
S=$(mktemp -d "${TMPDIR:-/tmp}/p3-chain-test.XXXXXX")
mkdir -p "$S/files" "$S/fake"
URL=http://127.0.0.1:$PORT
ORG=novxwn552ssc
TOKEN=example-token
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $*"; }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }
check() { local text=$1; shift; if "$@"; then ok "$text"; else bad "$text"; fi; }
api() { # <method> <path> [body file]
  if [ -n "${3:-}" ]; then
    curl -sS --max-time 20 -X "$1" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' --data-binary "@$3" -w '\nHTTP %{http_code}\n' "$URL$2"
  else
    curl -sS --max-time 20 -X "$1" -H "Authorization: Bearer $TOKEN" -w '\nHTTP %{http_code}\n' "$URL$2"
  fi
}
body() { sed '$d'; }

# The settings of run-sim.sh for step B. Three differ for the test: the listen address is the
# loopback address, the Docker program is the fake, and the two DHCP paths of the VM backend
# point into the state folder (the VM backend is "mock" and does not use them).
env -i PATH="$PATH" HOME="$S" \
  NICO_SIM_LISTEN_ADDR="127.0.0.1:$PORT" \
  NICO_SIM_SEED_PATH="$SEED" \
  NICO_SIM_DB_PATH="$S/nico-sim.db" \
  NICO_SIM_FILES_DIR="$S/files" \
  NICO_SIM_LOG_FORMAT=text NO_COLOR=1 \
  NICO_VMS_VM_BACKEND=mock \
  NICO_VMS_BGP_ENABLED=false \
  NICO_VMS_BRIDGE_CIDR=172.30.0.0/24 \
  NICO_VMS_CONSOLE_SSH_PORT=-1 \
  NICO_VMS_DHCP_HOSTS_DIR="$S/dhcp-hosts" NICO_VMS_DHCP_LEASE_FILE="$S/dhcp-leases" \
  NICO_CONTAINERS_ENABLED=true \
  NICO_CONTAINERS_NODE_IMAGE=nvke-node-nico:bcc4376f-w1 \
  NICO_CONTAINERS_NODE_NETWORK=kata-bb-node \
  NICO_CONTAINERS_SPIRE_ATTESTATION_METHOD=joinToken \
  NICO_CONTAINERS_DOCKER_BINARY="$HERE/../docker-two-nets" \
  NICO_CONTAINERS_REQUIRE_HEALTHY=true \
  P3_REAL_DOCKER="$HERE/fake-docker" FAKE_DOCKER_STATE="$S/fake" \
  P3_NODE_NET=kata-bb-node P3_NODE_IP_PREFIX=172.28.2 P3_API_NET=kata-bb P3_API_IP_PREFIX=172.29.2 \
  P3_LOG="$S/docker-two-nets.log" P3_LOCK="$S/docker-two-nets.lock" \
  "$BIN" >"$S/sim.log" 2>&1 &
SIM_PID=$!
echo "== simulator started, process $SIM_PID, state folder $S"

up=0
for _ in $(seq 1 40); do
  kill -0 "$SIM_PID" 2>/dev/null || break
  if [ "$(curl -s --max-time 2 -o /dev/null -w '%{http_code}' "$URL/healthz")" = 200 ]; then up=1; break; fi
  sleep 0.5
done
if [ "$up" != 1 ]; then
  bad "the simulator answers /healthz"
  tail -20 "$S/sim.log"
  kill "$SIM_PID" 2>/dev/null
  echo "== result: $pass ok, $fail FAIL"
  exit 1
fi
ok "the simulator answers /healthz with 200"
check "it listens on the loopback address only" [ "$(ss -H -ltn "sport = :$PORT" | awk '{print $4}' | sort -u | tr '\n' ' ')" = "127.0.0.1:$PORT " ]
check "the health call of the start went through the program to docker (info)" grep -q -E '^1 info --format ' "$S/fake/calls.log"
check "a call with no token gets 401" [ "$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "$URL/v2/org/$ORG/forge/site")" = 401 ]
api GET "/v2/org/$ORG/forge/site" >"$S/sites.txt"
check "the catalog has the container site 00000000-0000-0000-0000-000000000001" grep -q '00000000-0000-0000-0000-000000000001' "$S/sites.txt"

# One instance request, with the IDs of the seed and a cloud-config in the form that NVKE writes
# (controller/internal/clients/capi/bootstrap_userdata.go): files and commands. No real value.
request() { # <name>
  jq -n --arg name "$1" '{
    name: $name,
    tenantId: "d282929f-49d5-4dec-8d27-21ceb30ade19",
    vpcId: "00000000-0000-0000-0000-000000000002",
    instanceTypeId: "00000000-0000-0000-0000-000000000005",
    sshKeyGroupIds: ["00000000-0000-0000-0000-000000000004"],
    interfaces: [{subnetId: "00000000-0000-0000-0000-000000000003"}],
    ipxeScript: "#!ipxe\necho local-nico-worker\n",
    labels: {"p3-test": "chain"},
    userData: "#cloud-config\nwrite_files:\n- path: /etc/default/nvke-agent\n  owner: root:root\n  permissions: \"0644\"\n  content: |\n    AGENT_ARGS=\"--secure-server-port 15005\"\nruncmd:\n- mkdir -p /run/cluster-api\n- echo success > /run/cluster-api/bootstrap-success.complete\n- systemctl restart nvke-agent\n"
  }' >"$S/request-$1.json"
}

echo "== first instance"
request kata-cp1-nw-1111
api POST "/v2/org/$ORG/forge/instance" "$S/request-kata-cp1-nw-1111.json" >"$S/create-1.txt"
check "create: HTTP 201 or 200 ($(tail -1 "$S/create-1.txt"))" grep -q -E '^HTTP 20[01]$' "$S/create-1.txt"
ID1=$(body <"$S/create-1.txt" | jq -r '.id // empty')
check "the answer has an instance ID ($ID1)" [ -n "$ID1" ]
check "status Ready (join token method, the container runs)" [ "$(body <"$S/create-1.txt" | jq -r '.status')" = Ready ]
check "the reported address is the fixed address on the node network: $(body <"$S/create-1.txt" | jq -c '[.interfaces[].ipAddresses]')" [ "$(body <"$S/create-1.txt" | jq -c '[.interfaces[].ipAddresses[]]')" = '["172.28.2.11"]' ]
n=$(grep -E '^[0-9]+ create ' "$S/fake/calls.log" | head -1 | cut -d' ' -f1)
tr '\n' '\001' <"$S/fake/call-$n.args" | tr '\0' '\n' | sed 's/\x01/\\n/g' >"$S/create-1.args"
check "docker got two network arguments" [ "$(grep -c -x -F -e '--network' "$S/create-1.args")" = 2 ]
check "the node network with the fixed address and the name eth0" grep -q -x -F 'name=kata-bb-node,ip=172.28.2.11,driver-opt=com.docker.network.endpoint.ifname=eth0' "$S/create-1.args"
check "the second network with the fixed address and the name eth1" grep -q -x -F 'name=kata-bb,ip=172.29.2.11,driver-opt=com.docker.network.endpoint.ifname=eth1' "$S/create-1.args"
check "the hosts line of the host name with the node address" [ "$(grep -x -A1 -F -e '--add-host' "$S/create-1.args" | tail -1 | grep -c -E ':172\.28\.2\.11$')" = 1 ]
check "the container name is <instance name>-<first 8 characters of the ID>" grep -q -x -F "kata-cp1-nw-1111-${ID1:0:8}" "$S/create-1.args"
check "the image is the worker image, and the entry command of the simulator follows it" [ "$(grep -n -x -F 'nvke-node-nico:bcc4376f-w1' "$S/create-1.args" | cut -d: -f1)" = "$(( $(wc -l <"$S/create-1.args") - 2 ))" ]
check "the entry command ends with the entry point of the image" grep -q 'exec /usr/local/bin/entrypoint /sbin/init$' <(tail -1 "$S/create-1.args")
check "the label of the attestation method is joinToken" grep -q -x -F 'nvidia.com/nico-containers.spire-attestation-method=joinToken' "$S/create-1.args"
check "the simulator wrote the agent file through docker exec -i" grep -q -F 'AGENT_ARGS="--secure-server-port 15005"' "$S"/fake/stdin-*
check "the order of the calls is create, start, then exec" [ "$(grep -E '^[0-9]+ (create|start) ' "$S/fake/calls.log" | head -2 | awk '{print $2}' | tr '\n' ' ')" = "create start " ]

echo "== second instance, then a delete"
request kata-cp1-nw-2222
api POST "/v2/org/$ORG/forge/instance" "$S/request-kata-cp1-nw-2222.json" >"$S/create-2.txt"
ID2=$(body <"$S/create-2.txt" | jq -r '.id // empty')
check "second instance: address 172.28.2.12" [ "$(body <"$S/create-2.txt" | jq -c '[.interfaces[].ipAddresses[]]')" = '["172.28.2.12"]' ]
api GET "/v2/org/$ORG/forge/instance/$ID1" >"$S/get-1.txt"
check "a later GET of the first instance reports the same address" [ "$(body <"$S/get-1.txt" | jq -c '[.interfaces[].ipAddresses[]]')" = '["172.28.2.11"]' ]
api DELETE "/v2/org/$ORG/forge/instance/$ID1" >"$S/delete-1.txt"
check "delete of the first instance: $(tail -1 "$S/delete-1.txt")" grep -q -E '^HTTP 20[0-4]$' "$S/delete-1.txt"
check "docker got stop and rm --force --volumes for it" [ "$(grep -c -E '^[0-9]+ (stop --time 10|rm --force --volumes) ' "$S/fake/calls.log")" = 2 ]
api GET "/v2/org/$ORG/forge/instance" >"$S/list.txt"
check "the list has one instance, the second" [ "$(body <"$S/list.txt" | jq -r '[.[].id] | join(",")')" = "$ID2" ]
request kata-cp1-nw-3333
api POST "/v2/org/$ORG/forge/instance" "$S/request-kata-cp1-nw-3333.json" >"$S/create-3.txt"
check "third instance takes the free address 172.28.2.11" [ "$(body <"$S/create-3.txt" | jq -c '[.interfaces[].ipAddresses[]]')" = '["172.28.2.11"]' ]

echo "== a reboot request (PATCH with triggerReboot)"
echo '{"triggerReboot": true}' >"$S/reboot.json"
api PATCH "/v2/org/$ORG/forge/instance/$ID2" "$S/reboot.json" >"$S/reboot.txt"
check "reboot: $(tail -1 "$S/reboot.txt")" grep -q -E '^HTTP 20[0-4]$' "$S/reboot.txt"
check "docker got restart --time 10" grep -q -E '^[0-9]+ restart --time 10 ' "$S/fake/calls.log"
check "the address after the restart is the same" [ "$(body <"$S/reboot.txt" | jq -c '[.interfaces[].ipAddresses[]]')" = '["172.28.2.12"]' ]

echo "== the log of the program"
cat "$S/docker-two-nets.log"
echo "== calls of the simulator to its Docker program, by command"
awk '{print $2}' "$S/fake/calls.log" | sort | uniq -c | tr '\n' ';'; echo
echo "== the arguments of the first create call, as docker got them"
cat "$S/create-1.args" | cut -c1-200

kill "$SIM_PID" 2>/dev/null
wait "$SIM_PID" 2>/dev/null
check "the simulator ended (process $SIM_PID)" [ -z "$(ss -H -ltn "sport = :$PORT")" ]
echo "== result: $pass ok, $fail FAIL (the state folder stays in $S)"
[ "$fail" = 0 ]
