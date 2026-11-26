# Gate 4: a LoadBalancer IP as the node address

Date 2026-11-25, on the kind node `kata-cp-control-plane`. The agent that ran the tests wrote this report, and the main session saved it.

Versions: Kata 4.4.0 with `kata-clh-runtime-rs`, guest kernel 6.18.62, Kubernetes v1.36.4, etcd 3.6.8, MetalLB 0.16.2, kube-proxy of the host cluster in iptables mode.

## Result

Steps 3, 4 and 6 pass in 3 of 3 full runs from empty volumes. The design works, but it needs two etcd settings, and one of them was not in the plan: etcd must listen on `0.0.0.0`, and etcd must not compare a peer certificate with the source address of the call. Step 5 (the cold start) did not run. The script and the unit are ready.

Files: `~/notes/hosted/lab/gate4/` (`run.sh`, `wrapper.sh`, `podspec.inc`, `node-sts.yaml.tmpl`, `node-pod.yaml.tmpl`, `services.yaml.tmpl`, `volumes.yaml.tmpl`, `kubeadm-init.yaml.tmpl`, `kubeadm-join.yaml.tmpl`, `cold-start.sh`, `g4-loop-nodes.service`).

Logs: `/scratch/kata-cp/logs/gate4/` (`run-1`, `run-2`, `run-3` and `run-<n>.out`, `dev1-etcd-default`, `dev2-etcd-listen-all-san-check`, `dev3-final-settings`, `final-state`, `cold-start-dry-run`).

## 1. Result of each step

Each run is `run.sh full` with exit code 0 and 7 of 7 `RESULT` lines with PASS.

- **Step 3** passes in runs 1, 2 and 3 (`check-3-after-join.txt` and `check-3-after-replaces.txt`). Lines of run 1:
  - `1a5adbf75288ab81 | started | cp-c | https://172.30.255.213:2380 | https://172.30.255.213:2379 | false`, and the same form for cp-a (.211) and cp-b (.212). No learner.
  - `endpoint health --cluster` gives three lines "is healthy: successfully committed proposal".
  - `https://172.30.255.211:6443/readyz: ok (http 200)`, and the same for .212, .213 and the shared .210. 30 calls to .210 showed the three serving certificates, one for each replica.
  - `cp-a NotReady control-plane v1.36.4 172.30.255.211`, cp-b .212, cp-c .213. The nodes are NotReady because the inner cluster has no CNI, as in gate 1. The endpoints of the `kubernetes` Service of the inner cluster are the three LoadBalancer IPs.
- **Step 4** passes in runs 1, 2 and 3 for three cases each (`replace-4-follower.txt`, `replace-4-leader.txt`, `replace-4-bare-pod.txt`), so 9 replaces. In each one the pod IP is new (for example 10.244.0.127 to 10.244.0.132), the etcd member list is the same with the same IDs, and the identity file of the replaced replica differs only in the pod IP and the boot ID. The two other replicas show "no difference". The identity file has the sha256 of all 10 certificates and `sa.pub`, of all keys, kubeconfig files and manifests, the kubelet certificates, the node UID and the machine ID. The pod log has 0 lines "regenerating the certificate".
- **Step 6** passes in runs 1, 2 and 3 (`reach-6-*.txt`). Each pod gets 200 from its own address, from the shared address and from the two other replicas. The own address is local in the guest (`local 172.30.255.211 dev lo`), so that call does not leave the guest. The calls to .210 and to the other replicas go through kube-proxy of the kind node with the pod IP as source. In the comparison with the address on no interface, the pod reached its own address through the Service (200).

## 2. Final settings, and what NVKE must change

kubeadm:

- `controlPlaneEndpoint` is `172.30.255.210:6443`.
- `advertiseAddress` and the kubelet `node-ip` are the LoadBalancer IP of the replica.
- `nodeRegistration.name` is `cp-a` (the pod is `cp-a-0`).
- `etcd.local.extraArgs`: `listen-client-urls=https://0.0.0.0:2379`, `listen-peer-urls=https://0.0.0.0:2380`, `peer-skip-client-san-verification=true`.
- No `certSANs` entry is necessary. kubeadm puts the node address and the shared address in `apiserver.crt`.
- Lab only: `imagePullPolicy: Never`, no kube-proxy addon, the kubelet settings of kind.
- Join: `kubeadm join --control-plane` with a certificate key (`--upload-certs` at init).

Services:

- One for each replica: type LoadBalancer, the annotation `metallb.io/loadBalancerIPs`, `publishNotReadyAddresses: true`, `allocateLoadBalancerNodePorts: false`, `externalTrafficPolicy: Cluster`, and the ports 6443, 2379, 2380 and 10250.
- The shared Service `cp-api`: LoadBalancer .210, port 6443. It selects all replicas and has no `publishNotReadyAddresses`. The pod has a readiness probe on `/readyz`. A replica that waits for its join has no API server, so it must not get traffic of the shared address.

NVKE changes:

1. `etcdExtraArgs` (`controller/internal/kubeadmconfig/init.go:225-239`): add the two listen URLs. Part 3 gives the reason.
2. The same function: add `peer-skip-client-san-verification=true`. etcd 3.5 has only the name `experimental-peer-skip-client-san-verification`, so the name depends on the etcd version, like the bootstrap defrag flag in that function.
3. No change in the renderer for `advertiseAddress`, `node-ip`, the node name and `controlPlaneEndpoint` (`init.go:180, 186, 188, 317`, `join.go:267-283`). They need `node.IP` to be the LoadBalancer IP and an endpoint that is not kube-vip (see `results/architecture-reading.md`).
4. Node image or pod wrapper, not the controller: put the address on an interface before the kubelet starts, turn the kind address repair off, and set the systemd stop timeout (10 s, from gate 1).

Address repair, exactly: `wrapper.sh` part 5 runs `rm -f /kind/old-ipv4 /kind/old-ipv6` before it starts the kind entrypoint (variable `G4_REPAIR=off`). The entrypoint then finds no old address and changes nothing. `/kind/old-ipv6` holds `::ffff:<pod IP>`, so both files must go. It worked with a new pod IP in 9 of 9 counted replaces, in 5 development replaces and in one restart in place.

## 3. etcd listen result

- **kubeadm default** (client on 127.0.0.1 and the node address, peer on the node address). The init on A passes. The join of B fails after 121 s in the phase `check-etcd`: "error syncing endpoints with etcd: context deadline exceeded". From B and from the kind node, `172.30.255.211:2379` and `:2380` give "connection refused", and `:6443` answers. Cause: kube-proxy changes the destination to the pod IP, and etcd has no socket on the pod IP. A stays as it was. Log: `dev1-etcd-default/etcd-default-evidence.txt`.
- **With `0.0.0.0` only.** The join fails after 121 s in the phase `etcd-join`: "the etcd member ba5f9d46a8e032b7 is not started". etcd of A logs `rejected connection on peer endpoint, remote-addr 10.244.0.1, error: tls: "10.244.0.1" does not match any of DNSNames ["cp-b" "localhost"]`. etcd of B logs "cannot fetch cluster info from peer urls" and exits. Cause: kube-proxy masquerades each call to a LoadBalancer IP (rule `KUBE-EXT-... -j KUBE-MARK-MASQ`), and etcd compares the source address of a peer with the names in its client certificate. B stays a learner that is not started, and A keeps quorum. With `externalTrafficPolicy: Local` the source is the pod IP of the peer (10.244.0.111), and etcd rejects it in the same way. Logs: `dev2-etcd-listen-all-san-check/etcd-san-evidence.txt` and `etp-local-evidence.txt`.
- **The flag** turns that check off. It does not repair the address. TLS with the etcd CA stays (`peer-client-cert-auth`).
- **Not tested:** keep the check with the policy `Local` and a headless Service that gives the node name the pod IP. That makes etcd depend on the DNS of the host cluster. A fixed pod IP has no address change and needs neither setting. The two fallbacks of the plan were not necessary and are not tested.

## 4. Owner of the pod

- **StatefulSet (main form).** 1 replica, `OnDelete`, two claim templates with `volumeMode: Block`. The claims `var-cp-a-0` and `etcd-cp-a-0` bind to the local volumes through `claimRef`. `serviceName` is the LoadBalancer Service, and no headless Service was necessary. After a pod delete, the controller of the host cluster makes the pod again 2 to 3 s after the old pod is gone, with the same name and claims. The hostname is `cp-a-0`, and the node name stays `cp-a` (`--hostname-override=cp-a` from kubeadm). A delete of the StatefulSet keeps the claims (the default retention), so the provider must delete them.
- **Bare Pod.** Nothing makes it again ("NotFound" 5 s after the delete). `run.sh` applied it again, as a provider must do. The provider must also make the claims and watch the pod. The pod name, the hostname and the node name are equal.
- In each run one replica changed its owner from a StatefulSet to a bare Pod on the same claims and kept its identity. Only the hostname changed (`cp-c-0` to `cp-c`). The time from a new pod to `/readyz` is the same for the two forms.
- Neither form uses the host network, a `hostPath` volume or a host socket.

## 5. Numbers

Runs 1, 2 and 3, in seconds.

- `kubeadm init`: 8.9, 8.1, 8.6. Pod create to `/readyz` through the Service of the replica: 14.7, 13.1, 14.9.
- Join of B: 22.0, 22.3, 22.1. Join of C: 21.9, 22.0, 8.5. Final state: 9.0 and 8.5. So the join time is not stable: about 9 or about 22. The etcd part is the same each time (member add to promote: 3 s). The kubelet log shows the difference: a certificate request that reaches the new local API server too early gets "Unauthorized", and the kubelet waits for its next try.
- Follower replace (StatefulSet), after the delete: old pod gone 11.8, 11.6, 11.5. `/readyz` through its Service 20.1, 19.9, 20.2. Three healthy etcd endpoints 20.3, 20.2, 20.5.
- Leader replace: `/readyz` 20.1, 18.4, 20.5. etcd 20.3, 18.7, 20.7. The leader moved to another member each time, with no member change.
- Bare Pod: `/readyz` 23.2, 23.4, 23.4. This includes 5 s that the script waits before it applies the pod. New pod create to `/readyz`: 7.4 to 8.7.
- Shared endpoint, one call each second: 193 calls during the 9 replaces, 3 failed. Each one is a single call in the first second after the delete: one "500" from an API server in shutdown, and two timeouts of 2 s. 6 of 9 replaces had no failed call. The longest time between two good calls was 3.0 s.
- Memory: the pod cgroup has 1.3 to 2.8 GiB with a limit of 6.1 GiB. The guest has 5975 MiB. `oom_kill` is 0 in each check (`run.sh check` tests it).

## 6. What failed on the way, with the cause

1. The two etcd failures of part 3.
2. Control test with the repair on (`G4_REPAIR=on`) and a new pod, on a replica that joined. The entrypoint logs "detected old IPv4 address: 10.244.0.119" and "clearing and regenerating the certificate". It deletes `apiserver.crt` and `apiserver.key`, then kubeadm fails: "open /kind/kubeadm.conf: no such file or directory". The second container start finds no address difference, and kube-apiserver cannot start with no certificate. This is the same failure as with the NVKE image. Log: `dev3-final-settings/control-repair-on-evidence.txt`.
3. The 3 failed calls of part 5. The endpoint of a pod in termination stays for a moment. NVKE sets `shutdown-delay-duration` to 10 s (`init.go:257`). The lab did not, and it is not tested.
4. A fault of the test agent: after the control test it made the certificate again by hand with `kubeadm init phase certs` and no version, and kubeadm made one call from the guest to the Kubernetes release server. One connection. The scripts make no such call.
5. The test agent ran `git status` one time in `~/notes`. It is a read, but it can refresh the index file.

Comparisons (`dev3`, one test each):

- The address on a bridge with no ports (`g4-node=172.30.255.213/32`) passes like the second address on `eth0`.
- With the address on no interface, a replica that had joined returns and answers, but the kubelet logs at each status update `failed to validate nodeIP: node IP: "172.30.255.213" not found in the host's network interfaces`. Not tested from `kubeadm init`.
- A restart in place (power-off in the pod, final state): 11.2 s to the new container, 15.3 s to `/readyz`, the same pod IP, the same VM, no identity difference.

## 7. Cold start (not run)

- `~/notes/hosted/lab/gate4/cold-start.sh --stop-the-kind-node` records the state, runs `docker stop` and `docker start`, starts the loops in the kind node, and stamps these times: host API ready, pods running again, etcd quorum, `/readyz` of each replica and of the shared address. Then it compares the identity and runs the checks of steps 3 and 6. It does nothing by hand after the start. `--dry-run` does all but the stop and start, and it passed (`cold-start-dry-run`).
- Unit: `g4-loop-nodes.service` makes `/dev/loop0` to `/dev/loop127` before the kubelet and containerd start. Install: `docker cp ~/notes/hosted/lab/gate4/g4-loop-nodes.service kata-cp-control-plane:/etc/systemd/system/`, then `docker exec kata-cp-control-plane systemctl daemon-reload` and `docker exec kata-cp-control-plane systemctl enable g4-loop-nodes.service`. It is not installed. It was checked with `systemd-analyze verify` (exit 0) and with its shell line in a temp folder. The D-Bus part of `01-node-prep.sh` needs no unit: the package stays in the container, and `sockets.target` starts `dbus.socket`. `cold-start.sh` refuses to run when the unit is not enabled.
- Expected: the stop kills the Kata VMs with no clean stop of the guests. After the start, the kubelet makes new sandboxes for the same pods with new pod IPs and the same claims. The wrapper removes the old address files, so no certificate changes. etcd gets quorum when two replicas run and kube-proxy has the new endpoints. The estimate is 1 to 2 minutes. Risks that reading cannot settle: the old loop devices of the kubelet stay attached in the host kernel, containerd must clean the dead Kata sandboxes, and the kind node must get 172.30.0.2 again.

## 8. State after the work

- Running, ready for the cold start: the namespace `gate4` with the StatefulSets cp-a, cp-b and cp-c (pods 1/1, about 7.9 GiB in the pod cgroups), the Services cp-a, cp-b, cp-c and cp-api (.211 to .213 and .210), 6 claims, 6 PersistentVolumes `gate4-cp-*`, and 2 ConfigMaps. `cp-b-0` has 1 container restart from the restart test. Steps 3 and 6 pass on it (`final-state/check-3-final-state.txt`).
- `/scratch/kata-cp/gate4-secrets` has the bootstrap token (2 h) and the certificate key of this cluster, with mode 600. No secret is in `~/notes` or in this report. The copies of the kubeadm files in the logs have `<token>` in their place.
- Remove: `LOG_DIR=/scratch/kata-cp/logs/gate4/final-state ~/notes/hosted/lab/gate4/run.sh down`, then the same with `wipe`. `down` also deletes the secret files.
- Not touched: the namespaces `gate1-nvke` and `gate1-nvke-spire`, the RuntimeClasses, MetalLB, Kata, `/opt/kata`, Docker and the other loop devices. Nothing is installed in the kind node.
- Not tested: the cold start and the VM restart test, a runc baseline for gate 4, a host cluster with more than one node (the masquerade address then depends on the node), QEMU, the NVKE image with the agent port 15005, the approval of kubelet serving certificates, and the two fallbacks.
