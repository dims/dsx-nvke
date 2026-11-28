# Try it: control plane nodes of an NVKE cluster as Kata pods

State of 2026-11-28. The guide uses two public branches:

- `integration/control-plane-kata-pods` of `https://github.com/dims/dsx-nvke`, at `8bc32175`
- `integration/control-plane-kata-pods` of `https://github.com/dims/kata-containers`, at `96a8d905b`

**Nothing of this path ran from start to end yet.** A first run of the guide is under way since 2026-11-28. Part 1, the 13 set up steps, passed in it. Four steps needed a fix of the branch first (7, 11, 12 and the port of 13). Each of the ten scenarios passed. Scenario 6 passed at its second try, on a cluster that was made again: "Known obstacles" has why. A mark on each step and each scenario says how it ran. Expect to find faults, and tell us where.

## What the feature is

- NVIDIA Kubernetes Engine (NVKE) makes Kubernetes clusters. A control plane node of such a cluster is normally a machine.
- With this feature each control plane node is a pod of the cluster that runs NVKE, which this guide calls the host cluster. The pod is a small virtual machine that Kata Containers starts.
- A new Cluster API provider, `cluster-api-provider-podvm`, makes one pod, two block volumes and one fixed address for each node. It also makes one Service with a fixed address in front of the API servers.
- NVKE drives the node in the pod as it drives a machine. Its node agent runs `kubeadm` there.
- Workers stay machines. In this guide they are containers of the NICo simulator of the repository.

## What you need

- One Linux machine on amd64 or arm64 with `/dev/kvm`. In a virtual machine, nested virtualization must be on. Each step is tested on amd64. On arm64 the first run is in work, and "On arm64" has its state.
- 16 CPUs, 48 GB of memory and 100 GB of free disk. Our lab machine was larger, and a smaller one never ran.
- `sudo` rights, for `modprobe`, `sysctl` and `losetup`.
- Docker 28 or newer with `buildx`. A container must reach the internet. The user of the run must be able to call `docker` with no `sudo`.
- `git`, `make`, a C compiler, `python3`, `curl`, `jq`, `tar` with `zstd`, Go 1.27, `kind`, `kubectl`, `helm`, `clusterctl`, and for the kernel build `yq`, `flex`, `bison`, `patch` and the headers of `libelf`.
- The NVKE tree pins the versions that it is tested with: `kind`, `kubectl`, `helm` and Cluster API (for `clusterctl`) in `make/tool-versions.mk`, and Go in `go.work`. The first run used these versions.
- No account and no secret. Each input is public.

## On arm64

State of 2026-11-28. A first run is in work, on one arm64 machine with `/dev/kvm`. The last line of this section names the steps that passed there.

- The commands are the same on both architectures. The README and the scripts take the architecture from the machine.
- The hypervisor differs. Kata Containers 4.4.0 has Cloud Hypervisor with its Rust runtime for amd64 only. On arm64 `up.sh` puts the runtime class `kata-podvm` on QEMU with the same Rust runtime. The guest kernel, the guest image and the name of the runtime class are the same.
- On arm64 `up.sh` also gives each kind node a larger `/dev/shm`. QEMU keeps the memory of a guest there, and a container has 64 MB of it.
- Each mark, each time and each number of this guide is from amd64.
- Steps that passed on arm64: 1 to 13, each as it is written here, on 2026-11-28. The guest kernel of step 3 has the same file name there. Step 4 took 11 minutes, and the base image of step 5 has 1.1 GB. The pod of step 8 runs on QEMU and prints the same kernel version.
- Scenarios that passed on arm64: 1, 2, 3 and 4, on 2026-11-28. The status was `Provisioned` after 2 minutes and 26 seconds, and each of the four nodes was Ready after 3 minutes and 47 seconds. In scenario 3 the node was Ready again after 55 seconds. The other scenarios did not run there yet.

## The marks

- **Ran.** The same commands ran, in our lab or in a check of the branch.
- **Lab.** The same thing ran in our lab, with other commands.
- **New.** It never ran in any form.
- **Ran in the first run of 2026-11-28.** The step passed as this guide has it, in the first run of the guide on one machine.

A mark says nothing about this path as a whole. The first run is not at its end.

## Part 1, set up

Set these names in each shell that you use for the guide:

```bash
export TRY=~/podvm-try
export NVKE=$TRY/dsx-nvke KATA_SRC=$TRY/kata-containers
export KATA_GUEST_DIR=~/.local/state/podvm-kind/kata-guest
export PATH=$NVKE/cli/bin:$PATH
kh() { kubectl --context kind-podvm "$@"; }                         # the host cluster
kc() { kubectl --kubeconfig $TRY/podvm-example.kubeconfig "$@"; }   # the new cluster
```

The run follows `controller/hack/podvm-kind/README.md` of the NVKE tree. This guide calls it the README. Where a step says "README, section", run the commands of that section as they are.

### 1. Check the machine

**Ran in the first run of 2026-11-28.**

```bash
ls -l /dev/kvm
docker version --format '{{.Server.Version}}' && docker buildx version
docker run --rm busybox:1.36 wget -q -O /dev/null https://github.com && echo "a container reaches the internet"
```

- **See.** The device, a Docker version of 28 or more, a `buildx` version, and the last line.
- **If not.** Read "Known obstacles" at the end before you go on.

### 2. Get the two trees

**Ran in the first run of 2026-11-28.**

```bash
mkdir -p $TRY && cd $TRY
git clone --branch integration/control-plane-kata-pods https://github.com/dims/dsx-nvke.git
git clone --branch integration/control-plane-kata-pods https://github.com/dims/kata-containers.git
```

- **See.** `git -C $NVKE log -1 --format=%h` and `git -C $KATA_SRC log -1 --format=%h` print the two commits of the first lines, or newer ones.

### 3. Build the guest kernel

**Ran in the first run of 2026-11-28.** The build took 68 s on 64 CPUs.

Run the commands of `cluster-api-provider-podvm/node-image/README.md`, section "The guest kernel", from `$NVKE`. Then:

```bash
mkdir -p $KATA_GUEST_DIR
cp ~/kata-kernel/out/opt/kata/share/kata-containers/vmlinux-6.18.62-211 $KATA_GUEST_DIR/vmlinux
grep -c -E '^CONFIG_(OPENVSWITCH|INET_DIAG_DESTROY)=y' ~/kata-kernel/out/opt/kata/share/kata-containers/config-6.18.62-211
```

- **See.** The last command prints `2`.
- **If not.** The two option files were not in `tools/packaging/kernel/configs/fragments/common/` at the `setup` step. Copy them and build again.

### 4. Build the guest image

**Ran in the first run of 2026-11-28.** The build took 6 min 24 s. Scenario 1 showed the first of the two changes in the agent of the image: a pod that runs systemd takes an exec probe. The second, a stop in seconds, shows when a pod stops, from scenario 3 on.

Run the commands for `kata-containers.img` of the README, section "1. Build the guest kernel and the guest image". `KATA_SRC` is the Kata tree of step 2, which has the two agent changes.

- **See.** `ls -lh $KATA_GUEST_DIR/kata-containers.img` shows a file of about 100 MB.
- **If not.** The build runs in containers and downloads a Rust toolchain and packages. A failed download is the usual cause.

### 5. Build the base node image

**Ran in the first run of 2026-11-28.** The two commands took 3 min 22 s.

Run the two commands of `cluster-api-provider-podvm/node-image/README.md`, section "The base image".

- **See.** `docker image inspect cwe-capd-kindest-node:local --format '{{.Size}}'` prints a size of about 1.2 GB. The lab measured 103 s and 39 s for the two commands.

### 6. Build the other images and nvkectl

**Ran in the first run of 2026-11-28.** The README had five commands then, and they took 1 min 54 s. The sixth command, the build of the image of the profiles, came into the README during the run. It ran in step 12 of that run and makes an image of 4 MB.

Run the commands of the README, section "2. Build the images and nvkectl", from `$NVKE`.

- **See.** `docker image inspect podvm-node:local nvke-controller:local cluster-api-provider-podvm:latest docker.local/cwe-profiles:tilt --format '{{.RepoTags}}'` prints four lines, and `nvkectl version` prints a version.
- The node image of this tree ran in a pod for the first time in scenario 1 of the first run.

### 7. Bring the host cluster up

**Ran in the first run of 2026-11-28, in two parts.** The first try stopped at the step `kata`, and the fix is in the public branch. With it each check below passed. A run of the script in one go is planned for the end of the first run. The script took about 4 minutes.

```bash
$NVKE/controller/hack/podvm-kind/up.sh
```

The script runs eight steps. Each can run again alone, for example `up.sh kata`.

| Step | What it makes | Mark |
|---|---|---|
| `host` | The kernel modules of Kata and a higher inotify limit | Ran in the first run |
| `network` | The Docker network `podvm-nodenet`, `172.28.0.0/16` | Ran in the first run |
| `cluster` | The kind cluster `podvm` with one control plane node and three workers | Ran in the first run |
| `nodes` | In each kind node: D-Bus, loop device nodes, the bridge `br-nodenet`, two CNI plugins | Ran in the first run |
| `multus` | Multus, the namespace `podvm-clusters` and its network attachment | Ran in the first run |
| `kata` | Kata Containers 4.4.0 with the runtime class `kata-podvm` | Ran in the first run, at the second try |
| `metallb` | MetalLB with a pool on the node network | Ran in the first run. It answers on the node network: scenario 1 |
| `storage` | Loop devices and the local static provisioner in block mode | Ran in the first run |

```bash
kh get nodes
kh get runtimeclass kata-podvm
kh -n podvm-clusters get network-attachment-definitions
kh -n metallb-system get pods
kh get pv
```

- **See.** Four nodes that are Ready. The runtime class. The attachment `nodenet`. MetalLB pods that run. Twelve volumes with the status `Available` and the class `podvm-block`, six of 20Gi and six of 8Gi.
- **If not.** The script stops at the first fault and names the step. Correct the cause and run that step again. With fewer than twelve volumes, read the logs of the pods in the namespace `local-static-provisioner`.

### 8. Check Kata

**Ran in the first run of 2026-11-28.**

```bash
kh run kata-check --image=busybox:1.36 --restart=Never --overrides='{"spec":{"runtimeClassName":"kata-podvm"}}' -- sleep 3600
kh wait --for=condition=Ready pod/kata-check --timeout=120s
kh exec kata-check -- uname -r
kh delete pod kata-check
```

- **See.** `uname -r` prints `6.18.62`, which is the guest kernel and not the kernel of the machine.
- **If not.** `kh describe pod kata-check` names the fault. A message about the kernel or the image file means that step 3 or 4 did not give the file that `up.sh kata` copied.

### 9. Load the images into the kind nodes

**Ran in the first run of 2026-11-28.** The load of the three large images took 2 min 22 s. The fourth, the image of the profiles, came into the loop during the run and went into the nodes in step 12.

Run the loop of the README, section "3. Bring the host cluster up".

- **See.** `docker exec podvm-worker crictl images | grep -c -E 'podvm-node|nvke-controller|cluster-api-provider-podvm|cwe-profiles'` prints `4`.

### 10. Install Cluster API and the provider

**Ran in the first run of 2026-11-28.** It took 18 s.

Run the commands of the README, section "4. Install Cluster API and the provider", from `$NVKE`.

- **See.** `kh -n podvm-system rollout status deployment/podvm-controller-manager` ends with "successfully rolled out".

### 11. Install CAPNICo and start the simulator

**Ran in the first run of 2026-11-28, after one fix of the branch.** It took 1 min 43 s. The first try stopped, because the README called `install-capnico.sh` by its path and the script has no execute bit. The fix is in the public branch.

Run the commands of the README, section "5. Install CAPNICo and start the simulator", from `$NVKE`. They get the CAPNICo source as a Go module, build CAPNICo from it and start the simulator.

- **See.** `kh -n capnico-system get pods` shows a manager that runs. `up.sh sim` ends with no error. It waits for the answer of the simulator itself.
- **If not.** The log of the simulator is `~/.local/state/podvm-kind/nico-sim/nico-sim.log`. For a fault of `kind load`, read "Known obstacles".
- A worker of the simulator is a privileged container on the kernel of your machine. `up.sh sim` loads the kernel module `openvswitch` for it.

### 12. Install the management plane

**Ran in the first run of 2026-11-28, after one fix of the branch.** It takes about 2 minutes. The first try stopped, because the README had no step for the image of the profiles fixture. The fix is in the public branch: steps 6 and 9 now build and load four images.

Run the commands of the README, section "6. Install the management plane", from `$NVKE`.

```bash
helm --kube-context kind-podvm list --all-namespaces
kh -n nvke-controller get pods
kh get clusterrole nvke-controller-podvm
```

- **See.** The five releases of this step with the status `deployed`: `postgresql`, `spire-crds`, `temporal`, `spire` and `nvke-controller`. The list also has the four releases of the steps before. A controller pod that runs. The ClusterRole.
- **If not.** The script prints the item that failed. `kh get pods --all-namespaces | grep -v -E 'Running|Completed'` shows what does not start.

### 13. Point nvkectl at the API

**Ran in the first run of 2026-11-28.**

Run the commands of the README, section "7. Create a cluster", up to `nvkectl config set-site`. Stop before `nvkectl create cluster`. The first line sets `API_PORT`, the local port of the port forward. Take another free port there when something on the machine listens on 8080.

```bash
nvkectl get clusters
export API=http://localhost:${API_PORT}
TOKEN=$(kh -n nke-clients create token nke-client --audience https://nke.tilt.local)
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOKEN" "$API/api/clusters"
```

- **See.** An empty list from `nvkectl`, with no authentication error, and `200` from `curl`.
- `nvkectl` gets its own token. `curl` needs `$TOKEN`. A token lasts one hour, so make a new one when a call answers `401`.

## Part 2, scenarios

Run them on one cluster, in this order: 1, 2, 3, 4, 5, 6, 8, 9, 7, 10. Scenario 7 comes last before the delete, because NVKE avoids a kind worker that was full for 3 hours after it, and a later rollout of the control plane can wait that long. Each one names its pass rule.

Three helpers for the scenarios:

```bash
nodes() { curl -s -H "Authorization: Bearer $TOKEN" "$API/api/nodes?clusterName=podvm-example" \
  | jq -r '.nodes[] | [.id, .name, .ip, .controlPlane, .conditions.kubernetesReady.status] | @tsv'; }
template() { cat <<EOF
controlPlaneConfig:
  infra:
    machineTemplate:
      apiVersion: infrastructure.cluster.x-k8s.io/v1alpha1
      kind: PodVMMachineTemplate
      spec:
        template:
          spec:
            image: docker.io/library/$1
            imagePullPolicy: Never
            resources: {cpu: "2", memory: 6Gi}
            volumes:
              var: {storageClassName: podvm-block, size: 20Gi}
              etcd: {storageClassName: podvm-block, size: 8Gi}
EOF
}
load() { for n in $(kind get nodes --name podvm); do
  docker save --platform "linux/$(go env GOARCH)" "$1" | docker exec -i "$n" ctr -n k8s.io images import --digests -; done; }
```

`nodes` lists each node of the cluster with its ID. `template` prints a patch with the machine template for one node image. `load` puts an image into the kind nodes.

### Scenario 1, one request makes the cluster

**Ran in the first run of 2026-11-28.** It was the first cluster with the Service that the provider makes, and the first run of the node image of this tree in a pod.

```bash
cd $NVKE
nvkectl create cluster -f cli/examples/podvm-cluster.yaml
kh -n podvm-clusters get service,pods -o wide
nvkectl get clusters podvm-example
nvkectl get kubeconfig podvm-example --output-file $TRY/podvm-example.kubeconfig
kc get nodes -o wide
```

- **Pass.** The Service `podvm-example-control-plane` has the external address `172.28.255.220`. Three pods run, each on another kind worker. The cluster has the status `Provisioned`. `kc get nodes` shows three control plane nodes and one worker, each Ready. No other step by hand. The status `Provisioned` comes when the first control plane node is up. The other nodes join after that, so run the last command again until it shows four nodes.
- **Time.** In the first run the Service had its address after 11 s, the status `Provisioned` came after 3 min 29 s, and the last of the four nodes was Ready after 5 min 37 s. A second cluster in the same run took 12 s, 3 min 21 s and 5 min 12 s.
- **If not.** `kh -n nvke-system get podvmclusters,podvmmachines` shows the reason of the provider. For a pod that stays Pending, run `kh -n podvm-clusters describe pod <name>`. For a node that does not join, read `kh -n nvke-controller logs deployment/nvke-controller`.

### Scenario 2, pod traffic between the nodes

**Ran in the first run of 2026-11-28.** The block took 10 s. It was the first run with a worker on the one node network.

```bash
kc apply -f - <<'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata: {name: web}
spec:
  selector: {matchLabels: {app: web}}
  template:
    metadata: {labels: {app: web}}
    spec:
      tolerations: [{operator: Exists}]
      containers:
        - name: web
          image: registry.k8s.io/e2e-test-images/agnhost:2.47
          args: [netexec, --http-port=8080]
---
apiVersion: v1
kind: Service
metadata: {name: web}
spec: {selector: {app: web}, ports: [{port: 8080}]}
EOF
kc rollout status daemonset/web
for p in $(kc get pods -l app=web -o name); do
  for ip in $(kc get pods -l app=web -o jsonpath='{.items[*].status.podIP}'); do
    kc exec $p -- /agnhost connect $ip:8080 --timeout=3s && echo "$p to $ip ok"
  done
  kc exec $p -- /agnhost connect web:8080 --timeout=3s && echo "$p to the Service ok"
done
```

- **Pass.** With four nodes: 16 lines for the pods and 4 lines for the Service, each with `ok`. The Service lines also prove the name service.
- **If not.** Lines that fail only between a control plane node and the worker mean that the tunnels of the pod network do not work between the two. That is the part of the one node network that never ran.

### Scenario 3, a lost pod comes back

**Ran in the first run of 2026-11-28.** The delete returned after 22 s. The new pod was ready and its node Ready 61 s after the delete.

```bash
kh -n podvm-clusters get pods -o wide
POD=$(kh -n podvm-clusters get pods -o name | head -n 1)
kh -n podvm-clusters delete $POD
kh -n podvm-clusters get pods -o wide --watch
```

- **Pass.** A new pod comes with the same name, on the same kind worker. Its node is Ready again in `kc get nodes -o wide`, with the same name and the same address. No request to NVKE.

### Scenario 4, replace a control plane node

**Ran in the first run of 2026-11-28.** The oldest control plane node is the first line of `kc get nodes --sort-by=.metadata.creationTimestamp`.

```bash
nvkectl patch cluster podvm-example --patch 'controlPlaneConfig: {desiredCount: 4}'
nodes                                        # wait for four control plane nodes with True
curl -X DELETE -H "Authorization: Bearer $TOKEN" "$API/api/nodes/<ID of the oldest control plane node>"
nodes                                        # wait: the old node is gone, a new one has True
nvkectl patch cluster podvm-example --patch 'controlPlaneConfig: {desiredCount: 3}'
```

- **Pass.** After the DELETE a new control plane node joins, and NVKE does it alone. At the end `kc get nodes` shows three control plane nodes that are Ready. Some minutes later `kh get pv` shows no volume with the status `Released`.
- **Why 4 first.** NVKE refuses the delete of a control plane node while only three are joined.
- **Time.** In the first run the fourth node took 2 min 21 s, and the new node after the delete 4 min 15 s. After the last patch NVKE removed one node in 73 s. The volumes of each removed node were `Available` again in under 30 s.

### Scenario 5, roll the control plane to a new image

**Ran in the first run of 2026-11-28.** The load of the tag took 1 min 45 s.

```bash
docker tag podvm-node:local podvm-node:local-b && load podvm-node:local-b
template podvm-node:local-b | nvkectl patch cluster podvm-example --patch-file -
```

In a second shell, call the API of the new cluster each second until the rollout ends:

```bash
while sleep 1; do kc get --raw /readyz --request-timeout=3s >/dev/null && echo ok || echo FAIL; done
```

- **Pass.** NVKE replaces the three control plane nodes one after the other. `kh -n podvm-clusters get pods -o jsonpath='{.items[*].spec.containers[0].image}'` shows the new tag three times. The loop prints no `FAIL`.
- **Time.** In the first run the rollout took 10 min 30 s, and 620 of 620 calls had an answer. The status of the cluster is `Recycling` during the rollout.
- The provider README, section "Roll to a new image", has the rules of this request.

### Scenario 6, turn etcd encryption on

**Ran in the first run of 2026-11-28, at the second try and on a cluster that was made again.** The first try did not pass: the fork of this guide had no version tag then. "Known obstacles" has what you see with no tag.

```bash
nvkectl patch cluster podvm-example --patch 'enableEtcdEncryption: true'
nvkectl get clusters podvm-example
nvkectl get clusters podvm-example -o yaml | grep etcdEncrypted
```

- **Pass.** The status goes to `Updating` and back to `Provisioned`. Then `etcdEncrypted` is `true`, and each node is Ready. Then run the patch of scenario 5 with the tag `podvm-node:local`. A control plane node must still join after encryption. The first run used another tag for it, because its cluster was new and ran `podvm-node:local`.
- **If not.** If the status stays `Updating` for more than 10 minutes, search the log of the controller: `kh -n nvke-controller logs deployment/nvke-controller --since=5m | grep 'Activity error'` shows the reason.
- **Time.** In the first run the change took 6 min 58 s, and the rollout after it 10 min 26 s. The loop of scenario 5 on the API had an answer to each call in both.

To see that a new Secret is stored encrypted, read it from etcd:

```bash
kc create secret generic enc-check --from-literal=k=v
N=$(kc get nodes -l node-role.kubernetes.io/control-plane -o name | head -n 1 | sed 's#node/##')
kc -n kube-system exec etcd-$N -- etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/default/enc-check --print-value-only | head -c 21; echo
```

- **See.** `k8s:enc:secretbox:v1:`. `kc get secret enc-check -o jsonpath='{.data.k}' | base64 -d` still prints `v`.

### Scenario 8, upgrade the Kubernetes version

**Ran in the first run of 2026-11-28, on a cluster that was made again.** It was the first upgrade with a node image for 1.37.0 from the public scripts.

A node runs only the version that its image carries. So build a second pair of images first. Run the second command of step 5 again, with `CAPD_KINDEST_NODE_IMAGE=cwe-capd-kindest-node:v1.37.0` in place of its image name and with `CAPD_KINDEST_NODE_TAG=v1.37.0` added. Then:

```bash
cd $NVKE
BASE_IMAGE=cwe-capd-kindest-node:v1.37.0 IMAGE=podvm-node:v1.37.0 cluster-api-provider-podvm/node-image/build-image.sh
load podvm-node:v1.37.0
{ echo 'controlPlaneKubernetesVersion: "1.37.0"'; template podvm-node:v1.37.0; } | nvkectl patch cluster podvm-example --patch-file -
```

- **Pass.** NVKE replaces each control plane node. `kc get nodes` shows `v1.37.0` on the three control plane nodes, and the cluster is `Provisioned`. The worker keeps its version.
- **Time.** In the first run the two image builds took 44 s and 24 s, the load 2 min 3 s, and the upgrade 12 min 44 s.
- The loop of scenario 5 on the API had 740 of 742 calls with an answer. Two calls failed within 6 s, when NVKE ran the last upgrade step on the newest node and its etcd started again.
- A load of a second node image takes about 12 GB of disk in the four kind nodes.

### Scenario 9, workers from the simulator

**Ran in the first run of 2026-11-28, on a cluster that was made again.** Each worker has one network.

```bash
ID=$(nvkectl get clusters podvm-example -o json | jq -r '.[0].id')
sed "s/^clusterID: .*/clusterID: $ID/" $NVKE/cli/examples/podvm-nico-mock-nodepool.yaml | nvkectl create nodepool -f -
nvkectl patch nodepool extra-workers --cluster podvm-example --patch 'desiredNodeCount: 2'
nodes                                        # wait for three workers with True
curl -X DELETE -H "Authorization: Bearer $TOKEN" "$API/api/nodes/<ID of one worker>"
kc get node <name of another worker> -o jsonpath='{.status.nodeInfo.bootID}{"\n"}'
kc label node <name of that worker> nvke.nvidia.com/reboot=try-1
```

- **Pass, add.** The new workers join and are Ready. `docker ps` shows one container for each worker.
- **Pass, remove.** The worker leaves the cluster, its container is gone, and NVKE makes a new one because the pool still asks for its count.
- **Pass, reboot.** The Node is not Ready for a short time. Then it is Ready with another boot ID.
- **Time.** In the first run 57 s for the two new workers, 73 s for a delete with a new worker, and 12 s for a reboot. The run made the reboot request for a worker that had joined some seconds before.
- A worker of the simulator runs the Kubernetes version of its image, v1.36.4, also after scenario 8, where `nvkectl get nodepools --cluster podvm-example` shows 1.37.0 for the new pool.
- A lower count of a pool removes no node. Only a node delete does.
- No product page has the label command. The label is the reboot request of NVKE.

### Scenario 7, a full failure domain

**Ran in the first run of 2026-11-28**, at that time before scenario 8 and with a roll to the tag `podvm-node:local`. In the lab a worker that was a pod took the place. Here a plain pod does.

Run this scenario last before the delete. After it NVKE avoids each kind worker that was full for 3 hours, and a later rollout of the control plane can wait that long. In the first run the next rollout did not go on.

Each kind worker has two volume places, and a control plane node holds one. Check with `kh -n podvm-clusters get pods -o wide` that `podvm-worker` runs one control plane pod. Give the node image that the control plane runs a second name, take the second place of `podvm-worker`, then roll the control plane to the second name:

```bash
NOW=$(kh -n podvm-clusters get pods -o jsonpath='{.items[0].spec.containers[0].image}' | sed 's#.*/##')
docker tag $NOW $NOW-x && load $NOW-x
kh -n podvm-clusters apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: blocker-var}
spec: {storageClassName: podvm-block, volumeMode: Block, accessModes: [ReadWriteOnce], resources: {requests: {storage: 20Gi}}}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: blocker-etcd}
spec: {storageClassName: podvm-block, volumeMode: Block, accessModes: [ReadWriteOnce], resources: {requests: {storage: 8Gi}}}
---
apiVersion: v1
kind: Pod
metadata: {name: blocker}
spec:
  nodeSelector: {kubernetes.io/hostname: podvm-worker}
  containers:
    - name: pause
      image: registry.k8s.io/pause:3.10
      volumeDevices: [{name: var, devicePath: /dev/blocker-var}, {name: etcd, devicePath: /dev/blocker-etcd}]
  volumes:
    - {name: var, persistentVolumeClaim: {claimName: blocker-var}}
    - {name: etcd, persistentVolumeClaim: {claimName: blocker-etcd}}
EOF
template $NOW-x | nvkectl patch cluster podvm-example --patch-file -
kh -n nvke-system get podvmmachines --watch
```

- **Pass.** One machine shows the reason `FailureDomainUnavailable`, and its pod stays Pending. About 16 minutes later NVKE deletes that node and makes a new one on another kind worker. The rollout then ends with three new nodes.
- **It can happen two times.** The new node goes to a kind worker that already runs a control plane node, and that worker is full then. In the first run the machine for the next old node on that worker waited 16 minutes too.
- **What stays.** At the end one kind worker runs two control plane nodes and one runs none. NVKE avoids the two workers that were full for 3 hours. In the first run that left only the worker with two control plane nodes for a new node, which is full, so the next rollout did not go on. NVKE shows nothing of this, and the log of the controller is silent about it.
- **After it.** `kh -n podvm-clusters delete pod/blocker pvc/blocker-var pvc/blocker-etcd`.
- **Time.** In the first run 42 minutes, with two waits of 16 minutes. The loop of scenario 5 on the API had 2419 of 2419 calls with an answer.

### Scenario 10, delete the cluster

**Ran in the first run of 2026-11-28.**

```bash
nvkectl delete cluster podvm-example
nvkectl get clusters
kh -n podvm-clusters get pods,pvc,service
kh -n nvke-system get podvmclusters,podvmmachines
kh get pv
docker ps --format '{{.Names}}'
```

- **Pass.** No cluster, no pod, no claim, no Service and no provider object. Twelve volumes with the status `Available` again, with no step by hand. In `docker ps` only the four kind nodes, and the build container of `buildx` if step 6 made one.
- **Time.** In the first run the cluster was gone from `nvkectl` after 100 s, and the twelve volumes were `Available` after 121 s.

## Not possible from public interfaces yet

- **A forced certificate renewal.** `nvkectl` and the API have no call for it. The product page starts a Temporal workflow from inside the management cluster.
- **A rotation of the etcd encryption key.** The same. Only a Temporal workflow starts it.
- **A reboot through the API or `nvkectl`.** The product page says that it is not available yet. Scenario 9 uses the label.
- **A control plane that cannot open a connection to the workers.** That needs a proxy between the two. Only a prototype exists.

## Known obstacles

- **A firewall that drops forwarded packets from a Docker bridge.** Then no container reaches the internet. A kind node cannot install D-Bus or pull an image, a new node cannot pull, and the build containers of Kata cannot download. Step 1 shows it. The guide has no way around it.
- **A resolver that a container cannot reach.** Docker gives a container the name servers of the machine. If the name server of the machine answers only on a VPN interface, step 1 fails with `bad address`, also when the firewall is open. Give the Docker daemon a name server that a container reaches, with its `dns` setting.
- **A Docker with no `buildx`.** The controller image and the provider image need it. Install the `buildx` plugin of Docker.
- **A proxy.** Docker, the kind nodes and the nodes of the new cluster each need the proxy settings. This guide does not set them.
- **`kind load docker-image` fails.** With the containerd image store of Docker, kind cannot import an image that has one platform. `install-capnico.sh` uses `kind load` for the CAPNICo image. If it fails, the image `cluster-api-provider-nico:local` is built and not loaded. Load it with the `load` helper of Part 2. Then run the `install-capnico.sh` line of the README again with `KIND_BIN=true` in front, so that the script skips its own load.
- **A clone with no version tag.** The build of step 5 names the node agent of the image with `git describe --tags --match 'v*'`. In a clone with no such tag the name is a commit, as `nvke-agent --version` in a node shows. NVKE needs a node agent of the version 0.1.26 or newer to turn etcd encryption on, and it cannot read a commit as a version. In scenario 6 the status of the cluster then stays `Updating` for 30 minutes and goes to `UpdateFailed`. `etcdEncrypted` stays `false`, no node changes, and the log of the controller has the line `node agent version "<commit>" on control-plane node <name> is older than required version 0.1.26` each minute. NVKE takes the next request after that. The other scenarios do not need the version. The fork of this guide has one version tag since 2026-11-28. A fork or a shallow clone with no tag still meets this. `git describe --tags --match 'v*'` in the tree shows if a tag is there.
- **The subnet `172.28.0.0/16` is in use.** `up.sh network` then fails. The subnet is a constant of `up.sh`, of `metallb.yaml` and of the example request.
- **A restart of the machine or of a kind node.** The bridge and the loop devices are gone then. Run `up.sh` again.

## Clean up

```bash
nvkectl delete cluster podvm-example        # if it still exists, and wait until it is gone
$NVKE/controller/hack/podvm-kind/down.sh
```

`down.sh` stops the simulator, deletes the kind cluster, detaches the loop devices, deletes their files and removes the network `podvm-nodenet`. Stop the port forward of step 13 too.

What stays on the machine:

- The kernel modules `vhost_vsock`, `vhost_net` and `openvswitch`, and the inotify limit, until the next restart.
- The Docker network `kind`, and each image that you built or pulled.
- The folders `$TRY`, `~/kata-kernel`, `~/.local/state/podvm-kind` and `/tmp/kata-out`.
- The site `podvm` in the settings of `nvkectl`, and its token cache.
