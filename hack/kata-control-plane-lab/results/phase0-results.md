# Phase 0 results: NVKE control planes as Kata pods

State: in work. Last update: 2026-11-26, 07:40. The plan is [nvke-control-planes-as-kata-pods.md](../nvke-control-planes-as-kata-pods.md). The method is in [PROMPT.md](../PROMPT.md). The dated log with each install and its removal is [runlog.md](../runlog.md).

This file changes while the work continues. A line that says "not tested" or "in work" is not a result.

## The five gates

| Gate | State | Result in one line |
|---|---|---|
| 1. The kubelet and containerd run in the Kata guest | Pass | One Kata pod with Cloud Hypervisor is a kubeadm control plane node, also with the NVKE node image and `kubeadm init` through `nvke-agent` |
| 2. etcd WAL sync below 10 ms at p99 on a raw block volume | Pass | One Kata node: p99 7.8 ms under the 756 node load in 3 of 3 runs. Kata is about 1.15 times runc for the mean. Three replicas on one disk are at 10.7 to 11.7 ms, and the evidence points to the shared disk |
| 3. The agent gets its identity in a Kata pod | Pass with two paths: a join token, and a service account token. The host socket path fails with Cloud Hypervisor | `nvke-agent` in a Kata pod completes an authenticated call from a client that checks its SPIFFE ID. Each path has one limit |
| 4. LoadBalancer IP as node address, and recovery after a cold start | Pass. Steps 3 to 6 on the kind node, and the machine restart in a VM in 10 of 10 restarts | Three replicas keep their identity through a pod replace, a cold start of the host cluster, a machine restart and a power loss. The design needs two etcd settings. The option that keeps the etcd peer check also passes, at the cost of a dependency on the DNS of the host cluster |
| 5. Running pods continue through a containerd and Kata restart | Not tested as a gate. One containerd restart passed | Three running replicas kept their processes and guest boot IDs through one containerd restart |

Recommendation so far: continue with Kata pods. No gate failed. The work found three defects in Kata 4.4.0 for this use, and each one has a fix that is tested in the lab. The final recommendation comes when all gates have a result.

## The lab

- One machine: Ubuntu 26.04.1, kernel 7.0.0-44, x86_64, 24 cores, 60 GB of memory, KVM.
- Host cluster: one kind node (`kindest/node:v1.36.4`, Kubernetes v1.36.4, containerd 2.3.4, cgroup version 2) on its own Docker network. Davanum chose kind in place of k3s.
- Kata 4.4.0 from the `kata-deploy` chart, with Cloud Hypervisor v54.1, guest kernel 6.18.62 and virtiofsd 1.14.0. The Rust runtime (`kata-clh-runtime-rs`) is the main shim. The Go runtime (`kata-clh`) is the comparison. QEMU was not necessary.
- Raw block volumes are loop devices on sparse files, attached with direct I/O. The files are on ext4 on LUKS on NVMe.
- MetalLB 0.16.2 with a pool in the subnet of the Docker network. No lab port listens outside `127.0.0.1`, and a capture on the LAN interface had 0 packets.
- The kind node needed two changes to be equal to a real node: a D-Bus system bus (the Rust runtime asks systemd for cgroups over D-Bus) and loop device nodes (the kubelet attaches one loop device for each raw block volume). Neither is a Kata change.
- A fault of the lab, found in the VM test. While a kind node starts, its pods call the Service address `10.96.0.1:443` before kube-proxy has its rules. Those packets have no translation and follow the default route. In the VM they left through QEMU, and the lab host sent them to its LAN gateway: 10 connection tries for about 71 s in each of 8 boots. A packet filter in the VM stopped it for the last 2 boots. The kind node on the lab host has the same route, so the same is probable for each of its 5 starts. That is not measured. No lab service was reachable from the LAN, and the tries got no answer.
- While the VM ran, QEMU held UDP sockets on all interfaces for the outgoing UDP flows of the guest. They are not listeners of a lab service. The VM is stopped.

## What a Kata pod needs to be a control plane node

| Need | Level | Without it |
|---|---|---|
| `/var` and the etcd data on raw block volumes | Pod spec | overlayfs fails on the virtio-fs root filesystem |
| A CPU limit and a memory limit | Pod spec | The Rust runtime sizes the guest from the limits |
| The device node `/dev/kmsg`, made in the pod | Node image | The kubelet does not start |
| `net.ipv4.ip_forward=1`, set in the pod | Node image | kubeadm preflight error |
| The Kata kernel config at `/boot/config-<release>` | Node image or volume | The kubeadm check `SystemVerification` finds no kernel config. With the file the check reports nothing |
| Node state on a volume: `/etc/kubernetes`, and `/var` for the agent state and the SPIRE agent data | Node image | Kubernetes makes a new container at each restart, so files outside a volume return to the image content |
| A memory overhead of 512 Mi on the RuntimeClass (rule: 100 Mi plus 2 percent of the limit) | RuntimeClass setting | With the stock 130 Mi, an 8 Gi guest that fills its memory gets its hypervisor killed by the pod cgroup |
| Direct I/O for block volumes (`block_device_cache_direct = true`) | Kata configuration value | A write burst in the guest gets the hypervisor killed, with any overhead |
| The kill fix in the Kata agent | Kata source patch | A kill does not stop a container that runs systemd. A stop or a pod delete takes 91 s, and a node that hangs cannot be killed |
| The exec fix in the Kata agent, or a cgroup `init` made in the pod before systemd starts | Kata source patch, or node image | `kubectl exec` fails with EBUSY |
| kubelet reservations below the guest memory | NVKE setting | With the NVKE default of 16 Gi the kubelet does not start in an 8 GiB guest |

No guest kernel option was necessary. The guest kernel has no `dummy` interface type, no modules, no `/proc/config.gz` and no Open vSwitch. Each one has a way around it in the table above or in gate 4.

## Gate 1: the kubelet and containerd run in the Kata guest

Reports: `lab/gate1/report-runc-baseline.md`, `lab/gate1/report-kata.md`, `lab/gate1-nvke/report.md`, `results/kata-fix-install-and-direct-io-test.md`.

Method. One pod with one privileged container runs the node image with systemd as PID 1. A wrapper script runs before the kind entrypoint. `kubeadm init` starts the API server and etcd as static pods. Pass rules: `/readyz` through the Service of the pod, etcd healthy, the node in `kubectl get nodes`, and the control plane returns after a container stop, a power-off in the pod and a new pod on the same volumes.

| Case | Result |
|---|---|
| runc baseline, plain kind node image | Pass, 3 of 3 full runs |
| Kata, `kata-clh-runtime-rs`, plain kind node image | Pass, 3 of 3 full runs |
| Kata, `kata-clh` (Go runtime) | Pass, 1 of 1 |
| Kata with the patched agent, no `init` cgroup workaround | Pass, 2 of 2 |
| NVKE node image, `kubeadm init` through `nvke-agent`, runc | Pass, 3 of 3 (plaintext and mTLS) |
| NVKE node image, `kubeadm init` through `nvke-agent`, `kata-clh-runtime-rs` | Pass, 3 of 3 |
| NVKE node image, `kubeadm init` through `nvke-agent`, `kata-clh` | Pass, 1 of 1 |

Numbers (seconds, and MiB):

| Measure | runc | Kata, Rust runtime |
|---|---|---|
| Pod create to `/readyz`, plain kind image | 11.6 to 12.9 | 14.3 to 15.3 |
| Pod create to `/readyz`, NVKE image through the agent | 21.3 | 23.8 to 24.3 |
| New pod on the same volumes to `/readyz` | 6.5 to 8.6 | 9.6 to 9.7 |
| Memory of the pod on the node after init | 880 to 908 | 2115 to 2849 (Cloud Hypervisor holds about 2100) |

What a restart changes with Kata: a container stop and a power-off in the pod keep the guest VM, the kernel boot ID, the pod IP, the certificates and the etcd data. A new pod gets a new VM and a new boot ID.

Limits: one kind node, no CNI in the inner cluster (the node is `NotReady`, as the plan expects), no QEMU run.

## Gate 2: etcd sync time on a raw block volume

State: done. Report: `lab/gate2/report.md`. Logs: `/scratch/kata-cp/logs/gate2/`.

fio test of the etcd documents (`fdatasync` time in ms, the median of three runs):

| Place | Mean | p50 | p99 | Writes each second |
|---|---|---|---|---|
| Host, ext4 on a loop device | 2.49 | 2.67 | 5.14 | 399 |
| runc pod, raw block volume | 2.51 | 2.67 | 5.14 | 397 |
| Kata pod, raw block volume, class of record | 2.88 | 2.93 | 6.19 | 345 |
| Kata pod, raw block volume, no direct I/O | 2.71 | 2.90 | 5.73 | 367 |
| Kata pod, raw block volume, Go runtime | 2.74 | 2.90 | 5.93 | 363 |
| Host, folder on the disk, no loop device | 1.10 | 1.25 | 2.80 | 904 |
| runc pod, filesystem volume, no loop device | 1.10 | 1.25 | 2.80 | 906 |
| Kata pod, filesystem volume (virtio-fs) | 1.15 | 1.29 | 2.83 | 817 |
| Three streams at one time, host | 4.32 | 4.88 | 7.05 | 231 each |
| Three streams at one time, three runc pods | 4.34 | 4.88 | 7.05 | 230 each |
| Three streams at one time, three Kata pods | 4.31 | 4.82 | 7.18 | 231 each |

- Ratio of Kata to runc on the same raw block volume: 1.15 for the mean and 1.20 for p99. The difference is about 0.37 ms for each sync.
- Each `fdatasync` of the guest reaches the disk. The loop device got the same number of flushes with Kata and with runc.
- Direct I/O costs a little: mean 2.88 against 2.71 ms.
- With three streams at one time, the host, runc and Kata have the same sync time. The disk is then the limit, not the runtime.

etcd under load, one control plane node, 10 minutes each. The load is fake nodes with leases and node status, plus 23 patches each second:

| Load | Requests each second | WAL sync mean, runc | WAL sync mean, Kata | Ratio | WAL sync p99, runc | WAL sync p99, Kata | Syncs above 8 ms, runc | Syncs above 8 ms, Kata |
|---|---|---|---|---|---|---|---|---|
| 355 nodes | 79 | 2.64 ms | 3.06 ms | 1.16 | 7.75 ms | 7.91 ms | 0.08 % | 0.40 % |
| 756 nodes | 146 | 2.44 ms | 2.77 ms | 1.14 | 7.64 ms | 7.83 ms | 0.06 % | 0.20 % |

Pass rule: p99 below 10 ms for the Kata raw block case under the 756 node load. Result for one control plane node: 7.83, 7.82 and 7.86 ms in three runs, each from empty devices. 0.20 to 0.41 percent of the syncs took more than 8 ms. The p99 reaches 10 ms only when 1.33 percent are above 8 ms.

The same load on the three replica cluster of gate 4 (Kata, class of record). Here the three etcd members have their loop devices on the same physical disk:

| Load | WAL sync mean, three members | WAL sync p99, three members | Syncs above 8 ms |
|---|---|---|---|
| 355 nodes | 3.5 to 3.7 ms | 8.8 to 10.0 ms | 1.1 to 1.3 % |
| 756 nodes | 3.3 to 3.5 ms | 10.7 to 11.7 ms | 1.5 to 1.8 % |

So the three replica case does not meet the 10 ms rule in this lab. The evidence points to the shared disk and not to Kata. Three fio streams at one time have the same sync time on the host, in runc pods and in Kata pods (mean 4.3 ms, against 2.5 ms for one stream). At a site each replica is on a different host. A three replica cluster with runc, and three replicas on three separate disks, are not tested.

The cost of Kata looks like a fixed time for each sync (0.3 to 0.4 ms). So on a faster disk the ratio can be higher than 1.15 while the absolute time stays low. That is an inference, and a fast disk is not tested.

Limits:

- The etcd histogram has bucket limits at 4, 8 and 16 ms. The exact statement is that 99.8 percent of the syncs are below 8 ms at 756 nodes with Kata.
- The disk is not the disk of the site, and the block volumes are loop devices. The loop device alone adds about 1.4 ms, so the lab cannot rank the block path against the filesystem path. The ratio of Kata to runc on the same device (about 1.15) is the result that transfers.
- The load model is light in CPU and heavy in writes. The API server uses 0.27 cores at 756 nodes here, and one API server at the target site used 9.1 cores on 2026-11-20. The model has no watch load, no list calls and no large objects. It makes 144 to 149 writes each second at 756 nodes, because the fake nodes patch their status each 20 to 25 seconds and a kubelet does it each 5 minutes.
- Each load window is 10 minutes. The Kata 756 node case ran three times. The runc cases and the three replica cases ran one time each.

## Gate 3: the agent gets its identity in a Kata pod

Reports: `lab/gate1-nvke/report.md` (join token), `lab/gate3/report.md` (host socket and service account token). Procedure from the source: `results/nvke-agent-procedure.md`.

| Path | State | Result |
|---|---|---|
| 1. A SPIRE agent in the pod with a join token | Pass, both Cloud Hypervisor shims | The node pod and the client pod each have their own SPIRE agent. The client checks the agent ID `spiffe://<trust domain>/host/<node UUID>`. Three negative tests fail as they must |
| 2. The socket of a SPIRE agent on the host, with hostPath and with the SPIFFE CSI driver | Fail with both Cloud Hypervisor shims (13 of 13 runs). runc passes (6 of 6) | `connect()` returns ECONNREFUSED in the guest. Kata issue 8024 is true here |
| 3. A SPIRE agent in the pod with a projected service account token (`k8s_psat`) | Pass, both Cloud Hypervisor shims | The agent attests with no secret from NVKE, and it attests again by itself after each kind of absence. `nvke-agent` completed authenticated calls on this identity in 2 node instances |
| The DSX metadata service token | Not testable on this machine | |

Path 1, join token:

- The identity stays through a container restart and through a new pod on the same volumes, with no new join token.
- Limit: a node that is absent for longer than the life of its SPIRE agent identity (1 hour by default) loses it. The agent port then stays closed until the node gets a new join token. So a site needs a path to give a node a new token, for example after a long cold start.
- A site must supply: a SPIRE server address that the pod reaches, the trust bundle, one join token for each node, the registration entry for the host ID, and a caller ID under `/nvke-service/`.

Path 2, host socket:

- The guest sees the socket file through virtio-fs with the correct type and inode. A Unix socket lives in the kernel that made it. The guest kernel has its own socket table, finds no socket for the file, and returns ECONNREFUSED by itself. The call never leaves the guest.
- Kata 4.4.0 has no code that forwards a Unix socket, in the Rust runtime and in the Go runtime.
- The open fix, Kata PR 13162, is not merged. It takes the guest address from a `vsock://` agent address and rejects `hvsock://`, which Cloud Hypervisor uses. So it gives no fix for Cloud Hypervisor.
- The NVKE text (`deploy/nico/spire/values.yaml`, lines 70 to 81) covers another step: how a host SPIRE agent attests a caller in the cgroup of a Kata pod. A model of that step works with `disable_container_selectors = true`. It needs a connection that reaches the host agent, and stock Kata with Cloud Hypervisor makes none.
- QEMU is not tested. Both QEMU classes do not start in this kind node, because `/dev/shm` of the node has 64 MB and QEMU keeps the guest memory there.
- The result agrees with the design: the node pod needs no host socket (architecture question 1).

Path 3, service account token:

- The pod has a ServiceAccount and a projected token volume. The SPIRE agent in the pod shows the token to the SPIRE server, and the server checks it with the TokenReview API of the host cluster. No join token and no other secret goes to the node.
- The agent attests again with no manual step after a container restart, after a new pod, after the loss of its data, and after an absence longer than the life of its identity (2 of 2). The join token path fails in the last case.
- The token in the guest is a virtio-fs mount. The guest saw a renewed token at the same time as the node.
- Limit: the SPIRE agent ID is `spire/agent/k8s_psat/<cluster name>/<UID of the host node>`. Two such pods on one host node with the same cluster name share one agent identity. In the test both pods then got the node ID of the first pod. A new pod can also get the ID of the pod before it for about 5 seconds. So the path is safe only with one such pod for each host node and cluster name.
- A site must supply: the `k8s_psat` plugin on the SPIRE server with a list of permitted ServiceAccounts, RBAC for token review, a node alias entry and a host ID entry for each node, and a scheduling rule that keeps two such pods off one host node.
- NVKE has no template for this attestor (`capi_spire_agent.conf.tmpl` has `joinToken`, `tpm` and `dsxImds`). It is new work.
- Not tested: more than one host node, a SPIRE server outside the host cluster, a cold start, and `kubeadm init` on this identity.

## Gate 4: a LoadBalancer IP as the node address

Reports: `lab/gate4/report.md`, `lab/gate4/report-step5.md`, `lab/gate4/report-vm-restart.md`, `lab/gate4/report-etcd-peer-dns.md`.

| Step | State | Result |
|---|---|---|
| 3. Three replicas join. etcd lists the three LoadBalancer addresses | Pass, 3 of 3 runs, and 1 run with the class of record | |
| 4. A replaced pod returns as the same etcd member with the same certificates | Pass, 9 of 9 replaces, and 3 more with the class of record | About 20 s from the delete to `/readyz` with a 10 s stop timeout. About 28 s with the systemd default and the patched agent |
| 5. Cold start of the host cluster (stop and start of the kind node) | Pass, 3 of 3 valid runs, with the class of record | The cluster returns with no manual step. etcd has quorum 17 to 28 s after the start of the node, and the shared API address answers after 20 to 33 s. One more run was not valid because of a fault of the test script |
| 5. Machine restart, in a VM | Pass, 10 of 10 restarts (6 clean, 4 power loss), with the class of record | The cluster returns with no manual step, with the same etcd member IDs and certificates. The machine needs a boot unit for the loop devices and a module file. Nested virtualization, so the times do not compare with the lab |
| 6. Each pod reaches its own LoadBalancer address | Pass, 3 of 3 runs | |

The design, as tested:

- One LoadBalancer Service for each replica, with a fixed address and `publishNotReadyAddresses: true`. One shared Service for the API endpoint, which does not publish addresses that are not ready.
- The LoadBalancer IP is a second address on `eth0` in the guest, set before the kubelet starts. The kubelet rejects a node IP that is on no interface. A bridge with no ports works too. `lo` is not usable, because `nvke-agent` reads a `/32` on `lo` as the kube-vip address.
- The address repair of the kind entrypoint is off. With it on, a new pod loses its API server certificate and does not return.
- etcd listens on `0.0.0.0`, because kube-proxy changes the destination of a call to the pod IP.
- etcd does not compare a peer certificate with the source address (`peer-skip-client-san-verification=true`), because kube-proxy masquerades each call to a LoadBalancer IP. TLS with the etcd CA stays. Davanum decided to keep the flag in the lab and to test the option that keeps the check before the design is final.

The option that keeps the etcd peer check (`lab/gate4/report-etcd-peer-dns.md`):

- One headless Service selects all replicas, its DNS name is in each etcd peer certificate, and the Service of each replica has `externalTrafficPolicy: Local`. etcd then accepts a peer when its source address, the pod IP, is in the DNS answer for that name. etcd has no skip flag.
- It passes: 3 of 3 full runs (join, replace of a follower, of the leader and of a bare Pod), and one run with all three pods deleted at the same time. etcd rejected 0 peer connections. A replaced pod returns in 28 to 30 s, the same as with the skip flag.
- Its cost: etcd of each tenant cluster needs the DNS of the host cluster at each new peer connection. With that DNS down, a healthy cluster kept running (0 failed calls in 844), but a replica with a new pod did not return in 747 s, and etcd also rejected a new connection between two healthy members. With the DNS back, the member returned in 4.7 s.
- Machine restarts in the VM with this option pass in 5 of 5 (three clean, two power loss). The etcd quorum comes after 31 to 45 s, against 17 to 34 s with the skip flag, because etcd rejects each peer until the DNS of the host cluster has the new pod IPs.
- The two designs side by side are in the report. Davanum chose the skip flag for the design on 2026-11-26, because it adds no dependency. The DNS name stays as a tested option for a site that must keep the check.

During 9 replaces the shared endpoint failed 3 of 193 calls, each in the first second after a delete.

Cold start. The script `lab/gate4/cold-start.sh` stops the kind node container with `docker stop` and starts it with `docker start`, with the three replicas up (class `kata-clh-runtime-rs-fix-direct`). The stop kills the Kata VMs with no clean stop of the guests. Times in seconds after the start of the container:

| Event | Run 2 | Run 3 | Run 4 |
|---|---|---|---|
| API server of the host cluster ready | 4.6 | 5.1 | 4.4 |
| The containers of the three replicas run again | 6.3 | 7.9 | 7.3 |
| etcd of the inner cluster has quorum | 27.4 | 27.9 | 17.3 |
| `/readyz` of each replica through its own Service | not measured | 30.6 | 19.8 to 26.2 |
| The shared API address answers `/readyz` | 31.4 | 32.5 | 19.8 |
| All pods of the host cluster ready | not measured | 57.8 | 58.0 |

- In each run, for each replica only the pod IP and the kernel boot ID changed. The etcd member IDs and all certificates are the same. The pod objects are the same (same UID), with one more restart.
- After each start the node has its address, the loop device nodes from the boot unit, D-Bus, the Kata handlers and the MetalLB addresses, and the API port listens on `127.0.0.1` only.
- The kubelet of the host cluster left no loop device attached on the host after the stop.
- Run 1 is not valid. The test script started its measurement loops with `docker exec -d` right after `docker start`. The two loop processes were in the root cgroup of the kind node, and the kubelet of a kind node does not start while that cgroup holds a process. With the loops stopped, the kubelet started in 3 seconds and the cluster returned. On a node that runs, a `docker exec` process is in `/init.scope` and does no harm (measured later). The fault is specific to a kind node and to the test.
- Not tested: a cold start with the stock class, and a cold start that lasts longer than the life of the SPIRE identity.

Machine restart. A copy of the lab ran in one Lima VM on the lab host (QEMU with KVM, 8 CPUs, 16 GiB, Ubuntu 26.04.1, Docker 29.1.3, the same kind, Kubernetes, Kata and MetalLB versions). Kata ran with nested virtualization there. A clean restart is `systemctl reboot` in the VM. A power loss is a kill of the QEMU process. Times in seconds after the kernel boot of the VM:

| Event | Clean restart (6 runs) | Power loss (4 runs) |
|---|---|---|
| Loop devices attached, then Docker starts | 5.1 to 6.0 | 5.1 to 5.9 |
| API server of the host cluster ready | 10.8 to 12.4 | 10.3 to 11.7 |
| The containers of the three replicas run again | 12.6 to 14.4 | 12.7 to 14.8 |
| etcd of the inner cluster has quorum | 16.8 to 31.6 | 19.0 to 33.9 |
| Three healthy etcd endpoints | 30.6 to 37.7 | 27.6 to 34.3 |
| The shared API address answers `/readyz` | 37.4 to 52.5 | 30.2 to 52.7 |

- In each run and for each replica only the pod IP and the boot ID changed. The pod objects are the same, with one more restart each time.
- After a power loss each Kata guest replayed the ext4 journal of its two volumes, and each etcd member started with its ID.
- What the machine needs for a return with no manual step: a module file for `vhost_vsock` and `vhost_net`, a boot unit that attaches each sparse file to a fixed loop device before Docker starts, and Docker enabled at boot. In the kind node: the D-Bus package and the loop device node unit, as in the lab.
- The restart policy of kind (`on-failure:1`) started the node container in 10 of 10 restarts. It works only because the node container ends with a code that is not 0. A probe container that ends with code 0 did not start again after a clean restart. A site that runs a node as a Docker container needs `always` or `unless-stopped`.
- The shared address answers late because of MetalLB, not because of the replicas. The first MetalLB speaker container of each boot waits 30 s for the API of the host cluster and ends. The API servers of the replicas were ready after 20 to 37 s.
- Limits: one machine, so the three replicas always stop and start together. No load, no SPIRE and no `nvke-agent` in the VM. A kill of QEMU keeps data that the guest wrote with no flush, so it is weaker than a power loss on hardware.

## Gate 5: running pods continue through a host runtime restart

State: not tested as a gate.

One result exists from the install of the extra Kata handlers. The containerd of the kind node restarted one time while three replicas ran. containerd was back in less than 0.4 s. The three replicas kept their shim, virtiofsd and Cloud Hypervisor processes, their pod IPs and their guest boot IDs. A loop on the shared API address had 0 failed calls in 124, with a longest gap of 1.03 s.

Still to test: a kubelet restart, a restart of `kata-deploy` (the chart of 4.4.0 installs with a Job for each node by default, and a DaemonSet is an option), and the upgrade from Kata 4.3.1 to 4.4.0.

## Defects and fixes

| Finding | Where the cause is | Fix, and its level | State |
|---|---|---|---|
| A kill does not stop a container that runs systemd | Kata agent. For a kill of the whole container it reads the processes of the container cgroup only, and systemd moves all processes to child cgroups. A regression from Kata PR 13163 | Source patch, commit `e0f5597` | Tested: the container exits after 1 to 2 s. Upstream issue 14062 is open. Not sent upstream |
| `kubectl exec` fails after systemd starts in the container | Kata agent. It puts an exec process in the container cgroup, which cannot hold a process when its children have controllers | Source patch, commit `96a8d90`, a backport of upstream PR 13627 with one change | Tested with both shims |
| The pod cgroup kills the hypervisor when the guest fills its memory | The RuntimeClass overhead of 130 Mi is too small for the Rust runtime with an 8 Gi guest | RuntimeClass setting: 512 Mi | Tested |
| The pod cgroup kills the hypervisor at a write burst | The hypervisor writes a block volume through the page cache of the host, and those pages count in the pod cgroup | Kata configuration value: `block_device_cache_direct = true` | Tested: 3 of 3 runs survive, against 3 of 3 killed |
| The Go runtime does not account the guest memory to the pod | The hypervisor runs outside the pod cgroup, with no limit | None. It is a reason to use the Rust runtime | Measured |
| The Rust runtime fails on a stock kind node | It needs the D-Bus system bus, and a kind node has none | Lab node only: install D-Bus. A real node has it | Fixed in the lab |

The two source patches are on the branch `lab/agent-kill-child-cgroups` of the fork `dims/kata-containers`, and as files in `lab/patches/`. Detail: `results/kata-agent-kill-fix.md`.

## Architecture questions

These answers are the state of the work. Each one can change with the gates that are still open. The source reading is `results/architecture-reading.md`.

1. **Isolation.** The design needs no host network, no `hostPath` volume and no host socket. One concrete case: `nvke-agent` runs `swapoff -a` at start. In a runc pod the call reaches the kernel of the host. In a Kata pod it touches only the guest.
2. **Owner of the pod.** A StatefulSet with one replica for each control plane node makes the pod again in 2 to 3 seconds with the same name and claims. Nothing makes a bare Pod again, so a provider must do it. Both forms keep the identity of the node. The StatefulSet fits better, because NVKE never changes a machine in place and the pod must return when the management side is down.
3. **Node address.** The LoadBalancer IP of the replica, on an interface in the guest. It needs the two etcd settings of gate 4.
4. **Node state.** `/etc/kubernetes` must stay. The agent state and the SPIRE agent data are in `/var`, which is a volume. NVKE upgrades by replacement, so a new version is a new pod with a new image.
5. **Provider.** Three kinds through the `infra` path of NVKE, with no new NVKE provider type and no Cluster API source change. NVKE needs these changes: an endpoint mode with no kube-vip, the etcd arguments of gate 4, the kubeadm container mode for a kind that is not `DockerMachineTemplate`, smaller kubelet reservations, and chart RBAC for the new kinds. From the source reading, not tested.
6. **Identity.** A SPIRE agent in the pod works with no host socket, with a join token or with a projected service account token. The host socket does not work with Cloud Hypervisor at all. The join token path needs a new token after an absence longer than the life of the agent identity. The service account token path needs no secret and repairs itself, but it permits only one such pod for each host node and cluster name, and NVKE has no template for it. Davanum chose the join token for the phase 1 design on 2026-11-26. The service account token stays as the candidate for the long absence case.
7. **Restart and repair.** A container restart keeps the guest and the boot ID. A new pod gets a new guest and a new boot ID, and keeps the node address, the etcd member and the certificates. From the source reading, NVKE does nothing when a control plane host is lost, so a replacement needs a trigger that NVKE does not have today.

## What this lab cannot answer

- The Kata version, hypervisor and snapshotter of a real site.
- The DSX metadata service path for identity.
- OVN-Kubernetes behavior on the host cluster. This lab has a different CNI.
- Disk and CPU numbers of the real hosts.
- arm64. The Kata chart has Cloud Hypervisor for amd64 only. The hosts for the pods at the target site are x86_64.
- The behavior with real DPU workers.
- Kata on a bare metal node. In this lab the Kata hypervisor runs in the kind node, which is a Docker container.
- A host cluster with more than one node.
