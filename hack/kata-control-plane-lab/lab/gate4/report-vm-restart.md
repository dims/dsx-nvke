# Gate 4, step 5: machine restart test in a Lima VM

Date: 2026-11-26, 04:32 to 05:22 UTC. A test agent ran the work and returned this report as text. The main session wrote the file. The VM `kata-restart` ran on the lab host. It is stopped and not deleted.

Main points:

- The answer is yes. After a machine restart the inner cluster returned with etcd quorum, the same etcd member IDs and the same certificates, with no manual step, in 10 of 10 restarts (6 clean, 4 power loss).
- The VM leaked connection tries to the lab host. At each boot of the VM, pods of the kind node called the Service address `10.96.0.1:443` before kube-proxy had its rules. The packets left the VM through QEMU, and the host sent them to its LAN gateway. A packet filter in the VM stops it since the run "clean 6". Section 5 has the detail.
- The export of images from the kind node of the host does not work. kind sets `discard_unpacked_layers = true`, so containerd has no layer data for pulled images. The agent pulled six images in the VM, one at a time.

The permission system refused no tool call. No `sudo` ran on the host.

## 1. Verdict

Pass for the clean restart (3 of 3 planned runs, and 3 of 3 extra runs). Pass for the power loss (2 of 2 planned runs, and 2 of 2 extra runs). No run needed a manual step. No boot ordering fix was necessary.

- Clean restart: `sudo systemctl reboot` in the VM.
- Power loss: `limactl stop --force`, which kills QEMU with SIGKILL, then `limactl start`.

Times are seconds after the kernel boot of the VM, from `/proc/uptime`. A boot unit in the VM wrote them. Kata runs with nested virtualization here, so the times are not comparable with the lab.

Planned runs:

| Event | Clean 1 | Clean 2 | Clean 3 | Power 1 | Power 2 |
|---|---|---|---|---|---|
| Result | Pass | Pass | Pass | Pass | Pass |
| Manual step | None | None | None | None | None |
| Modules loaded (`systemd-modules-load`) | 3.7 | 3.6 | 3.7 | 3.7 | 3.7 |
| Loop devices attached | 5.1 | 5.1 | 5.2 | 5.2 | 5.2 |
| Docker start job begins | 5.2 | 5.2 | 5.2 | 5.2 | 5.2 |
| Kind node container started (Docker `StartedAt`) | 5.7 | 5.6 | 5.6 | 5.7 | 5.7 |
| Docker active | 5.9 | 5.7 | 5.8 | 5.9 | 5.9 |
| API server of the host cluster answers `/readyz` | 11.6 | 12.1 | 11.3 | 10.3 | 11.5 |
| Kubelet of the kind node renews its node lease | 12.4 | 12.3 | 11.4 | 10.4 | 12.4 |
| Containers of the three replicas are new and run | 13.7 | 13.6 | 12.6 | 12.7 | 13.6 |
| etcd quorum of the inner cluster (first `etcdctl` call that commits) | 24.6 | 17.7 | 16.8 | 33.0 | 19.0 |
| Three healthy etcd endpoints | 37.7 | 33.7 | 32.4 | 33.5 | 32.0 |
| `/readyz` of replica a, b and c through its Service | 42.5 | 42.4 | 52.5 | 52.7 | 52.5 |
| `/readyz` through the shared address | 42.5 | 42.4 | 52.5 | 52.7 | 52.5 |
| All pods of the host cluster ready | 55.4 | 62.8 | 64.3 | 63.3 | 63.8 |

Extra runs. All have four small probe containers for the restart policy question (section 3). Clean 6 and Power 4 also have the packet filter of section 5:

| Event | Clean 4 | Power 3 | Clean 5 | Clean 6 (filter) | Power 4 (filter) |
|---|---|---|---|---|---|
| Result | Pass | Pass | Pass | Pass | Pass |
| Loop devices attached | 5.1 | 5.1 | 6.0 | 5.2 | 5.9 |
| Docker start job begins | 5.1 | 5.2 | 6.0 | 5.2 | 5.9 |
| Kind node container started | 5.5 | 5.8 | 6.5 | 5.6 | 6.1 |
| API server of the host cluster | 11.2 | 11.7 | 12.4 | 10.8 | 11.0 |
| Containers of the three replicas new | 13.6 | 14.8 | 14.4 | 12.6 | 13.6 |
| etcd quorum (`etcdctl`) | 17.6 | 33.9 | 18.9 | 31.6 | 27.2 |
| etcd leader elected (etcd log, about) | 17.9 | 31.8 | 19.1 | 31.7 | 26.7 |
| Three healthy etcd endpoints | 30.6 | 34.3 | 34.7 | 32.0 | 27.6 |
| Pods of the replicas Ready (kubelet probe of `/readyz` through the pod IP, 1 s steps) | 20 to 21 | 36 to 37 | 21 to 22 | 34 | 30 to 31 |
| `/readyz` of each replica through its Service | 52.4 | 42.4 | 51.3 | 34.4 to 34.5 | 30.0 to 30.9 |
| `/readyz` through the shared address | 52.4 | 42.4 | 51.3 | 37.4 | 30.2 |
| All pods of the host cluster ready | 63.5 | 63.3 | 63.5 | 38.2 | 34.9 |
| Second start of the MetalLB speaker container | 52 | 41 | 51 | 20 | 21 |

How to read the times:

- The Service addresses answer late because of MetalLB, not because of the replicas. Without the filter, the first speaker container of each boot waits 30 s for `10.96.0.1` and ends (`dial tcp 10.96.0.1:443: i/o timeout`). The addresses answer 1 to 2 s after the second speaker container starts. With the filter the first container fails at once, and the addresses answer when the replicas are ready.
- The API servers of the replicas were ready 20 to 37 s after the kernel boot (extra runs, pod Ready time).
- etcd quorum came in two groups: 17 to 19 s (5 runs) and 25 to 34 s (5 runs). In the one slow run that the agent read (Power 4), the start check of etcd waited 7 s for its peers (`failed hash kv request ... context deadline exceeded`). The other slow runs are not examined.
- Precision. The watch unit checks one time each second. A probe call that times out takes 1 s more, so the Service times have steps of 2 s. The etcd log times come from the clocks of the Kata guests and can differ by some tenths of a second.
- After a power loss the wall clock of the VM made a step of 0.4 to 1.4 s during the boot (time sync). The uptime values do not have this error.
- A clean restart needs about 14 s from `systemctl reboot` to the new kernel. Docker needs 10 s of that to stop the kind node.

## 2. Versions and differences from the lab

| Item | Version |
|---|---|
| Lima | 2.3.0 (release of 2026-11-06). The sha256 of the tarball matches the digest of the release |
| QEMU (host) | 10.2.1, machine q35, KVM, `-cpu host`, UEFI (`/usr/share/OVMF/OVMF_CODE_4M.fd`) |
| Guest OS | Ubuntu 26.04.1 LTS server cloud image `release-20261016`, kernel 7.0.0-38-generic, systemd 259 |
| Docker in the VM | 29.1.3 (`docker.io` 29.1.3-0ubuntu4.1), containerd 2.2.2, runc 1.4.0, no `daemon.json` |
| kind | v0.34.0-alpha+54e57d2af1f9b2, node image `kindest/node:v1.36.4` |
| Kubernetes | v1.36.4 (host cluster and inner cluster), containerd 2.3.4 and runc 1.4.3 in the node, etcd 3.6.8, kubectl v1.37.1, Helm v4.2.4 |
| Kata | 4.4.0 from the `kata-deploy` chart 4.4.0, Rust shim, guest kernel 6.18.62 |
| Hypervisor | Cloud Hypervisor v54.1 |
| RuntimeClass | `kata-clh-runtime-rs-fix-direct`: patched guest image `kata-ubuntu-resolute-killfix-execfix.image` (sha256 `aca24d7f...`), `block_device_cache_direct = true`, overhead 512Mi and 250m |
| MetalLB | 0.16.2 (chart), FRR 10.6.2, frr-k8s v0.0.27 |

The six pulled images have the same digests as in the kind node of the host.

Differences from the lab:

- Nested virtualization: the Kata guests run in a KVM guest. `/dev/kvm` was present in the VM from the first boot, `kvm_intel` with `nested=Y`.
- VM size: 8 CPUs, 16 GiB, one 60 GiB sparse disk. The lab host has 24 CPUs and 60 GB.
- Replicas: `CPU=2` (lab 4) and `MEMORY=4Gi` (lab 6Gi). With 4 CPUs the three pods do not fit on 8 CPUs. The guest has 3 vCPUs and 4.06 GB. The node requests are 7.7 CPUs (96 percent) and 14.1 GiB (88 percent).
- Sparse files: three of 12 GiB for `/var` (lab 30, 30 and 20) and three of 4 GiB for etcd (lab 10). Loop devices `/dev/loop20` to `/dev/loop25`.
- Names and addresses: cluster `kata-vm`, node `kata-vm-control-plane`, Docker network `kata-vm` on `172.31.0.0/16` with bridge `br-katavm`, MetalLB pool `172.31.255.200` to `250`. They differ from the lab values on purpose, so that a command on the wrong machine fails and a leaked packet cannot reach the lab.
- Gate 4 uses `kindest/node:v1.36.4` for the replicas. The NVKE node image was not necessary.
- The copy of `run.sh` in the VM is the lab version of 2026-11-25, 23:33, with the new options at their defaults. It differs in the addresses, the loop devices and the sizes only (`vm-restart/guest/gate4-run.sh.diff`).
- `fs.inotify` values set to the host values (8192 and 1048576). The Ubuntu default is 128 instances.
- No SPIRE, no `nvke-agent`, no load on the cluster.

## 3. What the machine needs for an unattended return

Needs of the machine (the VM):

1. Kernel modules at boot. File `/etc/modules-load.d/kata-lab.conf` with the lines `vhost_vsock` and `vhost_net`. `kvm_intel` loaded by itself at each boot.
2. Loop devices before Docker. Unit `/etc/systemd/system/vm-restart-loops.service` (`vm-restart/guest/vm-restart-loops.service`):
   - `After=systemd-modules-load.service`, `Before=docker.service`, `RequiredBy=docker.service`, `Type=oneshot`.
   - Its script reads a table (`/dev/loop20 /var/lib/vm-restart/disks/var-0.img`, one line for each of the six devices) and runs `losetup --direct-io=on "$dev" "$file"` for each line. It fails if direct I/O is not on.
   - `losetup` adds a device with the given number if the kernel does not have it. `RequiredBy=docker.service` means that Docker does not start if a device is absent.
   - In all 10 runs the unit ended 0 to 0.1 s before the Docker start job began. The kind node had `/dev/loop20` to `/dev/loop25`, `/dev/kvm`, `/dev/vhost-vsock` and `/dev/vhost-net`. The six files had the same devices with direct I/O after each restart.
3. Docker enabled at boot (the default of the package), and a restart policy on the node container (see below).
4. `/etc/sysctl.d/60-kata-lab-inotify.conf` with `fs.inotify.max_user_instances = 8192` and `fs.inotify.max_user_watches = 1048576`. From the kind documents. A restart without it is not tested.

Needs in the kind node. Both stay in the filesystem of the container through a restart:

5. `g4-loop-nodes.service` from `lab/gate4`, unchanged. After each restart it was active, and the node had 128 loop device nodes. The kubelet attached six new loop devices (`/dev/loop0` to `/dev/loop5`).
6. The package `dbus` (`lab/01-node-prep.sh`, unchanged). After each restart `dbus.socket` and `dbus.service` were active.

What Docker did with the kind node container (policy `on-failure:1` from kind):

- Clean shutdown (6 runs). Docker sent the stop signal. The node did not stop in the 10 s stop timeout, and Docker killed it. Record on disk after the shutdown: `"Running":false,"ExitCode":137,"HasBeenManuallyStopped":false`. At the next boot Docker started the container about 0.4 s after its own start. `RestartCount` stayed 0.
- Power loss (4 runs). Record on disk before Docker started: `"Running":true,"Pid":1746` (a dead process). Docker journal: `Removing stale sandbox`, then the container started. `RestartCount` stayed 0.
- So `on-failure:1` was enough in 10 of 10 restarts. The count stays 0, so machine restarts do not use up the one retry.
- It is enough only because the exit code is not 0. Four probe containers show the rule. Each ends with exit code 0 at its stop signal:

| Policy of the probe | After a clean restart (3 runs) | After a power loss (2 runs) |
|---|---|---|
| `on-failure:1` | Not started. `status=exited exit=0` | Started |
| `always` | Started | Started |
| `unless-stopped` | Started | Started |
| `no` | `exited`, code 0 | `exited`, code 255 |

- Docker gives a container that it finds dead after a power loss the exit code 255, so `on-failure` starts it.
- What a site needs: if a node runs as a Docker container, use `--restart=always` or `unless-stopped`. With `on-failure`, a node that completes its stop inside the stop timeout with exit code 0 does not come back after a clean restart. A change of the policy of the kind node is not tested.
- The stop of a clean restart also kills the Kata guests, because Docker kills the node after 10 s. So for the guests a clean restart is the same as a power loss.

Units for the test only, not needs of a site: `vm-restart-guard.service` (packet filter, section 5), `vm-restart-record.service` (copies the container state that Docker has on disk, at boot before Docker and at shutdown after Docker), `vm-restart-watch.service` (writes the event times, then compares the state). The watch unit only reads. It does not use `docker exec` before the cluster is back. It calls the cluster from the VM.

## 4. Identity check for each replica and run

In each of the 10 runs the script compared 43 lines (cp-a) or 42 lines (cp-b, cp-c) before and after: 12 certificate and public key checksums, 15 or 16 checksums of private keys and kubeconfigs, the kubelet certificates, 5 manifest and flag files, the etcd member list, node UID, node address, marker object, machine ID, pod IP, boot ID.

- Result in all 10 runs and for all three replicas: only `pod-ip` and `boot-id` differ. In 9 of 30 cases the pod IP was the same by chance, and only `boot-id` differs.
- From the state before Clean 1 to the state after Power 4: 0 other lines differ.
- 0 lines "regenerating the certificate" in each pod log, 30 of 30.
- The pod UIDs are the same in all runs. The restart count of each pod went from 0 to 10.

| Replica | etcd member ID | Node address | Pod UID | `apiserver.crt` sha256 | `etcd/peer.crt` sha256 |
|---|---|---|---|---|---|
| cp-a | `2c3ee611d1d8bb64` | 172.31.255.211 | `fe5fcb51-a59b-4c93-933b-5fec62829364` | `cbaa3e1c54cb0eaf...` | `e538d9f748966f92...` |
| cp-b | `6bea08fb998a6eda` | 172.31.255.212 | `dcc9de72-22df-4bd5-8221-6fea715a6fa4` | `c310abdf4288d759...` | `8312a66b591c8983...` |
| cp-c | `d911ecdcc8cb87c6` | 172.31.255.213 | `2c05ed08-428f-4d3b-ae1f-9117a0e0170d` | `705d80098c615809...` | `9c672373bcc6f0dd...` |

CA `94a9bad9c44f774e...`, etcd CA `c88533a20b0cfafd...`, etcd cluster ID `5e202b2c371bc26a`.

Other checks after each restart, all pass:

- Steps 3 and 6 of `run.sh`: three started members with the LoadBalancer addresses, three healthy endpoints, `/readyz` on .210 to .213, and each pod reaches its own and the shared address.
- 13 node checks: address 172.31.0.2, device nodes, D-Bus, the same 10 runtime handlers, MetalLB answers for the four addresses, the API port on 127.0.0.1 only, all 16 pods of the host cluster ready, loop devices, modules.

After the power loss each Kata guest replayed the ext4 journal of both volumes (`EXT4-fs (vdb): recovery complete`, `(vdc): recovery complete`), and each etcd member started with its ID (`restarting local member`, the same commit index on all three).

## 5. Faults of the setup and of the test

No restart run failed. These are the faults of the setup and of the test:

1. Image export. `docker exec kata-cp-control-plane ctr -n k8s.io images export ...` gave `ctr: failed to get reader: content digest sha256:32cb93fb...: not found`. Cause: `discard_unpacked_layers = true` in the containerd configuration of a kind node. The agent removed the partial file and pulled in the VM, one at a time: `k8s-job-dispatcher:0.3.0`, `kata-deploy:4.4.0` (63 s), MetalLB controller and speaker `v0.16.2`, `frr:10.6.2`, `frr-k8s:v0.0.27`. `kindest/node` came from `docker save` of the host.
2. MetalLB pool. The first `kubectl apply` failed: `failed calling webhook ... connect: connection refused`. The webhook was not ready. The second try worked.
3. Leak of connection tries to the host, and a safety unit that did not work.
   - Cause. A pod of the kind node calls `10.96.0.1` before kube-proxy has its rules. The packet has no translation, the node sends it to its gateway (the VM), and the VM sends it through the user-mode network of QEMU. The host then routes it to the LAN gateway (`10.96.0.1 via 10.0.0.1 dev enp128s31f6`).
   - Evidence. Sockets of the QEMU process on the host during the boot of Power 3 and of Clean 5: 10 sockets `SYN-SENT 10.0.0.75:port -> 10.96.0.1:443`, about 71 samples each at one sample each second.
   - Extent. 8 boots (Clean 1 to 5, Power 1 to 3), so about 80 tries in groups of 10. A request from the host after that answered in 0.1 s.
   - The first safety unit added an `unreachable` route for the lab subnet, and version 2 for all private ranges. Both did not work after a boot: systemd-networkd removes routes that it did not make. The agent found it only in Clean 5, which is why that run has the same times as the runs before.
   - Fix (version 3): a packet filter table (`vm-restart/guest/vm-restart-guard.nft`), loaded by `vm-restart-guard.service` before the network starts. It rejects each packet that leaves through `eth0` to a private address range, except the user-mode network of Lima (`192.168.5.0/24`).
   - Result. Clean 6 and Power 4: 0 sockets to a private address on the host. The filter rejected 40 and 32 packets. This is a safety change, not a boot ordering fix. It also changes the times, because the callers fail at once.
   - The probe loops of the watch unit never leaked: they call an address only when its route goes to `br-katavm`.
   - The kind node on the lab host. The main session read the routes on 2026-11-26: the kind node sends a Service address with no kube-proxy rule to its gateway `172.30.0.1`, and the host routes `10.96.0.1 from 172.30.0.2` to `10.0.0.1 dev enp128s31f6`. So the same leak is probable at each start of the kind node on the host (5 starts on 2026-11-25). It is not measured there.
4. MetalLB speaker. In each boot the first speaker container ends with exit code 1: `unable to start manager ... Get "https://10.96.0.1:443/api": dial tcp 10.96.0.1:443: i/o timeout` (after 30 s without the filter, at once with it). The kubelet starts it again. No manual step.
5. The agent changed the test scripts one time during the work (before Clean 4): more records (pod Ready times, etcd log lines, speaker state, Docker events). The planned runs do not have these records.

## 6. What is not tested

- A restart with the stock class `kata-clh-runtime-rs`. All runs use the class of record.
- A restart without one of the needs (no loop unit, no module file, no `g4-loop-nodes.service`, no inotify setting). Whether the vhost modules load on demand is not tested.
- A power loss on hardware. `limactl stop --force` kills QEMU with SIGKILL. Data that the guest wrote to its disk stays, also without a flush. A disk that loses its write cache is not in this test.
- A power loss under load. The inner cluster was idle, with about 3.6 MB of etcd data.
- Three hosts. All three replicas are on one machine, so they always stop and start together.
- A long outage, the SPIRE identity and `nvke-agent`. They are not in the VM.
- A restart of Docker only, a failed first start of the node (with `on-failure:1` Docker tries one more time), another restart policy on the kind node, another Docker version.
- LVM volumes in place of loop devices.
- The extra conditions have one or two runs each, not three.
- In Clean 1, the agent read the event file one time over SSH 20 s after the boot. In all other runs no SSH command ran before the boot unit ended. `limactl start` opens its own SSH session after a power loss.

## 7. Files, installs, listeners, use and removal

Files:

- In this folder: `vm-restart/kata-restart.yaml` (VM configuration), `vm.sh` (run a command in the VM), `collect.sh` (copy one run to the logs), and `vm-restart/guest/` with the units, the scripts and the settings of the VM. The originals are in `/scratch/kata-cp/work/vm-restart/`. The gate 4 files of the VM are not copied. `guest/gate4-run.sh.diff` is their difference to `lab/gate4/run.sh`.
- Raw output: `/scratch/kata-cp/logs/vm-restart/`. Numbered step logs `00` to `72`, `70-all-runs-table.txt`, the host socket samples (`46`, `52`, `58`, `63`), the listener lists, and `runs/<run>/` with the full record of each of the 10 runs.
- The agent wrote nothing into `~/notes`, `~/.ssh`, `~/.kube`, `~/.lima` or `~/.cache`. It ran `git status --short` one time in `~/notes` to check that. That command can refresh the git index file.

Installed on the host, only under `/scratch/kata-cp/`: Lima 2.3.0 in `lima-install/lima-2.3.0`, its download in `lima-install/dl`, the Lima cache with the Ubuntu image in `lima-install/cache` (`XDG_CACHE_HOME`), the VM in `lima/kata-restart`, the Lima SSH key pair in `lima/_config`, the share `vm-share`. No change to Docker or containerd of the host. Reads on the host: `docker save kindest/node:v1.36.4`, and `docker exec` reads in the lab node.

Secrets: the kubeconfig, the bootstrap token and the certificate key of the VM cluster are only on the VM disk (`/var/lib/vm-restart/`). The share and the logs have none (checked with a search).

Listeners on the host with the VM up, against the list before:

- Two new TCP listeners, both on 127.0.0.1 (QEMU for the SSH forward, `limactl` for the host agent). The ports change at each `limactl start`.
- The port forward rule of the VM ignores all guest ports (Lima log: "TCP (except for SSH) and UDP port forwarding is disabled").
- After the stop the list is equal to the list before.
- QEMU holds UDP sockets on `0.0.0.0` with random ports for the outgoing UDP flows of the guest (24 to 33 at a time). They are not TCP listeners, but they are bound to all interfaces while the VM runs.

Connections to outside: one GitHub API request and one download for Lima, the Ubuntu image, one health request. From the VM: apt (`docker.io`, `jq`, `gettext-base`), apt in the kind node (`dbus`), six image pulls one at a time, the Kata chart, two requests for the MetalLB chart, and the time servers of Ubuntu at each boot. The apt, snap and update timers of the VM are stopped.

Use: VM disk file 12.1 GB of 60 GiB, `lima-install` 0.94 GB, `vm-share` 0.70 GB, logs 7 MB. Total about 13.7 GB. Memory: the QEMU process had 7.7 GiB resident with the cluster up. In the VM: 4.9 GiB used, 11 GiB available, each replica pod about 1.9 GiB.

State: `limactl list` shows `kata-restart Stopped`. No QEMU or `limactl` process is left. A `limactl start kata-restart` brings the cluster back by itself, with the packet filter active.

Removal:

```
export LIMA_HOME=/scratch/kata-cp/lima XDG_CACHE_HOME=/scratch/kata-cp/lima-install/cache
/scratch/kata-cp/lima-install/lima-2.3.0/bin/limactl delete --force kata-restart
rm -rf /scratch/kata-cp/lima/_config /scratch/kata-cp/lima-install /scratch/kata-cp/vm-share /scratch/kata-cp/work/vm-restart
rm -rf /scratch/kata-cp/logs/vm-restart     # only after the notes have what they need
```
