# Gate 1, step 2: the same pod with Kata and Cloud Hypervisor

Date: 2026-11-25. Kata 4.4.0 (commit 3fa2b14e), Cloud Hypervisor v54.1, guest kernel 6.18.62, kind node kernel 7.0.0-44. One template and one wrapper serve runc and Kata. The agent that ran the tests wrote this report, and the main session saved it.

## Result for each shim

| Shim | Result | Runs |
|---|---|---|
| `kata-clh-runtime-rs` (Rust runtime) | Pass | 3 full runs from empty volumes, 12 of 12 checks (`kata-rs-run-1` to `kata-rs-run-3`, systemd stop timeout 10 s). 1 full run with the systemd default, 4 of 4 checks (`kata-dev3`) |
| `kata-clh` (Go runtime) | Pass | 1 full run, 4 of 4 checks (`kata-go-run-1`) |
| QEMU shims | Not run | Cloud Hypervisor works with the two shims. `/dev/shm` of the kind node did not change |
| runc with the final files | Pass | 1 full run, 4 of 4 checks (`runc-regression-final`) |

One Kata finding needs a decision. A kill from the runtime (SIGKILL) does not stop this container. See part 5.

Logs are in `/scratch/kata-cp/logs/gate1/`. The files are in `~/notes/hosted/lab/gate1/`, with copies in `lab-files-final` and `lab-files-at-runc-baseline` of the log folder.

## 1. Pass rules

Lines from `kata-rs-run-3/check-4-after-new-pod.txt`:

- Rule 1: `curl -sk https://10.96.83.180:6443/readyz` in the kind node gives `ok (http 200)`.
- Rule 2: `etcdctl endpoint health` gives `https://127.0.0.1:2379 is healthy: successfully committed proposal: took = 4.44ms`.
- Rule 3: `kubectl get nodes` in the pod gives `cp NotReady control-plane v1.36.4 ... 6.18.62 (amd64) containerd://2.3.4`.
- Rule 4: after `crictl stop` and after `systemctl poweroff` the check prints "identity: no difference from the first check". After a new pod the differences are the pod IP and `apiserver.crt`, as with runc.
- Rule 5: each `kata-rs-run-<n>.out` has four `RESULT ...: PASS` lines and `rc=0`.

What a restart changes. The result is the same in all runs and with the two shims.

| Restart type | Kernel boot ID | Guest VM (cloud-hypervisor PID) | Container ID | Container cgroup at start | Exit code of the old container |
|---|---|---|---|---|---|
| `crictl stop` in the kind node | Same | Same | New | Empty ("children [] processes [1 4 5]") | 130 |
| `systemctl poweroff` in the pod | Same | Same | New | Empty | 130 |
| New pod on the same volumes | New | New | New | Empty | Not applicable |

- The pod IP, the certificates, the etcd data and the machine ID stay through the first two types. The sandbox is the same.
- `/run` and `/tmp` keep the files of the old container, and the wrapper makes them empty. The block devices stay attached. Sysctl values stay, because the kernel is the same.
- The number of cgroups in the guest kernel rises at each restart (65, 89, 114 with the Rust runtime, and 65, 68, 72 with the Go runtime). After `echo 3 > /proc/sys/vm/drop_caches` the number is 50 with both. So the old cgroups are dying cgroups that the page cache holds. No live cgroup of an old container stays (`guest-cgroup-count-test.txt`).
- With runc the boot ID is the boot ID of the host for all three types.

## 2. Paths outside /var

The list is the same as in the baseline. `/etc/kubernetes` and `/kind` are bind mounts from the `/var` volume, and `container_uuid` keeps the machine ID. The guest adds one path, `/boot/config-<release>`, which the wrapper copies at each start.

## 3. Preflight, and what a Kata guest needs to be a kubeadm node

The raw preflight in the guest (no ignore flag, guest steps of the wrapper off, `kata-dev1/preflight.txt`) has two errors: `SystemVerification` (no kernel config) and `FileContent--proc-sys-net-ipv4-ip_forward`. It has no swap warning. With the list below, the preflight has no warning and no error (exit code 0), and `kubeadm init` needs no ignore flag (`kata-rs-run-*/preflight.txt`).

| Need | Where | Evidence without it |
|---|---|---|
| `/var` and `/var/lib/etcd` on raw block volumes | Pod spec | overlayfs fails on virtio-fs (probe 11 of the main session) |
| `mkdir /sys/fs/cgroup/init` before systemd | Wrapper, with `G1_GUEST=1` | `kubectl exec` fails with "failed to add process into unit cri-containerd-<id>.scope ... EBUSY", with the two shims. Only exec breaks. The control plane of an initialized node returns, and `/readyz` is ok |
| `net.ipv4.ip_forward=1` | Wrapper | Preflight error |
| `/dev/kmsg` (`mknod c 1 11`) | Wrapper | kubelet: "failed to create kubelet: open /dev/kmsg: no such file or directory" |
| Kernel config at `/boot/config-$(uname -r)` | ConfigMap as a folder, variable `KERNEL_CONFIG` | Preflight error. With the file, SystemVerification reports nothing for kernel 6.18.62 |
| inotify limits 8192 and 1048576 | Wrapper, with `G1_GUEST=1` | Not necessary for gate 1. With 128 the init passed and used 34 instances. The wrapper keeps it as a margin |
| No `/lib/modules` mount, snapshotter overlayfs | `LIB_MODULES=0`, `SNAPSHOTTER=overlayfs` | |
| CPU and memory limits | Pod spec | The runtime sizes the VM from them |

Not necessary: `failSwapOn: false` (the test with `FAIL_SWAP_OFF=0` passed, `kata-rs-failswapon-default`), `/dev/fuse`, `/dev/loop-control`, `/dev/net/tun`. No Kata setting, no kernel option and no change to a Kata file was necessary. The `create-kubelet-cgroup-v2.sh` script of kind passes with the `init` cgroup.

## 4. Numbers

Times are in seconds. Memory is in MiB.

| Run | Create to node up | Create to `/readyz` | crictl stop to `/readyz` | poweroff to `/readyz` | Pod delete | New pod to `/readyz` | Pod cgroup after init, and maximum | cloud-hypervisor RSS | Guest `free -m`: used, cache |
|---|---|---|---|---|---|---|---|---|---|
| Rust 1 | 4.8 | 15.2 | 16.1 | 31.8 | 11.3 | 9.7 | 2849, 3003 | 2035 to 2128 | 620, 1275 |
| Rust 2 | 4.8 | 15.3 | 18.8 | 25.5 | 11.2 | 9.6 | 2156, 2514 | 2028 to 2203 | 616, 1275 |
| Rust 3 | 4.7 | 14.3 | 18.0 | 26.6 | 11.5 | 9.7 | 2115, 2436 | 1996 to 2133 | 613, 1275 |
| Rust, systemd default (`kata-dev3`) | 4.7 | 14.2 | 96.7 | 109.2 | 91.1 | 9.7 | 2357, 2450 | 2037 to 2125 | 651, 1275 |
| Go 1 | 4.7 | 15.5 | 17.3 | 28.6 | 12.9 | 9.7 | 0 | 2045 to 2052 | 828, 1272 |
| runc baseline | 2.6 | 11.6 to 12.9 | 26.6 to 28.7 | 109 to 112 | 20 | 6.5 to 8.6 | 880 to 908, 953 | none | not measured |

- virtiofsd has an RSS of 870 to 1370 MiB. It is shared guest memory, and the pod cgroup counts it one time (shmem about 2000 to 2200). A new VM after a new pod has 1400 to 1700 in the pod cgroup.
- `oom_kill` in `memory.events` of the pod cgroup is 0 in all checks.
- Rust runtime: the guest has 7991 MiB and 5 CPUs. Go runtime: 10175 MiB and 5 CPUs. With the Go runtime `memory.current` of the pod cgroup is 0, so the hypervisor is not in the pod cgroup.

## 5. What failed, with the cause

1. A kill does not stop the container. It is so with stock Kata 4.4.0, with the two shims, with and with no `init` cgroup. `ctr -n k8s.io tasks kill -s SIGKILL <id>` (also with `--all`) gives exit code 0, and `/sbin/init` runs on. Tests: `kata-dev2/kill-test-kata-clh-runtime-rs.txt`, `kata-test-stop-timeout-and-no-init/kill-test-no-init-cgroup.txt`, `kata-go-kill-test/`. The cause is in the agent source at tag 4.4.0:
   - `src/agent/src/rpc.rs`, line 531: `let all = eid.is_empty() && sig == libc::SIGKILL;`. Lines 547 to 582 signal the init process only if `all` is false. Lines 583 to 624 freeze the cgroup, call `get_pids`, kill each PID and thaw.
   - `src/agent/rustjail/src/cgroups/systemd/manager.rs`, lines 92 to 94, and `cgroups/fs/mod.rs`, lines 226 to 232: `get_pids` reads the tasks of the container cgroup only, not of its child cgroups.
   - systemd moves each process to a child cgroup. So `cgroup.procs` of the container cgroup is empty, and the agent signals nothing. The stop signal of the image (SIGRTMIN+3) takes the other path and works.
   - Level: a source patch to the Kata agent (read the child cgroups, or signal the init process too). The test agent did not patch.
2. Effect with the systemd default: `crictl stop --timeout 20` ends with DeadlineExceeded. The container stops 91 s later, when systemd stops its wait for the kube-apiserver scope (90 s) and halts. The exit code 130 shows that path. With runc the code is 137 (killed). The kubelet then starts the container again, which is the restart that the main session saw in `kata-dev2`. A pod delete takes 91 s. A node that hangs cannot be killed in place. A hang is not tested.
3. The answer in the lab is a node setting, not a Kata fix. `STOP_TIMEOUT=10` writes `DefaultTimeoutStopSec=10s` for systemd in the node. The node then stops by itself in 11 to 13 s, inside the grace period of 20 s, with the two shims and with runc (`runc-stop-timeout-10`). etcd gets SIGTERM and up to 10 s.
4. An exec process has its own cgroup namespace with its root at the `init` cgroup. Do not start a node service from an exec session.
5. A script fault: `crictl pods --name` matches a pattern, so one runc check printed the sandbox of another pod also. The lookup now uses labels. No other pod was touched.

## 6. Changes for Kata, each with its reason

- Wrapper: the `init` cgroup, the sysctl steps, `/dev/kmsg` and the kernel config copy (part 3). The optional stop timeout (part 5). One log line with the cgroup state at start. The test switch `G1_SKIP`.
- Template: `G1_GUEST=1` with a runtime class, the kernel config volume (tag `#@kernelconfig`), `G1_SKIP`, `G1_STOP_TIMEOUT`. It has no subPath mount.
- kubeadm config: `failSwapOn: false` has a tag, and `FAIL_SWAP_OFF=0` removes the line.
- `run.sh`: variables `KERNEL_CONFIG`, `FAIL_SWAP_OFF`, `STOP_TIMEOUT`, `G1_SKIP`. The check records the boot ID, the VM, the cgroups, `memory.events`, the sandbox processes and `free -m`. The restart step records the exit code and continues after a crictl error.
- The unshare step of the wrapper does not act in the guest, because the container sees "0::/".
- The preflight pulls `pause:3.10.2` in each run. It is one small pull from the guest.

## 7. State, and what is not tested

- Nothing of gate 1 runs. The namespaces `gate1` and `gate1-kata` and their PersistentVolumes do not exist. `/dev/loop19`, `/dev/loop23`, `/dev/loop22` and `/dev/loop26` have no filesystem signature.
- Nothing changed under `/opt/kata` and nothing in `kube-system`. The containerd of the kind node did not restart. `/dev/shm` of the kind node still has 64 MB.
- Not tested: QEMU, a node that hangs, a CNI, the NVKE image, a restart of the kind node or of the Kata shim, and the log of the guest agent (the debug console is a Kata setting).
- To run it, use the example line at the top of `run.sh`. `run.sh down` and `run.sh wipe` remove everything.
