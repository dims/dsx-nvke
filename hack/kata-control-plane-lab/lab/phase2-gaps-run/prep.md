# Phase 2 gaps, preparation of the tests on the second machine

Date: 2026-11-27, 10:17 to 10:55 local time of the workstation (15:17 to 15:55 UTC).
The clock of the second machine shows Pacific time. Each time of the machine in this note is UTC, from `date -u`.

This task was preparation only. It changed nothing in the lab cluster. It built no image. It ran no test script.
The design is `hosted/phase2-gaps-design.md`. The pass rules 1 to 7 are in its section 4.

Folders:

- This folder has the scripts, the build context of the node image without the agent binary, and the kernel files without the kernel.
- The working copy is `/scratch/kata-cp/work/bigbox/remote/p2-gaps/`. The built kernel is in `/scratch/kata-cp/work/bigbox/kernel/`.
- The same scripts are in `/root/kata-cp/p2-gaps/` on the machine.
- The logs of this task are in `/scratch/kata-cp/logs/bigbox/remote-logs/p2gaps/`.

## 1. Short answers

| Question | Answer |
|---|---|
| Is the lab as the last result says | Yes. `kata-cp1`, three control plane nodes and one worker, v1.36.4, healthy |
| Does the guest kernel have `INET_DIAG_DESTROY` | No. It has no `INET_DIAG` at all. `ss -K` closes nothing in a guest |
| Is a kernel with the option ready | Yes. It is beside the old kernel in each kind node. The class does not use it yet. No guest ran it yet |
| Does the image p5 have `ss` with `-K` | Yes. iproute2 6.15.0 |
| Is the build context of p6 and p7 ready | Yes. It waits for the agent binary |
| Are the test scripts ready | Yes, as files. They did not run. Local tests with made up data cover the parts that read the watch files |

## 2. The state of the lab (read only)

Checked at 15:19 UTC and again at 15:50 UTC. Both looks agree.

| Point | Value |
|---|---|
| Host cluster | `kata-bb`, four kind nodes, all Ready, v1.36.4 |
| NVKE cluster | `kata-cp1`, ID `e626b015-cd52-419b-a3f9-8f882365b017`, version 1.36.4, condition `provisioned` only |
| Control plane nodes | `kata-cp1-cp-8bc7bac7` (`172.28.1.5`, `kata-bb-worker2`), `kata-cp1-cp-41b1d0a0` (`172.28.1.6`, `kata-bb-worker`), `kata-cp1-cp-d10b34e5` (`172.28.1.3`, `kata-bb-worker3`) |
| Worker | `kata-cp1-wk-4368` (`172.28.1.4`, `kata-bb-worker`) |
| Nodes of the new cluster | 4 Ready, kubelet v1.36.4, guest kernel 6.18.62 |
| NVKE node list | 4 nodes, each joined, kubernetesReady, nodeAgentReady, provisioned |
| etcd | 3 started members, 3 healthy |
| Static pods | 12, each with 0 restarts |
| Pods of the provider | image p5, class `kata-clh-runtime-rs-fix-direct-ovs`, 0 restarts, readiness probe is the HTTPS call of the kubelet to `/readyz` |
| Shared address | `172.29.255.220:6443`, each call 200 |
| Provider and controller | `cluster-api-provider-podvm:bb15b535`, `nvke-controller:c6d669ef` |
| Workflows that run | 0 |
| Volumes | 8 Bound, 4 Available. `kata-bb-worker` has 0 free Machine places, `kata-bb-worker2` has 1, `kata-bb-worker3` has 1 |
| Machine | disk 213 GB of 300 GB after this task (210 GB before), memory 32 GB used |

`nextCertRenewalDue` of this cluster is 17:18:14 UTC. A scheduled cycle starts then. It renews nothing on this cluster.

## 3. The guest kernel

### What the kernel of the class has

The class `kata-clh-runtime-rs-fix-direct-ovs` uses `/opt/kata-fix/vmlinux-6.18.62-211-ovs` (sha256 `7d91d256...`).

| Source | Fact |
|---|---|
| Kernel build config on the machine (`kbuild/out/.../config-6.18.62-211`, sha256 `3b8ea855...`) | `# CONFIG_INET_DIAG is not set`. So `INET_TCP_DIAG` and `INET_DIAG_DESTROY` do not exist in it. `# CONFIG_IKCONFIG is not set` |
| `/proc/config.gz` in a guest | The file does not exist |
| `/boot/config-6.18.62` in a guest (the copy that the node image carries) | The same config |
| `/proc/kallsyms` in two guests | 0 symbols `inet_diag_`, 0 symbols `tcp_diag_`. 15 symbols `sock_diag_` |

### The proof in a guest

The script is `ss-kill-check.sh`. The log is `prep/ss-kill-old-kernel.txt`. The test has three parts:

- A throwaway listener on port 47611 in the guest of the worker `kata-cp1-wk-4368`. The program came through stdin, so no file went into the guest.
- A `curl` client in the kind node `kata-bb-worker2`, to the address of the guest on `eth0`.
- `ss -K` on that one socket, in the form that the NVKE agent uses (`ss -Ktan state established src <address> sport = :<port> dst <peer> dport = :<peer port>`).

Result at 15:21:27 UTC:

- `ss -K` printed the socket and ended with exit code 0.
- The socket was still in the list 2 s later.
- The client saw no reset. `curl` ended after 20 s with its own time limit (exit code 28).
- The listener saw the close of the client at 15:21:45, not a reset.
- No listener and no process of the test stayed in the guest.

So `ss -K` reports no error and closes nothing with this kernel. The agent counts such a socket as closed. Only its quiet window check finds the socket again. This is a point for the agent code.

### The new kernel

| Point | Value |
|---|---|
| Method | The method of block C3 (`phase1-second-machine/remote/c3/kbuild.sh`). It uses the kernel build files of Kata 4.4.0 (commit `f9cbda4d`), the same builder image, the same options and 24 CPUs |
| Change | One more fragment `sockdiag.conf` beside `ovs.conf` with `CONFIG_INET_DIAG=y`, `CONFIG_INET_TCP_DIAG=y`, `CONFIG_INET_DIAG_DESTROY=y`. `ovs.conf` has no change (sha256 `0ef724e5...`) |
| Build | `kernel/kbuild-sockdiag.sh`, 15:27:25 to 15:28:47 UTC. 82 s in all (setup 24 s, build 58 s). No download. The source file came from the first build, and the build files checked its sha256 |
| Config difference to the old kernel | Only the three options, and two more lines `INET_UDP_DIAG` and `INET_RAW_DIAG` that are not set |
| Kernel file in each of the four kind nodes | `/opt/kata-fix/vmlinux-6.18.62-211-ovs-sockdiag`, sha256 `ecc736a7643bb7df5592c1e3536772507b49f4f2d8b4f3153df2419272a2cf88` |
| Config file beside it | `/opt/kata-fix/config-6.18.62-211-ovs-sockdiag`, sha256 `d69b9e00...` (also in `kernel/` here) |
| Static check | `System.map` of the new kernel has `tcp_diag_destroy` and `inet_diag_handler_cmd`. The old one has neither |
| Disk write time before and after the build | 0.5 ms and 0.4 ms |

The class still uses the old kernel. Nothing names the new file.

The three commands below show the kernel of the class, switch to the new kernel, and switch back.

```
/root/kata-cp/p2-gaps/kernel/kernel-switch.sh status
/root/kata-cp/p2-gaps/kernel/kernel-switch.sh new
/root/kata-cp/p2-gaps/kernel/kernel-switch.sh old
```

- The script changes one line (`kernel = "..."`) of `/opt/kata-fix/configuration-clh-runtime-rs-fix-direct-ovs.toml` in each kind node. It keeps a copy of the file before the change.
- containerd does not restart. The Kata shim reads the file when it makes a sandbox.
- A running guest keeps its kernel. Only a pod that starts after the switch gets the new one. So the nodes of the test cluster must start after the switch.
- No guest ran the new kernel yet, so it is not proven. The first step after the switch is `run.sh kernel-check <pod> <kind node>` (the same throwaway check) in a guest that started after it. `run.sh gate-facts` also reads `uname -v` and looks for `tcp_diag_destroy` in each guest.

## 4. The node image p5 and `ss`

- `ss` is `/usr/bin/ss` from the package `iproute2 6.15.0-1`. Its help has `-K, --kill`.
- The image also has `curl 8.14.1`, `openssl 3.5.9` and `python3 3.13.5`. It has no `nc` and no `socat`.

## 5. The build context of the next node image

The folder is `image/`. The tags are `nvke-node-podvm:bcc4376f-p6` and `nvke-node-podvm:bcc4376f-p7`. p7 is p6 with another marker, as p5 was p4 with a marker.

| File | Content |
|---|---|
| `Dockerfile.p6` | From p5. It copies the agent binary and checks its sha256, copies the kernel config, and runs `gate-setup.sh` |
| `Dockerfile.p7` | From p6. Only the marker `p7` |
| `endpoint-gate.env` | The one place for the gate file and the three agent flags |
| `podvm-endpoint-ready.in` | The probe program, with a placeholder for the gate file |
| `gate-setup.sh` | Build step. It makes the probe program and the drop in file of the agent unit from `endpoint-gate.env` |
| `build.sh` | Builds p6 and p7 on the machine, checks them, and loads them into the three host nodes. It has the copy step of the agent binary |
| `Dockerfile.p8-nogate` | Proposal for pass rule 4 (section 7). `build.sh` builds it only with `WITH_P8=1` |

The agent binary is not here. `ws-sync.sh agent` copies `/scratch/kata-cp/work/phase2-gaps/bin/nvke-agent` beside `build.sh` on the machine and prints its sha256. `build.sh` needs that value as `AGENT_SHA256`.

### The probe program

The program is `/usr/local/bin/podvm-endpoint-ready`, mode 0755, 8 lines. Its two lines of code are below.

```
[ -e "/var/lib/nvke/control-plane-endpoint.gate" ] && exit 1
exec /usr/bin/curl --silent --fail --insecure --noproxy '*' --max-time 2 --output /dev/null https://127.0.0.1:6443/readyz
```

- `curl` 8.14.1 of the image (`/usr/bin/curl`, Debian package `curl`) does the HTTPS call.
- It passes when the gate file does not exist and `/readyz` answers within 2 s with a code below 400. `/readyz` gives 200 or 500.
- It does not check the certificate. The probe of the kubelet before it did not check it too.
- The shell becomes `curl` (`exec`). So the probe is one process, and a kill at the probe timeout leaves nothing.

Checks of the program before it is in an image (`probe-check.sh`, log `prep/probe-check.txt`), with the program from stdin of a shell in the guest:

- 20 runs in the guest of `kata-cp1-cp-8bc7bac7` gave exit code 0 each time, 56 ms mean, 65 ms longest.
- A gate file path that exists gave exit code 1.
- A target that never answers and a kill after 1 s gave exit code 137. No `curl` and no shell stayed.

### The agent unit

The unit of the base image is `ExecStart=/usr/local/bin/nvke-agent $AGENT_ARGS`. NVKE writes `AGENT_ARGS` into `/etc/default/nvke-agent` with its bootstrap data, so the flags cannot go there. The build adds the drop in file `/etc/systemd/system/nvke-agent.service.d/zz-podvm-endpoint-gate.conf`. Its content is below.

```
[Service]
Environment="PODVM_AGENT_GATE_FLAGS=--control-plane-endpoint-gate-file=/var/lib/nvke/control-plane-endpoint.gate --control-plane-endpoint-backend-interface=eth0 --control-plane-endpoint-gate-settle=10s"
ExecStartPre=/usr/bin/mkdir -p /var/lib/nvke
ExecStart=
ExecStart=/usr/local/bin/nvke-agent $AGENT_ARGS $PODVM_AGENT_GATE_FLAGS
```

- The flag names and values are only in `endpoint-gate.env`. A rename of a flag is a change of one line there.
- The build stops when the agent binary does not have one of the three flags in its help text. An agent stops at a flag that it does not know, and then the node never answers.
- The build also stops when the unit of the base image has another `ExecStart` line.
- I tested `gate-setup.sh` on the workstation against a made up root folder with a made up agent. I did not test it against the real binary.
- The same image serves the worker nodes. So the agent of a worker gets the three flags too. A worker pod has no readiness probe.

### The folder of the gate file

- `/var/lib/nvke` is an empty folder in the image p5. The base image made it.
- The entry point copies `/var` of the image to the `/var` volume at the first use and mounts the volume before systemd starts.
- In the guest of `kata-cp1-cp-8bc7bac7` the folder was made at 05:28:09 UTC. The agent started at 05:28:35 UTC.
- The folder is on the `/var` volume (device `/dev/podvm-var`, ext4, the claim `<machine>-var`).
- `ExecStartPre` makes the folder again for a volume that an older image filled.
- The gate file is on a volume. So it stays through a new pod of the same Machine. The agent must open a gate that an earlier pod left closed. This is a point for the agent code.

### One more change than the task listed

p6 carries the config of the new kernel as `/boot/config-6.18.62`. The system check of kubeadm reads that file, and I read it today to learn what the guest kernel has. `build.sh` stops when the config has no `INET_DIAG_DESTROY`. `KERNEL_CONFIG=<file>` gives another config.

## 6. The test scripts

They did not run. I ran three checks of them:

- `bash -n` and `shellcheck` on each script,
- one load of `run.sh` with no step on the machine (it loads the whole chain of the earlier scripts and prints its usage text),
- local tests with made up data of the functions that read the watch files.

`run.sh` loads `p2-gate/run.sh` and the scripts under it, as `p2-gate/run.sh` loaded `p2-worker/run.sh`. One run folder serves one cluster.

| Step of `run.sh` | What it does |
|---|---|
| `probe-start`, `probe-stop` | One call of `/readyz` on the shared address each second, as a transient systemd unit in the kind node of the machine. Each call gives one line with the time and the HTTP code, or `no answer` after 2 s. The steps of the last test (`g1`, `rotate`, `g2`) call these functions |
| `ready-start`, `ready-stop` | `ready-watch.sh` runs on the machine, detached. One look each second at the Nodes through the shared address. One line for each change of the Ready condition of a Node, for a Node that is gone, and for a list that did not come in 3 s |
| `gate-facts` | For each node the image, the readiness probe of the pod, the agent flags of the running process, the probe program, the gate file and the kernel. Reads only |
| `t1` | Pass rule 1. `cmd_g1` of `p2-gate/run.sh` starts the forced renewal with the command of `controller/docs/certificate-renewal.md:183-188`, exactly as the last test. Then the rule check |
| `enc` | etcd encryption on through the NVKE API (`cmd_g2` of the last test), with both watches |
| `t2` | Pass rule 2. `cmd_rotate` of `p2-gate/run.sh` starts the key rotation with the command of `controller/docs/etcd-encryption-key-rotation.md:186-194`, exactly as the last test. Then the rule check |
| `cp-rollout <label> <image>` | Pass rule 3. `PATCH /api/clusters/<id>` with the machine template. One look each 10 s until no old control plane Machine is left and each node is good. It also writes the watch file for the rules 5 to 7 |
| `free-place` | Pass rule 7. Pool count 2, wait for the second worker, pool count 1, `DELETE /api/nodes/<id>` of the worker on the full host node. All through the NVKE API. It does nothing when the surge is pending for more than 600 s |
| `gap2-check <label> free` or `wait` | The rules 5 and 7, or 5 and 6, against the watch file |
| `t4` | Pass rule 4 (section 7) |
| `kernel-check` | The throwaway `ss -K` check in a guest |

The watch file of a rollout (`gap2-<label>-watch.txt`) gets a line for each change of:

- the Ready condition of each `PodVMMachine` (status, reason, message),
- each node of the NVKE node list (the conditions that are True, and the pending message),
- each Machine of Cluster API (failure domain, phase),
- each pod of the cluster (phase, host node, the message of the scheduler),
- the failure domains that the cluster record of NVKE marks,
- the lines of the controller log about a pending node or a failure domain.

Rule check of the rules 1 and 2:

- Each call must have 200.
- A worker Node that loses Ready is a failure.
- For the renewal, a control plane Node may lose Ready only inside its own renewal. The script takes the start of the renewal of a node from the new end date of its API server certificate (365 days before it).
- For the other operations the script prints `REVIEW` for a control plane Node that loses Ready. A person compares it with the phase table.

Each driver runs detached on the machine, as `p2g-g1.sh` did.

| Driver | Chain |
|---|---|
| `p2gaps-cluster.sh <label>` | New cluster with p6 and one worker, health, pod traffic, `gate-facts` |
| `p2gaps-t1.sh <label>` | `gate-facts`, `t1`, health, pod traffic |
| `p2gaps-t2.sh <label>` | `gate-facts`, `enc` if the encryption is off, `t2`, health, pod traffic |
| `p2gaps-t3.sh <label>` | Rules 3, 5 and 7. Rollout to p7. When the surge is pending for 180 s it runs `free-place` one time |
| `p2gaps-t6.sh <label>` | Rules 5 and 6, and rule 3 a second time. Rollout back to p6 with no operator step. Limit 90 minutes |
| `p2gaps-t4.sh <label>` | Rule 4 on a cluster with p8-nogate |

Facts of the source (`d625fcfa`) that shape the tests:

- The guard of the shared address acts in the certificate renewal, in one phase of the enabling of the encryption, in the OIDC enabling, and in each teardown of a control plane node (`internal/temporal/workflows/teardown_node.go:250-258`). So each rollout uses it.
- The key rotation has no guard. Its page says "they do not drain or restart the node" (`controller/docs/etcd-encryption-key-rotation.md:99-102`). So pass rule 2 does not exercise the gate. The enabling of the encryption does. The chain runs both.
- One guarded step on a node takes about 45 s longer. That is the settle time of 10 s, the quiet window of 30 s (`defaultKubeVipSocketQuietSeconds`), and the poll of the controller each 10 s.
- The lab has two Machine places for each host node. With one worker in the cluster one host node is always full. So each rollout of a cluster with a worker meets a pending surge. Pass rule 3 cannot run alone on such a cluster.
- NVKE marks a failure domain for 3 hours after the rule of 15 minutes acts (`unplaceableDomainTTL`, in the cluster record). So rule 7 must run before rule 6 on the same cluster.
- After rule 6 two control plane nodes are on one host node. A later rollout can then meet a full domain two times.
- The provider check of the earlier flow (`cmd_provider`) has the HTTPS probe of the old provider in its pod rules. `run.sh` replaces that one rule with "the readiness probe runs `podvm-endpoint-ready`".
- The settle time is 10 s. With the probe values of today (period 2 s, 3 failures) the pod is not ready after 4 to 6 s, and then the Service must follow. The margin is about 2 s. If a call reaches the node later, the quiet window check stops the operation.

The Ready watch needs the kubeconfig of the test cluster. The script reads `admin.conf` of a control plane node into the secrets folder of the machine (mode 700), as `cmd_evidence` of the earlier scripts did. The file stays on the machine.

## 7. Proposal for pass rule 4

Do not build it before a decision.

- A third image tag `nvke-node-podvm:bcc4376f-p8-nogate` = p7 with one change. The probe program has no line that reads the gate file. The agent, its flags and the gate file are the same. The difference is in the image, so no file goes by hand into a guest.
- A new cluster with three control plane nodes and no worker from that image, through the NVKE API. Then the forced certificate renewal (`run.sh t4`).
- The agent of the first node must close its gate. The pod stays ready. The call each second and the kubelets bring new connections to the node. The quiet window check must fail. The renewal page says "A drain failure stops the cycle before any renewal is dispatched" (`controller/docs/certificate-renewal.md:76-86`).
- The script checks four things. No certificate has another end date. No static pod has a new container. An agent reports the quiet window check. NVKE reports the cycle as failed. It also records if NVKE keeps the lock and if a gate file is left.
- The cluster goes away after the test with a DELETE through the NVKE API. A node of that cluster cannot leave the shared address. So a rollout out of p8-nogate or a teardown of one of its nodes would not pass its guard.
- I do not know a way through the NVKE API to give the image to only one node of a cluster. With all three nodes on it the renewal stops at the first node, and that is what the rule asks.
- The other way is a rollout of the test cluster to p8-nogate at the end of the tests. It takes longer and can meet the full domain again.

## 8. Planned time

The times of the last test are the base. Each time is a plan, not a result.

| Step | Plan |
|---|---|
| Kernel switch | 1 minute |
| Build, save and load of the node images p6, p7 and p8-nogate | 6 minutes (the last build took 20 s, each save and load 90 s) |
| Build, load and install of the provider image and the controller image | Not in my scripts. They come with the second task |
| Delete of the present cluster, volume reset | 2 minutes (46 s the last time) |
| New cluster with p6 and one worker, checks, kernel check in a new guest | 12 minutes (three Ready nodes after 316 s, a worker after 99 s) |
| Encryption on | 11 minutes (5 min 40 s before, plus 3 guarded steps, plus health and pod traffic) |
| Rule 2, key rotation | 9 minutes (5 min 38 s before, no guard, plus the checks) |
| Rule 1, forced certificate renewal | 15 minutes (9 min 49 s before, plus 3 guarded steps, plus the checks) |
| Rules 3, 5 and 7, the rollout to p7 with a place that gets free | 20 minutes (about 11 for three nodes, 3 of pending, 3 for the two worker steps, 3 for the checks) |
| Rules 5 and 6 (and 3), the rollout to p6 with no operator step | 33 minutes. 51 minutes if the rollout meets a full domain two times. Limit of the script 90 minutes |
| Rule 4, with a delete, a new cluster with p8-nogate, a renewal that must stop, and a delete | 15 minutes |
| A cluster that stays up at the end, if wanted | 12 minutes |

The tests take about 105 to 125 minutes in sum. With the setup and a last cluster the whole work takes about 2.5 to 3 hours.

The order is encryption on, rule 2, rule 1, the rollout of the rules 3, 5 and 7, the rollout of the rules 5 and 6, rule 4.

## 9. The commands of the second task, in order

The commands on the workstation run from `/scratch/kata-cp/work/bigbox/remote/p2-gaps/`.

```
./ws-sync.sh scripts
./ws-sync.sh agent
```

The commands on the machine are below. `G` is `/root/kata-cp/p2-gaps` and `L` is `/root/kata-cp/logs/p2gaps`.

```
$G/kernel/kernel-switch.sh new
# WITH_P8=1 only after the decision on section 7
AGENT_SHA256=<value of ws-sync.sh agent> WITH_P8=1 $G/image/build.sh
# the provider image and the controller image, their install and their deploy
LOG_DIR=/root/kata-cp/logs/p2g/g-2 /root/kata-cp/p2-gate/run.sh delete
/root/kata-cp/p2-provider/storage.sh reset
setsid nohup $G/p2gaps-cluster.sh c-1 >$L/c-1-cluster.out 2>&1 &
# the kind node of the client must be another host node than the host node of the pod
LOG_DIR=$L/c-1 $G/run.sh kernel-check <worker pod> <kind node>
setsid nohup $G/p2gaps-t2.sh c-1 >$L/c-1-t2.out 2>&1 &
setsid nohup $G/p2gaps-t1.sh c-1 >$L/c-1-t1.out 2>&1 &
setsid nohup $G/p2gaps-t3.sh c-1 >$L/c-1-t3.out 2>&1 &
setsid nohup $G/p2gaps-t6.sh c-1 >$L/c-1-t6.out 2>&1 &
LOG_DIR=$L/c-1 $G/run.sh delete
/root/kata-cp/p2-provider/storage.sh reset
IMG_CLUSTER=docker.io/library/nvke-node-podvm:bcc4376f-p8-nogate WORKER_COUNT=0 setsid nohup $G/p2gaps-cluster.sh c-2 >$L/c-2-cluster.out 2>&1 &
setsid nohup $G/p2gaps-t4.sh c-2 >$L/c-2-t4.out 2>&1 &
LOG_DIR=$L/c-2 $G/run.sh delete
/root/kata-cp/p2-provider/storage.sh reset
```

Each driver ends before the next one starts. I read its output file on the machine and do not poll from the workstation.

## 10. What waits

| For | What |
|---|---|
| The agent binary | `ws-sync.sh agent`, then `AGENT_SHA256=... image/build.sh`. The flag check of the build runs against the real help text for the first time |
| The provider commits | A provider image and its install file. The name of the probe program, its period and its failure count. The reason texts `FailureDomainUnavailable` and `PodUnschedulable` (the rule check of `gap2-check` looks for the first one) |
| The controller tree | A controller image and its deploy. The pending message that NVKE shows (the check of rule 5 looks for the text of the scheduler or of the reason in it, and prints the line for a person) |
| A decision | The kernel switch. It must come before the first pod of the test cluster |

## 11. Points to decide

1. Switch the class to the new kernel before the tests. Without it the gate cannot close a socket.
2. Make a new cluster with p6, or bring the present cluster to p6. I propose a new cluster. Its guests then start with the new kernel, and it takes 12 minutes.
3. Pass rule 3 with a worker in the cluster always meets a full failure domain. I propose to count rule 3 on the two rollouts of the rules 5 to 7. The other ways are a rollout of a cluster with no worker (about 11 minutes more), or more volume places in the lab storage.
4. Do pass rule 4 as in section 7, with a third image and a short cluster that is deleted after the test. The test leaves a failed renewal cycle on that cluster, and NVKE can keep its lock.
5. Pass rule 2 names the key rotation, which has no guard. Decide if the enabling of the encryption, with both watches, counts as the test of the gate for this rule.
6. The settle time of 10 s has about 2 s of margin over the probe. Keep it, or raise it, or lower the failure count of the probe.
7. The gate file stays on the `/var` volume through a new pod of the same Machine. The agent must handle a gate that is left closed.
8. p6 carries the config of the new kernel in `/boot`. Say if it must stay as in p5.
9. Say if a cluster stays up at the end, and with which image.

## 12. What this task added on the machine, and how to remove it

All is under `/root/kata-cp` or in `/opt/kata-fix` of the kind nodes. No firewall change, no listener on the machine, no restart, no change of Docker or containerd, no NVKE API write, no workflow start, no database write, no Helm change.

| Change | Removal |
|---|---|
| `/root/kata-cp/p2-gaps` (scripts, 140 KB), `/root/kata-cp/logs/p2gaps` (196 KB) | Remove the folders |
| `/root/kata-cp/kbuild/work-sockdiag` (2.4 GB), `/root/kata-cp/kbuild/out-sockdiag` (51 MB), `/root/kata-cp/work/kernel-sockdiag` (40 MB) | Remove the folders |
| `sockdiag.conf` in the fragment folder of the Kata source tree under `kbuild` | `unlink` |
| `/opt/kata-fix/vmlinux-6.18.62-211-ovs-sockdiag` and `/opt/kata-fix/config-6.18.62-211-ovs-sockdiag` in each of the four kind nodes | `unlink` in each node |

Commands that ran in a guest, as checks only:

- reads (`uname`, `ss`, `ls`, `stat`, `findmnt`, `systemctl cat`, `ps`),
- one throwaway listener with one `ss -K` on its own socket, in the worker guest,
- 42 runs of the probe program from stdin in one control plane guest (two rounds, each with 20 runs and 1 run with a gate file path that exists),
- one killed probe in the worker guest, in each of the two rounds.

No file went into a guest. No socket of the cluster was touched.

## 13. What failed, and what I did not do

- The new kernel did not run in a guest. Its proof is the first step after the switch.
- The test scripts did not run. A fault in a step that only a run shows is possible.
- The images p6 and p7 are not built. The Dockerfile steps ran only as `gate-setup.sh` against a made up root folder.
- My first probe check printed a mean time of 0 ms. The script read the wrong field. I corrected it and ran the check again.
- The wrapper `bb.sh` has `ControlPersist=30m`. The task named 15 minutes. I used a copy of the wrapper in my scratch folder with 15 minutes, on the same control path.
- I put the three kernel options into a second fragment file and not into `ovs.conf`, so that the checksum of the first build stays true.
- I copied one read only sample of the state of the cluster (node list, Machines, pods, volumes, no secret value) to the scratch folder of the workstation for the local tests, and removed it after them.
