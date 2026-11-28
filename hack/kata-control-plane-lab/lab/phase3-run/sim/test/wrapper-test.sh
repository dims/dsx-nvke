#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Tests of docker-two-nets on the workstation, with fake-docker in the place of docker.
# No container, no network, no daemon. Each test has its own state folder.
# Usage: wrapper-test.sh [sh | dash | alpine <folder>]     (default: sh)
# "alpine <folder>" runs the program with the busybox of the image docker:29.1.3-cli. The folder
# has bin/busybox and lib/ld-musl-x86_64.so.1 from the first layer of that image. The shell and
# the tools flock, sed, tr, grep, date and sleep are then the applets of that busybox (1.37.0).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
W=$HERE/../docker-two-nets
FAKE=$HERE/fake-docker
SHELL_CMD=${1:-sh}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/p3-wrapper-test.XXXXXX")
pass=0
fail=0
WPATH=$PATH
if [ "$SHELL_CMD" = "alpine" ]; then
  BB_LD=${2:?the folder with bin/busybox and lib/ld-musl-x86_64.so.1}/lib/ld-musl-x86_64.so.1
  BB=$2/bin/busybox
  mkdir -p "$TMP/bb"
  # The busybox of Alpine needs its own loader, so each applet is a two line script here.
  for a in flock sed tr grep date sleep; do
    printf '#!/bin/sh\nexec %s %s %s "$@"\n' "$BB_LD" "$BB" "$a" >"$TMP/bb/$a"
    chmod 755 "$TMP/bb/$a"
  done
  WPATH="$TMP/bb:$PATH"
  SHELL_CMD="$BB_LD $BB sh"
fi

ok() { pass=$((pass + 1)); echo "ok   $*"; }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }
check() { # <text> <command...>
  local text=$1; shift
  if "$@"; then ok "$text"; else bad "$text"; fi
}
new_state() { # a new state folder for one test
  S=$(mktemp -d "$TMP/state.XXXXXX")
  export FAKE_DOCKER_STATE=$S P3_REAL_DOCKER=$FAKE P3_LOG=$S/wrapper.log P3_LOCK=$S/wrapper.lock
  unset P3_NODE_NET P3_NODE_IP_PREFIX P3_API_NET P3_API_IP_PREFIX P3_IP_FIRST P3_IP_LAST P3_FORBIDDEN_PREFIXES P3_LOCK_WAIT FAKE_DOCKER_FAIL_INSPECT P3_NODE_IFNAME P3_API_IFNAME P3_HOSTS_ENTRY
}
w() { PATH="$WPATH" $SHELL_CMD "$W" "$@"; }
# The arguments of the last "create" call that reached the fake, one for each line ("\n" in an
# argument shows as the two characters \n).
last_create_args() {
  local n
  n=$(grep -E '^[0-9]+ create( |$)' "$S/calls.log" | tail -1 | cut -d' ' -f1)
  [ -n "$n" ] || return 0
  tr '\n' '\001' <"$S/call-$n.args" | tr '\0' '\n' | sed 's/\x01/\\n/g'
}
creates() { if [ -e "$S/calls.log" ]; then grep -c -E '^[0-9]+ create( |$)' "$S/calls.log" || true; else echo 0; fi; }

# The create call as nico-sim makes it (controller/nico-sim/internal/container/service.go:254-277),
# with a label value that has spaces and an entry command that has more than one line.
ENTRY='set -e
mkdir -p /var/lib/nico-containers
exec /usr/local/bin/entrypoint /sbin/init'
sim_create() { # <name> [network]
  w create --name "$1-0a1b2c3d" --hostname "$1" --privileged \
    --security-opt seccomp=unconfined --security-opt apparmor=unconfined \
    --tmpfs /tmp --tmpfs /run --tmpfs /var/lib/etcd:size=4g --restart always \
    --network "${2:-kata-bb-node}" \
    --env KUBECONFIG=/etc/kubernetes/admin.conf --env KIND_EXPERIMENTAL_CONTAINERD_SNAPSHOTTER=fuse-overlayfs \
    --volume /var --volume /lib/modules:/lib/modules:ro --entrypoint /bin/sh --tty \
    --label nvidia.com/nico-containers.managed=true --label "nvidia.com/nico-containers.instance-name=$1" \
    --label "test/label=a value with  two spaces" \
    nvke-node-nico:bcc4376f-w1 -c "$ENTRY"
}

echo "== shell: $SHELL_CMD ($($SHELL_CMD -c 'echo ok' 2>&1)), flock of the program: $(PATH="$WPATH" command -v flock)"

echo "== 1. a call that is not create passes as it is"
new_state
out=$(w ps -aq --filter label=nvidia.com/nico-containers.managed=true 2>&1); rc=$?
check "ps: exit code 0 and no output" [ "$rc$out" = "0" ]
check "ps: the fake got the same arguments" grep -q -x -F "1 ps -aq --filter label=nvidia.com/nico-containers.managed=true" "$S/calls.log"
printf 'file content\nline 2\n' | w exec -i abc123 sh -c "cat > '/etc/x'" ; rc=$?
check "exec -i: exit code 0" [ "$rc" = 0 ]
check "exec -i: the standard input reached the fake" [ "$(cat "$S/stdin-2")" = "$(printf 'file content\nline 2')" ]
out=$(w info --format '{{.ServerVersion}}' 2>&1)
check "info: the output of the fake comes back" [ "$out" = "29.1.3" ]
check "no log line for these calls" [ ! -e "$S/wrapper.log" ]
check "no lock file for these calls" [ ! -e "$S/wrapper.lock" ]

echo "== 2. create: one network argument becomes two, the rest is the same"
new_state
export P3_API_IP_PREFIX=172.29.2
out=$(sim_create kata-cp1-nw-1111 2>"$S/stderr"); rc=$?
check "exit code 0" [ "$rc" = 0 ]
check "the output is only the container ID (64 hex characters)" grep -q -x -E '[0-9a-f]{64}' <<<"$out"
check "nothing on stderr" [ ! -s "$S/stderr" ]
last_create_args >"$S/got"
cat >"$S/want" <<EOF
create
--name
kata-cp1-nw-1111-0a1b2c3d
--hostname
kata-cp1-nw-1111
--privileged
--security-opt
seccomp=unconfined
--security-opt
apparmor=unconfined
--tmpfs
/tmp
--tmpfs
/run
--tmpfs
/var/lib/etcd:size=4g
--restart
always
--add-host
kata-cp1-nw-1111:172.28.2.11
--network
name=kata-bb-node,ip=172.28.2.11,driver-opt=com.docker.network.endpoint.ifname=eth0
--network
name=kata-bb,ip=172.29.2.11,driver-opt=com.docker.network.endpoint.ifname=eth1
--env
KUBECONFIG=/etc/kubernetes/admin.conf
--env
KIND_EXPERIMENTAL_CONTAINERD_SNAPSHOTTER=fuse-overlayfs
--volume
/var
--volume
/lib/modules:/lib/modules:ro
--entrypoint
/bin/sh
--tty
--label
nvidia.com/nico-containers.managed=true
--label
nvidia.com/nico-containers.instance-name=kata-cp1-nw-1111
--label
test/label=a value with  two spaces
nvke-node-nico:bcc4376f-w1
-c
set -e\nmkdir -p /var/lib/nico-containers\nexec /usr/local/bin/entrypoint /sbin/init
EOF
if diff "$S/want" "$S/got" >"$S/diff"; then ok "the fake got the expected argument list (43 arguments)"; else bad "the argument list differs"; cat "$S/diff"; fi
check "one log line with both addresses" grep -q -E 'create name=\[kata-cp1-nw-1111-0a1b2c3d\] kata-bb-node=172.28.2.11 kata-bb=172.29.2.11 ifnames=eth0,eth1 hosts-entry=kata-cp1-nw-1111 exit=0$' "$S/wrapper.log"

echo "== 3. the next address, a container that did not start, and a free address again"
id1=$out
id2=$(sim_create kata-cp1-nw-2222)
check "second create (the first did not start): 172.28.2.12" grep -q -x -F "name=kata-bb-node,ip=172.28.2.12,driver-opt=com.docker.network.endpoint.ifname=eth0" <(last_create_args)
"$FAKE" start "$id1" >/dev/null; "$FAKE" start "$id2" >/dev/null
id3=$(sim_create kata-cp1-nw-3333)
check "third create (two run): 172.28.2.13 and 172.29.2.13" [ "$(last_create_args | grep -c -x -E 'name=kata-bb-node,ip=172.28.2.13,driver-opt=com.docker.network.endpoint.ifname=eth0|name=kata-bb,ip=172.29.2.13,driver-opt=com.docker.network.endpoint.ifname=eth1')" = 2 ]
"$FAKE" rm --force --volumes "$id1" >/dev/null
id4=$(sim_create kata-cp1-nw-4444)
check "after the first is gone: 172.28.2.11 again" grep -q -x -F "name=kata-bb-node,ip=172.28.2.11,driver-opt=com.docker.network.endpoint.ifname=eth0" <(last_create_args)
: "$id3" "$id4"

echo "== 4. an address of the second network that another container has is not taken"
new_state
export P3_API_IP_PREFIX=172.29.2
"$FAKE" create --name other --network name=kata-bb,ip=172.29.2.11,driver-opt=com.docker.network.endpoint.ifname=eth1 some-image >/dev/null
sim_create kata-cp1-nw-5555 >/dev/null
check "172.29.2.11 is in use, so the worker gets .12 on both networks" [ "$(last_create_args | grep -c -x -E 'name=kata-bb-node,ip=172.28.2.12,driver-opt=com.docker.network.endpoint.ifname=eth0|name=kata-bb,ip=172.29.2.12,driver-opt=com.docker.network.endpoint.ifname=eth1')" = 2 ]

echo "== 5. no address prefix for the second network: Docker gives that address"
new_state
sim_create kata-cp1-nw-6666 >/dev/null
check "second argument is name=kata-bb with no address" [ "$(last_create_args | grep -c -x -E 'name=kata-bb-node,ip=172.28.2.11,driver-opt=com.docker.network.endpoint.ifname=eth0|name=kata-bb,driver-opt=com.docker.network.endpoint.ifname=eth1')" = 2 ]

echo "== 6. no second network (P3_API_NET empty): one network with the fixed address"
new_state
export P3_API_NET=""
sim_create kata-cp1-nw-7777 >/dev/null
check "one network argument" [ "$(last_create_args | grep -c -x -F -e '--network')" = 1 ]
check "with the fixed address" grep -q -x -F "name=kata-bb-node,ip=172.28.2.11,driver-opt=com.docker.network.endpoint.ifname=eth0" <(last_create_args)

echo "== 7. calls that the program refuses (exit code 64, nothing reaches the fake as create)"
new_state
out=$(sim_create kata-cp1-nw-8888 kata-bb 2>&1); rc=$?
check "another network than the node network: 64" [ "$rc" = 64 ]
check "the message names both networks" grep -q -F "asks for the network [kata-bb], not [kata-bb-node]" <<<"$out"
out=$(w create --name x --hostname x some-image 2>&1); rc=$?
check "no --network: 64" [ "$rc" = 64 ]
out=$(w create --name x --network kata-bb-node --network kata-bb-node some-image 2>&1); rc=$?
check "two --network: 64" [ "$rc" = 64 ]
out=$(w create --name x --network kata-bb-node --ip 172.28.1.9 some-image 2>&1); rc=$?
check "--ip in the call: 64" [ "$rc" = 64 ]
out=$(w create --name x --network=kata-bb-node some-image 2>&1); rc=$?
check "--network=<name> in one argument: 64" [ "$rc" = 64 ]
out=$(P3_NODE_IP_PREFIX=172.28.1 sim_create kata-cp1-nw-9999 2>&1); rc=$?
check "the range of the pod provider as prefix: 64" [ "$rc" = 64 ]
out=$(P3_NODE_IP_PREFIX=172.28.0 sim_create kata-cp1-nw-9999 2>&1); rc=$?
check "the range of Docker as prefix: 64" [ "$rc" = 64 ]
out=$(P3_NODE_IP_PREFIX=172.28 sim_create kata-cp1-nw-9999 2>&1); rc=$?
check "a prefix with two numbers: 64" [ "$rc" = 64 ]
out=$(P3_NODE_NET=kata-bb P3_API_NET=kata-bb sim_create kata-cp1-nw-9999 kata-bb 2>&1); rc=$?
check "the same network two times: 64" [ "$rc" = 64 ]
check "no create call reached the fake" [ "$(creates)" = 0 ]
check "each refusal has a log line" [ "$(grep -c 'REFUSED (64)' "$S/wrapper.log")" = 9 ]

echo "== 8. no free address (exit code 69), and a failing docker (its exit code comes back)"
new_state
export P3_IP_FIRST=11 P3_IP_LAST=12
sim_create a >/dev/null; sim_create b >/dev/null
out=$(sim_create c 2>&1); rc=$?
check "third create with a range of two: 69" [ "$rc" = 69 ]
check "two create calls reached the fake" [ "$(creates)" = 2 ]
new_state
sim_create same >/dev/null
out=$(sim_create same 2>&1); rc=$?
check "the name is in use: the exit code of docker (125) comes back" [ "$rc" = 125 ]
check "and the message of docker comes back" grep -q "already in use" <<<"$out"
new_state
export FAKE_DOCKER_FAIL_INSPECT=1 P3_LOCK_WAIT=2
"$FAKE" create --name other --network kata-bb some-image >/dev/null
out=$(sim_create d 2>&1); rc=$?
check "docker inspect fails two times: 75" [ "$rc" = 75 ]
check "and no create call of the program reached the fake" [ "$(creates)" = 1 ]

echo "== 9. six create calls at the same time get six addresses"
new_state
export P3_API_IP_PREFIX=172.29.2
for i in 1 2 3 4 5 6; do sim_create "par-$i" >"$S/par-$i.out" 2>&1 & done
wait
got=$(for f in "$S"/c/*.json; do jq -r '.NetworkSettings.Networks["kata-bb-node"].IPAMConfig.IPv4Address' "$f"; done | sort -t. -k4n | tr '\n' ' ')
check "addresses: $got" [ "$got" = "172.28.2.11 172.28.2.12 172.28.2.13 172.28.2.14 172.28.2.15 172.28.2.16 " ]
check "each call printed one container ID" [ "$(cat "$S"/par-*.out | grep -c -x -E '[0-9a-f]{64}')" = 6 ]

echo "== 10. a lock that another process holds"
new_state
export P3_LOCK_WAIT=2
( exec 9>>"$S/wrapper.lock"; flock 9; sleep 6 ) &
holder=$!
sleep 1
t0=$(date +%s)
out=$(sim_create e 2>&1); rc=$?
check "no lock after the wait limit of 2 s: 75 (waited $(( $(date +%s) - t0 )) s)" [ "$rc" = 75 ]
wait "$holder"
out=$(sim_create e 2>&1); rc=$?
check "after the other process ends: exit code 0" [ "$rc" = 0 ]

echo "== 11. the interface names and the hosts line"
IFO=driver-opt=com.docker.network.endpoint.ifname
new_state
export P3_API_IP_PREFIX=172.29.2
sim_create kata-cp1-nw-8811 >/dev/null
last_create_args >"$S/got"
check "default: the node network is eth0" grep -q -x -F "name=kata-bb-node,ip=172.28.2.11,$IFO=eth0" "$S/got"
check "default: the second network is eth1" grep -q -x -F "name=kata-bb,ip=172.29.2.11,$IFO=eth1" "$S/got"
check "default: the hosts line has the host name and the node address" [ "$(grep -x -A1 -F -e '--add-host' "$S/got" | tail -1)" = "kata-cp1-nw-8811:172.28.2.11" ]
check "the hosts line is right before the first network argument" [ "$(grep -n -x -F -e '--add-host' "$S/got" | cut -d: -f1)" = "$(( $(grep -n -x -F -e '--network' "$S/got" | head -1 | cut -d: -f1) - 2 ))" ]
check "one hosts line" [ "$(grep -c -x -F -e '--add-host' "$S/got")" = 1 ]
new_state
export P3_API_IP_PREFIX=172.29.2 P3_NODE_IFNAME="" P3_API_IFNAME=""
sim_create kata-cp1-nw-8812 >/dev/null
last_create_args >"$S/got"
check "both names empty: the arguments of the old form" [ "$(grep -c -x -E 'name=kata-bb-node,ip=172.28.2.11|name=kata-bb,ip=172.29.2.11' "$S/got")" = 2 ]
check "both names empty: the log says by-docker" grep -q -E 'ifnames=by-docker,by-docker hosts-entry=kata-cp1-nw-8812 exit=0$' "$S/wrapper.log"
new_state
export P3_API_IP_PREFIX=172.29.2 P3_HOSTS_ENTRY=0
sim_create kata-cp1-nw-8813 >/dev/null
check "P3_HOSTS_ENTRY=0: no hosts line" [ "$(last_create_args | grep -c -x -F -e '--add-host')" = 0 ]
check "P3_HOSTS_ENTRY=0: the log says none" grep -q -E 'ifnames=eth0,eth1 hosts-entry=none exit=0$' "$S/wrapper.log"
new_state
export P3_API_IP_PREFIX=172.29.2 P3_NODE_IFNAME=node0 P3_API_IFNAME=api0
sim_create kata-cp1-nw-8814 >/dev/null
check "other names: node0 and api0" [ "$(last_create_args | grep -c -x -E "name=kata-bb-node,ip=172.28.2.11,$IFO=node0|name=kata-bb,ip=172.29.2.11,$IFO=api0")" = 2 ]
new_state
w create --name no-host-name --network kata-bb-node nvke-node-nico:bcc4376f-w1 >/dev/null
check "a create call with no --hostname: no hosts line" [ "$(last_create_args | grep -c -x -F -e '--add-host')" = 0 ]
check "and the networks have their names" [ "$(last_create_args | grep -c -x -E "name=kata-bb-node,ip=172.28.2.11,$IFO=eth0|name=kata-bb,$IFO=eth1")" = 2 ]
new_state
export P3_API_NET=""
sim_create kata-cp1-nw-8815 >/dev/null
check "one network: eth0 and the hosts line" [ "$(last_create_args | grep -c -x -E "name=kata-bb-node,ip=172.28.2.11,$IFO=eth0|kata-cp1-nw-8815:172.28.2.11")" = 2 ]
new_state
out=$(P3_NODE_IFNAME=eth1 sim_create r1 2>&1); rc=$?
check "the same name for both networks: 64" [ "$rc" = 64 ]
out=$(P3_API_IFNAME="" sim_create r2 2>&1); rc=$?
check "one name empty: 64" [ "$rc" = 64 ]
out=$(P3_NODE_IFNAME="eth 0" sim_create r3 2>&1); rc=$?
check "a name with a space: 64" [ "$rc" = 64 ]
out=$(P3_NODE_IFNAME=0eth sim_create r4 2>&1); rc=$?
check "a name that starts with a digit: 64" [ "$rc" = 64 ]
out=$(P3_API_IFNAME=abcdefghijklmnop sim_create r5 2>&1); rc=$?
check "a name with 16 characters: 64" [ "$rc" = 64 ]
out=$(P3_HOSTS_ENTRY=2 sim_create r6 2>&1); rc=$?
check "P3_HOSTS_ENTRY=2: 64" [ "$rc" = 64 ]
check "no create call reached the fake" [ "$(creates)" = 0 ]
check "each refusal has a log line" [ "$(grep -c 'REFUSED (64)' "$S/wrapper.log")" = 6 ]

echo "== result with [$SHELL_CMD]: $pass ok, $fail FAIL (the state folders stay in $TMP)"
[ "$fail" = 0 ]
