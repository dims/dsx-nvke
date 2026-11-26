# Gate 2 report: etcd sync time in a Kata pod

Date 2026-11-25, 19:45 to 22:40. The agent that ran the tests wrote this report, and the main session saved it.

## 1. Result

Gate 2 passes by its rule. The three replica cluster on one disk is above the limit, and the evidence points to the disk.

- **Pass case.** One Kata control plane node (class `kata-clh-runtime-rs-fix-direct`, etcd on a raw block volume, 756 fake nodes, 23 patches each second) had a WAL sync p99 of 7.83, 7.82 and 7.86 ms in three runs, each from empty devices. 0.20 to 0.41 percent of the syncs took more than 8 ms. The p99 reaches 10 ms only when 1.33 percent are above 8 ms.
- **runc baseline** (same pod, devices and load, one run): p99 7.64 ms, 0.06 percent above 8 ms. Both p99 values are inside the 4 to 8 ms histogram bucket, so the p99 ratio of 1.02 says little. The ratio of Kata to runc is 1.14 to 1.16 for the mean, 1.21 to 1.25 for p50 and 1.22 to 1.42 for p90. The mean difference is 0.33 to 0.41 ms for each sync.
- **Three replicas (gate 4 cluster).** At 756 nodes the three members had a p99 of 10.7, 11.6 and 11.7 ms, with 1.5 to 1.8 percent above 8 ms. Their etcd devices are on one NVMe disk here. Three fio streams at one time have the same sync time on the host, in runc pods and in Kata pods (mean 4.3 ms, against 2.5 ms for one stream). A three replica cluster with runc was not tested.
- The disk here is slow for syncs. One fdatasync takes 1.1 ms on `/scratch` and 2.5 ms through a loop device, so the absolute numbers are lab numbers. No new Kata setting, kernel option or source change was necessary.

## 2. Tables and ratios

fio: `--rw=write --ioengine=sync --fdatasync=1 --size=22m --bs=2300`, fio 3.41 on the host and 3.39 in the pods. The numbers are fdatasync times in ms, the median of three runs. Each block place uses a loop device that is attached with direct I/O to a sparse file on `/scratch` (ext4 on LUKS on a Toshiba KXG60ZNV1T02 NVMe). Each run starts with a discard of the device and a new ext4 with no lazy init.

| Place | mean | p50 | p90 | p99 (range) | p99.9 | writes/s |
|---|---|---|---|---|---|---|
| Host, ext4 on the loop device | 2.49 | 2.67 | 3.88 | 5.14 (5.01 to 5.14) | 6.59 | 399 |
| runc pod, raw block volume | 2.51 | 2.67 | 3.92 | 5.14 (5.01 to 5.21) | 6.65 | 397 |
| Kata class of record, raw block volume | 2.88 | 2.93 | 4.62 | 6.19 (5.87 to 6.39) | 7.24 | 345 |
| Kata `kata-clh-runtime-rs-ovh512` (no direct I/O), raw block | 2.71 | 2.90 | 4.23 | 5.73 (5.67 to 6.06) | 7.37 | 367 |
| Kata `kata-clh` (Go runtime), raw block | 2.74 | 2.90 | 4.36 | 5.93 (5.80 to 6.00) | 7.11 | 363 |
| Host, folder on `/scratch`, no loop device | 1.10 | 1.25 | 1.53 | 2.80 (2.74 to 2.83) | 3.98 | 904 |
| runc pod, disk emptyDir, no loop device | 1.10 | 1.25 | 1.52 | 2.80 (2.77 to 2.80) | 3.52 | 906 |
| Kata class of record, disk emptyDir (virtio-fs) | 1.15 | 1.29 | 1.60 | 2.83 (2.83 to 2.87) | 3.85 | 817 |
| Three streams at one time, host, three loop devices | 4.32 | 4.88 | 6.26 | 7.05 (6.98 to 7.11) | 8.98 | 231 each |
| Three streams at one time, three runc pods | 4.34 | 4.88 | 6.26 | 7.05 (6.98 to 7.11) | 8.98 | 230 each |
| Three streams at one time, three Kata pods | 4.31 | 4.82 | 6.19 | 7.18 (7.05 to 7.24) | 9.11 | 231 each |

- Ratio of Kata (class of record) to runc on a raw block volume: mean 1.15, p50 1.10, p90 1.18, p99 1.20, p99.9 1.09, write rate 0.87. The mean difference is +0.37 ms. With three streams the ratio is 0.99 for the mean and 1.02 for p99.
- Each fdatasync of the guest reaches the disk. The guest device reports a write cache, and the loop device got 15,683 flushes for 10,029 syncs in each Kata run (all three classes) and 15,686 with runc. The virtio-fs run made 10,533 flushes on the NVMe disk.
- virtio-fs was not slow here. Its ratio to the same folder with runc is 1.05 for the mean and 0.90 for the write rate. It is faster than the block volume only because the block volume is a loop device on a file, which costs 1.4 ms more for each sync (host loop to host folder: 2.27). This lab cannot rank virtio-fs against a real block device.
- Direct I/O costs a little: mean 2.88 against 2.71 ms, p99 6.19 against 5.73 ms.

etcd 3.6.8 under load, Kubernetes v1.36.4, windows of 600 s or more (the idle rows 150 s). Times in ms from the histogram deltas. etcd of the single node is on loop device etcd-1 for Kata and runc. CPU is in cores: kube-apiserver, etcd, and the whole pod cgroup on the kind node.

| Control plane | Load | WAL syncs/s | mean | p50 | p90 | p99 | p99.9 | above 8 ms | above 16 ms | commit p50, p99 | CPU |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Kata, 1 node | idle | 1.8 | 3.22 | 3.04 | 5.85 | 7.94 | 14.9 | 0.75% | 0 | 5.8, 15.4 | 0.03, 0.01, 0.25 |
| Kata, 1 node | 355 nodes | 75 | 3.06 | 2.83 | 6.48 | 7.91 | 14.0 | 0.40% | 0 | 6.2, 15.6 | 0.17, 0.07, 0.81 |
| Kata, 1 node, run 1 | 756 nodes | 133 | 2.77 | 2.45 | 5.88 | 7.83 | 12.1 | 0.20% | 0.009% | 5.3, 15.2 | 0.27, 0.10, 1.12 |
| Kata, 1 node, run 2 | 756 nodes | 138 | 2.75 | 2.42 | 5.82 | 7.82 | 12.1 | 0.20% | 0 | 6.0, 15.5 | 0.27, 0.10, 1.14 |
| Kata, 1 node, run 3 | 756 nodes | 138 | 2.74 | 2.33 | 5.64 | 7.86 | 14.1 | 0.41% | 0 | 5.9, 15.6 | 0.27, 0.10, 1.14 |
| runc, 1 node | idle | 1.8 | 2.92 | 2.85 | 5.28 | 7.73 | 8.0 | 0 | 0 | 4.7, 13.6 | 0.03, 0.01, 0.10 |
| runc, 1 node | 355 nodes | 75 | 2.64 | 2.27 | 5.32 | 7.75 | 8.0 | 0.08% | 0 | 5.5, 14.5 | 0.23, 0.10, 0.40 |
| runc, 1 node | 756 nodes | 135 | 2.44 | 2.01 | 4.14 | 7.64 | 8.0 | 0.06% | 0 | 4.5, 13.3 | 0.40, 0.16, 0.66 |
| Kata, 3 replicas, each member | 355 nodes | 76 to 77 | 3.52 to 3.69 | 3.42 to 3.53 | 7.1 | 8.79 to 9.98 | 15.5 | 1.11 to 1.32% | 0.02% | 6.7, 15.8 | 0.10, 0.07, 0.67 to 0.77 |
| Kata, 3 replicas, each member | 756 nodes | 133 to 136 | 3.34 to 3.54 | 3.17 to 3.41 | 7.1 | 10.66 to 11.69 | 15.6 | 1.49 to 1.85% | 0.01% | 6.3, 15.8 | 0.14 to 0.17, 0.10, 0.87 to 1.04 |

- Ratio of Kata to runc, single node. WAL sync at 355 nodes: mean 1.16, p50 1.25, p90 1.22. At 756 nodes: mean 1.14, p50 1.21, p90 1.42. Backend commit mean: 1.19 and 1.14. CPU that the two processes report: 0.67 to 0.73, cause not examined. CPU of the whole pod on the node: 2.0 at 355 nodes and 1.7 at 756.
- The histogram buckets double (4, 8, 16 ms). The p99 of the single node is inside the 4 to 8 ms bucket, and the straight line method gives 7.8 ms. fio in the same place gives a p99 of 6.2 ms. In the Kata runs the p99 of a 30 s interval was at or above 10 ms in 1 of 60 intervals at 756 nodes.
- Three replicas: no leader change, no failed proposal, no slow apply, and no failed patch. At idle the three members already had 1.2 to 2.7 percent above 8 ms (about 480 syncs each, a small sample).

## 3. Load, CPU and memory

- Requests each second at 355 nodes: PUT leases 36, PATCH nodes/status 16, PATCH configmaps 23.0, PATCH events 1.7. Total 77 writes. At 756 nodes: PUT leases 75, PATCH nodes/status 34, PATCH configmaps 23.0, PATCH events 12 to 17. Total 144 to 149 writes. Reads are 2.5 each second for one node and 8 for three replicas (probes and leader election).
- The load has more writes than real nodes make. KWOK v0.7.0 patches the status of each node each 20 to 25 s, and a kubelet does it each 5 minutes when nothing changes. The event patches come from the node IPAM controller, because the pod subnet of the lab has 256 node ranges.
- The patcher held 23.00 patches each second with no failed call. Each patch writes a ConfigMap of 2 KiB. Patch time p50: 5.7 to 6.4 ms with Kata, 5.8 ms with runc, 9.3 to 9.7 ms with three replicas.
- Memory at 756 nodes, Kata single node: guest 7,992 MiB with 7,072 available, pod cgroup 2,987 of 8,704 MiB, `oom_kill` 0, kube-apiserver RSS 491 MiB, etcd RSS 267 MiB. runc: pod cgroup 1,843 of 8,192 MiB. Three replicas: guest 5,976 MiB with 5,079 to 5,167 available, pod cgroup 2,061 to 2,158 of 6,656 MiB, `oom_kill` 0.
- etcd database at the end of the 756 window: 172 to 185 MiB in all cases, 100 to 170 MiB in use.
- Load average (1 minute) before and after: fio rounds 2.3 and 3.3, Kata run 1 2.7 and 1.7, runc 1.7 and 2.0, three replicas 1.6 and 1.8, Kata run 2 4.8 and 2.1, Kata run 3 2.1 and 3.6. Each test raises it to 3 to 8 by itself, because tasks that wait for the disk count. The CPU counters of the machine (each 30 s from 20:16) had a maximum of 16.2 percent busy, during the three replica test. Two `top` samples before 20:16 showed 86 and 92 percent idle. No build of another session ran next to a test, so no test was repeated for that reason.

## 4. Things that failed, with the cause

- `docker cp` did not find the sample files. `/tmp` of the kind node is a memory filesystem, which `docker cp` does not read. The script now uses `tar` through `docker exec`.
- The first 756 window (Kata run 1) had 20 samples in its 615 s, because the sample loop needs 30.4 s for each round. The analysis now accepts a sample up to 4 s after the end mark (the load pods run 5 s more), and the later windows are 635 s.
- KWOK sends more node status patches than a kubelet (part 3). It is not changed, so all cases have the same, harder load.
- The node IPAM events (part 3) come from the kubeadm templates of gate 1 and gate 4. All three control planes have them.
- kubectl sends about 5 requests each second. The delete of 756 nodes takes 170 s, and the delete of 2,051 events of the fake nodes in the gate 4 cluster took 10 minutes. The agent stopped its first, slower delete command by its PID in the pod.
- The etcd database file of gate 4 grew from 4.1 MB to 194 MB (2.9 MB in use). No defrag ran, because the task did not permit it.

## 5. Limits, and what is not tested

- The disk: loop devices on sparse files on one NVMe disk with LUKS. No real block device and no LVM volume. The gate 4 cluster ran idle in the background during all fio tests and single node tests.
- The Kata cost looks like a fixed time for each sync (+0.3 to +0.4 ms in fio and in etcd), and it is not visible when three streams fill the disk. So on a faster disk the ratio can be higher than 1.15 while the absolute time stays low. This is an inference. A fast disk was not tested.
- Three replicas with etcd on three separate disks, and three replicas with runc.
- The load has leases, node status and ConfigMap patches only. It has no pods on the fake nodes, no kubelet watches and no list calls. The API server used 0.27 cores, against 9.1 at the site, so CPU pressure in the guest is not tested.
- Each window is 10 minutes. The Kata 756 case ran three times. The runc cases, the Kata 355 case and the three replica cases ran one time each.
- QEMU. The classes `kata-clh-runtime-rs-ovh512` and `kata-clh`, and the virtio-fs volume, have fio numbers only.
- One kind node on one machine. The load pods, the control planes and the disk share its 24 cores.

## 6. State after the work, and how to remove it

- Gate 4 cluster: healthy. `gate4/run.sh check` gives PASS before and after. The pods have the same UIDs, 0 restarts and the same boot IDs. The inner cluster has 3 nodes, 3 node leases, no load namespace and no event of a fake node. `etcdctl defrag --cluster` returns the 191 MB of free space in the database files.
- Host cluster: no gate 2 namespace, volume or pod. `/tmp/gate2` in the kind node is gone. The images `gate2-tools:1` and `registry.k8s.io/kwok/kwok:v0.7.0` stay in the kind node (`crictl rmi`) and in Docker, with `debian:trixie-slim` (`docker rmi`).
- Host: `fio` 3.41 with five libraries. Removal: `sudo apt-get remove fio libglusterfs0 libgfapi0 libgfrpc0 libgfxdr0 libnbd0`. Nothing is mounted under `/scratch/kata-cp/mnt`.
- Loop devices fio-1, spare-1, var-1, etcd-1 and etcd-2 are discarded, with no signature and 0 kB in their files. var-2 was not used.
- Files: the scripts and the patcher source in `~/notes/hosted/lab/gate2/` (`fio-run.sh`, `fio-all.sh`, `fio-three.sh`, `cp.sh`, `load.sh`, `sampler.sh`, `sample-once.sh`, `analyze.py`, `summary.py`, `repeat-kata.sh`, `host-cpu-log.sh`, `Dockerfile`, `patcher/`). Raw output is in `/scratch/kata-cp/logs/gate2/` (42 MB): `fio/summary.tsv`, `fio3/`, `etcd-summary.md`, `etcd-<case>/analysis.txt` and `samples/`, `host-cpu.log`. The patcher binary is in `/scratch/kata-cp/gate2-build/`.
- The kubeconfig copies of the test (`/scratch/kata-cp/gate2-secrets`) are deleted. No secret is in the notes, the logs or this report.
