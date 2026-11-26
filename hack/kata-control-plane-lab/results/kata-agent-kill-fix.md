# Kata agent fix for kill and exec with systemd as PID 1 (Kata 4.4.0)

Status: two commits, two patch files and two guest images are ready. Nothing ran in the kind cluster. No runtime test of the fixes in a Kata pod exists yet.

## Confirmed causes (tag 4.4.0)

1. Kill. The lab analysis is correct, with one addition.
   * `src/agent/src/rpc.rs:531` sets `all = eid.is_empty() && sig == SIGKILL`. Lines 547 to 582 signal the init process only if `all` is false. Lines 583 to 624 freeze, call `get_pids` (602, helper at 638 to 644), kill each PID and thaw.
   * `rustjail/src/cgroups/fs/mod.rs:226 to 232` returns `MemController::tasks()`. In the pinned cgroups-rs (rev 4eb91bc, `src/fs/mod.rs:429 to 452`) this reads `cgroup.threads` (v2) or `tasks` (v1) of one directory. `systemd/manager.rs:92 to 94` calls the same function.
   * Addition: a SIGKILL without `--all` takes the same path. Both shims send an empty exec ID for the container process (`containerd-shim-v2/service.go:847 to 849`, `kata_agent.go:2211 to 2214`, runtime-rs `container_inner.rs:319 to 323`).
   * History: PR #13163 (merged 2026-07-14) made this a regression. Before it, the agent signalled the init process first, then the cgroup.
2. Exec. Correct. `fs/mod.rs:88 to 101, 1039 to 1044, 1202 to 1211` and `systemd/manager.rs:44 to 48` use a child cgroup only if its name is `init`. In all other cases the agent attaches to the container cgroup, and the kernel refuses with EBUSY.

## Upstream (kata-containers/kata-containers, 10 requests, main at 0f2fbc43 of 2026-11-25)

* main has no fix. The agent cgroup code and `rpc.rs` are the same as 4.4.0.
* Kill: issue #14062 is open and describes this defect. PR #14130 is open with no review: recursive `get_pids` plus a new `destroy`. I did not backport it: it has no test, it does not signal init, and by my reading its `destroy` does nothing with cgroup v1 (it joins a mount point with a path that is already absolute). Issue #6077 (use `cgroup.kill`) is open since 2023.
* Exec: PR #13627 is open, with one approval (fidencio) and review comments. It attaches an exec process to the cgroup of the init process, as runc does.

## Design

* Kill, part 1: `get_pids` walks the container cgroup and all descendant cgroups and reads `cgroup.procs`. This file exists in v1 and v2, so one code path serves both, for the cgroupfs and the systemd manager. It is the only way to reach the processes of a container that shares the PID namespace of the sandbox. `LinuxContainer::destroy` uses the same list. PID 0 is never returned.
* Kill, part 2: the agent always adds the init process to the PIDs, unless the process is already reaped. With a private PID namespace the kernel then kills the rest, whatever the cgroup. No PID gets the signal two times.
* `cgroup.kill` is not used. It works only with v2 and kernel 5.14, v1 needs the walk anyway, and the freeze already stops forks. It stays a separate change (#6077).
* Exec: a backport of PR #13627 (commits 1 and 2), as a second commit. One change: the systemd manager passes `/init.scope`, not `init.scope`. systemd 259 in the guest has the check "Control group path is not absolute". Without this change the pull request cannot work with the systemd manager, which the lab uses.

## Commits and patches (branch `lab/agent-kill-child-cgroups` in `/scratch/kata-cp/src/kata-containers-fix`, not pushed)

* `e0f5597` agent: kill the init process and child cgroups of a container (2 files, +161 and 6 removed, 2 new unit tests)
* `96a8d90` agent: attach exec to the init process cgroup (author Martin Bidlingmaier, backport note and both sign-offs in the message)
* `~/notes/hosted/lab/patches/0001-agent-kill-the-init-process-and-child-cgroups-of-a-c.patch` and `0002-agent-attach-exec-to-the-init-process-cgroup.patch`
* The commits are not GPG signed. `commit.gpgsign` is true, and I used `--no-gpg-sign` so that no key of the user was used.

## Build and unit tests

* Builder image `kata-fix/agent-builder:4.4.0`: the Kata agent Dockerfile (Ubuntu 22.04, rustc 1.97.1, libseccomp 2.6.1) plus git. Command: `/scratch/kata-cp/images/kata-fix/builder/run.sh make` (8 CPUs, 8 GB, 8 jobs). gperf came from ftp.gnu.org, because the mirror in `versions.yaml` refused the connection.
* The release agent is a GNU libc build with `USE_DEVMAPPER=yes`, not musl. My build of unchanged 4.4.0 with these settings, after `strip`, has the same size as the stock agent (31082984 bytes) and the same `.text` size. So the build matches the release build.
* rustjail: 71 tests pass (68 before). kata-agent: 403 pass, 3 fail. The same 3 fail with unchanged 4.4.0 in this container (`netlink::tests::list_routes`, `rpc::tests::test_get_oom_event_no_deadlock`, `tests::test_create_logger_task`). `cargo fmt` and clippy for rustjail are clean. Logs: `/scratch/kata-cp/images/kata-fix/logs/`.

## Images (`/scratch/kata-cp/images/kata-fix/image/`, checksums in `SHA256SUMS`)

* `kata-ubuntu-resolute-killfix-execfix.image` (both commits) and `kata-ubuntu-resolute-killfix.image` (kill fix only, as a fallback).
* Method (`repack.sh`): copy the stock image, extract the erofs partition with `fsck.erofs`, replace `usr/bin/kata-agent`, run the `mkfs.erofs` command of `image_builder.sh` in Fedora 44 (erofs-utils 1.9.4), write the result at the same offset, and write a new dm-verity hash partition. No mount, no loop device, no privilege. This is less risky than osbuilder, which builds a new root filesystem from the network.
* Checks in the script: the same procedure gives the stock root hash and hash partition. Only `usr/bin/kata-agent` differs in content, size, owner, mode and time. The partition tables and the DAX header are the same bytes.
* The stock clh configurations use `image`, `rootfs_type = "erofs"` and no `kernel_verity_params`. So only the image path changes. New root hashes are in `root_hash_*.txt` if verity is ever used.
* Boot test on this host with the stock kernel and Cloud Hypervisor (`boottest/boot.sh`): stock and both patched images mount the root, start the agent and reach `kata-containers.target`. The patched agents report commit `4.4.0-96a8d90…` and `4.4.0-e0f5597…`.

## Install and test plan (scripts in `/scratch/kata-cp/images/kata-fix/plan/`, not run)

1. `01-install.sh`: copies the images to `/opt/kata-fix` in the node, makes two configuration files (stock files with another `image` line), adds the handlers `kata-clh-runtime-rs-fix` and `kata-clh-fix` through one more entry in `imports` of `/etc/containerd/config.toml`, restarts containerd one time, and makes the two RuntimeClasses. `/opt/kata` and the stock classes do not change. Only containerd restarts. I checked the sed edits and the merged containerd configuration offline with containerd 2.3.4 of the node image.
2. `02-test.sh <runtime class>`, one run for stock and one for `-fix`. Test 1: lab script 12 with no `init` cgroup (stock: EBUSY, patched: exec works). Test 2: pod delete with a grace period of 5 s (stock: about 90 s, patched: 5 to 10 s). Test 3: `ctr tasks kill -s SIGKILL` (stock: runs on, patched: `CONTAINER_EXITED exitCode=137` in 1 to 2 s).
3. If exec fails with the patched class: `docker exec kata-cp-control-plane ln -sfn kata-ubuntu-resolute-killfix.image /opt/kata-fix/kata-containers-fix.img`. New pods then use the image with the kill fix only. Keep the `init` cgroup step in that case.
4. Then gate 1: `RUNTIME_CLASS=kata-clh-runtime-rs-fix G1_SKIP=init-cgroup … run.sh full`. `03-rollback.sh` removes everything.
5. Chart way: `customRuntimes.enabled: true` with `baseConfig: clh-runtime-rs` and a `dropIn` that sets `[hypervisor.clh] image`. I do not recommend it here. `helm upgrade` runs the kata-deploy job again, which installs `/opt/kata` again and restarts containerd, and the image still needs a manual copy.

## Draft upstream texts

Issue: #14062 exists, so post this as a comment there. "We see the same with systemd as PID 1 (a Kubernetes node image) on 4.4.0, Cloud Hypervisor, both shims. `ctr tasks kill -s SIGKILL`, `crictl stop` and pod delete do not stop the container. Cause: since #13163 the SIGKILL path (`rpc.rs`, `all` branch) signals only the PIDs from `get_pids()`, and `get_pids()` (`rustjail/src/cgroups/fs/mod.rs`) reads one cgroup. With cgroup v2 all processes are in child cgroups, so the list is empty. Before #13163 the init process got the signal directly, so this is a regression. A fix with tests follows."

Pull request: "agent: kill the init process and child cgroups of a container. Fixes #14062. Problem: a SIGKILL for a container whose processes are all in child cgroups signals nothing and returns success. Cause: see the issue. Fix: `get_pids()` returns the processes of the cgroup and of all descendants from `cgroup.procs` (v1 and v2, both managers). The agent adds the init process to the list unless it is reaped, so a container with a private PID namespace always dies. Tests: `test_collect_pids`, `test_with_init_pid`. Relation: #14130 has the same walk but no init signal and no test. `cgroup.kill` (#6077) can follow." Also tell the author of #13627 about the absolute subcgroup path.

## Not verified

* No kill or exec test in a Kata pod. The plan above is the first runtime test of both fixes.
* The paths for cgroup v1 and for a shared PID namespace are checked by reading only. The root-only unit tests (the two live cgroup tests of the exec backport included) skip in the container.
* The text of PR #13627 describes "try first, then fall back". Its commits look up the init cgroup first. I backported the commits as they are today.
* Leftovers to remove when done: Docker images `kata-fix/agent-builder:4.4.0` (5.4 GB), `kata-fix/imgtools:fedora44`, `ubuntu:22.04`, `fedora:44`. Clone `/scratch/kata-cp/src/kata-containers-main` (49 MB). Worktree build output (8.7 GB).
