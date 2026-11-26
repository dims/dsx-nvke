# Memory overhead of a Kata pod: follow-up report

Date 2026-11-25. Kata 4.4.0, Cloud Hypervisor v54.1, host kernel 7.0.0-44, one kind node. The scripts are `overhead-test.sh`, `mem-sampler.sh` and `kata-extra-tests.sh` in `~/notes/hosted/lab/gate1-nvke/`. The logs are in `/scratch/kata-cp/logs/gate1-nvke/overhead/`. No Kata file changed and nothing restarted. The agent that ran the tests wrote this report, and the main session saved it.

A larger overhead removes the kill for a guest that fills its memory by reading. It does not remove the kill when the guest then writes a burst to a block volume. In that case the kernel killed the hypervisor with 256Mi, 512Mi, 1Gi and 2Gi of overhead. The likely fix for writes is a Kata configuration value, which is not tested here.

## Results

Each test used a plain pod with the Rust runtime unless the row says otherwise. The load read 10 GiB from the raw block volume, 10 GiB from a sparse file on the virtio-fs root, and all 6700 files of the image, in rounds. The guest size is the limit plus `overhead_memory = 32` MiB. Each row is one run unless it gives a count.

| Runtime | Limit | Overhead | Guest size | Load | Result | Peak of pod cgroup | Outside the guest, not reclaimable (anon plus kernel) |
|---|---|---|---|---|---|---|---|
| rs | 8Gi | 130Mi (stock) | 8224 MiB | read | Killed after about 15 s | 8322 MiB, the limit | 113 MiB |
| rs | 8Gi | 160Mi | 8224 MiB | read | 1 survived 120 s, 1 killed after about 12 s | the limit | 120 MiB |
| rs | 8Gi | 192Mi | 8224 MiB | read | Survived 120 s | the limit | 118 MiB |
| rs | 8Gi | 256Mi | 8224 MiB | read, and read plus small `dsync` writes | Survived 120 s and 150 s | the limit | 119 and 124 MiB |
| rs | 8Gi | 2Gi | 8224 MiB | read | Survived 120 s | 10240 MiB, the limit | 120 MiB |
| rs | 2Gi | 130Mi | 2080 MiB | read | Survived 120 s | the limit | 55 MiB |
| rs | 4Gi | 130Mi, 192Mi, 2Gi | 4128 MiB | read | Survived 120 s, 3 of 3 | the limit | 77 to 78 MiB |
| rs | 12Gi | 512Mi | 12320 MiB | read | Survived 120 s | 12800 MiB, the limit | 160 MiB |
| rs | 8Gi | 256Mi, 512Mi, 1Gi, 2Gi | 8224 MiB | read, then a 3 GiB write to the block volume | Killed in the first round, 4 of 4 | the limit | 103 to 112 MiB |
| rs | 4Gi | 512Mi | 4128 MiB | read, then a 3 GiB write | Killed in the first round | the limit | 71 MiB |
| rs | 8Gi | 2Gi | 8224 MiB | read, then a 1 GiB write each round | Killed in round 2 | the limit | 141 MiB |
| rs | 8Gi | 512Mi | 8224 MiB | read, then a 128 MiB write each round | Survived 120 s, 19 rounds | the limit | 125 MiB |
| rs, node pod after `kubeadm init` | 8Gi | 512Mi | 8224 MiB | read fill, then a 3 GiB file on `/var` | Survived the fill with the gate 1 rules still met, then killed by the write | the limit | 87 MiB before the write |
| go (`kata-clh`) | 8Gi | 130Mi | 10240 MiB | read | Survived, 2 of 2 | 0 MiB | Not in the pod cgroup |

- Numbers at the stock kill: `memory.max` 8322 MiB and `memory.current` 8319 to 8322 MiB. The kernel report gave anon 8, file 8209 (shmem 8200), and kernel 105 MiB (page tables 48, slab 56). RSS was 8202 MiB for cloud-hypervisor, 7826 MiB and 2 MiB for the two virtiofsd processes, and 26 MiB for the shim. The large virtiofsd maps the guest memory, so the cgroup counts those pages one time.
- With a full guest the pod cgroup stays at its limit in each Rust test, because the page cache of the host for the volume and for virtio-fs fills the rest. `memory.events` showed more than 100000 limit hits with no kill, so the count of limit hits is no sign of danger.
- The memory outside the guest grows with the guest. Page tables for the hypervisor, for virtiofsd and for the second-level mapping, plus slab, add about 10 MiB for each GiB. The use above the pod limit that reclaim cannot free was 80, 89, 133 and 170 MiB at 2, 4, 8 and 12 Gi.

## Answers

- Smallest overhead that survived the read load at 8Gi: 160Mi survived one time of two, so it is not stable. 192Mi survived 1 of 1, and 256Mi survived 2 of 2. The stock 130Mi is enough at 2Gi and 4Gi and too small at 8Gi.
- Rule for the read case: the overhead must be at least about 60Mi plus 1 percent of the memory limit. With a margin of about two, the recommended rule is 100Mi plus 2 percent of the limit. It gives 264Mi at 8Gi and 428Mi at 16Gi, so 512Mi covers limits up to about 20Gi.
- Level of the fix for the read case: a RuntimeClass object setting. The kata-deploy chart sets it with `shims.clh-runtime-rs.runtimeClass.overhead.memory`. No Kata configuration value and no source change is necessary.
- The upstream document `docs/how-to/how-to-size-sandbox-overhead-runtime-rs.md` gives no number. It says that `podFixed` must cover the guest overhead (`overhead_memory`) plus the host side, that larger VMs need more, and that an operator must measure the host cgroup use minus the nominal VM size. The stock values leave 98 MiB for the host side.
- Write bursts: no tested overhead protects. Each kill came from an I/O worker thread of the hypervisor with `GFP_NOIO`. In six of the seven write kills the kernel report shows dirty file cache of the host in the pod cgroup (140 to 1871 MiB), which was most or all of the file cache that remained. In the 1Gi case it shows 919 MiB of file cache and no dirty pages, so dirty pages do not explain each kill, and the cause is not proven. The shipped configuration has `block_device_cache_direct = false`, so the hypervisor writes a volume through the page cache of the host, and those pages are charged to the pod cgroup. The candidate fix is `block_device_cache_direct = true` for the shim, which is a Kata configuration value. The upstream document names the chart key `shims.<shim>.dropIn` for such a value. The annotation list of the shim does not permit the setting for one pod.
- Go runtime: the shim and both virtiofsd processes run in `/kata_overhead/<sandbox ID>`, and cloud-hypervisor runs in a cgroup `/kubelet-kubepods-pod<UID>.slice` at the root of the node tree, which is not the pod cgroup of the kubelet. Neither cgroup has memory files, `/kata_overhead` has `memory.max = max`, and the pod cgroup reads 0. So no limit applies and no kill occurs, and the kubelet does not account the memory. The guest gets 2048 MiB plus the limit, and virtiofsd had 9045 MiB RSS at the end of the fill.

## Not tested

- `block_device_cache_direct = true`, or any other Kata configuration value.
- A write burst to the virtio-fs root, a network load, more than 6700 files on virtio-fs, and a run longer than 5 minutes.
- Limits above 12Gi, the QEMU shims, and the Go runtime with a write burst or under memory pressure of the node.
- Three runs of each row. Most rows have one run.

## State after the work

- One extra RuntimeClass stays for the next gates: `kata-clh-runtime-rs-ovh512` (handler `kata-clh-runtime-rs`, 512Mi, 250m, the stock node selector). Remove it with `kubectl delete runtimeclass kata-clh-runtime-rs-ovh512`. The other six are deleted. `runtimeclasses-overhead.yaml` has all seven.
- The namespace and the volume of the tests are gone. var-2 and etcd-2 are wiped. var-1 and etcd-1 were not in use. The kind node has `mem-sampler.sh` in `/var/lib/gate1-nvke/bin`. The namespace `gate1-nvke-spire` is as before.
