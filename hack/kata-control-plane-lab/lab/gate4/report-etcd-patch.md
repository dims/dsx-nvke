# Phase 1, step 2: the etcd settings from a kubeadm patch file

Date: 2026-11-26, 09:37 to 09:58 local time. The main session ran the test. Raw output: `/scratch/kata-cp/logs/gate4/patch-run-1` to `patch-run-3`, with the files `patch-run-*.out`.

## Question

The gate 4 design needs two etcd settings: etcd listens on `0.0.0.0`, and etcd does not compare a peer certificate with the source address (`peer-skip-client-san-verification=true`). NVKE has no API field and no setting for etcd arguments (`controller/internal/kubeadmconfig/init.go:225-239`). NVKE does set the kubeadm patches folder `/etc/kubernetes/patches` for init and for join, and the agent does not clean that folder (`results/phase1-source-reading.md`, section "kubeadm rendering").

Can a patch file in the pod give the two settings, with no etcd argument in the kubeadm config? If yes, the first NVKE run of phase 1 needs no NVKE code change for etcd.

## Method

- `run.sh` has the option `ETCD_PATCH=1`. Before `kubeadm init` and before each join it writes the file `/etc/kubernetes/patches/etcd+json.json` into the pod. The kubeadm config names the patches folder (`patches.directory` in the init and in the join configuration), as NVKE does.
- The file is a JSON patch that adds three arguments at the end of the etcd command:

```
[
  {"op": "add", "path": "/spec/containers/0/command/-", "value": "--listen-client-urls=https://0.0.0.0:2379"},
  {"op": "add", "path": "/spec/containers/0/command/-", "value": "--listen-peer-urls=https://0.0.0.0:2380"},
  {"op": "add", "path": "/spec/containers/0/command/-", "value": "--peer-skip-client-san-verification=true"}
]
```

- The kubeadm config has no etcd argument in this mode (`ETCD_LISTEN=default ETCD_SAN_SKIP=0`). Each run is a full gate 4 run from empty volumes with the class `kata-clh-runtime-rs-fix-direct`.
- A patch that adds at the end does not depend on the position of an argument. NVKE adds etcd arguments of its own, so a patch by position is not safe.

## Result

Pass in 3 of 3 runs. Each run passes the join of three replicas, the checks of steps 3 and 6, the peer check, the replace of a follower, of the leader and of a bare Pod, and a restart in place.

Evidence:

- kubeadm at init and at each join: `[patches] Found the following patch files: [etcd+json.json]` and `[patches] Applied patch of type "application/json-patch+json" to target "etcd"`.
- The etcd command of a replica has the two listen URLs that kubeadm writes (`--listen-client-urls=https://127.0.0.1:2379,https://172.30.255.211:2379` and `--listen-peer-urls=https://172.30.255.211:2380`), and after them the three arguments of the patch file.
- etcd uses the last value of an argument that is given two times. The sockets in the pod are `*:2379` and `*:2380`.
- 0 lines "rejected connection on peer endpoint" in the etcd logs of all replicas in all runs.

Times, the same as with the arguments in the kubeadm config:

| Event | Run 1 | Run 2 | Run 3 |
|---|---|---|---|
| Join of replica b | 21.9 s | 21.9 s | 21.7 s |
| Join of replica c | 9.1 s | 8.4 s | 21.6 s |
| Follower replace: delete to three healthy etcd endpoints | 29.2 s | 30.0 s | 30.5 s |
| Leader replace: delete to three healthy etcd endpoints | 28.6 s | 29.7 s | 29.9 s |
| Calls to the shared address that are not 200 during the replaces | 0 of 95 | 0 of 94 | 0 of 96 |

## What it means for NVKE

- The image or the wrapper of a pod host can carry this one file. NVKE then needs no change for the etcd settings.
- It is a setting outside NVKE. NVKE does not know it, and an operator cannot see it in the cluster request. The clean form is still the two arguments in the renderer of NVKE.
- The file must be present before `kubeadm init`, before a join and before a kubeadm upgrade. In the lab `/etc/kubernetes` is on a volume, so the file stays through a new pod.

## Not tested

- The patch file together with the kubeadm files that NVKE writes into the same folder. Step 5 of phase 1 tests that.
- A kubeadm upgrade with the patch file.
- etcd 3.5, where the flag has the name `experimental-peer-skip-client-san-verification`.
