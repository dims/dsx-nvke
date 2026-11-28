# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Throwaway check of the Docker option for a fixed interface name of a network endpoint.
# Small containers that are not privileged, on the two lab networks, removed right after the look.
L=/root/kata-cp/logs/p3/prep7; mkdir -p "$L"
img=docker:29.1.3-cli
one() { # <name> <last number> <with option: 1|0> <with add-host: 1|0>
  local name=$1 n=$2 opt=$3 ah=$4 a=() o0="" o1=""
  [ "$opt" = 1 ] && { o0=",driver-opt=com.docker.network.endpoint.ifname=eth0"; o1=",driver-opt=com.docker.network.endpoint.ifname=eth1"; }
  [ "$ah" = 1 ] && a=(--add-host "p3check$n:172.28.2.$n")
  docker create --name "$name" --hostname "p3check$n" "${a[@]}" --network "name=kata-bb-node,ip=172.28.2.$n$o0" --network "name=kata-bb,ip=172.29.2.$n$o1" --entrypoint sleep "$img" 30 >/dev/null 2>"$L/.err" || { echo "$name: create failed: $(head -2 "$L/.err" | tr '\n' ' ')"; return 1; }
  docker start "$name" >/dev/null
  echo "$name option=$opt add-host=$ah: $(docker exec "$name" ip -o -4 addr show | awk '$2!="lo" {print $2 "=" $4}' | tr '\n' ' ') | default route: $(docker exec "$name" ip -4 route show default | cut -d' ' -f1-5) | hosts: $(docker exec "$name" grep "p3check$n" /etc/hosts | awk '{print $1}' | tr '\n' ' ')"
  docker restart -t 1 "$name" >/dev/null
  echo "$name after a restart:        $(docker exec "$name" ip -o -4 addr show | awk '$2!="lo" {print $2 "=" $4}' | tr '\n' ' ') | default route: $(docker exec "$name" ip -4 route show default | cut -d' ' -f1-5) | hosts: $(docker exec "$name" grep "p3check$n" /etc/hosts | awk '{print $1}' | tr '\n' ' ')"
  docker rm -f "$name" >/dev/null
}
{
echo "== check of the interface name option, Docker server $(docker version --format '{{.Server.Version}}'), at $(date -u +%FT%TZ)"
for i in 1 2 3 4; do one "p3-ifname-check-$i" "24$i" 0 0; done
for i in 5 6 7 8; do one "p3-ifname-check-$i" "24$i" 1 1; done
echo "left containers: [$(docker ps -a --filter name=p3-ifname-check --format '{{.Names}}' | tr '\n' ' ')]"
} 2>&1 | tee "$L/ifname-check.txt"
