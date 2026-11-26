# Gate 1, step 1: the runc baseline

Date: 2026-11-25. Place: the kind node `kata-cp-control-plane` on `ubuntu-box`. The agent that ran the tests wrote this report, and the main session saved it.

## Result

One pod with the default runtime (runc) is a kubeadm control plane node. The pod passed all five pass rules in three full runs from empty volumes. One rehearsal with the same code also passed. Nothing of gate 1 runs now.

The files are in `~/notes/hosted/lab/gate1/`:

- `run.sh` is the run script. Its head lists the steps and the variables.
- `wrapper.sh` is the container command. It runs before the kind entrypoint.
- `node-pod.yaml.tmpl` has the Service and the pod.
- `volumes.yaml.tmpl` has the two PersistentVolumes and the two claims.
- `kubeadm.yaml.tmpl` is the kubeadm config.

The Kata step changed these files later. A copy of the files of the baseline is in `/scratch/kata-cp/logs/gate1/lab-files-at-runc-baseline`. One full runc run with the final files passed (`runc-regression-final`).

The logs are in `/scratch/kata-cp/logs/gate1/`:

- `run-1`, `run-2` and `run-3` are the three formal runs.
- `dev2` is the rehearsal.
- `dev1` is the first test. Three wrapper steps were off in that test.
- `00-kind-load.log` is the image load.

Each run folder has `times.txt`, `summary-times.txt`, `preflight.txt`, `kubeadm-init.txt`, `kubeadm.conf`, `check-<n>.txt`, `identity-<n>.txt`, `pod-log-<n>.txt`, `pod.yaml`, `versions.txt` and `journal.txt`. The file `pod-log-<n>.txt` has the output of the wrapper and of the kind entrypoint. The file `pod.yaml` has the full pod spec.

## The pod

- Namespace `gate1`, one Pod `cp`, one ClusterIP Service `cp` on port 6443.
- One privileged container with the image `kindest/node:v1.36.4`. The limits are 4 CPUs and 8 Gi. The pod uses no host network and no host PID namespace.
- Memory volumes (emptyDir) for `/run` and `/tmp`.
- Two raw block volumes (`volumeDevices`). They are `/dev/loop22` (var-3) and `/dev/loop26` (etcd-3), offered as local PersistentVolumes with `volumeMode: Block`.
- A ConfigMap with `wrapper.sh` as the container command.
- `/lib/modules` of the kind node, read only. The variable `LIB_MODULES` removes it.

## Pass rules

`run.sh check` prints and tests each rule. The lines below are from `run-3/check-4-after-new-pod.txt`.

| Rule | Command | Output | Result |
|---|---|---|---|
| 1. `/readyz` through the Service | `docker exec kata-cp-control-plane curl -sk https://10.96.84.207:6443/readyz` | `ok (http 200)` | Pass in all 12 checks |
| 2. etcd is healthy | `crictl exec <etcd> etcdctl ... endpoint health` in the pod | `https://127.0.0.1:2379 is healthy: successfully committed proposal: took = 13.37ms` | Pass |
| 3. The node is in the inner cluster | `kubectl get nodes` in the pod | `cp NotReady control-plane v1.36.4 10.244.0.44 containerd://2.3.4` | Pass |
| 4. The control plane returns after a restart | See below | No manual step | Pass |
| 5. Three full runs | `run-1.out`, `run-2.out`, `run-3.out` | Each file has four lines `RESULT ...: PASS` and `rc=0` | Pass |

The node is NotReady because the cluster has no CNI. The plan expects that state.

Each run tested three restart types for rule 4:

- `crictl stop --timeout 20 <container>` in the kind node. The restart count went from 0 to 1. The check printed "identity: no difference from the first check".
- `systemctl poweroff` in the pod. The restart count went from 1 to 2. The check found no difference.
- A delete of the pod and a new pod with the same claims. The new pod had a new IP. The check found two differences, the pod IP and `apiserver.crt`.

The identity that the check compares is this list:

- The sha256 of `ca.crt`, `sa.pub`, `front-proxy-ca.crt`, `etcd/ca.crt`, `etcd/server.crt`, `etcd/peer.crt`, `apiserver-kubelet-client.crt` and `apiserver.crt`.
- The etcd member ID.
- The UID of a marker ConfigMap that the run makes after the init.
- The machine ID, the product UUID and the UID of the node object.

Limit of rule 4: a new pod has a new IP. The kind entrypoint then makes a new API server certificate from the same CA. The pod log shows the lines "detected old IPv4 address: 10.244.0.43" and "clearing and regenerating the certificate for serving the Kubernetes API". So the certificates are the same after a container restart. After a new pod, one certificate is new. Gate 4 owns the node address.

## Paths outside /var

Method: after the init, the agent listed the overlay upper folder of the container in the kind node. The list shows each file that the node wrote outside a volume. It is in `dev1/rootfs-upperdir-after-init.txt`.

The wrapper keeps three paths on the `/var` volume, under `/var/lib/g1-state`:

| Path | How | Necessary |
|---|---|---|
| `/etc/kubernetes` | Bind mount | Yes. It has the certificates, the kubeconfig files and the static pod manifests |
| `/kind` | Bind mount. The wrapper copies the image files (bin, manifests, version) over it at each start | Yes for a new pod IP. The entrypoint reads `/kind/old-ipv4` and `/kind/kubeadm.conf` to repair the address. The folder also keeps `product_uuid` |
| `/etc/machine-id` | The wrapper keeps one UUID and exports it as `container_uuid`. systemd then logs "Initializing machine ID from container UUID" | Optional. Without it the ID changed at each start, and the control plane still returned (`dev1`) |

`/run` and `/tmp` must be empty at each start. An emptyDir volume lives as long as the pod, so a new container gets the files of the old container. In `dev1` the cleanup was off. One restart left 63 old entries in `/run`, for example shim sockets and container IO folders. The control plane still returned in that test. The wrapper now makes the two folders empty, as a machine start does.

The entrypoint or systemd writes these paths again at each start, so they need no volume:

- `/etc/alternatives/iptables*` and `ip6tables*`
- `/etc/resolv.conf.original`
- `/etc/systemd/system.conf.d/proxy-default-environment.conf`
- `/etc/containerd/config.toml` (the snapshotter line)
- `/etc/ld.so.cache` and `/etc/.updated`
- `/usr/bin/mount` and `/usr/bin/umount` (the file mode)
- `/usr/libexec/kubernetes/kubelet-plugins/volume/exec` (an empty folder)
- `/root/.kube/cache` (the cache of kubectl)

The kubelet keeps its files in `/var/lib/kubelet` and `/etc/kubernetes`. Its unit files are image content. `/etc/cni/net.d` is empty, and nothing wrote to `/opt/cni/bin`, because gate 1 has no CNI. A CNI is not tested.

## kubeadm preflight

Each run ran `kubeadm init phase preflight` with no ignore flag. The output is in `preflight.txt` of each run.

| Finding | Cause | Action |
|---|---|---|
| WARNING Swap | The host has swap | `failSwapOn: false` is necessary here |
| ERROR SystemVerification, "failed to parse kernel config: unable to load kernel module configs" | The check needs the kernel config file. The Ubuntu kernel has no `/proc/config.gz`, and `/boot` of the host is not in the kind node | Ignore flag |
| ERROR DirAvailable--var-lib-etcd (in `dev1` only) | The new ext4 filesystem has a `lost+found` folder | The wrapper removes the folder while etcd has no data. It is a workaround |

Proof for SystemVerification: with `/boot/config-7.0.0-44-generic` copied into the pod, the error went away. The output is in `dev1/preflight-with-kernel-config-diagnostic.txt`. All cgroup lines of the check say "enabled".

The only necessary flag is `--ignore-preflight-errors=SystemVerification`. The variable is `IGNORE_PREFLIGHT`. An empty value gives no flag.

The preflight also pulls `registry.k8s.io/pause:3.10.2` (321 kB, 1 second). The image has `pause:3.10` only, and kubeadm 1.36.4 lists 3.10.2. So each of the five baseline runs made one small pull from the network, one at a time. kind does not pull, because it skips the preflight phase.

## Numbers

Times are in seconds. Memory is `memory.current` of the pod cgroup in the kind node, in MiB.

| Run | Pod create to node up | Pod create to `/readyz` | crictl stop to `/readyz` | poweroff to `/readyz` | New pod create to `/readyz` | Memory after init (anon, file, peak) | Memory after restarts |
|---|---|---|---|---|---|---|---|
| 1 | 2.6 | 12.9 | 28.7 | 109.1 | 8.5 | 880 (332, 510, 930) | 588 to 590 |
| 2 | 2.6 | 11.6 | 28.6 | 110.2 | 6.5 | 890 (341, 514, 928) | 570 to 582 |
| 3 | 2.6 | 11.6 | 26.6 | 112.4 | 8.6 | 908 (352, 521, 953) | 582 to 588 |

Versions:

- Kind node: Kubernetes v1.36.4, containerd 2.3.4, kernel 7.0.0-44-generic.
- Pod: kubeadm and kubelet v1.36.4, containerd 2.3.4, runc 1.4.3, systemd 257.13, etcd 3.6.8.
- The snapshotter in the pod is overlayfs on ext4.

## What failed or surprised, with the cause

1. `kind load docker-image` failed with "ctr: content digest sha256:10210eab...: not found". The Docker image store saves the index of all platforms, but it has the amd64 content only. kind imports with `--all-platforms`. The fix needs no network: `docker save --platform linux/amd64 kindest/node:v1.36.4 | docker exec -i kata-cp-control-plane ctr -n k8s.io images import --digests -`.
2. Main finding: containerd gives a privileged container the cgroup namespace of the node. A probe pod showed the same namespace ID in the pod and in the kind node, and `/sys/fs/cgroup` in the pod was the whole tree of the node. A kubelet with `cgroupRoot: /kubelet` in the pod then works on `/kubelet.slice/kubelet-kubepods.slice` of the kind node. Its cleanup of unknown pod cgroups can stop the pods of the host cluster. The agent found the problem before any kubelet started in a pod. The wrapper runs `unshare --cgroup` as PID 1 and mounts cgroup2 again. After the init, the inner kubelet was below the scope of the container, and the tree of the kind node had the host pods only. Docker does the same for kind with `--cgroupns=private`.
3. A `kubectl exec` process stays in the cgroup namespace of the node. runc joins only the namespaces of the container config. kubeadm is not affected, because systemd starts the kubelet. Do not start a node service from an exec session.
4. A clean stop does not end by itself. systemd stops all container scopes together. etcd stops at once, and kube-apiserver does not exit while etcd is down. systemd waits 90 seconds for the scope of the API server. So `crictl stop` and a pod delete use the full grace period and end with a kill (exit code 137). A poweroff takes about 105 seconds. `terminationGracePeriodSeconds` is 20 (variable `GRACE`). Docker gives a kind node 10 seconds. etcd got its SIGTERM each time. The later variable `STOP_TIMEOUT=10` makes the node stop by itself in 12 seconds (`runc-stop-timeout-10`).
5. With runc, the privileged pod sees each device of the host, for example `/dev/sda`, the NVMe disks and all loop devices. The wrapper uses only its two `devicePath` nodes. `run.sh` refuses a device that is not in `loop-map.txt`.

The inotify error and the wait-control-plane timeout did not occur. `fs.inotify.max_user_instances` is 8192 here, and the init took 9 seconds.

Changes to the given design, with the reason:

- `controlPlaneEndpoint` is `cp:6443`, as kind does. `admin.conf` and `kubelet.conf` then follow a new pod IP through `/etc/hosts`.
- The inner subnets are 10.112.0.0/16 and 10.113.0.0/16, so they do not overlap the host cluster.
- `tty: true`, as kind does. The start log of systemd is then in the pod log.
- A readiness probe on `/readyz`.
- `automountServiceAccountToken: false`. The node needs no token of the host cluster.
- A bare Pod, not a StatefulSet. A delete and a new apply are one command each.

## What was expected with Kata

The Kata step tested these points. Its result is in `report-kata.md`.

- The guest kernel has its own sysctl values, no swap and no modules.
- The kernel config must come from a file for the SystemVerification check.
- The entrypoint keeps overlayfs, because the wrapper binds `/kind` from the ext4 volume.
- The memory number is the VM, not the processes.

Not tested in the baseline: the other snapshotters, a CNI, an image change on a used `/var` volume, and a restart of the kind node.

## State after the work

- Nothing of gate 1 runs. The namespace `gate1` and the PersistentVolumes `gate1-*` do not exist. The kubelet holds no loop device for them.
- `/dev/loop22` and `/dev/loop26` have no filesystem signature.
- The image `docker.io/kindest/node:v1.36.4` is in the containerd of the kind node. Removal: `docker exec kata-cp-control-plane crictl rmi docker.io/kindest/node:v1.36.4`.
- On the host, `loop31` and higher exist and are not attached. The kubelet of the kind node attaches one loop device for each raw block volume.
- Kata, `kube-system`, `/dev/loop29` and the pod `guest-probe` were not touched. The containerd of the kind node did not restart. Nothing changed on the host outside the two work folders.

To run it again:

- `~/notes/hosted/lab/gate1/run.sh full` does one full run in 3.5 minutes and removes everything at the end.
- `run.sh up` and `run.sh check` start the pod and test it. `run.sh down` and `run.sh wipe` remove it.
