Date 2026-11-25. Kata Containers tag 4.4.0, commit f9cbda4d235b345340bf461e4aaba8c89e841d8d. The note is a source reading, and I ran no test.

# Kata Containers 4.4.0 source facts for the kind lab

## Sources and markers

The note uses the following sources:

- `K` is `/scratch/kata-cp/src/kata-containers`, the Kata Containers clone at tag 4.4.0.
- `KIND` is `/home/dsrinivas/go/src/sigs.k8s.io/kind`, at v0.32.0-alpha-65.
- `K8S` is `/home/dsrinivas/go/src/k8s.io/kubernetes`, with system-validators v1.12.1 in the vendor folder.
- The issue and pull request data is from the public GitHub API.
- The chart version list is from ghcr.io.

The note uses the following markers:

- `[GK]` marks a statement from general knowledge. The source does not state it.
- `[7.0]` marks a statement from the local kernel 7.0 headers in `/usr/src/linux-headers-7.0.0-44`. Kernel 6.18 can differ.
- `[inferred]` marks a conclusion that I drew from the source. The source does not state it.
- "Not found" means that I searched the source and found no match.

I write a line range with "to", e.g., `K/versions.yaml:211 to 214`.

## Limits

I read the kernel fragments and the build scripts. I did not read the built `.config` file. I ran no command on a node or in a guest.

## 1. Guest kernel

### Conclusion

The guest kernel is Linux 6.18.62 with config version 211. Cloud Hypervisor and QEMU boot the same kernel build. Every fragment value is `=y`, so the kernel has no modules. The default kernel has no module support, no `/proc/config.gz`, no AppArmor, no TPM, no dummy device, no squashfs and no dm-thin.

### Facts

- The kernel version is in `K/versions.yaml:211 to 214`. The config version is in `K/tools/packaging/kernel/kata_config_version:1`.
- The build script merges the fragments on an allnoconfig base. The command is `merge_config.sh -r -n` in `K/tools/packaging/kernel/build-kernel.sh:344`. An option that is in no fragment is off, unless another option selects it. The meaning of `-n` is in `scripts/kconfig/merge_config.sh:27` [7.0].
- The release builds the x86_64 `kernel` asset with the flags `-x` and `-m`. The scripts set the flags in `K/tools/packaging/kata-deploy/local-build/kata-deploy-binaries.sh:1398 to 1402` and `K/tools/packaging/static-build/kernel/build.sh:31 to 33`. The flags add `cryptsetup.conf` and the `x86_64/confidential` fragments, in `build-kernel.sh:296 to 312`.
- Both hypervisors use the same kernel file. The Go runtime selects `vmlinux.container` for QEMU in `K/src/runtime/Makefile:469 to 471`, and for Cloud Hypervisor in `K/src/runtime/Makefile:561 to 563`. The Makefile defines the file name in `K/src/runtime/Makefile:966 to 968`. The Rust runtime selects the same kernel type in `K/src/runtime-rs/Makefile:361 to 363` and `K/src/runtime-rs/Makefile:508 to 510`.

The fragment paths in the table are under `K/tools/packaging/kernel/configs/fragments/`.

| Item | State | Evidence |
|---|---|---|
| overlayfs | y | `common/fs.conf:56 to 60` |
| FUSE and virtio-fs | y | `common/fs.conf:63 to 64` |
| user, pid, net, ipc and uts namespaces | y | `common/namespaces.conf:5 to 11` |
| cgroup namespace | no separate option, built with `CGROUPS=y` | `common/cgroup.conf:3`, and `kernel/cgroup/Makefile:2` [7.0] |
| time namespace | absent | not found |
| cpu controller | y | `common/cgroup.conf:7 to 9` |
| cpuset, memory and pids controllers | y | `common/cgroup.conf:12`, `:4`, `:10` |
| io controller | y | `common/cgroup.conf:5`, `common/fs.conf:6` |
| hugetlb controller | y | `common/cgroup.conf:15`, `common/huge.conf:8` |
| misc controller | absent | not found |
| rdma controller | y | `common/mlx5.conf:23` |
| CGROUP_BPF and BPF_SYSCALL | y | `common/cgroup.conf:26 to 27` |
| BPF_JIT | absent, y in the debug kernel only | `debug/ebpf.conf:5` |
| seccomp | y | `common/seccomp.conf:3 to 4` |
| AppArmor | absent | not found |
| SELinux | y | `common/lsm.conf:7 to 9` |
| nf_tables | y | `common/network.conf:87 to 103`, `common/netfilter.conf:237 to 261` |
| legacy iptables and ip6tables | y | `common/netfilter.conf:11 to 13`, `:188`, `:213` |
| NAT | y | `common/netfilter.conf:49`, `:81`, `:196 to 197`, `:229`, `:232` |
| conntrack | y | `common/netfilter.conf:21 to 48` |
| xt matches comment, conntrack, mark, addrtype, statistic, multiport, recent, physdev, limit and set | y | `common/netfilter.conf:96`, `:101`, `:118`, `:92`, `:133`, `:119`, `:129`, `:123`, `:116`, `:70` |
| xt targets MARK, REDIRECT and REJECT | y | `common/netfilter.conf:80`, `:86`, `:194` |
| xt target MASQUERADE | y by selection | `common/netfilter.conf:197`, and `net/ipv4/netfilter/Kconfig:237 to 239` [7.0] |
| veth, bridge, br_netfilter and vxlan | y | `common/network.conf:74`, `:43`, `:81`, `:82` |
| IPVS | y | `common/netfilter.conf:154 to 175` |
| dummy | absent | not found |
| loop, ext4 and xfs | y | `common/fs.conf:9`, `:18`, `:26` |
| device mapper, dm-verity and dm-crypt | y, from the `-m` fragment only | `common/confidential_containers/cryptsetup.conf:1 to 7` |
| dm-thin | absent | not found |
| erofs | y | `common/fs.conf:43 to 46` |
| squashfs | absent | not found |
| inotify and fanotify | y | `common/fs.conf:34 to 35` |
| CONFIG_MODULES | absent in the default kernel | only in `common/signing/module_signing.conf:3` and `gpu/nvidia.x86_64.conf.in:7` |
| IKCONFIG and IKCONFIG_PROC | absent in the default kernel, y in the debug kernel | `debug/debug.conf:5 to 6`, `build-kernel.sh:321 to 327` |
| kernel keyring | y | `common/base.conf:44` |
| TPM | absent | no `TCG_` option in any common or x86_64 fragment |

- The build adds the signing fragment only when `KBUILD_SIGN_PIN` is set, in `build-kernel.sh:314 to 319`. The release workflow sets the pin for NVIDIA assets only, in `K/.github/workflows/build-kata-static-tarball-amd64.yaml:115`.
- The build installs the config next to the kernel as `config-6.18.62-211`, in `build-kernel.sh:631`. On a node, you can run `grep` on `/opt/kata/share/kata-containers/config-6.18.62-211` to settle any doubt.
- The installer extracts the debug kernel on nodes for the clh and qemu shims. The component list is in `K/tools/packaging/kata-deploy/shim-components.json`. I expect the file name `vmlinux-debug.container`, from `build-kernel.sh:600 to 605` and `build-kernel.sh:634 to 635`.
- The release builds the debug kernel without `-x` and `-m`, in `kata-deploy-binaries.sh:1410 to 1417`. The debug kernel has no device mapper.
- Pressure stall information is in the kernel but is off at boot, in `common/mem_agent.conf:3 to 4`.

## 2. kubeadm SystemVerification

### Conclusion

On the default guest kernel, the check fails before it compares any option. The validator finds no kernel config, and `modprobe configs` fails. If you supply a config, the only kernel item that the check reports is `AUFS_FS`. `AUFS_FS` is optional, so the check gives a warning.

### Facts

The validator files are in `K8S/vendor/k8s.io/system-validators/validators/`.

- The validator tries the following paths in order:
  - `/proc/config.gz`
  - `/boot/config-<release>`
  - `/usr/src/linux-<release>/.config`
  - `/usr/src/linux/.config`
  - `/usr/lib/modules/<release>/config`
  - `/usr/lib/ostree-boot/config-<release>`
  - `/usr/lib/kernel/config-<release>`
  - `/usr/src/linux-headers-<release>/.config`
  - `/lib/modules/<release>/build/.config`
- The path list is in `kernel_validator.go:192 to 202`.
- If no path exists, the validator runs `modprobe configs` once and tries the paths again, in `kernel_validator.go:236 to 243`.
- When `modprobe` fails, the validator returns `unable to load kernel module`, in `kernel_validator.go:238 to 239`.
- When `modprobe` succeeds and no path exists, the validator returns `no config path in [...] is available`, in `kernel_validator.go:245`.
- Both cases are errors, not warnings. The code is in `kernel_validator.go:73 to 78` and `kernel_validator.go:98 to 101`. kubeadm returns the errors as preflight errors, in `K8S/cmd/kubeadm/app/preflight/checks.go:591 to 606`.
- kind skips the whole preflight phase, in `KIND/pkg/cluster/internal/create/actions/kubeadminit/init.go:84 to 86`.
- The required list is in `types_unix.go:38 to 52`. The cgroup v2 list is in `types_unix.go:61 to 66`. The optional list is in `types_unix.go:67 to 74`. All required items are `y` in section 1.
- The optional items `OVERLAY_FS`, `BLK_DEV_DM`, `CFS_BANDWIDTH`, `SECCOMP` and `SECCOMP_FILTER` are present. The optional item `AUFS_FS` is absent. With the debug kernel, `BLK_DEV_DM` is also absent.
- The validator never reads the lists `OptionalCgroupsV1` and `OptionalCgroupsV2`. The lists are in `types_unix.go:75 to 80`. The loop that reads the other lists is in `kernel_validator.go:159 to 181`.
- The version pattern accepts 6.18.62, in `types_unix.go:34`.
- The cgroup validator reads `/sys/fs/cgroup/cgroup.controllers`. The cgroup validator tests the freezer when it creates a directory, in `cgroup_validator_linux.go:203 to 249`.
- The required controllers are cpu, cpuset, devices, freezer, memory and pids. The optional controllers are hugetlb and io. The lists are in `types_unix.go:92 to 97`. The kernel has all of them. I did not check that the agent gives them to the container cgroup.

## 3. kind entrypoint steps in a Kata guest

### Conclusion

I expect none of the listed steps to fail, if the guest runs cgroup v2 and the container root filesystem is writable. The entrypoint selects the fuse-overlayfs snapshotter on a virtio-fs root filesystem, and `/dev/fuse` does not exist in the container. The `boot_id` bind mount is not in the kind checkout that I read (not found).

### Facts

The entrypoint is `KIND/images/base/files/usr/local/bin/entrypoint`.

- The agent mounts `/proc` and `/sys` as new instances and gives them no special handling, in `K/src/agent/rustjail/src/mount.rs:302 to 314` and `mount.rs:836 to 900`. The step `mount -o remount,ro /sys` in `entrypoint:182` and the step `mount --make-rshared /` in `entrypoint:192` behave as in any privileged container.
- The agent rejects a bind mount inside `/proc` only when the mount is in the OCI spec, in `mount.rs:354 to 401`. A `mount --bind` that the entrypoint runs is not affected.
- Neither runtime adds a kernel parameter for the cgroup version for clh or qemu. Only the NVIDIA and OpenVMM configs add one, in `K/src/runtime/Makefile:499` and `K/src/runtime-rs/Makefile:674`.
- The default guest image boots systemd, because the build sets `AGENT_INIT="no"` in `kata-deploy-binaries.sh:1006`. The guest runs cgroup v2 [GK for systemd in Ubuntu 26.04]. The entrypoint then returns early, in `entrypoint:253 to 271`.
- On cgroup v2, the agent always unshares a cgroup namespace, in `K/src/agent/rustjail/src/container.rs:566 to 568`. The agent mounts `cgroup2` at `/sys/fs/cgroup`, in `mount.rs:403 to 436`.
- The Go runtime removes the cgroup namespace entry from the spec, in `K/src/runtime/virtcontainers/kata_agent.go:1119 to 1130`. The Rust runtime removes the pid, network and time entries and clears the path of the other entries, in `K/src/runtime-rs/crates/runtimes/virt_container/src/container_manager/container.rs:856 to 875`.
- With zero rules in both iptables back ends, the entrypoint selects legacy, in `entrypoint:418 to 427`. The kernel has the legacy tables. I expect the step `iptables-save | iptables-restore` in `entrypoint:459 to 470` to pass.
- The step `systemd-machine-id-setup` in `entrypoint:382 to 383` needs only a writable `/etc`.
- The entrypoint guards the product_name and product_uuid mounts with `-f` tests, in `entrypoint:389`, `entrypoint:405` and `entrypoint:409`. `CONFIG_DMIID` is in no fragment. I expect that `/sys/class/dmi/id` is missing and that the entrypoint skips the mounts [inferred]. The option is in `drivers/firmware/Kconfig:70 to 73` [7.0].
- On virtio-fs, `stat -f -c %T /kind` returns `fuseblk` [GK]. The entrypoint then sets `fuse-overlayfs` and enables its service, in `entrypoint:119 to 125` and `entrypoint:140 to 146`.
- No code creates `/dev/fuse` or `/dev/kmsg` in the container. A search of `K/src/agent` finds nothing. The only match for `kmsg` is `K/src/runtime-rs/crates/shim/src/panic_hook.rs:11`.
- After the entrypoint, `KIND/images/base/files/kind/bin/create-kubelet-cgroup-v2.sh:26 to 31` exits with 1 if the root `cgroup.procs` is not empty.

## 4. kata-deploy on a plain containerd node

### Conclusion

The chart default is job mode, not a DaemonSet. On a kind node, the installer appends an `imports` entry to `/etc/containerd/config.toml` and writes a drop-in file under `/opt/kata`. The installer restarts containerd through the private D-Bus socket of systemd. The installer uses no host PID and no nsenter. The Kata tree does not mention kind (not found).

### Facts

Chart paths are under `K/tools/packaging/kata-deploy/helm-chart/kata-deploy/`. Installer paths are under `K/tools/packaging/kata-deploy/binary/src/`.

### Deployment mode and pods

- The chart default is `deploymentMode: job`, in `values.yaml:51`. The chart enables all shims by default, in `values.yaml:743 to 825`. The default shim is `qemu-runtime-rs`, in `values.yaml:827 to 831`.
- A Job for one node has the init containers `load-kernel-modules`, `host-check` and `artifacts`, and the main container `cri`. The list is in `templates/_helpers.tpl:1418 to 1426`. The container `load-kernel-modules` is privileged and mounts the host `/` at `/host`.
- The Job pods mount no ServiceAccount token, in `templates/_helpers.tpl:1355`.
- No template has `hostPID`, `hostNetwork` or `nsenter` (not found).
- The stage containers run with a read-only root filesystem, in `templates/_helpers.tpl:1767 to 1769`. The binary stops if the user is not root, in `main.rs:231 to 234`.
- The pods mount the following host paths, in `templates/_helpers.tpl:1871 to 1921`:
  - `/etc/containerd` and `/etc/crio`
  - the install directory `/opt/kata`
  - `/etc/systemd/system`
  - `/run/systemd/private`, with type Socket
  - `/boot`
  - `/etc/machine-id`, with type File
  - `/run/lock`
  - `/usr/bin`, `/usr/sbin`, `/usr/local/bin`, `/usr/local/sbin`, `/bin` and `/sbin`
- Job mode adds the host paths `/etc/modules-load.d`, `/etc/udev/rules.d` and `/`, in `templates/_helpers.tpl:1443 to 1459`.
- The dispatcher is an unprivileged API client, in `templates/kata-deploy-install-job.yaml:75 to 99`.
- The dispatcher needs the machine ID, the runtime version and `status.runtimeHandlers` of the node, in `templates/_helpers.tpl:1002 to 1003` and `templates/_helpers.tpl:1017`.

### Files on the node

- The Go shim is `/opt/kata/bin/containerd-shim-kata-v2`. The Rust shim is `/opt/kata/runtime-rs/bin/containerd-shim-kata-v2`. The paths are in `utils/system.rs:147 to 153`.
- The configs are in `/opt/kata/share/defaults/kata-containers/runtimes/<shim>/` for a Go shim, and in `/opt/kata/share/defaults/kata-containers/runtime-rs/runtimes/<shim>/` for a Rust shim. Each folder has `configuration-<shim>.toml` and a `config.d` folder. The code is in `utils/system.rs:128 to 144` and `artifacts/install.rs:1326 to 1376`.
- The installer also writes `/opt/kata/VERSION` and `/opt/kata/versions.yaml`.
- The installer writes `/etc/modules-load.d/kata-containers-default.conf`, in `main.rs:787 to 799`.
- The installer takes the lock `/run/lock/kata-deploy.lock`, in `main.rs:491`.

### containerd configuration

- The installer uses drop-in mode when containerd is 2.0 or newer, in `runtime/manager.rs:310 to 324`.
- The installer uses `/etc/containerd/conf.d/` only when containerd is 2.2 or newer and `config.toml` already imports the folder, in `config.rs:994 to 1013`. The kind config has no `imports` key, in `KIND/images/base/files/etc/containerd/config.toml:1 to 42`.
- On kind, the installer appends `/opt/kata/containerd/config.d/kata-deploy.toml` to `.imports` in `/etc/containerd/config.toml`. The code is in `config.rs:368 to 369` and `runtime/containerd.rs:701 to 708`.
- The installer takes the plugin ID from the `version` key of the main file, in `runtime/containerd.rs:188 to 202`. Version 3 or higher gives `io.containerd.cri.v1.runtime`. Version 2 gives `io.containerd.grpc.v1.cri`. No version gives `cri`. The kind file has `version = 2`, so the installer selects `io.containerd.grpc.v1.cri`.
- Each handler gets `runtime_type`, `runtime_path`, `privileged_without_host_devices = true` and `ConfigPath`, in `runtime/containerd.rs:349 to 391`. The handler names are `kata-<shim>`.
- The installer writes no `version` key in the drop-in file (not found). The installer writes a `version` key only when the main config is missing, in `runtime/containerd.rs:958 to 968`.
- I did not check how containerd 2.x merges an import without a version into a version 2 file [GK].

### Restart of containerd

- The installer calls the D-Bus methods `Reload` and `RestartUnit` on `containerd.service` through `/run/systemd/private`. The code is in `utils/systemd.rs:11`, `utils/systemd.rs:82 to 93` and `runtime/lifecycle.rs:249 to 253`.
- In job mode, the installer then waits for the unit to be active, in `runtime/lifecycle.rs:258 to 264`. The dispatcher checks `status.runtimeHandlers` before it labels the node.

### Things that can break on a kind node

- **containerd version.** The kind checkout builds containerd v2.2.1, in `KIND/images/base/Dockerfile:127`. Kata 4.4.0 states a minimum of v2.3, in `K/versions.yaml:345` and `K/docs/releases/4.4.0.md:115 to 117`. Pull request 14183 changes one line and gives the end of life of containerd 2.2 as the reason. I found no version check in the installer.
- **Kernel modules.** The installer requires `vhost` and `vhost_net`. The installer requires `vhost_vsock` when a qemu shim is enabled. The code is in `main.rs:687 to 710` and `main.rs:750 to 755`.
- **Module loading.** The installer runs the `modprobe` of the node in a chroot, in `main.rs:887 to 907`. The kind image has kmod, in `KIND/images/base/Dockerfile:77`. kind mounts `/lib/modules` as read-only, in `KIND/pkg/cluster/internal/providers/docker/provision.go:237 to 238`. The modules load into the kernel of the real host.
- **Device nodes.** `/dev/kvm` must exist in the node container, in `main.rs:761 to 785`. Docker fixes the device nodes of a privileged container when it creates the container [GK]. A node that appears later on the host, e.g., `/dev/vhost-vsock` or `/dev/vhost-net`, is not in the kind node [GK].
- **Size of `/dev/shm`.** kind passes no `--shm-size`, in `provision.go:214 to 262`, so `/dev/shm` is 64 MB [GK]. QEMU with virtio-fs puts the guest memory in a file in `/dev/shm`. The Go code is in `K/src/runtime/virtcontainers/qemu.go:141`, `qemu.go:1062 to 1072` and `qemu.go:1196 to 1197`. The Rust code is in `K/src/runtime-rs/crates/hypervisor/src/qemu/qmp.rs:546 to 551`. Cloud Hypervisor sets shared memory without a path, in `K/src/runtime/virtcontainers/clh.go:618 to 626`.
- **Taints.** The dispatcher skips a node whose taints the install does not tolerate, in `K/docs/helm-configuration.md:1118`. In a kind cluster with more than one node, the dispatcher skips the control plane node.
- **Helm timeout.** The default Helm timeout of 5 minutes limits the hook and includes the image pulls, in `values.yaml:119 to 125`.
- **Shims and the restart.** The kind unit has `KillMode=process`, in `KIND/images/base/files/etc/systemd/system/containerd.service:16`. The shims stay alive when containerd restarts.

### Mention of kind

- The docs, tests and workflows do not mention kind (not found).
- The kata-deploy tests run on k0s, k3s, rke2, microk8s and kubeadm, in `K/.github/workflows/run-kata-deploy-tests.yaml:37 to 43`.
- The minikube guide uses the kvm2 driver, in `K/docs/install/minikube-installation-guide.md:17`.

## 5. Install the previous release, then upgrade

### Conclusion

The release before 4.4.0 is 4.3.1. Both releases use job mode by default, so Helm accepts a plain `helm upgrade`. Upstream has no test that installs the previous chart and upgrades to the current chart (not found).

### Facts

- The chart versions on ghcr.io are 3.17.0 to 3.32.0, then 4.0.0, 4.1.0, 4.2.0, 4.3.0, 4.3.1 and 4.4.0. The 3.x list also has 3.19.1 and two tags that start with `3.31.0-testing`. The registry has 26 tags and I printed 25, so I did not confirm the oldest tag.
- The install command is `helm install kata-deploy oci://ghcr.io/kata-containers/kata-deploy-charts/kata-deploy --version 4.3.1`. The docs give the command form in `K/docs/installation.md:131 to 137`.
- The upgrade command is `helm upgrade kata-deploy oci://ghcr.io/kata-containers/kata-deploy-charts/kata-deploy --version 4.4.0`.
- You cannot change `deploymentMode` during the life of a release. The chart refuses the change, in `K/docs/helm-configuration.md:559 to 563` and `K/docs/helm-configuration.md:1748 to 1753`.
- The chart made job mode the default in 4.3.0, in `K/docs/releases/4.3.0.md:120 to 130`.
- You cannot change `env.multiInstallSuffix` during the life of a release, in `K/docs/helm-configuration.md:1717 to 1721`.
- The upgrade notes of 4.4.0 are in `K/docs/releases/4.4.0.md:354 to 374`. The first step is containerd 2.3 or later. The guest images move to EROFS, so `rootfs_type` in a custom config must match the image, in `K/docs/releases/4.4.0.md:62 to 78`.
- Release 4.3.0 had a containerd minimum of 2.2, in `K/docs/releases/4.3.0.md:554`.
- On upgrade, job mode runs the cleanup on nodes that left the selection, in `K/docs/helm-configuration.md:967 to 970`.
- A chart upgrade can skip a node that is already installed, in `K/tests/functional/kata-deploy/kata-deploy-cri-replay.bats:59`.
- `K/docs/Upgrading.md` covers only the move from 1.x to 2.x.

### Checks in the lifecycle test

The test file is `K/tests/functional/kata-deploy/kata-deploy-lifecycle.bats`. The test deploys with `deploymentMode=daemonset`, in `kata-deploy-lifecycle.bats:50`.

- After the install, the test checks the following items, in `kata-deploy-lifecycle.bats:54 to 92`:
  - `/opt/kata` exists.
  - A shim binary exists.
  - `VERSION` and `versions.yaml` are not empty.
  - A kata RuntimeClass exists.
  - The node label `katacontainers.io/kata-runtime` is `true`.
- The test runs `kubectl rollout restart daemonset/kata-deploy` and checks that a Kata pod keeps its UID, its phase and its restart count, in `kata-deploy-lifecycle.bats:94 to 160`. The file names the check as the regression test for issue 12761, in `kata-deploy-lifecycle.bats:15`.
- After the uninstall, the test checks the following items, in `kata-deploy-lifecycle.bats:162 to 205`:
  - No kata RuntimeClass exists.
  - The node label is gone.
  - `/opt/kata` is empty.
  - The node reports a runtime version.

## 6. Three upstream items

### Conclusion

Issue 8024 is open and has no fix. Pull request 13162 is not merged and covers QEMU only. Issue 8237 is open. Release 4.4.0 has the kernel options that issue 8237 asks for, but the device and filesystem gaps remain. Issue 12761 is closed, and release 4.4.0 has the fix.

### Issue 8024 and pull request 13162

- Issue 8024 has the title "How to handle socket and hostPath in kata-containers?". The issue is open, has the label `question` and has no comments.
- The reporter mounts a SPIRE agent socket through the spiffe-csi driver and gets `connection refused`.
- The issue does not state the cause. A socket file that virtio-fs shares has no listener in the guest kernel [GK].
- Pull request 13162 has the title "Expose unix sockets to guest workloads (as vsock)". The pull request is open and not merged. The last update was on 2026-06-26.
- The pull request adds the option `vsock_uds_forward = ["port:/path"]`. The shim connects to a vsock port in the guest and joins the connection to the host socket. The workload must listen on vsock. The option supports one pair only.
- The pull request does not cover Cloud Hypervisor. The evidence is as follows:
  - The pull request adds the option only to the `configuration-qemu*.toml.in` files.
  - The code reads the guest CID from an agent URL that starts with `vsock://`, and rejects a URL that starts with `hvsock://`.
  - The test skips every hypervisor whose name does not start with `qemu`.
- The option does not exist at tag 4.4.0 (not found).

### Issue 8237

- Issue 8237 has the title "K3s and podman in Kata Container". The issue is open, has the labels `feature` and `needs-review`, and has 8 comments.
- Release 4.4.0 has all kernel options that the issue asks for. The options are in `common/netfilter.conf:123`, `common/network.conf:81 to 82`, `common/base.conf:44` and `common/fs.conf:38 to 39`.
- `/dev/kmsg` is missing in the container, and the kubelet does not start without it. The workaround in the issue is `mknod /dev/kmsg c 1 11`.
- One comment says that kind also needs `mknod /dev/fuse c 10 229`.
- One comment uses `--ignore-preflight-errors=SystemVerification`.
- overlayfs needs xattr support on its upper directory. The comments use tmpfs, virtiofsd with `--xattr`, or direct volumes.
- The default virtiofsd arguments have no xattr flag, in `K/src/runtime/Makefile:287` and `K/src/runtime-rs/Makefile:253`.
- One comment says that Kata does not support the setup.
- The issue applies to every hypervisor, and to Cloud Hypervisor too, because the gaps are in the guest kernel and in the agent.

### Issue 12761

- Issue 12761 has the title "[3.28] cleanup operation order change causes all kata pods to crash on containerd restart". The issue is closed as completed since 2026-04-01.
- The cause is in release 3.28. The kata-deploy pod removed `/opt/kata` when it stopped, and then restarted containerd. containerd did not find the shim path and removed the shims as leaked shims. Every Kata pod on the node crashed.
- The comments say that the fix is merged and is in 3.29.0. The CI image tag in the comments points to pull request 12766.
- In 4.4.0, the cleanup does nothing while the DaemonSet still selects the node, in `K/tools/packaging/kata-deploy/binary/src/main.rs:2286 to 2300`.
- The issue does not depend on the hypervisor. A containerd restart alone does not stop Kata pods.

## Most likely first failures in this lab, and what to check

1. **The inner containerd has no working snapshotter.** The entrypoint selects fuse-overlayfs, and `/dev/fuse` is missing. Plain overlayfs on virtio-fs has no xattr support. Check `stat -f -c %T /kind`, `ls -l /dev/fuse` and the snapshotter line in the inner `config.toml`. Put `/var/lib/containerd` on a memory emptyDir or on a block volume.
2. **The kubelet does not start because `/dev/kmsg` is missing.** Check `ls -l /dev/kmsg` in the Kata container. Create the device with `mknod` before systemd starts.
3. **kubeadm preflight fails at SystemVerification.** Check `ls /proc/config.gz` and `uname -r`. Skip the preflight phase as kind does, or ignore the check, or boot the debug kernel.
4. **Device nodes are missing in the kind node.** Check `ls -l /dev/kvm /dev/vhost-net /dev/vhost-vsock /dev/net/tun` in the node. Load the modules on the host before you create the cluster.
5. **The QEMU fallback crashes on guest memory.** Check `df -h /dev/shm` in the kind node. Make `/dev/shm` larger, or stay on Cloud Hypervisor.
6. **containerd does not serve the Kata handlers after the install.** Check `kubectl get node -o jsonpath='{.items[0].status.runtimeHandlers}'`. Check `containerd --version` and `containerd config dump` in the node.
7. **The guest is too small for a control plane.** The defaults are 1 vCPU and 2048 MiB, in `K/src/runtime/config/configuration-clh.toml.in:79` and `K/src/runtime/Makefile:221`. Check `nproc` and `free -m` in the guest. Set CPU and memory limits on the pod.
8. **`helm install` reaches the timeout or selects no node.** Check the log of the dispatcher Job. Check `kubectl get nodes -l kata-deploy-job-dispatcher/result=failed`. Raise `--timeout`.
9. **The cgroup setup of the kubelet fails.** Check `cat /sys/fs/cgroup/cgroup.controllers` and `cat /sys/fs/cgroup/cgroup.procs` in the Kata container.
10. **Host Unix sockets do not work in Kata pods.** A hostPath socket or a CSI socket, e.g., a SPIRE agent socket, refuses connections. Cloud Hypervisor has no fix.
11. **A command that calls `modprobe` or needs a dummy interface fails in the guest.** Check `grep -E 'CONFIG_MODULES|CONFIG_DUMMY' /opt/kata/share/kata-containers/config-6.18.62-211` on the node.
