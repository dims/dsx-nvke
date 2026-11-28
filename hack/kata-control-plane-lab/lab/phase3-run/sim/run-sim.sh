#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# The NICo simulator (nico-sim) of phase 3 as ONE container on the Docker network kata-bb, with
# the Docker socket of the machine. The form is the one of the CI deploy path
# (controller/hack/ci/backend-e2e.sh:941-948, :1168-1173, hack/nico-provider/run-nico-sim.sh:47-59).
#
#   start a    step A: a worker gets ONE network, kata-bb. The simulator calls docker itself.
#   start b    step B: a worker gets kata-bb-node (fixed node address) and kata-bb. The simulator
#              calls docker-two-nets, which adds the second network to each "create".
#   status     the container, its settings, /healthz, the catalog, the worker containers
#   logs [n]   the last n lines of the simulator and of docker-two-nets
#   remove     remove the simulator container (docker rm -f by its name). It refuses when a
#              worker container of the simulator exists. FORCE=1 removes it anyway.
#   command a|b   print the docker run command and do nothing
#
# The simulator keeps no instance in its database. An instance is a container with labels. So a
# new simulator container finds the workers of the one before it.
#
# Guards of "start": the kernel module openvswitch is loaded (the worker image stops its Open
# vSwitch unit when the module is absent, and the fallback behind that guard removes the bridge
# module of the machine), the worker image is in Docker, both networks exist, the binary has the
# checksum of SHA256SUMS.
# Usage: run-sim.sh <step>
set -euo pipefail
. /root/kata-cp/bin/env.sh
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../env-p3.sh
. "$HERE/../env-p3.sh"
KIND_NODE=${KIND_NODE:-$CP_NODE}

run_command() { # <a|b>: the docker run command, one argument for each line
  local form=$1 node_net docker_bin
  case "$form" in
    a) node_net=$API_NET; docker_bin=docker ;;
    b) node_net=$NODE_NET; docker_bin=/sim/docker-two-nets ;;
    *) echo "form a or b"; exit 1 ;;
  esac
  CMD=(docker run --detach
    --name "$SIM_NAME"
    --label "p3.sim-form=$form"
    --network "$API_NET" --ip "$SIM_IP"
    --restart no
    --volume /var/run/docker.sock:/var/run/docker.sock
    --volume "$HERE:/sim:ro"
    --volume "$SIM_STATE:/state"
    --env DOCKER_HOST=unix:///var/run/docker.sock
    --env "NICO_SIM_LISTEN_ADDR=:$SIM_PORT"
    --env NICO_SIM_SEED_PATH=/sim/default-seed.yaml
    --env NICO_SIM_DB_PATH=/state/nico-sim.db
    --env NICO_SIM_FILES_DIR=/state/files
    --env NICO_SIM_LOG_FORMAT=text
    --env NO_COLOR=1
    --env NICO_VMS_VM_BACKEND=mock
    --env NICO_VMS_BGP_ENABLED=false
    --env NICO_VMS_BRIDGE_CIDR=172.30.0.0/24
    --env NICO_VMS_CONSOLE_SSH_PORT=-1
    --env NICO_CONTAINERS_ENABLED=true
    --env "NICO_CONTAINERS_NODE_IMAGE=$WORKER_IMAGE"
    --env "NICO_CONTAINERS_NODE_NETWORK=$node_net"
    --env NICO_CONTAINERS_SPIRE_ATTESTATION_METHOD=joinToken
    --env "NICO_CONTAINERS_DOCKER_BINARY=$docker_bin"
    --env NICO_CONTAINERS_REQUIRE_HEALTHY=true)
  if [ "$form" = b ]; then
    CMD+=(--env P3_REAL_DOCKER=docker
      --env "P3_NODE_NET=$NODE_NET"
      --env "P3_NODE_IP_PREFIX=$WORKER_NODE_PREFIX"
      --env "P3_API_NET=$API_NET"
      --env "P3_API_IP_PREFIX=$WORKER_API_PREFIX"
      --env "P3_IP_FIRST=$WORKER_IP_FIRST" --env "P3_IP_LAST=$WORKER_IP_LAST"
      --env "P3_NODE_IFNAME=$WORKER_NODE_IFNAME" --env "P3_API_IFNAME=$WORKER_API_IFNAME" --env P3_HOSTS_ENTRY=1
      --env P3_LOG=/state/docker-two-nets.log
      --env P3_LOCK=/state/docker-two-nets.lock)
  fi
  CMD+=(--entrypoint /sim/nico-sim "$SIM_IMAGE")
}
print_command() { # an option and its value on one line
  local i=2 n=${#CMD[@]}
  printf 'docker run'
  while [ "$i" -lt "$n" ]; do
    if [[ "${CMD[$i]}" == --* ]] && [ $((i + 1)) -lt "$n" ] && [[ "${CMD[$((i + 1))]}" != --* ]]; then
      printf ' \\\n  %s %s' "${CMD[$i]}" "${CMD[$((i + 1))]}"
      i=$((i + 2))
    else
      printf ' \\\n  %s' "${CMD[$i]}"
      i=$((i + 1))
    fi
  done
  printf '\n'
}
workers() { docker ps -a --filter label=nvidia.com/nico-containers.managed=true --format '{{.Names}}'; }
curl_node() { docker exec "$KIND_NODE" curl -sS --max-time 5 "$@"; }

case "${1:-}" in
  command)
    run_command "${2:-}"
    print_command
    ;;
  start)
    run_command "${2:-}"
    [ -d /sys/module/openvswitch ] || { echo "the kernel module openvswitch is not loaded. Load it first (prep.md, step 1). Nothing started"; exit 1; }
    ( cd "$HERE" && sha256sum -c SHA256SUMS ) || { echo "the simulator binary or the seed file differs from SHA256SUMS. Nothing started"; exit 1; }
    [ -x "$HERE/docker-two-nets" ] || { echo "no program $HERE/docker-two-nets"; exit 1; }
    for net in "$API_NET" "$NODE_NET"; do docker network inspect "$net" >/dev/null || { echo "no Docker network $net"; exit 1; }; done
    docker image inspect "$SIM_IMAGE" >/dev/null 2>&1 || { echo "no image $SIM_IMAGE in Docker. Load the archive first (prep.md, step 2)"; exit 1; }
    docker image inspect "$WORKER_IMAGE" >/dev/null 2>&1 || { echo "no image $WORKER_IMAGE in Docker. Build it first (image/build-worker.sh)"; exit 1; }
    if docker inspect "$SIM_NAME" >/dev/null 2>&1; then echo "a container $SIM_NAME exists. Run \"$0 remove\" first"; exit 1; fi
    mkdir -p "$SIM_STATE/files" "$P3_LOGS"
    echo "== $(utc) start of the simulator, form $2"
    print_command | tee "$P3_LOGS/sim-run-command-$2.txt"
    "${CMD[@]}"
    for _ in $(seq 1 30); do
      [ "$(docker inspect -f '{{.State.Running}}' "$SIM_NAME" 2>/dev/null)" = true ] || break
      if [ "$(curl_node -o /dev/null -w '%{http_code}' "http://$SIM_IP:$SIM_PORT/healthz" 2>/dev/null)" = 200 ]; then break; fi
      sleep 1
    done
    "$0" status
    ;;
  status)
    docker ps -a --filter "name=^${SIM_NAME}$" --format 'container {{.Names}}: {{.Status}}, image {{.Image}}, form {{.Label "p3.sim-form"}}'
    docker inspect "$SIM_NAME" 2>/dev/null | jq -r '.[0] | "address: \([.NetworkSettings.Networks | to_entries[] | "\(.key)=\(.value.IPAddress)"] | join(" ")), restart policy: \(.HostConfig.RestartPolicy.Name), privileged: \(.HostConfig.Privileged)", "settings: \([.Config.Env[] | select(test("^(NICO_|P3_)"))] | join(" "))"' || echo "no container $SIM_NAME"
    echo "healthz from $KIND_NODE: $(curl_node -o /dev/null -w '%{http_code}' "http://$SIM_IP:$SIM_PORT/healthz" 2>&1 | tail -1)"
    echo "sites of the catalog: $(curl_node -H 'Authorization: Bearer example-token' "http://$SIM_IP:$SIM_PORT/v2/org/$NICO_ORG_ID/$NICO_API_NAME/site" 2>&1 | jq -c '[.[] | {id, name}]' 2>&1 | cut -c1-300)"
    echo "instances of the simulator: $(curl_node -H 'Authorization: Bearer example-token' "http://$SIM_IP:$SIM_PORT/v2/org/$NICO_ORG_ID/$NICO_API_NAME/instance" 2>&1 | jq -c '[.[] | {name, status, addresses: [.interfaces[]?.ipAddresses[]?]}]' 2>&1 | cut -c1-600)"
    echo "worker containers on the machine:"
    for c in $(workers); do
      docker inspect "$c" | jq -r '.[0] | "  \(.Name[1:]): running \(.State.Running), restarts \(.RestartCount), image \(.Config.Image), \([.NetworkSettings.Networks | to_entries[] | "\(.key)=\(.value.IPAddress)"] | join(" "))"'
    done
    ;;
  logs)
    docker logs --tail "${2:-40}" "$SIM_NAME" 2>&1 | cut -c1-400
    echo "== docker-two-nets"
    if [ -e "$SIM_STATE/docker-two-nets.log" ]; then tail -n "${2:-40}" "$SIM_STATE/docker-two-nets.log"; fi
    ;;
  remove)
    w=$(workers | tr '\n' ' ')
    if [ -n "$w" ] && [ "${FORCE:-0}" != 1 ]; then echo "worker containers of the simulator exist: $w. Remove the workers through the NVKE API first, or use FORCE=1"; exit 1; fi
    docker logs "$SIM_NAME" >"$P3_LOGS/sim-$(date -u +%Y%m%dT%H%M%SZ).log" 2>&1 || true
    docker rm -f "$SIM_NAME"
    ;;
  *) sed -n '2,16p' "$0"; exit 1 ;;
esac
