# Kata fix install and tests: patched agent and direct I/O (Kata 4.4.0, Cloud Hypervisor)

Both agent fixes work in Kata pods with both shims. Direct I/O for block volumes stops the kill by the pod cgroup in the write burst test. The gate 4 replicas did not change during the containerd restart. Raw output: `/scratch/kata-cp/logs/kata-fix/`.

## Results

| Test | Stock | Patched or direct |
|---|---|---|
| `kubectl exec`, no `init` cgroup, Rust runtime | Fails, EBUSY | Works. The exec processes are in `init.scope` |
| The same, Go runtime (`kata-clh`, `kata-clh-fix`) | Fails, EBUSY | Works |
| `ctr tasks kill -s SIGKILL`, Rust runtime | Runs on after 10 s | `CONTAINER_EXITED`, exit code 137, after 1 s |
| The same, Go runtime | Runs on after 10 s | Exit code 137 after 2 s |
| Pod delete, grace 5 s, small systemd pod | 1 to 4 s | 1 to 4 s. No difference, see "Things that failed" |
| Gate 1 full run, stop timeout 10 s | 4 checks PASS, stop 11.8 s, delete 11.3 s (earlier lab run `kata-rs-run-1`) | 4 PASS, stop 11.5 s, delete 11.3 s, no `init` cgroup |
| Gate 1 full run, systemd default stop timeout | Stop 91.5 s with a crictl error, delete 91.1 s (earlier lab run `kata-dev3`) | 4 PASS, stop 21.5 s with exit code 137, delete 21.8 s |
| `systemctl poweroff` in the guest, default timeout | 104.0 s | 103.9 s. It is a shutdown inside the guest, so no change |
| 3 GiB write burst after a read fill, 8Gi limit, 512Mi overhead | Killed 3 of 3, in round 1 after about 13 s | Direct: survived 3 of 3 (150 s, 20 to 21 rounds). Patched image plus direct: survived 1 of 1 |
| Pod cgroup at the peak (MiB), limit 8704 | current 8703, file 8589 to 8630, shmem 8176 to 8195, anon 7, kernel 64 to 105 | current 8703, file 8588 to 8590, file_dirty 0, shmem 8202 to 8204, anon 7, kernel 103 to 105 |
| Dirty pages | Kernel report at each kill: file_dirty 383 to 385, equal to all of inactive_file | file_dirty and file_writeback 0 in all samples |
| Read fill only, 120 s | Survives with 192Mi or more (lab report) | Direct: survived, oom_kill 0 |
| fdatasync, 22 MiB in writes of 2300 bytes (not fio) | avg 3.56 to 3.70 ms, p99 6.18 to 6.54 ms, 269 to 280 writes per second | Direct: avg 3.46 to 3.70 ms, p99 5.94 to 6.30 ms, 269 to 288 writes per second |

The stock class in the burst and fdatasync tests is `kata-clh-runtime-rs-ovh512` (stock handler, 512Mi).

## The containerd restart and the gate 4 replicas

* One restart, at 23:43:29 UTC. containerd was back in less than 0.4 s. `KillMode=process`, and the Kata shims are in the pod cgroups.
* cp-a-0, cp-b-0, cp-c-0: no change. Restart counts (0, 1, 0), pod IPs, sandbox IDs, container IDs, and the PIDs and start times of the shim, virtiofsd and cloud-hypervisor are the same. The guest boot IDs are the same. `etcdctl endpoint health --cluster` gives three healthy members before and after. `gate4/run.sh check` gives PASS before and after, and the identity files are the same. The state is the same again at the end of all tests.
* `/readyz` loop on https://172.30.255.210:6443, one call each second, from 16 s before to 110 s after the restart: 124 calls, 0 failed, longest gap 1.03 s. The Service of each replica: 119 calls each, 0 failed.

## Source facts on direct I/O (tag 4.4.0)

* Rust runtime: it honours the value. `src/runtime-rs/crates/hypervisor/src/ch/inner_device.rs:295 to 317` (`make_disk_config`) sets `direct` from `block_device_cache_direct` at lines 301 to 303, unless the device sets `is_direct`. Only swap does that (`resource/src/cpu_mem/swap.rs:165`). The hot-plug path uses it (`handle_block_device`, 325 to 336), and so does the cold-plug path (468 to 478). The boot image never gets direct I/O (`ch-config/src/convert.rs:425 to 427`).
* Rust runtime: `block_device_cache_set` and `block_device_cache_noflush` are parsed (`src/libs/kata-types/src/config/hypervisor/mod.rs:258 to 270`) and nothing in `src/runtime-rs` reads them. They do not matter.
* Go runtime: `src/runtime/virtcontainers/clh.go:1146 to 1148` sets direct for a hot-plugged disk only if `block_device_cache_set` is true. Lines 1101 to 1103 do the same for the boot image. So the Go runtime needs both values, and the image then also gets direct I/O. `block_device_cache_noflush` is not used for Cloud Hypervisor.
* Checked on the node: with the direct class the hypervisor has `/dev/loop21` open with flags 02140002 (O_DIRECT). With the stock class the flags are 02100002. The image has no O_DIRECT in both.
* No source change is necessary. `block_device_cache_direct = true` in the configuration of the Rust runtime is enough.
* Cause of the stock kill, now with numbers: an io_uring worker of cloud-hypervisor asks for memory with `GFP_NOIO|__GFP_WRITE`. At that time all the page cache that is left in the pod cgroup is dirty (383 to 385 MiB), and reclaim without I/O cannot free it.

## Things that failed, and the cause

* Test 2 of `02-test.sh` (pod delete with grace 5 s) shows no difference. systemd in this small pod halts 1 to 2 s after the stop signal, so no SIGKILL is sent. The gate 1 run with the default stop timeout shows the difference (21.8 s against 91.1 s).
* `02-test.sh` used `pgrep -x cloud-hypervisor`. The process name is cut to 15 characters, so it found nothing. I corrected it before the runs.
* fio is not in the node image or on the host. `plan/burst/fsync-test.py` does the same write pattern with Python and prints percentiles. It is not fio.
* The fdatasync script did not read the logical block size of the device (wrong sysfs path). The results are not affected.
* The stock numbers for gate 1 come from the earlier lab runs. I did not run stock gate 1 again.
* Not caused by this work: `systemctl poweroff` through exec prints "Failed to connect to system scope bus" and then works. The earlier stock and runc runs print the same. The Go shim logs "failed to delete dead shim" at each sandbox end, also before this work.

## State that I leave

* Node: `/opt/kata-fix` holds the two images, the link `kata-containers-fix.img` (to the image with both fixes), four configuration files, the containerd handler file and a copy of the old `config.toml`. `/etc/containerd/config.toml` has one more entry in `imports`. `/opt/kata`, the stock handlers and the stock RuntimeClasses are unchanged.
* New handlers and RuntimeClasses with the same names, all with 512Mi and 250m: `kata-clh-runtime-rs-fix`, `kata-clh-fix`, `kata-clh-runtime-rs-direct` (stock image), `kata-clh-runtime-rs-fix-direct`.
* Recommended class for the next gates: `kata-clh-runtime-rs-fix-direct`. It has the kill fix, the exec fix (no `init` cgroup step is necessary), direct I/O and 512Mi.
* Clean: the test namespaces and volumes are gone. var-1, etcd-1, var-2 and etcd-2 have no signature. gate4, gate1-nvke-spire, MetalLB and the other loop devices were not touched.
* Rollback: `/scratch/kata-cp/images/kata-fix/plan/03-rollback.sh` (one more containerd restart). The scripts that I ran are in `/scratch/kata-cp/images/kata-fix/plan/`.

## Not tested

* A full gate run with `kata-clh-runtime-rs-fix-direct`. That class had the write burst and the open flag check only. Gate 1 ran with `kata-clh-runtime-rs-fix`.
* Direct I/O with the Go runtime or QEMU, limits other than 8Gi, runs longer than 150 s, and a real disk. The loop devices here use direct I/O to a file, so the fdatasync numbers are lab numbers.
* The image with the kill fix only (the fallback), cgroup v1, and a container that shares the PID namespace of the sandbox.
* Throughput with direct I/O against stock. The stock pod died before a round ended.
