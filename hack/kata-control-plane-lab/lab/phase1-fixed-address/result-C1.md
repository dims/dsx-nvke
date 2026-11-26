# Block C1: a fixed address with no NAT for each control plane pod (second machine)

Date: 2026-11-26, 17:22 to 17:51 UTC, on the second test machine (kind cluster `kata-bb`, 1 control plane node and 3 workers). Kata runs with nested virtualization there, so times do not compare with the workstation. Logs: `/scratch/kata-cp/logs/bigbox/remote-logs/c1/` and `remote-logs/c1-net.log`. Scripts: `/scratch/kata-cp/work/bigbox/remote/c1/`.

## Verdict

Pass, rules 1 to 5, in 1 full run (`c1-run-1`) and 5 short runs with one variant each (`c1-v-*`).

One finding needs a fix in the design: after a replace, a peer reaches the fixed address again only 28 to 34 s after the delete. A fixed hardware address in the Multus annotation removes that time. A gratuitous ARP from inside the guest also removes it.

## The network form, and why

Form: a second Docker network that each kind node joins, a Linux bridge in each node, and the `bridge` CNI plugin with the `static` address plugin, attached through Multus.

- Docker network `kata-bb-node`, `172.28.0.0/16`, internal (no route to outside, no published port), bridge `br-katanode` on the machine. Docker gives the kind nodes `172.28.0.2` to `.5`. Pod addresses are in `172.28.1.0/24`.
- Each kind node joins it with the interface name `nodenet0` (`docker network connect --driver-opt com.docker.network.endpoint.ifname=nodenet0`). The name is fixed, so the network can never become `eth0` of a node after a restart.
- In each kind node the bridge `br-node` has `nodenet0` as a port and takes its hardware address and its IP address. A boot unit (`lab-node-bridge.service`) makes it again at each start of the node.
- Multus v4.3.2 (thin plugin) and the CNI plugins `bridge` and `static` v1.10.0 in each node. A kind node has only `ptp`, `host-local`, `portmap` and `loopback`.
- One NetworkAttachmentDefinition `nodenet` for each namespace: `bridge` on `br-node`, no gateway, no masquerade, `ipam: static`, capabilities `ips` and `mac`. The pod names its address in the annotation `k8s.v1.cni.cncf.io/networks: '[{"name": "nodenet", "ips": ["172.28.1.11/16"], "mac": "02:00:ac:1c:01:0b"}]'`.

Why this form:

- The address is in the pod annotation, so it is the same on each host node and after each replace. No address pool and no controller is in the path.
- The node has its own address on the bridge, so the node itself and the pods of that node reach each fixed address. macvlan and ipvlan on the node interface do not permit that, and the NVKE controller is a pod of the host cluster.
- It needs no kernel module load (bridge and veth are loaded) and no firewall change. The traffic on the second bridge is switched, not routed. `br_netfilter` is not loaded on the machine, before and after.
- It is the closest lab form of a secondary network on the node network of a site.

## Results by rule

1. The Kata guest (class `kata-clh-runtime-rs-fix-direct`, kernel 6.18.62) has `net1` with the fixed address `/16` and the route `172.28.0.0/16 dev net1`. The default route stays on `eth0`. Multus reports both interfaces in the pod status.
2. Replace (delete and new pod with the same annotation): the address is the same on the same host node and on another host node, in 4 of 4 replaces of the full run and in 10 of 10 replaces of the variants. Times below.
3. Two fixed pods reach each other on these addresses: 5 of 5 directions (3 between host nodes, 2 on one host node). ICMP 3 of 3, HTTP 200.
4. A runc pod of the host cluster with no second interface reaches the address from the same host node and from another host node: 4 of 4. Each kind node and the machine reach it too. The source at arrival is the address of the host node on the node network (`172.28.0.x`), because the node masquerades pod traffic that leaves the pod range.
5. A UDP datagram between two fixed addresses on port 6081 arrives with the fixed address of the sender as source and the own fixed address as destination: 3 of 3 (`source 172.28.1.11, destination 172.28.1.12`, and the reverse, and on one host node). Read with `IP_PKTINFO` (`udp-listen-dst.py`, a copy of the dry run script that also prints the destination).

## Time until a peer reaches a replaced pod again

Probe: one TCP connect each 0.1 s from a Kata pod with a fixed address, and from a runc pod through its node. The new pod is Ready 4.6 to 5.3 s after the delete in each run. An ARP capture on the bridge of the machine ran during each replace.

| Form | Peer reaches the address again, after the delete | After the new pod is Ready | Same node | Other node |
|---|---|---|---|---|
| No fix (new hardware address at each replace) | 28 to 34 s (8 probes of the full run), 30 to 33 s (variant run) | 23 to 29 s | yes | yes |
| Fix 1: fixed hardware address in the annotation (`mac`) | 5.1 to 7.5 s | 0.5 to 1.2 s | 7.1 and 7.5 s | 5.1 and 5.4 s |
| Fix 2a: gratuitous ARP from inside the guest at start (`garp.py`, the same frames as `arping -U`) | 6.5 to 6.8 s | 1.6 to 2.0 s | 6.6 and 6.8 s | 6.5 and 6.7 s |
| Fix 2b: `arp_notify=1` for `net1` in the guest, then link down and up | 5.7 to 6.4 s | 0.7 to 0.9 s | 5.7 and 5.9 s | 6.2 and 6.4 s |

- Cause of the 28 to 34 s: the new pod has a new hardware address, and nothing tells the peers. A peer keeps its old neighbor entry, sends to the old address, and learns the new one only when its entry fails and it asks again. The capture shows the first ARP frame with the new address 30 s after the delete, and it is a reply to that question.
- Does the announcement of the CNI plugin at pod create reach the peers with Kata? No. The capture shows no gratuitous ARP at pod create at all. It is the same when the replaced pod runs with runc (`c1-v-runc`: the Kata peer needed 40 s). So this is not a Kata effect: the `bridge` plugin v1.10.0 with the `static` address plugin sent no frame that left the node.
- Fix 1 works with Kata. The guest interface has the hardware address of the annotation (`02:00:ac:1c:01:20` before and after). A peer needs no new entry. The first frames of the new pod teach the bridges the new port.
- Fix 2 works with Kata in both forms. The capture shows the frames `who-has 172.28.1.32 tell 172.28.1.32` 5.0 to 5.6 s after the delete. Form 2b needs a privileged container (a write to `/proc/sys` and a link change), which the node pod is.
- Which one: fix 1 is the smaller change and has no step in the guest. The address and the hardware address are then both in the pod annotation. Fix 2 also covers a hardware address that the platform does not let the pod choose.

## What failed, and why

- The variant runs `runc` and `mac` report FAIL in their rule 4 lines ("ping rc-w to fx-b"). Cause: each run makes its pods again, the nodes still had the neighbor entry of the pod of the run before, and the rule 4 calls ran in the first seconds. It is the same stale entry effect, between two runs. The replace results of those runs are valid.
- A fault of the test order: the C1 variant run and the first C2 run used the same three addresses at the same time. The `static` plugin has no conflict check, so `172.28.1.11` answered from the C1 pod and the C2 API server did not answer. The C1 test now uses `172.28.1.31` to `.33`.

## What a site needs for this

- A node network that reaches each pod host, and a CNI of the host cluster that gives a pod a second interface on it with an address and a hardware address from the pod spec.
- No two pods with the same address: the lab plugin does not check it.
- If the hardware address cannot be fixed: an announcement from the guest at each start (`arping -U`, or `arp_notify` with a link change).

## Changes on the machine for C1, with removal

| Change | Removal |
|---|---|
| Docker network `kata-bb-node` (bridge `br-katanode`, internal) | `docker network disconnect kata-bb-node <node>` for each node, then `docker network rm kata-bb-node` |
| In each kind node: `/usr/local/sbin/lab-node-bridge.sh`, `lab-node-bridge.service`, bridge `br-node` | `systemctl disable lab-node-bridge.service`, remove the two files, `ip link del br-node` (or delete the cluster) |
| In each kind node: `/opt/cni/bin/bridge` and `static` (CNI plugins v1.10.0, sha256 of the release file checked) | remove the two files |
| Multus v4.3.2 (DaemonSet `kube-multus-ds`, CRD, RBAC, `00-multus.conf` in each node) | `kubectl delete -f /root/kata-cp/dl/c1/multus-daemonset-lab.yml`, then remove `/etc/cni/net.d/00-multus.conf`, `/etc/cni/net.d/multus.d` and `/opt/cni/bin/multus*` in each node |
| Images on the machine: `ghcr.io/k8snetworkplumbingwg/multus-cni:v4.3.2`, `python:3.13-alpine`; files in `/root/kata-cp/dl/c1` | `docker rmi` for each, `rm -rf /root/kata-cp/dl/c1` |
| No kernel module loaded. No firewall rule added. | |
