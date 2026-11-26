#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Block C1, the network: a second Docker network (the node network) that each kind node joins, a bridge
# in each node, the CNI plugins "bridge" and "static" in each node, and Multus.
# No kernel module load: bridge and veth are loaded already. No firewall change: the traffic on the
# second bridge is switched, not routed (br_netfilter is not loaded).
# Removal:
#   kubectl delete -f /root/kata-cp/dl/c1/multus-daemonset-lab.yml; in each node: rm /opt/cni/bin/{bridge,static,multus*} /etc/cni/net.d/00-multus.conf* and the multus.d folder
#   in each node: systemctl disable lab-node-bridge.service; rm /etc/systemd/system/lab-node-bridge.service /usr/local/sbin/lab-node-bridge.sh; ip link del br-node
#   for n in <nodes>; do docker network disconnect kata-bb-node $n; done; docker network rm kata-bb-node
set -euo pipefail
. /root/kata-cp/bin/env.sh
. /root/kata-cp/c1/env-c.sh
D=$W/dl/c1
echo "== $(utc) 1. Docker network $NODENET ($NODESUBNET, internal: no route to outside, no published port)"
ip route show table all | grep -E '172\.28\.' && { echo "ERROR: 172.28 is in a route of the machine"; exit 1; } || echo "172.28.0.0/16 is in no route of the machine"
docker network inspect "$NODENET" >/dev/null 2>&1 || docker network create -d bridge --internal \
  --subnet "$NODESUBNET" --ip-range "$NODERANGE" --gateway "$NODEGW" \
  -o com.docker.network.bridge.name="$NODEBR_HOST" "$NODENET"
docker network inspect "$NODENET" --format '{{.Name}} internal {{.Internal}} {{range .IPAM.Config}}subnet {{.Subnet}} range {{.IPRange}} gateway {{.Gateway}}{{end}} options {{.Options}}'
echo "br_netfilter loaded: $(lsmod | grep -c '^br_netfilter')"
echo "== 2. each kind node joins it with the interface name $NODEIF"
for n in $NODES; do
  if ! docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$n" | grep -qw "$NODENET"; then
    docker network connect --driver-opt com.docker.network.endpoint.ifname="$NODEIF" "$NODENET" "$n"
  fi
  echo "$n: $(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}={{$v.IPAddress}} {{end}}' "$n") | $(docker exec "$n" sh -c "ip -o -4 addr show | awk '{print \$2 \"=\" \$4}' | grep -v -E '^(lo|veth)' | tr '\n' ' '; ip route show default | head -1")"
done
echo "== 3. the bridge $NODEBR in each node, and its unit"
for n in $NODES; do
  docker cp -q "$W/c1/lab-node-bridge.sh" "$n:/usr/local/sbin/lab-node-bridge.sh"
  docker cp -q "$W/c1/lab-node-bridge.service" "$n:/etc/systemd/system/lab-node-bridge.service"
  docker exec "$n" sh -c 'chmod 755 /usr/local/sbin/lab-node-bridge.sh; systemctl daemon-reload; systemctl enable lab-node-bridge.service 2>/dev/null; systemctl restart lab-node-bridge.service; journalctl --no-pager -u lab-node-bridge.service | tail -1 | cut -d: -f4-; ip route show | grep br-node'
done
echo "== 4. node to node on the node network (ping from the control plane node to each worker, and from the machine)"
for n in $WORKERS; do
  a=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$NODENET\").IPAddress}}" "$n")
  echo "$CP_NODE to $n ($a): $(docker exec "$CP_NODE" sh -c "curl -s -m 3 -o /dev/null -w '%{http_code}' http://$a:10248/healthz; echo \" (kubelet healthz port, expect 000 or 200), neighbor: \$(ip neigh show $a | cut -c1-60)\"")"
  echo "machine to $n ($a): $(ping -c 1 -W 1 "$a" | grep -E 'received')"
done
echo "== 5. CNI plugins bridge and static ($(cat "$D/cni-version")) into /opt/cni/bin of each node"
for n in $NODES; do
  for p in bridge static; do docker cp -q "$D/cni-bin/$p" "$n:/opt/cni/bin/$p"; done
  echo "$n: $(docker exec "$n" sh -c 'ls /opt/cni/bin | tr "\n" " "; ls /etc/cni/net.d | tr "\n" " "')"
done
echo "== 6. Multus $(cat "$D/multus-version") (thin plugin, DaemonSet). The image is loaded into each node first."
"$W/bin/img-load.sh" "ghcr.io/k8snetworkplumbingwg/multus-cni:$(cat "$D/multus-version")"
"$W/bin/img-load.sh" python:3.13-alpine
sed -e "s#ghcr.io/k8snetworkplumbingwg/multus-cni:snapshot#ghcr.io/k8snetworkplumbingwg/multus-cni:$(cat "$D/multus-version")#" "$D/multus-daemonset.yml" >"$D/multus-daemonset-lab.yml"
grep -n 'image:' "$D/multus-daemonset-lab.yml"
kubectl apply -f "$D/multus-daemonset-lab.yml"
kubectl -n kube-system rollout status ds/kube-multus-ds --timeout=180s
kubectl -n kube-system get pods -l app=multus -o wide | awk '{print $1, $2, $3, $7}'
for n in $NODES; do echo "$n: $(docker exec "$n" sh -c 'ls /etc/cni/net.d | tr "\n" " "; ls /opt/cni/bin | tr "\n" " "')"; done
docker exec "$CP_NODE" sh -c 'cat /etc/cni/net.d/00-multus.conf' | cut -c1-600
echo
echo "C1 NET DONE"
