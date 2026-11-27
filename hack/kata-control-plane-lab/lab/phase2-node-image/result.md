# Phase 2, step 3: the node image for pods (result)

Machine: `the second test machine`, 2026-11-26. Design note: `phase2-design.md`, sections 5a and 6.
Sources: `/scratch/kata-cp/work/bigbox/remote/p2-image/` (the same files are in `/root/kata-cp/p2-image/` on the machine).
Logs: `/scratch/kata-cp/logs/bigbox/remote-logs/p2/` (copy of `/root/kata-cp/logs/p2/`, no secrets folder).

## 1. Verdict

| Test | Verdict | Main facts |
|---|---|---|
| T1, one pod in the 5a form, test data | PASS | systemd `running`, 0 failed units, 59.8 s after the pod create. 6 files with mode and owner. Commands ran one time. cloud-init answer `done`. Both volumes mounted |
| T2, pod deleted and made again, same name and claims | PASS | Repeat run: 3 absent files written, 0 commands. Markers, command output and counter are the same (same inode, same change time) |
| T3, Secret volume in a Kata pod | PASS (facts) | The file is in the guest 0.05 to 0.16 s before PID 1 of the container starts: first start, new pod, restart in place, and in T4. The files unit saw it present each time |
| T4, cluster through NVKE with the new image | PASS | Provisioned, 3 Ready nodes, pod traffic 6 of 6, stock etcd with 0 refused peers, endpoint rules pass. No wrapper ConfigMap, no helper, no image import by the script |
| T4, `NodePreflight` time | Slower than block D | 100.2 s (first node), 221.4 s and 222.2 s. Block D: 30.1 s. Cause: section 6 |

More tests than the brief asked for:

| Test | Verdict | Main facts |
|---|---|---|
| Error case (test data whose second command fails) | PASS | cloud-init answer `error`, one failed unit, the later commands did not run |
| New pod for a Machine in the T4 cluster (real data of NVKE) | PASS | Repeat run with 0 files written and 0 commands. `/readyz` of the pod 59.5 s after the delete (block D: 58.5 s). Shared address 254 of 254 calls |
| One bootstrap unit in place of two | Shows the reason for two units | The unit hangs in the command of NVKE with no end (section 4, point 1) |

No point of section 5a is impossible in a Kata pod. T4 does not need a pod before NVKE names the node.

## 2. The image

Name: `nvke-node-podvm:bcc4376f-p2`. Base: `nvke-node:bcc4376f-amd64`. One Dockerfile, built on the machine with the legacy builder and `docker build --network host` (the Go stage downloads modules from `proxy.golang.org`).
Size: base 1,211,478,586 bytes, new image 1,301,888,330 bytes (90.4 MB more).
Build: `/root/kata-cp/p2-image/build.sh`. It builds the image, takes the test data out of the build stage and loads the image into the three workers.

### Content against the base image

This list is the full difference of the two file lists (`logs/p2/build/image-file-diff.txt`, 34 lines).

| Change | Reason |
|---|---|
| Entry point `/usr/local/bin/podvm-entrypoint`, set as `ENTRYPOINT`. It ends with the entry point of the base image and `/sbin/init` | The pod has no command. The script does what the lab wrapper did before systemd (section 3) |
| `/usr/local/bin/podvm-bootstrap`, a static Go program (3.45 MB) | Applies the bootstrap data. It uses `cloudconfig.go` of the lab helper with no change |
| Units `podvm-bootstrap.service` and `podvm-bootstrap-final.service`, both wanted by `multi-user.target` | Files before the SPIRE agent, commands after the system is up (section 4, point 1) |
| Drop-in `ovs-vswitchd.service.d/zz-podvm-builtin-datapath.conf` and `/usr/local/lib/podvm/ovs-datapath-check` | The base image runs `modprobe openvswitch` when `/sys/module/openvswitch` is absent. A guest kernel with the datapath built in fails that step. The new step accepts a loaded module, a built in datapath (symbol in `/proc/kallsyms`), or a module that loads |
| `/boot/config-6.18.62` | The system check of kubeadm reads the kernel config, and the guest kernel has no `/proc/config.gz` |
| `/etc/default/nvke-agent` is a link to `/var/lib/podvm/agent/nvke-agent` (the file moved, same content) | The agent settings live on the `/var` volume. NVKE writes `/etc/default/nke-agent`, which is a link to this file in the base image |
| `/var/lib/dbus/machine-id` is a link to `/etc/machine-id` | Each node of the base image has the same machine ID (`48ac6baa...`), also the three nodes of block D. The base image has a D-Bus machine ID file, and `systemd-machine-id-setup` takes it first. With the link, the ID comes from the UUID that the entry point keeps on the `/var` volume |
| Images `registry.k8s.io/pause:3.10.2` and `registry.k8s.io/dns/k8s-dns-node-cache:1.26.8` (also under its digest name) in the containerd store, not unpacked (9 blobs, 44.5 MB) | kubeadm v1.36.4 asks for this pause image. NVKE names the DNS cache image by digest. A node of this lab cannot pull |
| Empty folders `/var/lib/podvm/agent` and `/var/lib/podvm/bootstrap` | State folders on the `/var` volume |
| `/run/containerd` of the base image is gone | A side effect of the build step that removes the files of its own containerd. `/run` is a tmpfs at run time |
| Labels `podvm.contract` and `podvm.kernel-release` | Record of the contract version and of the kernel that the config belongs to |

Not changed: the datapath mode (the base image sets `NKE_OVS_DATAPATH_TYPE=system`), the agent unit, the SPIRE agent unit, the cloud-init shim, the unit that installs the CNI images, the stop signal.

Known cost: the two image tar files stay in one layer of the image (44.6 MB that nothing uses). The legacy builder has no bind mount for a `RUN` step. With BuildKit the layer goes away.

## 3. What the image does at a start

Entry point (PID 1, before systemd):

1. It enters a private cgroup namespace and mounts cgroup2 again.
2. It mounts a tmpfs on `/run` and on `/tmp` (the pod of 5a has no volume for them).
3. It makes ext4 on `/dev/podvm-var` and `/dev/podvm-etcd` if a device has no filesystem. At the first use it copies `/var` of the image to the volume. It mounts the volumes at `/var` and `/var/lib/etcd`.
4. It keeps node state on the `/var` volume under `/var/lib/podvm/state` and bind mounts it: `/etc/kubernetes`, `/kind`, `/etc/spire-agent`, and one machine UUID.
5. It removes the old address files of the kind entry point, raises the inotify limits (only in a Kata guest, only upward), turns on IP forwarding, makes `/dev/kmsg`.
6. It stops with an error if the hostname is not `PODVM_MACHINE_NAME`. It writes the three variables to `/run/podvm/env` for the units. It checks that the fixed address is on `net1` and writes a warning if not. It sets no address.

Units:

- `podvm-bootstrap.service`, before `spire-agent.service` and `nvke-agent.service`. First start for a Machine: cloud-init status `running`, the marker `/var/lib/podvm/bootstrap/machine` with the Machine name, then each file of `write_files`. Later start with the same name: only a file that is absent.
- `podvm-bootstrap-final.service`, after `multi-user.target`. It runs each command of `runcmd` one time for a Machine, then writes the status `done`, or `error` when a command fails. The marker `/var/lib/podvm/bootstrap/commands` holds `started`, `done` or `failed` with the Machine name. A later start runs no command.

The cloud-init answer is the status file of the shim of the base image (`/var/lib/nico-containers/cloud-init/status`). It needs nothing new in the image, and it can say `error`. The marker file `/var/lib/dsxos/.cidata-consumed` cannot say `error`.

## 4. Section 5a: readings and choices

1. **One unit became two units of one program.** 5a and the brief say one unit before the SPIRE agent. The one command of NVKE is `systemctl restart nke-agent.service`, and that unit is ordered after `multi-user.target`. A unit that `multi-user.target` waits for cannot wait for that command. Test with one unit (`logs/p2/t123/one-unit-test.txt`): after 144 s the unit is still `activating`, the process `systemctl restart nke-agent.service` waits, the jobs of `multi-user.target`, `spire-agent.service` and `nvke-agent.service` wait, no listener on port 15005, cloud-init answer `running`. So the files come before the SPIRE agent, and the commands run after the system is up. cloud-init has the same two parts. Proposal for the text of 5a: "writes the files before the SPIRE agent starts, runs the commands when the system is up, then gives the answer".
2. **"One time for each Machine".** The marker holds `PODVM_MACHINE_NAME`. A volume with the marker of another Machine gets a full first run (unit test only). On a repeat the unit does not repair a file that is present with another content.
3. **A file on the root filesystem comes back at each new container, a file on the `/var` volume never changes after the first run.** That follows from "writes only a file that is absent". The three files of NVKE are all on the volume (0 files written at a repeat in T4).
4. **`/run` and `/tmp`.** 5a has no volume for them. The entry point mounts a tmpfs. A pod that gives volumes there also works (the entry point makes them empty).
5. **Resources.** 5a has no row. The Kata runtime sizes the guest from the limits, so the template needs CPU and memory (tests: 2 CPUs, 6Gi).
6. **Label with the machine name.** 5a has no key. Tests used `podvm.infrastructure.cluster.x-k8s.io/machine-name`.
7. **Names of the Secret and of the claims in the pod namespace.** Not in 5a. Tests used `<machine>-bootstrap-data` (the name of NVKE), `<machine>-var` and `<machine>-etcd`.
8. **Hostname.** The pod has no `hostname` field. Kubernetes gives the pod name. The agent, the kubelet, the mirror pods and the etcd member have the same name (T4, `names.txt`).
9. **Service account token, service links, grace period, `tty`.** Not in 5a. T1 ran with the defaults of Kubernetes (token and service links on, no `tty`). T4 ran with token and service links off and 20 s grace, as block D. The image works in both forms. The node needs no token of the host cluster.
10. **Readiness probe.** Tests used a failure threshold of 1, as block D. 5a gives only the period.
11. **Kernel config.** The image carries the config of one guest kernel release (6.18.62). So the image and the runtime class are a pair. With another guest kernel the entry point writes a warning, and the system check of kubeadm fails.
12. **More state than 5a lists.** The entry point also keeps `/etc/kubernetes`, `/kind` and the machine UUID on the `/var` volume. A new pod for the same Machine needs the certificates and manifests of kubeadm.
13. **`PODVM_NODE_ADDRESS` and `PODVM_NODE_INTERFACE`.** The image only checks them. Nothing in the image needs them to work.
14. **When is a Machine ready.** 5a has no rule. It matters for the time (section 6).

## 5. Tests T1 to T3

Script: `p2-image/test/t123.sh`, checks inside the pod: `incheck.sh` (15 rules). Namespace `p2`, class `kata-clh-runtime-rs-fix-direct-ovs`, address `172.28.1.41/16` with hardware address `02:00:ac:1c:01:29`, devices `/dev/loop60` and `/dev/loop63`. Bootstrap data: form `full` of the test generator of the helper (fake values): 6 files with modes 600, 640, 644, owners `root:root` and `etcd:etcd`, one path with a space and a quote, one base64 file, 3 commands with a counter.

T1 (`check-t1-first.txt`): all 15 rules pass. systemd `running`, 0 failed units. 6 of 6 files with content, mode and owner. Counter file has 1 line. cloud-init answer `done`. `/var` is `/dev/podvm-var` (ext4, 1.6 GB used of 20 GB), `/var/lib/etcd` is `/dev/podvm-etcd` (mode 700, empty). The agent runs with the settings of the data. Machine ID is the UUID on the volume.

T2 (`check-t1-again.txt`): pod deleted (3.0 s), same manifest applied again. Repeat run: `files=6 written=3` (the three files on the root filesystem), no command. The four markers are the same as in T1 (inode and change time of the machine marker and the commands marker, hash of the command output, counter with 1 line). Machine ID the same.

T3, times in UTC:

| Start | Container start (kubelet) | Entry point start | Data file written in the guest | Files unit | SPIRE agent unit start | Status `done` |
|---|---|---|---|---|---|---|
| First start (pod create 22:30:31) | 22:30:37 | 22:30:37.884 | 22:30:37.781 | 22:30:54.29 | 22:31:30.59 | 22:31:30.84 |
| New pod (pod create 22:31:38) | 22:31:43 | 22:31:43.805 | 22:31:43.683 | 22:31:47.36 | 22:32:08.93 | 22:32:08.99 |
| Restart in place (`systemctl poweroff` 22:32:12) | 22:32:14 | 22:32:14.423 | 22:32:14.373 | 22:32:17.06 | 22:32:36.00 | 22:32:36.06 |

- In the guest the Secret volume is a read only tmpfs (`/sandbox-<id>-bootstrap`). The runtime fills it before the container process starts, also for a new container in the same pod.
- The files unit logged "data present at the start" in each start. Its wait loop (30 s) was never used.
- A change of the Secret after the start reached the guest 56 s later (a new key at 22:33:57, the file at 22:34:53). The image reads the data only at a start.
- The restart in place gave container exit code 130 and a new container 7.0 s after the command.

Error case (`check-t1b-first.txt`, second pod, form `fail`): the second of 4 commands fails. cloud-init answer `error`, system state `degraded` with the one failed unit `podvm-bootstrap-final.service`, counter 1 (the third command did not run), the agent still has the settings of the data, because the files unit comes before the agent unit.

Start time of one pod alone: 59.8 s from pod create to `done` at the first start. Parts: 6 s to the container start, 14 s for the two filesystems and the copy of `/var`, 3 s to the files unit, 34.3 s for the unit `nke-container-cni-images.service` of the base image (it installs a package of 330 MB and imports its images, at each start, before both agent units). A later start: 31 s.

## 6. Test T4

Script: `p2-image/test/t4.sh` (it loads the functions of block D and replaces the ones that name a pod), run `t4-run.sh t4-run-1`. Namespace `p2c`.

Before: delete of the cluster of block D run 2 with the operator procedure (`delete.sh all`): PASS, row gone 129.1 s after the DELETE, 11.5 s after the operator steps. Then the helper Deployment deleted.

Flow:

1. Namespace, network attachment, shared Service `cp-api` (172.29.255.220) with the selector of 5a (the two Cluster API labels). No ConfigMap.
2. POST of the block D request.
3. One look each 2 s at the `ProvisionedMachine` objects of the cluster. When one has `status.hostName`, the script makes for that Machine:
   - the Secret copy: `kubectl -n nvke-system get secret <machine>-bootstrap-data -o json`, through `jq` (same name, type and data, namespace `p2c`, two labels), into `kubectl apply -f -`. The data goes through a pipe. No file and no log has it;
   - the two volumes and claims of the host that the Machine got;
   - the pod `<machine>` with the fixed address of that host.
4. Then only watch and record, as block D.

Times after the POST: host known 38.2 to 39.5 s, Secret copied 0.3 s later, pod made 0.5 s after the host was known.

| Pass rule | Block D run 2 | T4 |
|---|---|---|
| NVKE reports provisioned | 176.9 s | 239.5 s |
| Three provisioned nodes | 281.1 s | 354.2 s |
| Three Ready nodes | 281.9 s | 378.6 s |
| Pod traffic between nodes | 6 of 6 | 6 of 6 |
| Name lookup, API Service from test pods | 3 of 3 | 3 of 3 |
| `ovnkube-node` | 5/5 on each node | 5/5 on each node |
| etcd flags, refused peers | kubeadm defaults, 0 | kubeadm defaults, 0 |
| Endpoint rules (kubeadm config, SAN, kubeconfig, join strings, no kube-vip, GET) | pass | pass |
| Calls to the shared address from each guest | 30 of 30 | 30 of 30 |
| PATCH with `controlPlaneEndpoint` gives 400 | pass | pass |
| Failed workflows | 0 | 0 |

Images: the events of the new cluster show "already present on machine" for the DNS cache image by its digest name. The script imported no image.
Names (`names.txt`): pod name, hostname, `PODVM_MACHINE_NAME`, the node in the NVKE API, the agent state file, the kubelet node name, the four mirror pods and the etcd member agree for each of the three nodes. The three machine IDs differ.
Each pod after the flow: systemd `running`, 0 failed units, cloud-init answer `done`.

### `NodePreflight` against block D

| Node | Scheduled | Done | Time | Failed attempts |
|---|---|---|---|---|
| Block D, each node | 18:52:08.8 | 18:52:38.9 | 30.1 s | 1 |
| T4 host c (first node) | 22:37:43.640 | 22:39:23.863 | 100.2 s | 2 |
| T4 host b | 22:37:43.634 | 22:41:24.989 | 221.4 s | 3 |
| T4 host a | 22:37:43.614 | 22:41:25.839 | 222.2 s | 3 |

Cause, from the logs:

- With `cluster-api-provider-provisioned` the Machine is ready when it has a host. `WaitForCAPIMachineReady` ended at 22:37:43.6, and NVKE called the agent at once. The pods did not exist yet (made at 22:37:44.97 to 22:37:46.27).
- The retry rule of NVKE is 30 s, 60 s, 120 s (`provision_node.go:379-388`, no limit of attempts).
- The agent answered 97 to 100 s after the pod create: host c at 22:39:22.9, hosts a and b at 22:39:25.4. The third attempt reached host c (22:39:23.6) and found no listener on hosts a and b ("connection refused"). The fourth attempt came 120 s later.
- Parts of the 97 to 100 s, with three pods that start at the same time: 9 s to the container start, 28 s for the filesystems and the copy of `/var` (14 s alone), 3 s to the files unit, 55 to 57 s for `nke-container-cni-images.service` (34 s alone), 0.5 s for the agent units and the command.
- In block D the pods ran before the POST. So the start time of a node was not part of the step, and only the helper cost one retry.

The bootstrap part of the image costs no retry: status `done` came 0.2 to 0.5 s after the agent units started, and the first call that reached an agent passed.

What follows for the provider and the image (proposals, not tested):

- The provider should report its machine as ready only when the agent answers. Then NVKE calls one time. A startup probe on TCP port 15005 gives the provider that signal in the pod status.
- The CNI images can go into the containerd store at image build, as the two images of this step. That takes 34 to 57 s out of each start, also out of each new pod for a Machine.

### New pod for a Machine in the T4 cluster

`t4-replace.sh` deleted the pod of the first node (host c) and applied the same manifest again (`replace-c.txt`).

| Fact | Block D | T4 cluster |
|---|---|---|
| Old pod gone | 22.5 s | 22.5 s |
| `/readyz` of the new pod | 58.5 s | 59.5 s |
| New kubelet heartbeat | 85.8 s | 81.4 s |
| etcd healthy | 86.2 s | 81.8 s |
| Shared address during the test | 366 of 366 | 254 of 254 |
| Own address, failed calls | 25 (36 s) | 26 (36.5 s) |
| `nodeAgentReady` not True in the polls of NVKE | 4 of 32 | 13 of 24 |

- The new pod: repeat run, `files=3 written=0`, no command, cloud-init answer `done`, systemd `running`, 0 failed units. The markers, the machine ID and the three files of NVKE are the same as before. The SPIRE agent started with its data on the volume.
- NVKE kept the cluster provisioned and started no workflow.
- `nodeAgentReady`: the agent listened 80 s after the delete (22:48:57). The first call of NVKE that reached it came at 22:50:50. The agent log has no refused call in between. So the controller did not call for 113 s (deduction from the times: a wait of its connection, not read in the code).
- After it: pass rule, endpoint rules and etcd rule pass, pod traffic 6 of 6 with new test pods.

## 7. Failures and their causes

1. The first build script stopped after the build (a Docker template named a key that is absent, `Cmd`). Fixed with `jq`. No effect on the image.
2. One rule of my check script was wrong (it read the cgroup of PID 1 from a shell with another cgroup namespace). Fixed. The image was right.
3. The first image gave each node the same machine ID. The cause is in the base image (section 2). I saw it when the second test pod had the ID of the first. Fixed in the image, and T1 to T3 ran again with the final image (the logs of the first image are in `t123-image1`).
4. T4: two of three nodes lost one more retry in `NodePreflight` (section 6). It is no failure of a pass rule.

No stop condition came up. No tool call was refused.

## 8. Not tested

- A worker Machine (no control plane label, no probe).
- Another guest kernel or another runtime class. A Kata class with no fix for `exec` (the image has no `init` cgroup step). runc.
- A second run of T4. Block D had two runs.
- The provider gate and the CNI images at build (the two proposals of section 6).
- The `error` answer with the real controller (what `NodePreflight` then reports).
- A volume with the data of another Machine in a real cluster, an entry point stop for a wrong hostname or a missing device, a missing Secret (unit tests cover the program part only).
- A restart in place in the real cluster (T3 used test data). A loss of a host node.
- Bootstrap data of NVKE with files outside the three files of the lab form, or larger data.
- The provider ID `podvm://...` (the nodes of T4 have the ID of the provisioned provider).
- A build with BuildKit.

## 9. Changes on the machine and how to remove them

All under `/root/kata-cp` or in the lab cluster `kata-bb`. No firewall rule, no listener on an outside interface, no change of the Docker or containerd configuration, no change of the network settings. The machine checks at the end are the same as after block D (forward chain with its 3 rules, `br_netfilter` not loaded, disk 189 GB of 300 GB).

| Change | Removal |
|---|---|
| Cluster `kata-cp1` of T4 in NVKE (ID `97b8ff06-2808-4da2-aa0e-17410d2fd5a1`), namespace `p2c` (3 pods, 3 Secret copies, 6 claims, Service `cp-api`, network attachment), 6 volumes `p2c-{a,b,c}-{var,etcd}` on `/dev/loop66` to `/dev/loop71`. It stays up | `p2-image/test/t4-delete.sh t4-run-1` (the operator procedure with the pods of T4. Not run) |
| Cluster of block D run 2, its namespace `d` with pods, ConfigMaps and Service: gone (the approved delete) | `d/d-run.sh` makes a cluster in that form again |
| Helper Deployment `nvke-lab-bootstrap-helper`: deleted. Its namespace and RBAC stay. Manifest saved in `logs/p2/helper-deployment-before-t4.yaml` | `d/endpoint-run/run.sh helper` makes it again |
| Docker images `nvke-node-podvm:bcc4376f-p2` and `nvke-node-podvm-build:bcc4376f-p2`, archive `dl/img/nvke-node-podvm_bcc4376f-p2.tar` (1.3 GB), the image in containerd of the three workers | `docker rmi`, `unlink` of the archive, `ctr -n k8s.io images rm docker.io/library/nvke-node-podvm:bcc4376f-p2` in each worker |
| `/root/kata-cp/p2-image`, `work/p2-image-ctx`, `work/p2-diff`, `logs/p2`, `secrets/d-t4-run-1` (mode 700: controller log, workflow histories, kubeconfig of the new cluster, agent journals) | Remove the folders |
| Namespace `p2` and its volumes (T1 to T3): removed. `/dev/loop60`, `61`, `63`, `64` wiped, no signature | Nothing to do |
