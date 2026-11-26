Date 2026-11-25. Kata Containers tag 4.4.0, commit f9cbda4d235b345340bf461e4aaba8c89e841d8d. This note is a source reading, and I ran no test.

# Kata Containers 4.4.0 source facts for the kind and Cloud Hypervisor lab

## How to read this note

All paths are relative to the root of the Kata Containers repository at tag 4.4.0. I read a local clone at `/scratch/kata-cp/src/kata-containers`. A reference such as `clh.go:618 to 636` means lines 618 to 636 of that file.

The lab is a kind node that runs Kata 4.4.0 from the kata-deploy Helm chart. The pods use the shims `clh-runtime-rs` and `clh` first, and the QEMU shims `qemu-runtime-rs` and `qemu` as the fallback. In this note, CH means Cloud Hypervisor.

I use short names for these files:

* `clh.go`, `qemu.go`, `sandbox.go`, `container.go` and `kata_agent.go` are in `src/runtime/virtcontainers/`.
* `configuration-clh.toml.in` and `configuration-qemu.toml.in` are in `src/runtime/config/`.
* `configuration-clh-runtime-rs.toml.in` and `configuration-qemu-runtime-rs.toml.in` are in `src/runtime-rs/config/`.

The note uses these labels:

* `[GK]` marks a statement from general knowledge. The 4.4.0 source does not contain it.
* `[inferred]` marks my deduction from the lines that I cite. The source does not state it.
* `[lab]` marks a result that the coordinator reported from the lab. I did not test it.

A statement with no label comes from the 4.4.0 source at the cited lines.

## 1. Guest memory and virtio-fs

### Conclusion

The two CH shims do not use `/dev/shm`. Both shims ask CH for anonymous guest memory with `shared=on`, and the 4.4.0 documents call it memfd-based memory. The two QEMU shims put all guest memory in a file on `/dev/shm` when `shared_fs` is virtio-fs, which is the default. With a `/dev/shm` of 64 MB, the QEMU fallback fails to start or dies with SIGBUS.

### Facts

The Go shim `clh` sets the guest memory in `clh.go:618 to 636`:

* It sets `shared=false` only when `shared_fs` is `none` and hugepages are off. In all other cases it sets `shared=true` (`clh.go:624 to 628`).
* It copies `enable_hugepages` to the CH hugepages flag (`clh.go:630`). The default is false (`configuration-clh.toml.in:203`).
* It sets the hot-plug size to `DefaultMaxMemorySize` (`clh.go:631 to 635`).
* It uses a memory file only for VM templating (`clh.go:574 to 617`). It rejects VM templating together with virtio-fs (`clh.go:577 to 579`).

The Rust shim `clh-runtime-rs` sets the guest memory in `src/runtime-rs/crates/hypervisor/ch-config/src/convert.rs:182 to 231`:

* It always sets `shared: true` (`src/runtime-rs/crates/hypervisor/ch-config/src/convert.rs:220`).
* It sets `hotplug_size` to the host RAM from `sysinfo` minus `default_memory` (`src/runtime-rs/crates/hypervisor/ch-config/src/convert.rs:190 to 214`).
* It never sets hugepages. Only Dragonball reads `enable_hugepages` (`src/runtime-rs/crates/hypervisor/src/dragonball/inner.rs:280`).

The source says these things about memfd:

* The strings `/dev/shm` and `memfd` do not appear in `clh.go` or in `src/runtime-rs/crates/hypervisor/src/ch/`.
* `docs/how-to/how-to-use-virtio-fs-with-kata.md:16` says that Cloud Hypervisor uses memfd-based shared memory. It also says that the size of `/dev/shm` does not limit that memory.

The Go shim `qemu` uses `/dev/shm` in this way:

* The constant `fallbackFileBackedMemDir` has the value `/dev/shm` (`qemu.go:141`).
* The shim calls `setupFileBackedMem` when `shared_fs` is virtio-fs or virtio-fs-nydus and VM templating is off (`qemu.go:1195 to 1204`, `qemu.go:1062 to 1072`).
* QEMU then gets the argument `memory-backend-file,...,mem-path=/dev/shm,share=on` (`src/runtime/pkg/govmm/qemu/qemu.go:3364 to 3382`).
* Hot-plugged memory uses the same path (`qemu.go:1520 to 1549`, `qemu.go:2916 to 2921`).
* With `enable_hugepages=true` the path is `/dev/hugepages` (`src/runtime/pkg/govmm/qemu/qemu.go:3366 to 3368`).
* With `shared_fs=none` the shim uses `memory-backend-ram` (`src/runtime/pkg/govmm/qemu/qemu.go:3372 to 3375`).

The Rust shim `qemu-runtime-rs` uses `/dev/shm` in this way:

* The shim uses a RAM backend only when `shared_fs` is not set or is `none` (`src/runtime-rs/crates/hypervisor/src/qemu/cmdline_generator.rs:3046 to 3050`).
* In all other cases `add_virtiofs_share` uses the fixed path `/dev/shm` with `share=on` (`src/runtime-rs/crates/hypervisor/src/qemu/cmdline_generator.rs:3267 to 3301`).
* The driver calls `add_virtiofs_share` for every virtio-fs device (`src/runtime-rs/crates/hypervisor/src/qemu/inner.rs:153 to 169`).
* The directory `src/runtime-rs/crates/hypervisor/src/qemu/` does not contain the string `hugepage`. The shim has no hugepage memory path.
* With the file backend the shim sets the maximum memory and the slot count to 0 (`src/runtime-rs/crates/hypervisor/src/qemu/cmdline_generator.rs:3258 to 3263`). `[inferred]` The VM then has no memory hot-plug with DIMM devices.

The document `docs/how-to/how-to-use-virtio-fs-with-kata.md` describes the failure:

* Line 13 says that the memory object on `/dev/shm` has the size of the VM memory.
* Line 21 says that a VM fails to start when its boot memory does not fit into `/dev/shm`. It also says that a running VM receives SIGBUS when it touches pages beyond the limit.
* Lines 23 to 27 show the remount command that makes `/dev/shm` larger.

## 2. Raw block volumes with clh and clh-runtime-rs

### Conclusion

Both runtimes support raw block volumes. Each runtime hot-plugs the volume as a virtio-blk disk through the CH API call that adds a disk. The upstream test skips only `fc` and `stratovirt`, and the CI matrix lists `clh` and `clh-runtime-rs` for the suite that contains the test. The setting `disable_block_device_use` does not affect `volumeDevices`.

### Facts

The test and the run lists show these facts:

* The test skips only `fc` and `stratovirt` (`tests/integration/kubernetes/k8s-block-volume.bats:13 and 93`).
* The run list contains the test (`tests/integration/kubernetes/run_kubernetes_tests.sh:73`). The host type `baremetal-no-attestation` includes that list (`tests/integration/kubernetes/run_kubernetes_tests.sh:149`).
* The CI matrix contains `clh` and `clh-runtime-rs` (`.github/workflows/run-k8s-tests-on-free-runner.yaml:43 to 45 and 53 to 55`). The workflow sets the host type at line 78 of the same file.
* The directory `tests/integration/kubernetes/filter_out_per_arch/` has files only for aarch64, ppc64le and s390x. It has no filter for x86_64.
* The test pod is not privileged. It adds `SYS_ADMIN`, and it runs `mkfs` and `mount` itself (`tests/integration/kubernetes/runtimeclass_workloads/pod-block-pv.yaml:11 to 17`, `tests/integration/kubernetes/k8s-block-volume.bats:60 to 89`).

The Go runtime hot-plugs the volume in these steps:

1. It turns each OCI `linux.devices` entry of type `b` into a `DeviceInfo` (`src/runtime/pkg/oci/utils.go:378 to 444`).
2. `createDevices` creates the devices and does not check block support (`container.go:1138 to 1236`).
3. `BlockDevice.Attach` runs (`src/runtime/pkg/device/drivers/block.go:38 to 123`).
4. `Sandbox.HotplugAddDevice` runs (`sandbox.go:2320 to 2357`).
5. The CH driver calls `hotplugAddBlockDevice` (`clh.go:1281 to 1288`, `clh.go:1118 to 1171`).
6. `hotplugAddBlockDevice` fails if `block_device_driver` is not `virtio-blk` (`clh.go:1123 to 1126`). The shipped value is `virtio-blk` (`configuration-clh.toml.in:179`).
7. The runtime sends the device to the agent with the type `blk` and the PCI path as the id (`kata_agent.go:1208 to 1211`).

The Rust runtime hot-plugs the volume in these steps:

1. `handler_devices` handles each device of type `LinuxDeviceType::B` (`src/runtime-rs/crates/resource/src/manager_inner.rs:667 to 725`).
2. `create_block_device_modern` builds the block config (`src/runtime-rs/crates/hypervisor/src/device/device_manager.rs:487 to 535`).
3. The CH driver calls `handle_block_device` (`src/runtime-rs/crates/hypervisor/src/ch/inner_device.rs:326 to 354`).
4. The disk config is raw and has `sparse: true` (`src/runtime-rs/crates/hypervisor/src/ch/inner_device.rs:516 to 560`).

The shipped driver for `clh-runtime-rs` is `virtio-blk-pci` (`configuration-clh-runtime-rs.toml.in:173`).

Both runtimes find the host path of the device in the same way:

* They read `/sys/dev/block/<major>:<minor>/uevent` and use `/dev/<DEVNAME>` (`src/runtime/pkg/device/config/config.go:522 to 563`, `src/runtime-rs/crates/hypervisor/src/device/util.rs:18 to 38`).
* `[inferred]` The node `/dev/loopN` must exist with that exact name in the `/dev` of the kind node.

The setting `disable_block_device_use` works in this way:

* The Go default is true (`src/runtime/Makefile:266`).
* The Go runtime checks it only for a block rootfs (`src/runtime/pkg/containerd-shim-v2/create.go:351`, `container.go:1510 and 1971`) and for a bind mount with a block device as the source (`container.go:627`).
* The setting does not exist in the Rust runtime (`docs/releases/4.2.0.md:469 to 492`, `docs/design/architecture/storage.md:54 to 58`).

In the guest, the agent handles the device in these steps:

1. It waits for the uevent of the virtio-blk PCI device (`src/agent/src/device/block_device_handler.rs:45 to 60 and 116 to 127`). The timeout is 3 seconds (`src/agent/src/config.rs:66`).
2. It writes the guest major and minor numbers into the spec (`src/agent/src/device/mod.rs:726 to 815`). It adds a device rule with the access `rwm` (`src/agent/src/device/mod.rs:213`).
3. It creates the device node at the `devicePath` of the pod with `mknod` (`src/agent/rustjail/src/mount.rs:952 to 976 and 1002 to 1027`).

The container gets a raw block device. Kata mounts nothing on it.

On the host, the Go runtime adds the device to the device cgroup of the sandbox. A failure in that step gives only a warning (`sandbox.go:2324 to 2329`).

## 3. Shipped defaults of the four shims on x86_64

### Conclusion

All four shims use virtio-fs with a separate virtiofsd process. All four start with 1 vCPU and 2048 MiB, an image-based guest with systemd as PID 1, and cgroup v2 in the guest. The Go shims set `static_sandbox_resource_mgmt=false` and `sandbox_cgroup_only=false`. The Rust shims set both to true.

### Facts

| Setting | `clh` (Go) | `clh-runtime-rs` | `qemu` (Go) | `qemu-runtime-rs` |
|---|---|---|---|---|
| `shared_fs` | virtio-fs | virtio-fs | virtio-fs | virtio-fs |
| Extra virtiofsd arguments | `--announce-submounts` | `-o announce_submounts` | same as `clh` | same as `clh-runtime-rs` |
| Default vCPU and memory | 1 vCPU, 2048 MiB | 1 vCPU, 2048 MiB | 1 vCPU, 2048 MiB | 1 vCPU, 2048 MiB |
| `overhead_vcpus` and `overhead_memory` | the keys do not exist | 0.2 vCPU, 32 MiB | the keys do not exist | 0.2 vCPU, 32 MiB |
| `static_sandbox_resource_mgmt` | false | true | false | true |
| `sandbox_cgroup_only` | false | true | false | true |
| `enable_annotations` | enable_iommu, kernel_params, kernel_verity_params | the Go list plus default_vcpus and default_memory | same as `clh` | same as `clh-runtime-rs` |
| `block_device_driver` | virtio-blk | virtio-blk-pci | virtio-scsi | virtio-scsi |
| `disable_block_device_use` | true | the key does not exist | true | the key does not exist |
| `disable_guest_empty_dir` | true | the key does not exist | true | the key does not exist |
| `emptydir_mode` | shared-fs | shared-fs | shared-fs | shared-fs |

The values come from these lines:

* The Go values are in `src/runtime/Makefile:217 to 239, 266 to 288, 298 to 304 and 464`, in `src/runtime/arch/amd64-options.mk:9 and 28`, and in `configuration-clh.toml.in:79, 133 and 179`.
* The Rust values are in `src/runtime-rs/Makefile:181 to 195, 225, 230, 240 to 253, 364 to 367, 581 to 584 and 594 to 611`, and in `src/runtime-rs/arch/x86_64-options.mk:8`.

The four shims share these defaults:

* The virtiofsd path is `$(LIBEXECDIR)/virtiofsd`. The cache mode is `auto`, the DAX cache size is 0, and the queue size is 1024 (`src/runtime/Makefile:275 to 287`, `src/runtime-rs/Makefile:241 to 253`).
* `default_maxvcpus=0` means the number of host cores. `default_maxmemory=0` means the host RAM (`configuration-clh.toml.in:81 to 113`, `src/libs/kata-types/src/config/hypervisor/mod.rs:718 to 737 and 1155 to 1164`).
* The kernel parameters are `cgroup_no_v1=all systemd.unified_cgroup_hierarchy=1` (`src/runtime/arch/amd64-options.mk:9`, `src/runtime-rs/arch/x86_64-options.mk:8`).
* The runtimes add `systemd.unit=kata-containers.target` and they mask systemd-networkd (`src/runtime/pkg/katautils/create.go:36 to 49`, `src/runtime-rs/crates/hypervisor/src/kernel_param.rs:188 to 192`).
* Each file sets `image = @IMAGEPATH@` and has no active `initrd` line (`configuration-clh.toml.in:17`, `configuration-clh-runtime-rs.toml.in:15`, `configuration-qemu.toml.in:17`, `configuration-qemu-runtime-rs.toml.in:18`).
* The `rootfs_type` is erofs (`src/runtime/Makefile:145`). The image is Ubuntu "resolute" (`versions.yaml:145 to 147`).

The guest init process is systemd:

* The image runs systemd as PID 1, and systemd starts the agent (`docs/design/architecture/guest-assets.md:60 to 61 and 136 to 139`).
* The image build uses `AGENT_INIT=no` by default (`tools/osbuilder/rootfs-builder/rootfs.sh:18 and 861 to 868`).
* Only the plain initrd uses the agent as init (`tools/packaging/kata-deploy/local-build/kata-deploy-binaries.sh:1135 to 1139`).
* The agent is in init mode only when its PID is 1 (`src/agent/src/main.rs:350`).

The pinned versions are kernel v6.18.62, CH v54.1, QEMU v11.1.3 and virtiofsd v1.14.0 (`versions.yaml:76, 93, 214 and 442`). `docs/design/virtualization.md:305` says QEMU v10.2.1, and that value does not agree with `versions.yaml`.

By default kata-deploy does not change the shipped configuration files. It adds a drop-in file only for a non-default install prefix, for debug, for a rootless VMM, for kernel parameters, or for the user value `shims.<shim>.dropIn` (`tools/packaging/kata-deploy/binary/src/artifacts/install.rs:245 to 334`).

## 4. Privileged containers in the guest

### Conclusion

Kata has no code path that is specific to privileged containers. The container gets what the OCI spec from containerd says, and the agent applies the spec inside the VM. kata-deploy writes `privileged_without_host_devices = true`. On a guest with cgroup v2, the agent puts the container in its own cgroup, always creates a new cgroup namespace, and mounts a new cgroup2 file system at `/sys/fs/cgroup`. With a cgroup path in the systemd form, the container is in a scope with `Delegate=true`.

### Facts

The documents and kata-deploy say these things:

* `docs/Limitations.md:254 to 262` says that a privileged container runs with elevated capabilities in the guest. It also says that Kata does not support the pass-through of host devices.
* `docs/how-to/privileged.md:16 to 20 and 25 to 26` says that the mitigation "does not affect a container's ability to mount *guest* devices".
* kata-deploy writes the value `"true"` for containerd (`tools/packaging/kata-deploy/binary/src/runtime/containerd.rs:372 to 376`). It writes the same value for CRI-O (`tools/packaging/kata-deploy/binary/src/runtime/crio.rs:37`).
* A search for the word `privileged` in `src/agent`, `src/runtime-rs/crates` and `src/runtime` finds no code that handles privileged containers.

`[GK]` containerd gives a privileged container all capabilities, no masked paths and no read-only paths. It mounts sysfs and the cgroup file system read-write. It adds no seccomp profile and no cgroup namespace entry. With `privileged_without_host_devices=true`, `linux.devices` contains only the `volumeDevices` of the pod.

The agent applies these parts of the spec:

* It applies the capabilities (`src/agent/rustjail/src/capabilities.rs:55 to 75`).
* It applies the masked paths and the read-only paths (`src/agent/rustjail/src/mount.rs:1069 to 1078`).
* It applies the sysctls (`src/agent/rustjail/src/container.rs:649 and 1816`).
* Both runtimes remove the seccomp profile by default (`kata_agent.go:1062 to 1066`, `src/runtime-rs/crates/runtimes/virt_container/src/container_manager/container.rs:852 to 854`).

The container gets these devices:

* The agent creates only null, zero, full, tty, urandom and random (`src/agent/rustjail/src/container.rs:154 to 217`). It then adds the `linux.devices` entries, the symlinks and ptmx (`src/agent/rustjail/src/mount.rs:341 to 347`).
* `[inferred]` `/dev/kmsg`, `/dev/fuse`, `/dev/net/tun` and `/dev/loop-control` do not exist unless the image creates them.
* Both runtimes remove `resources.devices` from the spec (`kata_agent.go:1100`, `src/runtime-rs/crates/runtimes/virt_container/src/container_manager/container.rs:229 to 234`).
* A comment says that the device cgroup is disabled in the systemd cgroup manager (`src/agent/rustjail/src/cgroups/fs/mod.rs:1184 to 1186`).

The runtimes change the namespaces in this way:

* The Go runtime removes the cgroup, network and time namespaces (`kata_agent.go:1120 to 1128`).
* The Rust runtime removes the pid, network and time namespaces (`src/runtime-rs/crates/runtimes/virt_container/src/container_manager/container.rs:858 to 875`).
* The container runs in the network namespace of the guest.

The agent selects the cgroup manager in this way:

* It uses the systemd manager when the path has the form `slice:prefix:name` and the agent is not PID 1 (`src/agent/src/rpc.rs:369 to 384`). The pattern is at `src/agent/rustjail/src/container.rs:219`.
* In all other cases it uses the cgroupfs manager and replaces each `:` with `/` (`src/agent/rustjail/src/container.rs:1769 to 1789`).
* The two runtimes do not change `cgroupsPath`.
* The systemd manager starts a transient unit `<prefix>-<name>.scope` in the given slice with `Delegate=true` (`src/agent/rustjail/src/cgroups/systemd/dbus_client.rs:48 to 78`, `src/agent/rustjail/src/cgroups/systemd/cgroups_path.rs:38 to 75`).
* The guest image enables the D-Bus socket (`tools/osbuilder/rootfs-builder/rootfs.sh:866 to 867`).

The agent sets up the cgroup namespace and the cgroup mount in this way:

* The parent attaches the process to the cgroup first (`src/agent/rustjail/src/container.rs:1645 to 1648`).
* The child then calls `unshare` with `CLONE_NEWCGROUP` when the guest uses cgroup v2 (`src/agent/rustjail/src/container.rs:566 to 568`).
* `[inferred]` The container sees its own cgroup as the root.
* The agent mounts a new `cgroup2` file system at `/sys/fs/cgroup`. It makes the mount read-only only if the spec asks for it (`src/agent/rustjail/src/mount.rs:285 to 286, 403 to 436 and 454 to 456`).

The agent handles an exec process in this way:

* It attaches each exec process to the root of the container cgroup.
* If the child cgroup `<container cgroup>/init` exists, it attaches the process to that child (`src/agent/rustjail/src/cgroups/fs/mod.rs:47 to 48, 88 to 101, 1039 to 1044 and 1202 to 1211`, `src/agent/rustjail/src/cgroups/systemd/manager.rs:44 to 57`, `src/agent/rustjail/src/cgroups/systemd/dbus_client.rs:155 to 165`).
* The name must be exactly `init`. The agent has no code for `init.scope`.

The source does not show which controllers the container cgroup gets. I did not find that information. The result depends on systemd in the guest and on the external crate cgroups-rs.

`docs/design/agent-systemd-cgroup.md:3` says that the agent uses cgroupfs unless it gets the parameter `--systemd-cgroup`. The code does not agree, because it decides from the form of the path.

## 5. Sizing, hot-plug and RuntimeClasses

### Conclusion

`clh-runtime-rs` sets the VM size one time at boot. The size is the pod limits plus 0.2 vCPU and 32 MiB, and the shim does no hot-plug. `clh` (Go) boots with 1 vCPU and 2048 MiB and then hot-plugs the container limits. Both runtimes contain resize code for CH. The RuntimeClass names have the form `kata-<shim>`, and each CH class has an overhead of 130Mi and 250m.

### Facts

The document `docs/how-to/how-to-size-sandbox-overhead-runtime-rs.md` gives this model:

* With limits, the VM size is the limits plus `overhead_*`. The runtime rounds a fractional CPU count up (lines 26 to 40).
* Without limits, the VM size is `default_vcpus` and `default_memory` (lines 26 to 40).
* With a CPU limit and no memory limit, the VM memory is `overhead_memory` only (lines 189 to 207).
* The document recommends the static mode (lines 6 to 8).
* `podFixed` must be larger than `overhead_*` (lines 75 to 88).
* The runtime does not read the overhead of the RuntimeClass (lines 366 to 367).

The code in `src/runtime-rs/crates/resource/src/cpu_mem/initial_size.rs` agrees with the document:

* For a pod sandbox, the size comes from the annotations `io.kubernetes.cri.sandbox-*` (lines 68 to 71 and 235 to 259).
* The code uses the CPU shares only when the quota is less than 0 (lines 47 to 49).
* In static mode it sets `default_vcpus` to the larger of 1 and `overhead_vcpus` plus the pod vCPUs. It sets `default_memory` to `overhead_memory` plus the pod memory. It sets `default_maxvcpus` to `default_vcpus` rounded up (lines 170 to 195).
* `[inferred]` A limit of 2 CPUs gives 3 vCPUs at boot, because the CH config rounds 2.2 up (`src/runtime-rs/crates/hypervisor/ch-config/src/convert.rs:300`).
* In static mode the Rust runtime does no CPU hot-plug and no memory hot-plug (`src/runtime-rs/crates/resource/src/manager_inner.rs:1313 to 1333`).

The Rust CH driver contains this resize code:

* `resize_vcpu` is at `src/runtime-rs/crates/hypervisor/src/ch/inner_hypervisor.rs:792 to 825`.
* `resize_memory` is at `src/runtime-rs/crates/hypervisor/src/ch/inner_hypervisor.rs:897 to 973`.
* The driver does not remove memory (`src/runtime-rs/crates/hypervisor/src/ch/inner_hypervisor.rs:916 to 919`).

The Go runtime resizes the VM in `updateResources` (`sandbox.go:2580 to 2700`):

* It adds the container limits to the default vCPUs and the default memory (`sandbox.go:2594 to 2606`).
* `ResizeVCPUs` is at `clh.go:1419 to 1477`.
* `ResizeMemory` is at `clh.go:1339 to 1417`. It has no virtio-mem support (`clh.go:1341`), and it does not remove memory (`clh.go:1377 to 1380`).
* `ResizeMemory` uses the CH API timeout of 1 second (`clh.go:78 and 1403`).
* The runtime adds memory in steps. Each step adds at most 48 times the current memory (`sandbox.go:96 and 2636 to 2679`).

The test helper treats each hypervisor as able to hot-plug, except the confidential hypervisors and Firecracker (`tests/hypervisor_helpers.sh:148 to 158`).

The file `tools/packaging/kata-deploy/helm-chart/kata-deploy/templates/runtimeclasses.yaml` defines the RuntimeClasses:

* The name and the handler are `kata-<shim>` (lines 76 to 77). The four names are `kata-clh`, `kata-clh-runtime-rs`, `kata-qemu` and `kata-qemu-runtime-rs`.
* `clh` and `clh-runtime-rs` have an overhead of 130Mi memory and 250m CPU (lines 13 and 15).
* `qemu` and `qemu-runtime-rs` have an overhead of 320Mi memory and 250m CPU (lines 20 and 23).
* Each class has the node selector `katacontainers.io/kata-runtime: "true"` (lines 131 to 133).
* The chart creates no default class `kata` unless `createDefault` is true (`tools/packaging/kata-deploy/helm-chart/kata-deploy/values.yaml:833 to 836`). The default shim is `qemu-runtime-rs` (`tools/packaging/kata-deploy/helm-chart/kata-deploy/values.yaml:827 to 831`).

## 6. Limits of Cloud Hypervisor against QEMU in the 4.4.0 documents

### Conclusion

The documents list no missing CH feature that the lab needs. `docs/design/virtualization.md` says that CH has disk hot-plug, virtio-fs, vsock, and CPU and memory resize. The documented gaps are GPU, TDX, SNP and virtio-mem. I did not find a documented limit for the number of block devices. I did not find a statement about operation inside a container.

### Facts

The documents say these things:

* `docs/hypervisors.md:19 to 25` says that CH has no GPU support, no TDX support and no SEV-SNP support.
* `docs/design/virtualization.md:179 to 200` lists the CH features. The comparison table at lines 228 to 241 says yes for file system sharing, device hot-plug, and CPU and memory hot-plug.
* `docs/how-to/how-to-use-virtio-mem-with-kata.md:12` says that Kata supports virtio-mem only with QEMU.
* `docs/Limitations.md` applies to all hypervisors. It says that host network is not supported (lines 105 to 118), that `subPath` is not supported (lines 195 to 201), and that privileged containers differ from runc (lines 254 to 262).

The code has these limits that the documents do not list:

* The Go CH driver rejects 9p (`clh.go:408 to 410`).
* It has no NVDIMM and no DAX (`clh.go:362 to 363 and 651 to 652`).
* It rejects a swap disk (`clh.go:1119 to 1121`).
* It rejects confidential guests (`clh.go:463 to 480`).
* The Go runtime sets 2 PCI segments and puts virtio-fs on segment 1 (`clh.go:561 and 2192`). The Rust runtime sets no platform config, so CH uses its default. `[GK]` CH has 32 slots for each segment and has no PCI bridges.

The two hypervisors use different vsock types:

* CH uses a hybrid vsock with a Unix socket (`clh.go:1753 to 1764`, `src/runtime-rs/crates/hypervisor/src/ch/inner_hypervisor.rs:864 to 877`).
* QEMU needs `/dev/vhost-vsock` and `/dev/vhost-net` on the node (`src/runtime/virtcontainers/utils/utils_linux.go:70 to 73`, `src/runtime/virtcontainers/network_linux.go:914`, `src/runtime-rs/crates/hypervisor/src/device/driver/virtio_vsock.rs:110`).

## 7. Mounts and volumes that affect a nested container runtime

### Conclusion

With the default overlayfs snapshotter, the container root is a virtio-fs share in both runtimes. The documents say that virtio-fs cannot be the upper layer of overlayfs. A memory emptyDir becomes a tmpfs inside the guest and uses VM memory. A disk emptyDir reaches the guest through virtio-fs. The block devices of the lab for `/var` agree with the advice in the document.

### Facts

The container root reaches the guest in this way:

* The Go shim mounts the rootfs on the node, unless the rootfs is a block device and block use is on (`src/runtime/pkg/containerd-shim-v2/create.go:346 to 353`). The runtime then shares it below `/run/kata-containers/shared/containers/` (`kata_agent.go:113, 116 and 1577`).
* The Rust runtime uses `ShareFsRootfs` for a single layer that is not a block device (`src/runtime-rs/crates/resource/src/rootfs/mod.rs:131 to 170`).
* `docs/design/architecture/storage.md:21 to 27` describes the virtio-fs root.

A memory emptyDir reaches the guest in this way:

* The Go runtime changes the mount type to `ephemeral` (`src/runtime/pkg/katautils/create.go:98 to 101`). It then asks the agent for a tmpfs with no size option (`kata_agent.go:1802 to 1840`).
* In dynamic mode, the Go runtime mounts the tmpfs again with `size=<sandbox MiB>M` after a memory hot-plug (`sandbox.go:2700 to 2743`).
* The Rust runtime does the same type change and asks for the same tmpfs (`src/libs/kata-sys-util/src/k8s.rs:66 to 79`, `src/runtime-rs/crates/resource/src/volume/ephemeral_volume.rs:26 to 85`). The Rust runtime has no call that changes the tmpfs size.
* The agent mounts the tmpfs in the guest (`src/agent/src/storage/ephemeral_handler.rs:45 to 86`).

A disk emptyDir reaches the guest in this way:

* In the Go runtime it stays a bind mount, and the runtime shares it through virtio-fs, because `disable_guest_empty_dir` is true (`configuration-clh.toml.in:470 to 472`, `src/runtime/pkg/katautils/create.go:102 to 114`).
* In the Rust runtime it is a `ShareFsVolume` when `emptydir_mode` is `shared-fs`. The block modes are optional (`src/runtime-rs/crates/resource/src/volume/mod.rs:119 to 192 and 282 to 288`).

The document `docs/how-to/how-to-run-docker-with-kata.md` says these things about a container runtime in the guest:

* The root is a `kataShared` virtio-fs mount. The document says that virtio-fs cannot be the upper layer of overlayfs without a custom patch (lines 44 to 53).
* The first solution is a memory emptyDir together with a privileged container (lines 59 to 99).
* The second solution is a loop-mounted disk inside the container (lines 101 to 124).
* The third solution is a custom kernel (lines 126 to 130).

The guest kernel fragments in `tools/packaging/kernel/configs/fragments/common/` show these facts:

* `fs.conf` has loop, ext4, xfs, overlayfs and fuse (lines 9, 18, 26, 56 and 64).
* `cgroup.conf` has the cpu, cpuset, memory, pids, hugetlb and blkio controllers and cgroup BPF (lines 3 to 27).
* `network.conf` has bridge, veth, br_netfilter, vxlan and nf_tables (lines 43, 74 and 81 to 103).
* `netfilter.conf` has iptables, ipvs and ipset.
* The fragments do not contain `CONFIG_MODULES`, `CONFIG_IKCONFIG` or AppArmor.

## Most likely first failures in this lab, and what to check

1. **VM size with `clh-runtime-rs`.** The source makes this result certain when the pod has no limits. A pod with no limits gets 1 vCPU and 2048 MiB. A pod with a CPU limit and no memory limit gets a VM of 32 MiB (`src/runtime-rs/crates/resource/src/cpu_mem/initial_size.rs:175 to 195`). `[GK]` kubeadm needs at least 2 CPUs and about 1.7 GB of memory. Set both limits on the pod. Look for the text "resource with vcpu" and "resource with memory" in the shim log.

2. **Host cgroup setup with the Rust shims on the kind node.** With `sandbox_cgroup_only=true` and a cgroup path in the systemd form, the Rust shims use a systemd manager from the external crate cgroups-rs (`src/runtime-rs/crates/resource/src/cgroups/resource_inner.rs:243 to 257`). The lock file shows that the crate depends on zbus (`Cargo.lock:892 to 906`). I did not find in the Kata tree which socket the crate uses. `[GK]` A kind node uses the systemd cgroup driver and normally has no D-Bus system bus daemon. `[lab]` The coordinator reported that the Rust shim needs the D-Bus system bus on the node. Check that `/run/dbus/system_bus_socket` exists in the node. Look for errors with the text "create new cgroups", "new systemd manager" or "add runtime to sandbox cgroup". The Go shims do not have the problem, because with `sandbox_cgroup_only=false` they use the path as a cgroupfs path (`src/runtime/pkg/resourcecontrol/cgroups.go:200 to 204`, `src/runtime/pkg/resourcecontrol/utils_linux.go:27 to 34`).

3. **`kubectl exec` after systemd starts in the container.** `[inferred]` The agent attaches each exec process to the root of the container cgroup, unless a child cgroup with the name `init` exists (`src/agent/rustjail/src/cgroups/fs/mod.rs:88 to 101 and 1202 to 1211`). `[GK]` systemd moves itself to `init.scope` and enables controllers for the child cgroups, and the kernel then refuses the write with EBUSY. `[lab]` The coordinator reported that `kubectl exec` fails with EBUSY after systemd starts, unless the child cgroup `init` exists. Create `/sys/fs/cgroup/init` in the image entrypoint before systemd starts.

4. **Missing device nodes for kubelet and containerd.** `/dev` has only six default devices and the block volumes (`src/agent/rustjail/src/container.rs:154 to 217`). `[GK]` kubelet fails without `/dev/kmsg`. Run `ls /dev` in the container. Create the missing nodes with `mknod` in the image entrypoint.

5. **Host path of the block volume.** Kata opens `/dev/<DEVNAME>` on the node, and it takes `DEVNAME` from sysfs. It does not use the path of the PersistentVolume (`src/runtime/pkg/device/config/config.go:522 to 563`, `src/runtime-rs/crates/hypervisor/src/device/util.rs:18 to 38`). Check that `/dev/loopN` exists with that exact name in the node. Look for a CH error with the text "No such file" when CH adds the disk. For the Go shim, look for the warning "Could not add device to the ... controller" (`sandbox.go:2324 to 2329`).

6. **QEMU fallback.** The guest memory is a file on the `/dev/shm` of 64 MB, so the VM fails to start or receives SIGBUS (`docs/how-to/how-to-use-virtio-fs-with-kata.md:13 and 21`). Mount `/dev/shm` again in the node with a size of at least the VM memory. Check that `/dev/vhost-vsock` and `/dev/vhost-net` exist in the node.

7. **Out of memory in the pod cgroup on the node with the Rust shims.** `[inferred]` The VM memory is the limit plus 32 MiB. The pod cgroup has the limit plus 130Mi, and it contains the shim, the VMM and virtiofsd. Read `memory.events` of the pod cgroup on the node. Raise the overhead of the RuntimeClass if the kernel kills the VMM.

8. **Guest memory use of `/run` and `/tmp`.** Each memory emptyDir is a tmpfs in the guest. With the Rust runtime the tmpfs has no size option. With the Go runtime in dynamic mode the tmpfs gets the size of the total sandbox memory (`sandbox.go:2700 to 2743`). Run `df` in the container. Include the tmpfs use in the memory limit of the pod.

9. **Hot-plug with the Go shim `clh`.** The memory above 2048 MiB arrives after boot through ACPI hot-plug, and the CH API timeout is 1 second (`clh.go:78 and 1403`). Look for the error "Failed to resize memory". Run `nproc` and `free` in the container. `[inferred]` A limit of 2 CPUs gives 3 vCPUs.

10. **Guest kernel.** The guest kernel has no loadable modules and no `/proc/config.gz`. `[GK]` The kubeadm preflight check SystemVerification can fail, and each `modprobe` call can fail. Run `cat /sys/fs/cgroup/cgroup.controllers` in the container. Check that the output contains cpu, cpuset, memory, pids and hugetlb.

11. **Features of the pod spec.** `docs/Limitations.md:195 to 201` says that `subPath` is not supported. `docs/Limitations.md:105 to 118` says that host network is not supported, and the lab does not use host network.
