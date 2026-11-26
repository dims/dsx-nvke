# Block C3: pod traffic between nodes with the NVKE node image, fixed addresses and the kernel datapath (second machine)

Date: 2026-11-26, 16:55 to 18:20 UTC, on the second test machine. Kata runs with nested virtualization there, so times do not compare with the workstation. Logs: `/scratch/kata-cp/logs/bigbox/remote-logs/c3/` (`c3-try-1`, `c3-try-2`, `c3-run-2`), `remote-logs/c3-kbuild.out`, `c3-kernel-install.log`. Scripts: `/scratch/kata-cp/work/bigbox/remote/c3/` (`kbuild.sh`, `ovs.conf`, `kernel-install.sh`, `env-c3.sh`, `c3.sh`, `c3-measure.sh`, `node-cache-image.sh`, `dry/` = the dry run scripts with the changes below, `labrender` = the render helper as a program).

## Verdict

Pass with the first form (kernel datapath). The second form (userspace datapath with the fixed interface as a port of an Open vSwitch bridge) was not necessary and is not tested.

Flow: the dry run flow of the workstation (three NVKE control plane nodes as Kata pods through `nvke-agent`, the lab client in the place of the controller), with these differences: the node address is the fixed address on `net1` (C1, with a fixed hardware address), no Service, no etcd patch file, the class `kata-clh-runtime-rs-fix-direct-ovs` (guest kernel with Open vSwitch), and the stock value `NKE_OVS_DATAPATH_TYPE=system` of the image.

| Pass rule | Result (run `c3-try-2`) |
|---|---|
| The flow: three Ready control plane nodes, three started etcd members, a Ready DNS pod | Pass. `dry-cp-1`, `dry-cp-2`, `dry-cp-3` Ready with the addresses `172.28.1.21` to `.23`. 0 lines "rejected connection on peer endpoint" with stock etcd settings |
| Pod to pod between three nodes | Pass, 6 of 6 directions: ICMP 3 of 3, TCP to the pod address, TCP to a ClusterIP Service with its endpoint on the other node. The dry run had 0 of 6 |
| A name lookup from a pod on each node | Pass, 3 of 3 (`kubernetes.default.svc.cluster.local`). CoreDNS is on node 1 only, so the lookups from node 2 and node 3 cross a tunnel |
| The OVN pod Ready on each node | Pass. `ovnkube-node` 5/5 on each of the three nodes after the flow, and again after the replace |
| Tunnels use the fixed addresses | Pass. `k8s.ovn.org/node-encap-ips` is `172.28.1.21`, `.22`, `.23`. Each Geneve port has `local_ip` = the own fixed address and `remote_ip` = the fixed address of the other node. A packet counter in each node saw Geneve packets only with these pairs, for example on node a: in `172.28.1.22 > 172.28.1.21` and `172.28.1.23 > 172.28.1.21`, out `172.28.1.21 > 172.28.1.22` and `> .23` (24 packets in, 25 out during six calls) |
| Replace of one node pod (node b) | Pass. Seconds after the delete: old pod gone 22.4, node up 35.6, `/readyz` 56.5, three healthy etcd endpoints 56.9, OVN container runs 59.9, a new pod on that node is Ready 76.2. Then pod traffic again in 6 of 6 directions, and the API Service and a name lookup from the new pod |

- After the replace the fixed address, the tunnel endpoint and the etcd member are the same. The Open vSwitch system ID is new (`b52414b8...` to `2ddb2222...`), and the two other nodes replaced the chassis row and the tunnel port by themselves, as in the dry run.
- The datapath is the kernel datapath: `system@ovs-system`, bridges `br-ex` and `br-int` with `datapath_type: system`, the kernel device `genev_sys_6081`. The agent made `br-ex` with no uplink port, and `eth0` and `net1` are not ports of a bridge. The kernel routes the tunnel packets from `net1` by itself.
- Times of the flow, seconds: pod create to the agent answer 133 to 212, `kubeadm init` 30.2 (10 s poll), CNI install 3.5, join of node 2 50.2, join of node 3 150.3, first pod create to the last Node Ready 458. The long join of node 3 is not examined.

## The guest kernel

- Source: the kernel build files of Kata 4.4.0 (`git clone --depth 1 --branch 4.4.0`, commit `f9cbda4d235b345340bf461e4aaba8c89e841d8d`, `kata_config_version` 211), kernel `linux-6.18.62.tar.xz` from `cdn.kernel.org`, sha256 `490a7aedf1b355c565d3a6c05333ccccb5da82064eca46b590448a7099d7d651` (checked by `build-kernel.sh` against `sha256sums.asc`).
- One added fragment, `tools/packaging/kernel/configs/fragments/common/ovs.conf` (sha256 `0ef724e5ab70f78bcbeb6b5929ede1d05ba8ce9489fc917e99db31299d728c91`), all built in:

```
CONFIG_OPENVSWITCH=y
CONFIG_OPENVSWITCH_GENEVE=y
CONFIG_OPENVSWITCH_VXLAN=y
CONFIG_GENEVE=y
CONFIG_MPLS=y
CONFIG_NET_NSH=y
CONFIG_NF_CONNTRACK_OVS=y
CONFIG_NF_NAT_OVS=y
```

- The stock kernel already has `NF_CONNTRACK`, `NF_CONNTRACK_ZONES`, `NF_CONNTRACK_LABELS`, `NF_CONNTRACK_MARK`, `NF_NAT`, `NF_DEFRAG_IPV4/6`, `VXLAN` and `NET_UDP_TUNNEL`. It has no modules.
- Build: in a container from the Dockerfile of Kata (`tools/packaging/static-build/kernel`), with the host network of the machine for its downloads, with the options of the stock x86_64 kernel (`build-kernel.sh -a x86_64 -v v6.18.62 -f -u ... -x -m`). Time: setup 266 s (clone, builder image, source download, config check), build 57 s on 24 CPUs, 325 s in all. The config check of `build-kernel.sh` passed with the fragment.
- Result: `vmlinux-6.18.62-211`, 40.9 MB, sha256 `7d91d25615ebb21fef1e1ba0ac01cd75bfc9d78f7d7d1866b09982b958b64740`. `uname -r` is `6.18.62` as before.
- Install: only as a new handler and a new RuntimeClass, `kata-clh-runtime-rs-fix-direct-ovs` = the class of record with `kernel = "/opt/kata-fix/vmlinux-6.18.62-211-ovs"`. One more file in the `imports` line of containerd in each node (`/opt/kata-fix/containerd-kata-ovs.toml`), one containerd restart in each node. The stock kernel and the other handlers are unchanged. A test pod on each worker: kernel built today, 150 `ovs_` symbols, a Geneve link can be made.
- Removal: `kubectl delete runtimeclass kata-clh-runtime-rs-fix-direct-ovs`; in each node take `"/opt/kata-fix/containerd-kata-ovs.toml"` out of the `imports` line, restart containerd, remove `/opt/kata-fix/vmlinux-6.18.62-211-ovs`, `config-6.18.62-211-ovs`, `configuration-clh-runtime-rs-fix-direct-ovs.toml`, `containerd-kata-ovs.toml`. On the machine: `rm -rf /root/kata-cp/kbuild; docker rmi kata-kernel-builder:lab ubuntu:22.04`.

## What the node image still needs with this kernel

- `ovs-vswitchd.service` of the image has `ExecStartPre=test -e /sys/module/openvswitch || exec modprobe openvswitch`. With Open vSwitch built in, `/sys/module/openvswitch` does not exist, and `modprobe` fails because the guest has no `/lib/modules/6.18.62` (measured: exit code 1). The wrapper removes that line (`P1_OVS_NO_MODPROBE=1`, a switch of the dry run). A site image needs the same, or a test that also accepts a built in datapath.
- `/dev/net/tun` is not necessary with the kernel datapath (`P1_TUN=0`).
- No datapath override: the wrapper sets no `NKE_OVS_DATAPATH_TYPE`.
- The image has no `arping`. It has `python3`.

## Changes to the dry run scripts

- Fixed addresses `172.28.1.21` to `.23` with the annotation of C1 in the StatefulSet template (address and hardware address). No Service, no MetalLB. `ADDR_FORM=none`, `ETCD_PATCH=0`.
- Each node has its own host node (node affinity of its two volumes). The second set of devices (`/dev/loop66` to `/dev/loop71`).
- The lab client program goes to each host node, because the client pod can run on each worker. The client pod is a runc pod and reaches each agent on its fixed address.
- `render.sh` runs the render helper as a program (`labrender`, built on the workstation with `go build -overlay` from `render/main.go` at the lab commit `bcc4376f`). The machine has no Go and no NVKE clone.
- A new step `preload`: two images go into each node from files (below).

## What failed, and why

1. `c3-try-1`: `kubeadm init` through the agent did not end. Cause: kubeadm v1.36.4 pulls `registry.k8s.io/pause:3.10.2` in its preflight, the node image has `pause:3.10`, and a node cannot reach a registry on this machine (the firewall of the machine drops a new connection from a Docker bridge to outside). containerd of the node also tried `mirror.gcr.io` and `registry-k8s-mirror:5000`. On the workstation that pull goes to the internet. Fix with no firewall change: the machine pulls the image with `ctr` and the flow imports it into each node, together with the DNS cache image.
2. `c3-try-2`: the `node-local-dns` pods were in `ImagePullBackOff`. Cause: the manifest names the image by tag and digest, and the imported file had the tag only. The name lookups passed all the same, through CoreDNS. Fix: the preload step adds the name with the digest. Run `c3-run-2` uses it.
3. The UDP test listener of the dry run on port 6081 cannot bind ("Address already in use"). The kernel datapath owns that port. The packet counter gives the addresses instead.
4. The firewall rule that Davanum approved was not added. No step needed it after the two image files.

## What a site needs for this design

- The fixed interface of C1 for each control plane pod, and the node IP on it.
- A guest kernel with Open vSwitch, Geneve and the connection tracking parts built in (the fragment above), as its own Kata handler.
- A node image whose Open vSwitch unit accepts a built in datapath, and that has `pause:3.10.2` (or the tag that its kubeadm asks for), or a registry that the node reaches.
- Not needed any more: the etcd skip flag, the etcd listen change, the address on a guest bridge, a LoadBalancer Service for each pod, the userspace datapath.

## Not tested

- The second form (userspace datapath).
- The real controller, mTLS, workers, a replace of node 1 (the endpoint) in this block, a host node loss with the NVKE image, an upgrade of the guest kernel under a running node.
- The default route of the node stays on `eth0` (the pod network). OVN uses the pod IP for the gateway (`host-cidrs` lists it). Egress of tenant pods through that path is not tested.
