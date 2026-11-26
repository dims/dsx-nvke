# Phase 1: the tests on the second machine (blocks A to D)

Date: 2026-11-26, 10:55 to 14:09 local time (15:55 to 19:09 UTC). A test agent ran the work on the second test machine and returned this report as text. The main session wrote the file. Its file tool refused a report file for a subagent, so the agent wrote only the four result files (`lab/phase1-fixed-address/result-C1.md` to `result-D.md`) and `progress.txt` (in this folder, one line for each step).

Scripts: this folder (`bb.sh`, `remote/`, `kernel/` with the config fragment, the kernel config and the checksums). The originals are in `/scratch/kata-cp/work/bigbox/`, with the built kernel and two programs that are not in the notes. Logs: `/scratch/kata-cp/logs/bigbox/`. The address of the machine and its name are replaced by placeholders in the copies.

Kata runs with nested virtualization on that machine (a KVM guest). Times do not compare with the workstation.

Not in this folder, because they are the same files as in `lab/phase1-dry/`: the lab client source (`remote/c3/dry/client/`) and the render helper source (`remote/c3/dry/render/main.go`).

## Three things to know first

1. All blocks pass. The cluster of block D, run 2, is up on the machine.
2. No firewall rule was added, in any block. No step needed it: each image went through the machine itself. The agent also did not take the approval of Davanum from a message of the main session as the consent of the user. So the facts "with the rule" do not exist.
3. Block D is the full proof of the fixed address design: the real NVKE controller, the helper, mTLS and `controlPlaneEndpoint`, with pod traffic between the nodes in 6 of 6 directions.

## Part I: block D, the real NVKE controller on the fixed address design

### Verdict

Pass, 2 of 2 runs from empty volumes. The NVKE controller `c6d669ef` in the kind cluster of the second machine made one cluster with three control plane nodes on three Kata pods. No lab client and no NVKE code change.

| Rule | Run 1 | Run 2 |
|---|---|---|
| 1. NVKE reports provisioned | 176.9 s after the POST | 176.9 s |
| 1. Three provisioned nodes, three Ready control plane nodes | 291.4 s, 296.0 s | 281.1 s, 281.9 s |
| 2. Pod to pod between the three nodes | 6 of 6 directions | 6 of 6, and 6 of 6 after the replace |
| 2. Name lookup from a pod on each node | 3 of 3 | 3 of 3, also after the replace |
| 2. OVN pod Ready on each node | `ovnkube-node` 5/5 on each | 5/5 on each |
| 2. Tunnels use the fixed addresses | `node-encap-ips` `172.28.1.21` to `.23`, Geneve packets only between them | The same, also after the replace |
| 3. etcd stock settings, 0 rejected peers | 0 on each host | 0 on each host |
| 4. The endpoint is the shared address `172.29.255.220:6443` | In the kubeadm config, as a SAN of each API server certificate, in both kubeconfig Secrets, in 2 join commands. No kube-vip | The same, also after the replace |

- The etcd flags are the kubeadm defaults (`--listen-client-urls=https://127.0.0.1:2379,https://172.28.1.2x:2379`, `--listen-peer-urls=https://172.28.1.2x:2380`). The patches folder has only the two NVKE files.
- The shared address answered first about 95 s after the POST, then each call (199 of 199 and 186 of 186).

Replace of the first node (run 2, host c):

- Shared address, one call each second for 372 s: 366 of 366 answered.
- Own address of the node: 25 calls failed in 36 s.
- Seconds after the delete: the old pod is gone after 22.5, systemd is up after 35.9, `/readyz` answers after 58.5, the kubelet heartbeat comes after 85.8, etcd is healthy after 86.2.
- NVKE, 32 polls in 360 s: the cluster is `provisioned` in each poll. `nodeAgentReady` is not True in 4 polls. No workflow started.
- After it: the endpoint rules pass, 0 rejected peers, pod traffic in 6 of 6 directions and name lookups in 3 of 3 with new test pods.

### What changed

Against block C3:

- The real controller, mTLS, the bootstrap helper, and the step 5 form of the host pods (no SPIRE file and no cloud-init status from the wrapper, `/etc/spire-agent` on the `/var` volume, the label `nvke.lab/host`, the container name `node`).
- A shared LoadBalancer Service `cp-api` (MetalLB, only ready pods) as `controlPlaneEndpoint`. C3 used the address of the first node.
- Kept: the fixed address and the fixed hardware address on `net1`, the class `kata-clh-runtime-rs-fix-direct-ovs`, the stock datapath mode, no etcd patch file, no address on a guest bridge, two images from files (`pause:3.10.2`, the DNS cache), the removed `modprobe` line.

Against steps 5 and 7:

- No LoadBalancer Service for each host, no guest bridge address, no etcd patch file, no userspace datapath, no `/dev/net/tun`.
- The inventory address of a host is its fixed address. The controller pod reaches `<fixed address>:15005` through its host node. The agent sees `172.28.0.x` (the host node on the node network) as the caller.
- The SPIRE address in `agent.conf` is `172.29.0.3:30081`. A Kata probe pod reached it.
- The stack install runs on the machine itself with no toolbox container. Four kind nodes. Each image goes through the machine.

### What NVKE sees

- POST with `controlPlaneEndpoint` and no `controlPlaneVIP`: HTTP 201. GET returns the field. PATCH with the field: HTTP 400.
- `NodePreflight` attempt 1 fails in each run ("failed to get agent version"). The retry passes. The agent answers 130 to 210 s after the pod create on this machine.
- Run 1: the first `JoinNode` run of the third node failed in `KubeadmJoin` ("failed to get etcd mirror Pod for node"). It is the race of step 5. The retry of NVKE passed. Run 2 did not have it.
- No step failed by a timeout.
- Delete of run 1: the API delete, then the two operator steps on the 3 `ProvisionedMachine` objects and the 3 host claims of that cluster. The row is gone 129.0 s after the DELETE and 11.5 s after the operator steps. The empty check passes.

### Failures and causes

1. Images of the stack. The first way (`ctr` pull on the machine, export, import in each node) worked for 13 of 17. The mirror refused one pull with a quota answer, and a later try passed. The export of the 3 cert-manager images failed ("content digest not found"). The third way was skopeo in a throwaway container with the host network.
2. A fault of the install step: it did not see a failed image load. Step 06 reported a pass with 4 images missing, and one Temporal pod was in `ImagePullBackOff`. Corrected.
3. `check.sh`: 66 passes, 1 failure. It expects `allowControlPlaneWithoutVIP: true`. Block D sets `false` on purpose.
4. `delete.sh` printed one error for a file in a `secrets` folder that this copy keeps elsewhere. No effect.
5. Traffic after the replace, first measurement: 4 of 9 lines. The old test pod on the replaced node has the restart policy Never. With new test pods: 9 of 9.

Not tested in block D: more than two runs, a replace of another node, a host node loss with the controller, a restart of a kind node with the stack, workers, an upgrade, a delete with no operator step.

## Part II: blocks A, B and C

### 1. Verdict

| Test | Result | Runs |
|---|---|---|
| A. Build with a host cluster of four nodes | Pass, no firewall change | 1 |
| B1. Gate 4 across three host nodes, class of record, etcd settings in the kubeadm config | Pass, steps 3, 4, 6 | 3 of 3 full runs |
| B2. The same with the etcd patch file | Pass | 1 of 1 |
| B3. The option that keeps the etcd peer check (DNS name, policy `Local`) | Pass. The source across host nodes is the pod IP. 0 refused peers | 1 of 1 |
| B4. Source addresses and paths | Measured on two clusters | 2 |
| B5. Host node of a follower down 3 minutes | Pass. Quorum stays, the replica returns by itself | 1 |
| B5. Host node of the etcd leader down 3 minutes | Pass. New leader | 1 |
| B5. Host node down 10 minutes | Pass after the node start. Nothing replaces the pod while the node is down | 1 |
| B6. All three workers stopped and started together | Pass for the inner cluster | 2 |
| C1. Fixed address with no NAT on a second interface | Pass, rules 1 to 5. One fix is necessary for a replace | 1 full run, 5 variants |
| C2. Control plane on fixed addresses, stock etcd settings | Pass | 1 run, plus the replaces with the fix |
| C3. Pod traffic between nodes, NVKE node image, kernel datapath | Pass, 6 of 6 | 2 full runs |

### 2. The build

- Machine: Ubuntu 26.04, kernel 7.0.0-43, 64 CPUs, 251 GB, Docker 29.1.3, containerd 2.2.2. No `daemon.json` and no `/etc/containerd`, before and after. dockerd and containerd were not restarted.
- kind v0.33.0 (the newest release, the workstation has v0.34.0-alpha), kubectl v1.36.7, helm v4.2.4, each checked against its release checksum.
- Host cluster `kata-bb`: `kindest/node:v1.36.4` with the digest of the workstation, Kubernetes v1.36.4, containerd 2.3.4, kindnet, kube-proxy iptables. One control plane node and three workers.
- Kata 4.4.0 on all four nodes: the Rust shim, Cloud Hypervisor v54.1, guest kernel 6.18.62. The patched handlers on each node come from the two guest images of the workstation (sha256 checked).
- MetalLB 0.16.2, L2 pool `172.29.255.200` to `.250`.

Differences from the workstation lab:

- Four nodes. Docker network `kata-bb`, `172.29.0.0/16`, bridge `br-katacp`. 12 sparse files on `/dev/loop60` to `71`, with direct I/O.
- The firewall of the machine drops a forwarded new connection from a Docker bridge. So a kind node reaches no registry and no mirror. In its place: images pulled on the machine and loaded into the nodes, D-Bus packages downloaded by one throwaway container with the host network, and two more chart values for Kata (`imagePullPolicy: IfNotPresent`, a control plane toleration).
- `fs.inotify.max_user_instances` from 128 to 8192 at runtime. `kubeProxyMode: iptables` in the kind config.

Firewall facts with no rule:

- A container on the bridge to the internet: no (timeout). Names resolve.
- Two containers on the bridge reach each other.
- A container to the machine itself: rejected, with a kernel log line.
- `br_netfilter` is not loaded: before kind, after kind and after each block.
- A capture on the three outside interfaces during each node stop test: 0 packets for a lab address range.

Listeners: the only lab listener is the kind API port on `127.0.0.1`. Nothing on the outside interfaces. The DNS server of the machine opened port 53 on the two lab bridges by itself.

Use at the end of block D: disk 184 GB of 300 GB (100 GB before the lab), memory 27 GB used.

### 3. Script changes for more than one host node

`wrapper.sh`, `podspec.inc`, both owner templates, `services.yaml.tmpl` and both kubeadm templates of gate 4 have no change in block B. Difference of `run.sh`:

- kubectl, curl and the loops run in the control plane kind node.
- New `HOST_NODES` (replica a on worker, b on worker2, c on worker3) and a function for the host node of a replica.
- `volumes.yaml.tmpl`: the node affinity names the host node of the replica. That places the pod.
- A fault of the original script: `full` ends with exit code 2 from a `grep` over a pattern with no file when no peer check file exists. Corrected in the copy.
- New commands: `host-loss`, `move`, `host-move`, `rest`. New variables: `FIXED`, `FIXED_MAC`, `PV_NODES`, `INNER_CNI`.

### 4. B4: source addresses

Receiver `cp-a` on one worker. Method: a call with no client certificate to the etcd peer port fails in TLS, and etcd logs the remote address with the server name of the call.

| Caller | LoadBalancer address, policy `Cluster` | LoadBalancer address, policy `Local` | Pod IP |
|---|---|---|---|
| A replica on another host node | The address of the host node of the caller (`172.29.0.5`) | The pod IP of the caller (`10.244.3.10`) | The pod IP |
| The replica itself | Its own LoadBalancer address | The same | Its pod IP |
| A runc pod on the same host node | `10.244.2.1` | Its pod IP | Its pod IP |
| A runc pod on another host node | The address of its host node | Its pod IP | Its pod IP |
| Another host node itself | Its node address | Its node address | Its node address |
| The machine | `172.29.0.4`, the node that answers ARP | `172.29.0.1`, the machine | Not called |

- With the etcd peer check on and the policy `Cluster`, etcd refused 25 real peers in one minute, with a node address as the remote address. With `Local`: 0.
- ARP: with `Cluster` MetalLB picks one node with no relation to the pod. With `Local` it is the node of the pod.
- Path from a pod on another node: kube-proxy of the caller node translates at once, and the packet goes from node to node with the pod IP as destination. The ARP node is on the path only for a caller outside the cluster.
- With `Local` the address still answers: from 7 of 7 pod callers on other nodes, from each host node, and from the machine.

### 5. B5 and B6: loss of host nodes

| Point | Follower, 3 minutes | Leader, 3 minutes | Follower, 10 minutes |
|---|---|---|---|
| etcd | 2 of 3 healthy, the term stays | New leader, term 3 to 4 | 2 of 3 healthy |
| Node `NotReady` | 45 s | 47 s | 53 s |
| Shared address, failed calls | 9 of 198 (first 43 s) | 1 of 214 | 11 of 609 (first 48 s) |
| MetalLB moved the addresses of the stopped node | 15 s | 16 s | 15 s |
| Pod object while down | Running, Ready false | The same | `Terminating` after 353 s |
| After the start: node Ready | 9.2 s | 9.1 s | 9.1 s |
| Replica runs again | 9.3 s, same pod | 9.2 s, same pod | 16.8 s, a new pod |
| Three healthy etcd endpoints | 23.7 s | 25.8 s | 25.2 s |
| `/readyz` of the replica | 28.8 s | 29.4 s | 30.0 s |
| Identity | Only the pod IP and the boot ID change | The same | The same |

- 10 minutes, the view of an operator: the node is `NotReady` with the `unreachable` taints, the StatefulSet shows `0/1`, the pod is `Terminating` with `DisruptionTarget`, the claims are `Bound`, and there is no new pod.
- B6 (three workers, 30 s down): the pods run again 12.6 to 20.4 s after the start, etcd has quorum after 33.6 and 47.2 s, `/readyz` of each replica answers after 41.5 to 50.2 s, the identity is the same, and steps 3 and 6 pass.
- In run 1 of B6 the script started the nodes in another order, and Docker swapped the addresses of two workers. The host cluster followed, and the inner cluster returned. The script marks run 1 as a failure for its own address compare.

### 6. What the results change for the design

- With the LoadBalancer address as the node address both etcd settings stay necessary across nodes. The source with `Cluster` is a node address.
- The peer check option works across nodes with `Local`. A new cost: each lookup of the peer name walks the pod search list, with 20 queries, 12 of them with the search domains of the host machine to the upstream DNS.
- With `Cluster` a caller outside the cluster depends on a third node (the ARP node).
- A StatefulSet with local volumes brings the replica back only when the same host returns.
- Block C removes the special settings. A fixed address on a second interface has no Service in the path, etcd runs with stock settings, and the OVN tunnels work. With a volume that can attach elsewhere, one trigger (the out-of-service taint) brings three healthy members back in 30 s.

### 7. Block C in short

The detail is in `lab/phase1-fixed-address/result-C1.md` to `result-C3.md`.

- Network form: a second Docker network (`172.28.0.0/16`, internal) that each kind node joins, a bridge `br-node` in each node, Multus v4.3.2 with the `bridge` and `static` plugins v1.10.0. Why: the address is in the pod annotation, the node and its pods reach it (macvlan and ipvlan do not permit that), no module load, no firewall change.
- C1: rules 1 to 5 pass. After a replace a peer reaches the address only after 28 to 34 s. A fixed hardware address in the annotation: 0.5 to 1.2 s after Ready. A gratuitous ARP from the guest: 1.6 to 2.0 s. `arp_notify` with link down and up: 0.7 to 0.9 s. All work with Kata.
- C2: three started members, 0 refused peers, three Ready nodes, follower and leader replace, 3 moves to another host node, and a host loss with a move (three healthy members 30.0 s after the taint, 110.6 s after the stop). With the fixed hardware address: follower replace 43.0 s to `/readyz`, leader replace 47.1 s.
- C3: the guest kernel 6.18.62 from the Kata 4.4.0 build files with one fragment, 325 s in all, installed as one more handler and RuntimeClass. Pod traffic in 6 of 6 directions, the OVN pod 5/5 on each node, tunnels on the fixed addresses. Two clean runs.

### 8. Failures of blocks A to C, and not tested

1. `docker save` refused two MetalLB images (incomplete in the Docker store). Second way with `ctr`.
2. The first Kata test pod had no `uname` in its image. A fault of the test.
3. `docker cp` into `/tmp` of a kind node fails (tmpfs).
4. B6 run 1: the address swap of section 5.
5. C2 first start: the C1 test pods held the same addresses. The static plugin has no conflict check.
6. C2: a new check line ended the script (`grep -c` with the count 0 under `set -e`).
7. C3 try 1: kubeadm pulls `pause:3.10.2`, and a node cannot pull on this machine.
8. C3: after the C2 host loss test one kind node took its address on the second Docker network as its node address (Docker lists it first in `/etc/hosts`). Pods on it could not reach pods on other host nodes, a name lookup from node c failed, and the join of node c took 150 s. Corrected by hand. A kind node with two networks can do this at each restart.
9. Three times a remote command stopped itself with a kill by pattern on its own command line. No effect on a result.

Not tested: a load on the inner cluster, a host that never returns with local volumes, more than one run of each B5 case, B5 with the patch file or the peer check option, the userspace datapath form of C3, a real network volume.

## Part III: state, files, removal

State on the machine: the kind cluster `kata-bb` is up with Kata, the patched handlers, the Open vSwitch kernel handler, MetalLB, Multus, the NVKE stack, and the cluster `kata-cp1` of run 2 (namespace `d`). The clusters of blocks B and C are removed.

Files:

- On the machine: all under `/root/kata-cp`. Secrets are only in two folders with mode 700 there, and they were made new on that machine.
- On the workstation: `/scratch/kata-cp/work/bigbox/` (scripts, and `kernel/` with the built kernel, the config, the fragment and the checksums), `/scratch/kata-cp/logs/bigbox/` (logs, `progress.txt`, four result files), `/scratch/kata-cp/tmp/bigbox/` (two image archives, 1.3 GB, safe to delete).
- No secrets folder was copied. A search of the copied logs for tokens, keys and passwords found none.
- The lab cluster of the workstation was not touched.

Each change on the machine, with its removal:

| Change | Removal |
|---|---|
| Folder `/root/kata-cp` (kind, kubectl, helm, clusterctl, downloads, scripts, kernel build) | `rm -rf /root/kata-cp`, as the last step |
| Kernel modules `vhost_vsock`, `vhost_net` | `modprobe -r vhost_vsock vhost_net` |
| `fs.inotify.max_user_instances` 8192 (runtime) | `sysctl -w fs.inotify.max_user_instances=128` |
| 12 loop devices `/dev/loop60` to `71` | `losetup -d` for each, then delete the files |
| Docker networks `kata-bb` (bridge `br-katacp`) and `kata-bb-node` (bridge `br-katanode`, internal) | `docker network rm`, after the cluster |
| kind cluster `kata-bb` with all in it (D-Bus, the loop unit, the `br-node` unit, Kata, `/opt/kata-fix` with the new kernel, MetalLB, Multus, CNI plugins, the NVKE stack, the cluster `kata-cp1`) | The NVKE cluster first: `LOG_DIR=/root/kata-cp/logs/d/d-run-2 CLUSTER_NAME=kata-cp1 /root/kata-cp/d/endpoint-run/delete.sh all`. Then `kind delete cluster --name kata-bb` |
| Docker images: the kind node image, the four NVKE lab images, the Kata deploy images, 4 MetalLB images, Multus, a python image, the kernel builder image, `ubuntu:22.04`, skopeo | `docker rmi` for each. `golang:1.27.4` was there before |
| containerd namespace `kata-lab` of the machine (22 images) | `ctr -n kata-lab images rm` for each, then `ctr namespaces rm kata-lab` |
| No firewall rule, no change to the Docker or containerd configuration, no change to the cluster software of the machine, no restart | |
