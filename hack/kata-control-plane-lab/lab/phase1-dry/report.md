# Phase 1, step 1c: dry run of the full flow with three nodes and no NVKE controller

Date: 2026-11-26, about 10:20 to 11:30 local time. A test agent ran the work and returned this report as text. The main session wrote the file. Scripts: this folder, with the originals in `/scratch/kata-cp/work/phase1-dry/`. Logs: `/scratch/kata-cp/logs/phase1-dry/`, with `progress.txt`. "Deduction" marks what is not tested.

## Answer

The flow passes. Three Kata pods become three Ready control plane nodes through `nvke-agent`, in the order of the controller. It passes in 2 of 2 full runs from empty volumes and in 1 exploratory run by steps. The lab client plays the controller.

The measurements show one large problem for open point 2 of `phase1-design.md`. Pod traffic between two nodes does not work at all in this design, for two separate causes (section 5).

## 1. Verdict

Class `kata-clh-runtime-rs-fix-direct`, 2 CPUs and 6Gi for each pod, userspace datapath, plaintext agent.

| Run | Address form | Result | First pod create to third Node Ready | Folder |
|---|---|---|---|---|
| d0 | a and c bridge, b `eth0` (to compare) | Pass by steps. Then replace of c and of b | Not comparable (manual steps) | `d0-explore` |
| d1 | bridge | Pass. Then traffic, tunnels, replace of b, replace of a. Removed | 143.3 s | `d1-full-measure` |
| d2 | bridge | Pass. Then traffic and tunnels. Removed at the start of step 5 | 142.3 s | `d2-full-keep` |

Pass rules, seen in each run (`check-final.txt`, `check-end.txt`):

- `kubectl get nodes` from the client pod through `172.30.255.221:6443` shows `dry-cp-1`, `dry-cp-2` and `dry-cp-3`, each Ready, role control-plane, with the addresses .221, .222 and .223.
- etcd has three started members with the peer URLs `https://172.30.255.221:2380`, .222 and .223. No learner. Three healthy endpoints. 0 lines "rejected connection on peer endpoint".
- Ready pods with `dns-role=cluster-dns`: two CoreDNS pods on node 1 and one node-local-dns pod on each node.

Times in d1 and d2, in seconds:

| Step | Time |
|---|---|
| Pod create to systemd up | 5.6 to 6.0 |
| Preflight plus the Open vSwitch step | 2.1 to 2.2 |
| `kubeadm init` (10 s poll) | 20.1 to 20.2 |
| CNI install | 3.2 to 3.3 |
| DNS apply to a Ready `dns-role` pod | 14.9 to 17.6 |
| `kubeadm reset` before a join | 0.2 |
| Join of node 2 | 30.2 |
| Join of node 3 (10 s poll) | 20.1 to 20.2 |
| Join done to Node Ready | 15.8 to 17.9 for node 2, 1.8 to 1.9 for node 3 |

- The guest has 3 CPUs (2 plus the Kata default of 1). With the `kubeReserved` of NVKE (1 CPU) the allocatable value is 2 CPUs.
- Pod cgroups: 3.4 to 5.4 GiB of 6.5 GiB, and no OOM event.

## 2. The address form that works, and why

Use the bridge form: the LoadBalancer address as a /32 on a Linux bridge with no ports (`g4-node`), set by the wrapper before systemd starts.

- Seen with the bridge form (d0 nodes a and c, d1, d2):
  - `eth0` has one global address. `nke-container-network.service` passes, writes netplan for `eth0` and gives `eth0` to systemd-networkd.
  - networkd lists `g4-node` as "unmanaged" and does not touch it.
  - systemd reports "running" with 0 failed units. The kubelet accepts the node IP.
  - OVN lists the address in `k8s.ovn.org/host-cidrs`.
- Seen with the address as a second address on `eth0` (d0 node b):
  - The unit fails with "prepare container network: expected one Docker IPv4 address on the uplink" (`controller/hack/capd-kindest-node/scripts/prepare-container-network:37-39`).
  - systemd is "degraded", and `eth0` stays unmanaged.
  - The node still joins, etcd works, and a pod replace works (`d0-explore/replace-b.txt`). So `eth0` is usable but leaves a failed unit at each boot.
- Neither form has an effect on Open vSwitch. The agent bridges no interface in the netdev mode.
- Not usable: `lo` (the agent reads a /32 there as kube-vip), a dummy interface (no `CONFIG_DUMMY` in the guest), `br-ex` (it does not exist when the wrapper runs, and OVN owns its addresses).

## 3. Changes

Against gate 4:

- The NVKE node image and `nvke-agent` in place of the kind image and kubeadm by hand. The kubeadm files come from the NVKE renderer, for init and for join.
- No shared API Service. The endpoint is `172.30.255.221`, as `kubeadm_init.go:80-83` does with no VIP.
- Each Service has two more ports: 15005/TCP (agent) and 6081/UDP (Geneve).
- The bridge address form in place of `eth0`.
- The wrapper writes `/etc/kubernetes/patches/etcd+json.json` at each start. Gate 4 wrote it by exec before init and join.
- The node name (`dry-cp-1`) is not the pod hostname (`cp-a-0`), as with NVKE, where the node name is the machine name.
- The join uses the join strings of the agent, and the cleanup before the join of the controller.
- 2 CPUs in place of 4.

Against step 1:

- Three nodes, with the LoadBalancer address as the node address and as the dial address of the client.
- Wrapper: the address step is new, the kind address repair is off, and the etcd patch file is new.
- The client has five new steps: `joinstrings`, `etcdremove`, `reset`, `join`, `waitjoin`. The render helper has a join mode (`NewJoinConfigFromString` and `JoinConfig.Render`).
- The API actions of the controller (DNS step, namespace labels, zone label, role label check, certificate approval) run from the client pod with the kubeconfig from `GetKubeconfig`, so through the LoadBalancer address.
- New controller steps imitated: the etcd quota check (`kubeadm_join.go:233-277`), the join string cache of 5 minutes (`kubeadm.go:36`), `RemoveEtcdMember` and `kubeadm reset` before each join (`provision_node.go:576-647`), the zone label (`provision_node.go:684-688`), the role label check (`:316`).

The etcd patch file next to the NVKE files works:

- After init and after each join the folder has `etcd+json.json`, `kube-apiserver-base-graceful-shutdown+merge.yaml` and `kubeletconfiguration0+merge.yaml`.
- The etcd command ends with the three arguments of the patch, and etcd listens on `*:2379` and `*:2380`.
- The API server has `terminationGracePeriodSeconds` 45, and the kubelet has the reservations of the request (`patch-evidence-a.txt`, `-b`, `-c`).
- `kubeadm reset` through the agent does not remove the patch file and does not remove `br-ex` (`after-reset-b.txt`).

## 4. Failures on the way

- No failure in the flow itself. Init and both joins passed at the first try in each run.
- The OVN pod of node 2 and of node 3 is never Ready (4/5, container `ovnkube-controller`). Cause: its readiness script runs `nslookup kubernetes.default.svc.cluster.local 10.112.0.10` from the node, and it times out, because CoreDNS is on node 1 and pod traffic between nodes does not work. The Node is Ready all the same.
- Faults of the test scripts, corrected: an nft syntax error in the packet probe (d0), a wait for the OVN pod in the replace test (it gave a false failure for the replace of c in d0), and a count of etcd "rejected connection" lines that also counted one client line.

## 5. The three measurements

### 5.1 Pod traffic between nodes

Files `traffic-after-flow.txt`. The result is the same in d0, d1 and d2.

- Same node: ping 3 of 3, and HTTP 200 to the pod address and to the Service.
- Other node: 0 of 6 directions work. A ping gets no answer. TCP to the pod address and to a ClusterIP Service with its endpoint on the other node times out (3 s limit).
- From a pod on each node the API Service `10.112.0.1:443` gives 200, because the endpoints are node addresses and that traffic leaves through the node.
- A name lookup works from a pod on node 1 and times out from a pod on node 2 and node 3. node-local-dns there forwards to CoreDNS on node 1.

### 5.2 Tunnel endpoints and source address

Files `tunnels-after-flow.txt` and `tunnels-extra-etp-local.txt`.

- `k8s.ovn.org/node-encap-ips` is the LoadBalancer address of each node. The Open vSwitch tunnel ports are geneve with `local_ip` = the own LoadBalancer address and `remote_ip` = the LoadBalancer address of the other node. The southbound database of each node has the two other nodes as remote chassis with those addresses.
- Open vSwitch sends no tunnel packet.
  - `ofproto/trace` for a packet from the pod on node a to the pod on node b ends with "output to native tunnel", ">> native tunnel routing failed", drop.
  - An nft counter on each node counts 0 UDP packets to port 6081 in and 0 out during six calls between nodes.
  - Cause (deduction from the behaviour of Open vSwitch): the userspace datapath sends a tunnel packet only through a port of one of its bridges, and the route to the other node leaves through `eth0`, which is not such a port. The agent makes only the dummy `br-ex` in this mode (`agent/internal/agent/open_vswitch.go:288-303`).
- No process listens on UDP 6081 in a node. A test datagram shows the arrival address:

| Test datagram | Arrival |
|---|---|
| Sent to the LoadBalancer address of the other node | It arrives with the source `10.244.0.1` (the kind node, masquerade of kube-proxy with `externalTrafficPolicy: Cluster`). Its destination is the pod IP |
| The same with `externalTrafficPolicy: Local` | The source is the pod IP of the sender (`10.244.0.250`) |
| Sent with the own LoadBalancer address as source (what `local_ip` asks for) | It does not arrive. The kind node has `rp_filter` 1 on the pod interfaces, and its route to that address is `eth0` |
| Sent to the pod IP of the other node | It arrives with the pod IP of the sender |

- So there are two separate causes.
  - First, this datapath mode cannot send.
  - Second, a datapath that sends would still fail at arrival. The tunnel port expects the LoadBalancer address of the sender as source and the own LoadBalancer address as destination, and neither is true after the Service.
- Between nodes OVN needs only 6081/UDP. The single node zone mode has no database connection between nodes: `ovn-remote` is a unix socket, and no node listens on 6641 or 6642 (`listeners-b.txt`).

### 5.3 Replace of one node pod

Files `replace-*.txt`. Seconds after the delete:

| Node | Old pod gone | systemd up | `/readyz` | Three healthy etcd endpoints | OVN container runs | A new pod on the node is Ready |
|---|---|---|---|---|---|---|
| c, d0 | 21.1 | 25.8 | 30.1 | 30.4 | 32.9 | Not measured |
| b, d0 (`eth0` form) | 21.3 | 25.7 | 32.3 | 32.6 | 32.8 | 49.2 |
| b, d1 | 21.9 | 26.7 | 30.9 | 31.2 | 33.7 | 49.3 |
| a, d1 (the endpoint) | 21.7 | 26.3 | 30.7 | 30.9 | 33.5 | 48.0 |

- 20 s of each value is the kill timeout of the pod.
- Each time the pod IP is new, the LoadBalancer address and the volumes are the same, and the etcd member list has no difference. The agent still reports the status ready (phase join, or initialize on node a).
- The tunnel endpoint does not change, so there is nothing to learn. The Open vSwitch system ID does change (a step 1 finding). The node annotation `node-chassis-id` follows, and the other nodes replace the chassis row and the tunnel port in the same test window. `host-cidrs` gets the new pod IP.
- The new test pod on the replaced node reaches the API Service. Traffic between nodes stays broken (`traffic-after-replaces.txt`).
- During the replace of node a the cluster endpoint was down until `/readyz`, about 31 s. The two other nodes were Ready after it.

## 6. What NVKE would see or need at each point

- Dial: `node.IP:15005` is the LoadBalancer address. It works only with `publishNotReadyAddresses` on the Service.
- Preflight: it needs the cloud-init status "done" (the helper of the design).
- Open vSwitch step: it needs the two image changes of step 1, or the controller repeats it with no end.
- `kubeadm init`: the cluster request must carry a small `systemReservedMemory` (gate 1). The etcd patch file must be in the pod before init and before each join.
- Kubeconfig: the server is `https://172.30.255.221:6443`, and the tenant client path works through the Service.
- DNS step: it passes when CoreDNS is Ready on node 1.
- Certificate approval: the request of a kubelet has "DNS:dry-cp-2, IP Address:172.30.255.222". Deduction: this matches the rule of the approver (`controller/internal/controllers/tenant/csr/controller.go:413-437`), if the node IP in NVKE is the LoadBalancer address.
- Join: the quota check passes with the patch file. `RemoveEtcdMember` returns success for a name that is not a member. The reset takes 0.2 s.
- After the joins NVKE sees a provisioned cluster with three Ready nodes. It does not see three faults:
  - The OVN pods of node 2 and node 3 are not Ready.
  - Cluster DNS fails for pods on those nodes.
  - Pods on different nodes cannot reach each other.
- Deduction: a later `helm upgrade` of the chart would not finish its DaemonSet rollout.
- Deduction, not tested: after a restart of the first node, `/tmp/kubeadm-init-config.yaml` is gone (`/tmp` is an emptyDir). The agent then runs `kubeadm init phase upload-certs` with no config file (`agent/internal/agent/agent.go:1597-1604`), and kubeadm can try a version lookup on the internet.
- Deduction: the agent sets `registerNode` false after init and join (`agent.go:693, 970`), so a deleted Node object does not return by itself.
- Deduction: `agent/internal/agent/apiserver_readiness.go:155-166` looks for the mirror pod `kube-apiserver-<hostname>`. The hostname is `cp-a-0` and the node is `dry-cp-1`. This flow does not use that code.

## 7. Not tested

- A way to make traffic between nodes work. Deduction only: it needs tunnel endpoints that pods reach directly (the pod IP, which changes at a replace) and a datapath that can send (`eth0` as a port of an Open vSwitch bridge, or the kernel datapath). The chart has a setting for the tunnel port only (`daemonset.yaml:468-469`).
- The real controller, mTLS, workers, a container restart in the three-node cluster, two nodes down at once, a cold start, a new join after a replace of node 1, a full clean run with the `eth0` form.

## 8. Files, images and state

- Files in this folder: `run.sh`, `measure.sh`, `d-run.sh`, `wrapper.sh`, `podspec.inc`, the templates, `ping.py`, `udp-listen.py`, `udp-send.py`, `client/`, `render/`. The built client is only in `/scratch/kata-cp/work/phase1-dry/bin/`.
- The host module list is the same as before step 1 (263 names). No node service restarted.
- Each node pulled `registry.k8s.io/dns/k8s-dns-node-cache:1.26.8` one time in each run, so 9 pulls in all, one at a time.
- The namespaces of the NVKE stack are not touched.
- The cluster of run d2 stayed up at the end of the dry run. Step 5 removes it first, because it needs the same six loop devices.
- The secrets of run d2 (the kubeconfig, the kubeadm files, the join string) are in `/scratch/kata-cp/logs/phase1-dry/d2-full-keep/secrets` with mode 700, and not in the notes.
