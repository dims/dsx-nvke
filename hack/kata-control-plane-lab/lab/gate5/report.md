# Gate 5: running pods continue through a host runtime restart

Date: 2026-11-26. A test agent ran the work and returned its reports as text. The main session wrote this file. Raw output: `/scratch/kata-cp/logs/gate5/<test>-<run>/`, console output in `/scratch/kata-cp/logs/gate5/console/`, one line for each run in `/scratch/kata-cp/logs/gate5/progress.txt`.

State: done. The four restart tests pass, and the upgrade from Kata 4.3.1 to 4.4.0 passes in one full run.

## Question and pass rule

Does a running control plane in Kata pods continue when containerd, the kubelet and Kata start again on the host node? Pass: no pod restart, no etcd leader change that the restart causes, and no failed call in a loop apart from a short gap that is measured.

## Subject and method

- The subject is the gate 4 cluster in the namespace `gate4`: three replicas (`cp-a-0`, `cp-b-0`, `cp-c-0`) on the class `kata-clh-runtime-rs-fix-direct`, each with a LoadBalancer Service, and one shared API Service.
- Host: the kind node `kata-cp-control-plane`, Kubernetes v1.36.4, containerd 2.3.4, Kata 4.4.0 from the `kata-deploy` chart, Cloud Hypervisor v54.1.
- Loops, all as systemd units in the kind node or in the guests, none on the host:
  - `/readyz` of the shared address and of each replica, one new connection each 0.5 s from the node.
  - Pods, endpoints of the shared Service, node labels, runtime handlers, units and Kata processes each second.
  - In each guest: a heartbeat each 0.2 s, the etcd leader, raft term and member list each second, and `/readyz` on 127.0.0.1.
- State before and after each run, 69 values: pod UID, container ID, restart count, pod IP, guest boot ID, the PID and start time of each shim, virtiofsd and Cloud Hypervisor process, the etcd member IDs, the handler of the sandbox, the guest kernel, the open files of each Kata process, the `imports` line of the containerd configuration, and the gate 4 identity files.
- Each restart runs as a unit in the node. The host starts no `docker exec` for 10 to 30 s around it.
- A loop call is a new connection each 0.5 s. So the loops cannot see an outage shorter than about 0.5 s.

Baseline with no restart (4 runs): 0 failed calls, and the longest time between two good calls is 0.521 to 0.534 s. The heartbeat in a guest has at most 0.218 s between two samples.

## Result of the four restart tests

13 runs with running replicas. 0 failed calls in 9,354 calls. No etcd leader or term change, no pod restart, the same guest boot IDs, and the same shim, virtiofsd and Cloud Hypervisor processes in each run. The longest time between two good calls was 0.557 s.

Times are UTC. "Gap" is the longest time between two good calls of `/readyz` (shared address, cp-a, cp-b, cp-c). "Values" is the count of state values that differ before and after, of 69.

| Run | Start | Gap shared, a, b, c (s) | Failed calls | Leader/term before, after | Pod restarts before, after | Boot IDs kept | Values | What changed on the node |
|---|---|---|---|---|---|---|---|---|
| Baseline 3 | 12:25:06 | 0.531, 0.528, 0.528, 0.527 | 0 of 480 | cp-b/9, cp-b/9 | 4,4,4, 4,4,4 | 3 of 3 | 0 | Nothing |
| containerd 1 | 12:26:59 | 0.522, 0.526, 0.524, 0.526 | 0 of 598 | cp-b/9, cp-b/9 | 4,4,4, 4,4,4 | 3 of 3 | 0 | containerd PID 304 to 195441 |
| containerd 2 | 12:28:50 | 0.536, 0.535, 0.534, 0.538 | 0 of 596 | cp-b/9, cp-b/9 | 4,4,4, 4,4,4 | 3 of 3 | 0 | containerd PID to 215327 |
| containerd 3 | 12:30:33 | 0.523, 0.523, 0.521, 0.521 | 0 of 600 | cp-b/9, cp-b/9 | 4,4,4, 4,4,4 | 3 of 3 | 0 | containerd PID to 235306 |
| kubelet 1 | 12:32:19 | 0.522, 0.523, 0.521, 0.523 | 0 of 752 | cp-b/9, cp-b/9 | 4,4,4, 4,4,4 | 3 of 3 | 0 | kubelet PID 512 to 255834 |
| kubelet 2 | 12:34:26 | 0.525, 0.521, 0.522, 0.533 | 0 of 756 | cp-b/9, cp-b/9 | 4,4,4, 4,4,4 | 3 of 3 | 0 | kubelet PID to 279577 |
| kubelet 3 | 12:36:23 | 0.522, 0.523, 0.524, 0.522 | 0 of 756 | cp-b/9, cp-b/9 | 4,4,4, 4,4,4 | 3 of 3 | 0 | kubelet PID to 303370 |
| `kata-deploy` job mode 1 | 12:38:23 | 0.524, 0.525, 0.525, 0.524 | 0 of 840 | cp-b/9, cp-b/9 | 4,4,4, 4,4,4 | 3 of 3 | 0 | 85 of 86 files of `/opt/kata` written again. No containerd restart |
| `kata-deploy` job mode 2 | 12:49:17 | 0.524, 0.526, 0.543, 0.523 | 0 of 840 | cp-b/9, cp-b/9 | 4,4,4, 4,4,4 | 3 of 3 | 0 | The same |
| `kata-deploy` job mode 3 | 13:00:11 | 0.525, 0.524, 0.525, 0.525 | 0 of 844 | cp-b/9, cp-b/9 | 4,4,4, 4,4,4 | 3 of 3 | 0 | The same |
| `kata-deploy` job mode, forced restart | 13:11:05 | 0.526, 0.525, 0.524, 0.524 | 0 of 840 | cp-b/9, cp-b/9 | 4,4,4, 4,4,4 | 3 of 3 | 0 | 85 files written again, containerd PID 235306 to 412870 |
| `kata-deploy` DaemonSet 1 | 13:17:40 | 0.550, 0.548, 0.557, 0.524 | 0 of 644 | cp-c/11, cp-c/11 | 0,0,0, 0,0,0 | 3 of 3 | 0 | 85 files written again, containerd PID 434191 to 448676 |
| `kata-deploy` DaemonSet 2 | 13:19:41 | 0.525, 0.526, 0.528, 0.524 | 0 of 644 | cp-c/11, cp-c/11 | 0,0,0, 0,0,0 | 3 of 3 | 0 | 85 files written again, containerd PID to 470922 |
| `kata-deploy` DaemonSet 3 | 13:21:34 | 0.524, 0.526, 0.545, 0.536 | 0 of 644 | cp-c/11, cp-c/11 | 0,0,0, 0,0,0 | 3 of 3 | 0 | 85 files written again, containerd PID to 493070 |
| Baseline 4 | 13:25:52 | 0.524, 0.523, 0.524, 0.525 | 0 of 480 | cp-a/12, cp-a/12 | 0,0,0, 0,0,0 | 3 of 3 | 0 | Nothing |

- The rows for DaemonSet mode and baseline 4 have restart count 0 and another leader, because the replicas are new pods after a mode change. A mode change needs an uninstall, and the replicas were at 0 for it on purpose.
- In each guest: `/readyz` on 127.0.0.1 had 0 failed calls, the etcd status had 0 samples with no answer and one value of leader and term, and the member list had one value. The longest time between two heartbeat samples over all runs was 0.223 s.
- No change of pod readiness, of the endpoints of the shared Service, of the node labels or of the handler list in any run.
- The gate 4 identity files (certificates, keys, etcd members) are the same before and after in each run.
- containerd down time, from its journal: 0.153 to 0.195 s in 7 restarts.
- kubelet: 0.050 to 0.064 s from stop to start. Its health address answered 0.28 to 0.30 s after the restart command. The Ready condition of the node pods kept its time, so the new kubelet did not report them as not ready.

## What each `kata-deploy` mode did (seen)

Job mode, the same version again (`helm upgrade` with the 4.4.0 chart and the lab values, runs 1 to 3):

- One run took 41 s. 15 s of that is the wait of the dispatcher for a stable node list.
- The installer extracted all 10 components in about 1 s. 85 of 86 files and links of `/opt/kata` got a new change time. The one file not written is `/opt/kata/containerd/config.d/kata-deploy.toml`.
- The running shim, virtiofsd and Cloud Hypervisor kept their PIDs. Their program files then show "(deleted)". The processes run on the old files.
- The installer did not restart containerd. Its log: "CRI config for containerd is unchanged from a previous attempt, and containerd has been up since it was written. Skipping the (self-terminating) restart".
- The containerd configuration kept its content and time. The `imports` line and the 10 handlers are the same. The node labels did not change.
- Forced run: with a newer time on the drop-in file, the installer restarted containerd one time. The replicas continued.

DaemonSet mode, `kubectl rollout restart daemonset/kata-deploy` (runs 1 to 3). This is the upstream test for Kata issue 12761:

- The old pod at its stop: "DaemonSet 'kata-deploy' still selects this node, skipping all cleanup to avoid disrupting a rolling restart".
- The new pod extracted all components (85 files written again), restarted containerd one time, and logged "node is already labelled, skipping". The rollout took 10.8 to 11.3 s.
- The `imports` line and the handlers did not change.

Uninstall (one time in each mode, with the replicas at 0):

- The `imports` line after it: `imports = [ "/opt/kata-fix/containerd-kata-fix.toml"]`. The entry and the drop-in file of `kata-deploy` are gone.
- `/opt/kata` has 0 entries. `/opt/kata-fix` has its 10 entries, not changed.
- containerd restarted one time. The node labels and the four RuntimeClasses of the chart are gone. The five lab classes stay.
- The containerd configuration and the node still list the four extra handlers while `/opt/kata` is empty. Their shim path does not exist then.
- The uninstall took 17.6 s in job mode and 5.8 s in DaemonSet mode.

Install after the uninstall:

- The `imports` line after it: `imports = [ "/opt/kata-fix/containerd-kata-fix.toml", "/opt/kata/containerd/config.d/kata-deploy.toml"]`. The installer added its entry at the end, so the order is the reverse of the first install.
- 86 files in `/opt/kata`, one containerd restart, all 10 handlers. A test pod on the class of record started at once.
- Each mode change: replicas down 21 s, ready again 23 s after the apply, about 100 s with no replica. The identity files differ only in the pod IP and the boot ID.

What a site that carries the patched agent can take from it:

- No `kata-deploy` action changed `/opt/kata-fix`, its entry in the `imports` line or the four extra handlers. A custom handler in its own file and folder stays through an install, a restart and an uninstall.
- An uninstall empties `/opt/kata`. The extra handlers then point to a shim that is absent until the next install. So no Kata pod may run during an uninstall.
- The install and rollback scripts of the extra handlers (`/scratch/kata-cp/images/kata-fix/plan/01-install.sh` and `03-rollback.sh`) depend on the form of the `imports` line. After one uninstall and install the order of its entries is different, and the rollback script then matches nothing. That is a deduction from the script text. The scripts are not changed.

## Upgrade from Kata 4.3.1 to 4.4.0

One full run in job mode, on 2026-11-26 from 13:30 to 13:57 UTC. Davanum chose one run, not three. Each step passes.

The replicas must run on a 4.3.1 guest while the upgrade happens. The patched guest image fits 4.4.0 only. So for this test the replicas used the stock handler `kata-clh-runtime-rs` of 4.3.1, through the class `kata-clh-runtime-rs-ovh512`. The 512 Mi overhead is a value of the RuntimeClass object. The runtime, the shim and the guest image were stock 4.3.1. The StatefulSets had the `init` cgroup step and the 10 s stop timeout.

| Step (log folder) | Time (UTC) | Gap shared, a, b, c (s) | Failed calls | Leader/term before, after | Pod restarts | Boot IDs kept | What changed |
|---|---|---|---|---|---|---|---|
| `t4-to-old-1` | 13:30:02 to 13:36:35 | No loop | No loop | cp-a/12, cp-a/15 | 0,0,0 (new pods) | 0 of 3, by design | Replicas to 0, uninstall of 4.4.0, install of 4.3.1, replicas up on 4.3.1 |
| `t4-baseline-431-1` | 13:37:11 | 0.533, 0.529, 0.530, 0.525 | 0 of 480 | cp-a/15, cp-a/15 | 0,0,0 | 3 of 3 | Nothing (control run on 4.3.1) |
| `t4-upgrade-1` | 13:46:01 | 0.527, 0.525, 0.528, 0.527 | 0 of 956 | cp-a/15, cp-a/15 | 0,0,0 | 3 of 3 | Kata 4.3.1 to 4.4.0. 77 files written again, 8 new, 9 not touched. containerd keeps its PID |
| `t4-mixed-containerd-1` | 13:48:57 | 0.524, 0.521, 0.527, 0.524 | 0 of 596 | cp-a/15, cp-a/15 | 0,0,0 | 3 of 3 | containerd PID 542670 to 602914 |
| `t4-new-pod-1` | 13:50:33 to 13:51:51 | No loop | No loop | cp-a/15, cp-a/15 | 0,0,0 | 2 of 3: cp-c is new, by design | A test pod on stock 4.4.0. Follower cp-c made again on 4.4.0 |
| `t4-to-record-1` | 13:52:09 to 13:54:42 | No loop | No loop | cp-a/15, cp-b/16 | 0,0,0 (new pods) | 0 of 3, by design | cp-b, cp-c, then the leader cp-a moved to the class of record |
| `t4-baseline-final-1` | 13:55:18 | 0.524, 0.524, 0.542, 0.525 | 0 of 480 | cp-b/16, cp-b/16 | 0,0,0 | 3 of 3 | Nothing (control run on the end state) |

- In the three runs with a loop and running replicas, the compare step found no difference in 69 state values, and the gate 4 identity files were the same.
- The leader changed one time, in `to-record`, when the pod of the leader cp-a was deleted. That is the planned replace.

What the upgrade did to the running Kata pods (seen):

- Before the upgrade each replica had one shim, two virtiofsd processes and one Cloud Hypervisor, with programs in `/opt/kata`. Each Cloud Hypervisor held the 4.3.1 guest image `/opt/kata/share/kata-containers/kata-ubuntu-resolute.image` open.
- After the upgrade all 12 processes run with the same PID and start time. The program file of each one shows "(deleted)". Each Cloud Hypervisor holds the old image file, also "(deleted)". The file with that name is now the 4.4.0 image.
- The guests are the same: guest kernel 6.18.56 and the same boot IDs. `kubectl exec` into the 4.3.1 guests worked after the upgrade and after the containerd restart.
- The last 4.3.1 guest ran 7 minutes on replaced files.
- containerd restart in that state, the case of Kata issue 12761: containerd was down 0.141 s. Its journal has 0 lines with a cleanup, a leaked or dead shim, or a load failure. The shims, the hypervisors and the guests are the same after it.
- A 4.3.1 pod that stops after the upgrade: the delete took 11.4 to 11.5 s, as before the upgrade, and no process of the old sandbox stayed.
- A new pod on 4.4.0 started (guest kernel 6.18.62). The follower made again on 4.4.0 had `/readyz` through its Service 18.6 s after the delete, with the same etcd member ID and the same certificates.
- For two minutes the cluster had two replicas on 4.3.1 guests and one on a 4.4.0 guest, with the leader and the term not changed.

What the upgrade did to the files and to containerd (seen):

- `helm upgrade` with the 4.4.0 chart and the lab values took 40.9 s. The installer extracted all 10 components in about 1 s.
- `/opt/kata`: 86 files and links before, 94 after. 77 have a new change time, 8 are new (the kernel files of 6.18.62), and 0 are gone.
- 9 were not touched: the containerd drop-in file, and 8 kernel files that only 4.3.1 had (417 MB). The installer removes no file that the new release does not ship, so old kernel files stay after each upgrade.
- containerd did not restart, because the drop-in file of `kata-deploy` is the same in 4.3.1 and 4.4.0.
- The `imports` line, the 10 handlers and the node labels did not change. `/opt/kata-fix` was not touched.
- The extra handlers worked after the upgrade with no run of their install script. A test pod on the class of record started.

The step to 4.3.1, for the record:

- Uninstall of 4.4.0 in job mode: the dispatcher set the two node labels to `false`, the installer removed the containerd entries, restarted containerd and emptied `/opt/kata`. 19.5 s.
- Install of 4.3.1: 114 s with one image pull (1.89 GB), and one containerd restart.
- The three replicas ran on 4.3.1 at the first try (guest kernel 6.18.56, Cloud Hypervisor v54.0), from their volumes, as the same cluster.

Left on the node after the test: the 8 kernel files of 4.3.1 in `/opt/kata` (417 MB), and the images `kata-deploy:4.3.1` (1.89 GB) and `kubectl:latest` (26 MB) in the image store of the kind node.

## Faults of the harness

No test failed. Three faults of the harness, each one fixed, and none changed a result:

1. The first job mode run reported "76 files with the same inode". The file system gives a new file the inode number of the file that was just removed. The harness now compares change times.
2. The uninstall in job mode left no log of its cleanup Job, because the pods go away with the hook. The node state before and after and the containerd journal are the evidence for that step. The harness now follows the logs during an uninstall.
3. A warning of awk in the compare step. Fixed.

## Not tested

- More than one upgrade run, and an upgrade in DaemonSet mode.
- An upgrade that changes the containerd drop-in file of `kata-deploy`. Here the file was the same, so the upgrade had no containerd restart. The forced restart run covers that path for one version only.
- A 4.3.1 guest that runs for hours or days on replaced files, a container restart in place in such a guest, and a kubelet restart in that state.
- A rollback from 4.4.0 to 4.3.1 with running pods.
- The stock 130 Mi overhead under 4.3.1.
- A second job mode run while the Job of the run before exists. Each run waited about 10 minutes for the end of that Job.
- A containerd restart or a new Kata pod during the one second in which the installer writes the files.
- A kubelet restart during a `kata-deploy` run.
- Connections that stay open (watches, exec sessions). Each loop call is a new connection.
- The Go runtime, QEMU, a node under load, a host cluster with more than one node.
- An uninstall with running Kata pods. It was not done on purpose.

## Files

- `g5.sh` (loops, state, compare, analysis), `lib.sh`, `analyze.sh`, `table.sh`, `bg.sh` (start a test detached from the session), `t0-baseline.sh`, `t1-containerd.sh`, `t2-kubelet.sh`, `t3a-kata-deploy-job.sh`, `t3b-kata-deploy-daemonset.sh`, `t4-upgrade.sh`, and `node/` (scripts that run in the node and in the guests). The originals are in `/scratch/kata-cp/work/gate5/`.
