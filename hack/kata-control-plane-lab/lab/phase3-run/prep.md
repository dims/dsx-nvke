# Phase 3, preparation of the test on the second machine

Date: 2026-11-27, 16:20 to 17:02 local time of the workstation (from `date`).

This task was preparation on the workstation only. It touched nothing on the second machine. It ran no cluster. It changed no NVKE source and no simulator source.
The design is `hosted/phase3-design.md`, accepted on 2026-11-27. The two readings are `hosted/results/phase3-source-reading-nico-sim.md` and `hosted/results/phase3-source-reading-nvke.md`.

How to read this note:

- A sentence with a file reference is a fact from that file. Paths with no root are in the lab tree `/scratch/kata-cp/src/nvke-ctrllab` at `5c08484c`.
- "(deduction)" marks a conclusion that no test has shown. Section 10 has each one that the lab must prove first.
- "(tested here)" marks a fact from a test on the workstation, with a fake docker program or with an image build.
- "(machine fact)" marks a fact that the preparation on the second machine recorded today between 21:22 and 21:27 UTC. That work is not mine. Its lines are in `progress.txt` of this folder (T4-01 to T4-05), and its files are in `/scratch/kata-cp/logs/bigbox/remote-logs/p3/prep/`. I read them at 17:01, after my own work. Where they settle a deduction of mine, the text says so.

Folders:

- This folder has the scripts, the request templates, the manifest of CAPNICo and the build context of the worker image without the agent binary.
- The working copy is `/scratch/kata-cp/work/phase3/remote/p3/`. `ws-sync.sh scripts` copies it to `/root/kata-cp/p3/` on the machine.
- The build outputs are in `/scratch/kata-cp/work/phase3/`, in `sim/` (the simulator binary, the seed file), `images/` (two image archives) and `logs/`.

## 1. Short answers

| Question | Answer |
|---|---|
| Is the simulator binary ready | Yes. Static, linux/amd64, from `5c08484c`, built with the make target of the CI deploy path |
| How does a worker get two networks | A program in `NICO_CONTAINERS_DOCKER_BINARY` (`sim/docker-two-nets`). No other setting of the simulator can do it. No simulator change |
| Is the program tested | Yes, with a fake docker program, under three shells, and with the real simulator binary on the loopback address. Not with a real Docker |
| Which CAPNICo does NVKE deploy | v0.3.0-rc.1, image `ghcr.io/dsx-ai-factory/cluster-api-provider-nico/controller:v0.3.0-rc.1` |
| Does the image need a credential | No. One pull with no login passed. The archive is ready |
| Does the lab controller need a new Helm value | No (deduction). The ClusterRole for the NICo kinds is in the release of today and is bound (machine fact) |
| Must the NICo controllers of NVKE be on | No (deduction). They are off in the lab and on in the chart default |
| Does a container worker need `LOCAL_DEV_FORCE_DOCKER_MACHINE_BOOTSTRAP` | No (deduction). Keep it off |
| Is the worker image ready | The build context is ready. A build check on the workstation passed. The real build runs on the machine, because the two inner image files are there |
| Are the requests ready | Yes, as templates and as rendered examples |

## 2. What is ready and where

| What | Where | Fact |
|---|---|---|
| Simulator binary | `/scratch/kata-cp/work/phase3/sim/nico-sim` | 28.7 MB, sha256 `a127acb9b8682bc6f49e662126e41c5962ca328356f238b4fce97be851a25c68` |
| Seed file | `/scratch/kata-cp/work/phase3/sim/default-seed.yaml` | sha256 `af182b37ec301bbd680753716ae20cd9df3d3642ad0fb0f3f0726bf086cd8f74`, equal to `controller/nico-sim/internal/seed/default-seed.yaml` |
| Image archive of the simulator container | `/scratch/kata-cp/work/phase3/images/docker_29.1.3-cli.tar` | 65 MB, sha256 `d79d7adb81e8f8e5d09db580580b3797334e2c721f5db6962a5d2323da80f826`, tag `docker:29.1.3-cli` |
| Image archive of CAPNICo | `/scratch/kata-cp/work/phase3/images/ghcr.io_dsx-ai-factory_cluster-api-provider-nico_controller_v0.3.0-rc.1.tar` | 36 MB, sha256 `8f93a10bf9aadab25c50165b6166b172ed212ead886954aaa3ba011cbbc45ac2`, linux/amd64 only |
| Agent binary (not new) | `/scratch/kata-cp/work/phase2-gaps/bin-encfix/nvke-agent` | sha256 `cafddb1d4d28c79f2a07e05539440fd04402842d7c2157be754be3826b1e8a33`, `v0.24.0-beta.18-6-g41e88c4d` |
| Program for the second network | `sim/docker-two-nets` | 41 checks pass under three shells |
| Start script of the simulator | `sim/run-sim.sh` | Not run. `shellcheck` and one print of its command |
| CAPNICo manifest, Secret template, install script | `capnico/` | The manifest is a byte copy of `deploy/nico/capnico/capnico.yaml` |
| Worker image build context | `image/` | Build check passed (section 7) |
| Request templates and examples | `requests/` | Rendered and compared with the request of phase 2 and with the API schema |
| Copy script for the workstation | `ws-sync.sh` | Not run |

## 3. The simulator

### The build

- The CI deploy path builds the simulator with `GOOS=linux GOARCH=<arch> make -C nico-sim BINARY=<file> build-static` and then checks with `readelf` that the binary has no interpreter (`controller/hack/ci/backend-e2e.sh:850-857`).
- The target is `build-static` in `controller/nico-sim/Makefile:56-59`. It runs `CGO_ENABLED=1 go build -tags "netgo osusergo" -ldflags "-linkmode external -extldflags -static"`. cgo is necessary because the store is SQLite.
- The repository has no Dockerfile for the simulator. A search of the tree for a Dockerfile with `nico` or `sim` in its path finds none.
- I ran the same command with `GOARCH=amd64`, Go 1.27.4 and gcc 15.2.0, with `GOPROXY=off` and `GOFLAGS=-mod=readonly`. The build took 5 s and needed no download. The log is `/scratch/kata-cp/work/phase3/logs/build-nico-sim.log`.
- The source was a copy of the commit `5c08484c`, made with `git archive`. I did not build inside the lab tree, because that tree is read only for this task and a build in a Go workspace can write files. `controller/nico-sim` of the copy was equal to the lab tree (`diff -r`). The lab tree had no change before and after. I removed the copy after the build, because seven files of the repository in it have the bash network socket device path form.
- `readelf -l` shows no `INTERP` segment. `file` says "statically linked". The linker printed one warning about `dlopen` in SQLite. It matters only for SQLite extensions, which the simulator does not load.
- The binary has no commit stamp, because the copy has no `.git` folder.

### The container

The image is `docker:29.1.3-cli`, digest `sha256:4fa0ee1f3a7e4354c4ea34558b6d4ee32859baf4973d4c8ccc8e7fe3dd730c04`. It is the runner image of the CI deploy path (`controller/hack/ci/backend-e2e.sh:34`). It has the Docker client and a busybox shell, which the program for the second network needs.

- The second machine does not have it. Its Docker has the base node image, the provider image and two controller images, and no Docker CLI image and no CAPNICo image (machine fact, T4-05). So the archive is ready, and step 3 of section 9 loads it. One pull through `mirror.gcr.io` on the workstation passed.
- The image is Alpine 3.23.2 with BusyBox 1.37.0. It has `sh`, `flock`, `sed`, `tr`, `grep`, `date` and `sleep`. It has no bash and no curl (from a listing of the archive, `logs/docker-cli-archive-listing/files.txt`).

The exact command of step B is below. `sim/run-sim.sh start b` runs it, and `sim/run-sim.sh command b` prints it.

```
docker run \
  --detach \
  --name p3-nico-sim \
  --label p3.sim-form=b \
  --network kata-bb \
  --ip 172.29.2.5 \
  --restart no \
  --volume /var/run/docker.sock:/var/run/docker.sock \
  --volume /root/kata-cp/p3/sim:/sim:ro \
  --volume /root/kata-cp/p3/state:/state \
  --env DOCKER_HOST=unix:///var/run/docker.sock \
  --env NICO_SIM_LISTEN_ADDR=:18080 \
  --env NICO_SIM_SEED_PATH=/sim/default-seed.yaml \
  --env NICO_SIM_DB_PATH=/state/nico-sim.db \
  --env NICO_SIM_FILES_DIR=/state/files \
  --env NICO_SIM_LOG_FORMAT=text \
  --env NO_COLOR=1 \
  --env NICO_VMS_VM_BACKEND=mock \
  --env NICO_VMS_BGP_ENABLED=false \
  --env NICO_VMS_BRIDGE_CIDR=172.30.0.0/24 \
  --env NICO_VMS_CONSOLE_SSH_PORT=-1 \
  --env NICO_CONTAINERS_ENABLED=true \
  --env NICO_CONTAINERS_NODE_IMAGE=nvke-node-nico:bcc4376f-w1 \
  --env NICO_CONTAINERS_NODE_NETWORK=kata-bb-node \
  --env NICO_CONTAINERS_SPIRE_ATTESTATION_METHOD=joinToken \
  --env NICO_CONTAINERS_DOCKER_BINARY=/sim/docker-two-nets \
  --env NICO_CONTAINERS_REQUIRE_HEALTHY=true \
  --env P3_REAL_DOCKER=docker \
  --env P3_NODE_NET=kata-bb-node \
  --env P3_NODE_IP_PREFIX=172.28.2 \
  --env P3_API_NET=kata-bb \
  --env P3_API_IP_PREFIX=172.29.2 \
  --env P3_IP_FIRST=11 \
  --env P3_IP_LAST=250 \
  --env P3_LOG=/state/docker-two-nets.log \
  --env P3_LOCK=/state/docker-two-nets.lock \
  --entrypoint /sim/nico-sim \
  docker:29.1.3-cli
```

The command of step A differs in three points. `NICO_CONTAINERS_NODE_NETWORK` is `kata-bb`, `NICO_CONTAINERS_DOCKER_BINARY` is `docker`, and it has no `P3_` setting.

| Part of the command | Reason |
|---|---|
| `--network kata-bb --ip 172.29.2.5` | CAPNICo is a pod of the kind cluster and reaches the simulator over the bridge of the kind nodes. A simulator as a process of the machine is not reachable (reading, section 7). The fixed address keeps the Secret of CAPNICo true after a new container. It is outside the range that Docker gives out (`172.29.0.0/24`) and outside the MetalLB pool (`172.29.255.200` to `.250`) |
| The Docker socket | The container backend makes each worker with the Docker client (`controller/nico-sim/internal/container/docker.go:289-303`) |
| `/sim` read only, `/state` | The binary, the seed file and the program come from the machine folder. The database, the log of the program and its lock are in `/root/kata-cp/p3/state` |
| `--restart no`, no `--privileged`, no published port | Nothing starts by itself. The simulator needs no privilege. No listener on an interface of the machine |
| `--entrypoint /sim/nico-sim` | The entry script of the image does not run |
| `NICO_SIM_SEED_PATH`, `NICO_SIM_DB_PATH`, `NICO_SIM_FILES_DIR` | The defaults are relative paths (`internal/config/config.go:176`, `:188`, `:352-357`) |
| `NICO_VMS_VM_BACKEND=mock`, `NICO_VMS_BGP_ENABLED=false` | No libvirt, no bridge, no metadata server and no BGP speaker (`internal/app/app.go:129`, `:174`, `internal/vm/mock.go:31`). The values of `hack/nico-provider/run-nico-sim.sh:50-51` |
| `NICO_VMS_BRIDGE_CIDR=172.30.0.0/24` | The value must be a CIDR (`internal/config/config.go:241-243`). In mock mode it only fills catalog data. Nothing on the machine gets this range |
| `NICO_VMS_CONSOLE_SSH_PORT=-1` | No console listener (`internal/app/app.go:111`). The CI script leaves the default 2222. `hack/local-site.sh` sets `-1` |
| `NICO_CONTAINERS_NODE_IMAGE` | The default `cwe-capd-kindest-node:local` is not in the lab |
| `NICO_CONTAINERS_NODE_NETWORK` | The default `kind` is not in the lab. It is also the network whose address the simulator reports (`internal/container/docker.go:100-101`) |
| `NICO_CONTAINERS_SPIRE_ATTESTATION_METHOD=joinToken` | The default is `tpm`. With `tpm` an instance stays `Pending` until an EK certificate exists (`internal/container/convert.go:136-143`) |
| `NICO_CONTAINERS_DOCKER_BINARY` | Section 4 |
| `NICO_CONTAINERS_REQUIRE_HEALTHY=true` | The simulator stops at its start when Docker does not answer (`internal/app/app.go:90-96`) |

Two settings of the CI script are not here, `NICO_VMS_BGP_VIP_CIDRS` and `NICO_VMS_VM_DISK_GIB`. They act only on the VM backend.

Each pod and each container on `kata-bb` can reach port 18080 of the simulator. The simulator accepts each token that is not empty and starts privileged containers. That is point 2 of section 6 of the design.

## 4. The second network of a worker

### The decision

A program in `NICO_CONTAINERS_DOCKER_BINARY` is the only way with no simulator change.

- The simulator has six settings for the container backend (`internal/config/config.go:212-217`). Only two concern the network, the network name and the Docker program.
- The network name goes into one argument, `--network <name>` (`internal/container/service.go:265`). One `--network` argument names one network. The long form `name=...,ip=...` can carry a fixed address, but one value is the same for each worker, and the simulator then finds no network of that name in `docker inspect` and reports the address of any network (`internal/container/docker.go:100-108`).
- So the second network and a fixed address for each worker both need a change of the `create` call. The program does that.

Inside the program I chose the `create` call and not a `docker network connect` before `start`, as the reading proposed. The reasons are below.

- One call makes the container with both networks. If it fails, no container exists. With `network connect` a failure between the two calls leaves a container with one network.
- The fixed address needs a change of the `create` call in both ways. With that, the second way has two changed calls and the first has one.
- Docker takes more than one `--network` argument in one `create` call from version 25. I know that from the Docker release notes and not from a test. The machine has 29.1.3 (lab note).

### What the program does

- Each call that is not `create` goes to `docker` as it is, with its standard input.
- For `create` it replaces `--network kata-bb-node` with `--network name=kata-bb-node,ip=172.28.2.N` and `--network name=kata-bb,ip=172.29.2.N`. N is the first free number from 11 to 250. Each other argument stays, in the same order.
- The addresses in use come from `docker ps -aq` and one `docker inspect` of each container on the machine. A container that did not start counts with its fixed address. The program keeps no state file.
- One `create` runs at a time (a lock with `flock`), so two workers cannot get one address.
- It refuses a `create` call with no `--network kata-bb-node`, with two of them, or with `--ip`. It refuses the prefixes `172.28.0` and `172.28.1` for a node address. Docker gives out the first range (the network was made with `--ip-range 172.28.0.0/24`, lab note, `lab/phase1-second-machine/remote/c1/env-c.sh:4`), and the pod provider gives out the second.
- It prints nothing on a good call. The simulator reads the output of `create` as the container ID.
- It writes one line for each `create` to `/state/docker-two-nets.log`.

The address on `kata-bb` is fixed too (`P3_API_IP_PREFIX`). With an empty value Docker gives that address from `172.29.0.0/24`. A fixed one is my choice, because Docker gave a kind node the address of another kind node after a restart one time (lab note, `lab/phase1-second-machine/report.md:168`), and a worker must not take the address of a kind node that is down.

The node address that the simulator reports to CAPNICo is the address on `kata-bb-node`, because `NICO_CONTAINERS_NODE_NETWORK` is `kata-bb-node`. The chain test below shows it.

### The tests (tested here)

The tests are in `sim/test/`. `result.txt` has the output. No container, no network and no Docker daemon was used.

| Test | Result |
|---|---|
| `wrapper-test.sh` with `sh` (dash), with `dash`, and with the busybox of the image `docker:29.1.3-cli` | 41 of 41 checks, three times |
| The argument list of a `create` call in the form of the simulator, with a label value that has spaces and an entry command of three lines | Equal to the expected list, argument for argument |
| The next address, a container that did not start, a free address again, an address that another container holds | Pass |
| Nine calls that the program refuses | Exit code 64 each, and no `create` reached the fake |
| No free address, a failing `docker`, a failing `docker inspect` | Exit codes 69, 125 (the code of docker) and 75 |
| Six `create` calls at the same time | Six addresses, `.11` to `.16` |
| A lock that another process holds | Exit code 75 after the wait limit, then a good call |
| `sim-chain-test.sh`, the real simulator binary on `127.0.0.1` with the settings of step B | 28 of 28 checks |

What the chain test shows:

- The simulator starts with the settings of `run-sim.sh` and reads the seed file.
- For one instance request the simulator calls `create`, `start` and then `exec`. The fake got `--network name=kata-bb-node,ip=172.28.2.11` and `--network name=kata-bb,ip=172.29.2.11`.
- The instance is `Ready` with the join token method, and its address in the answer is `172.28.2.11`. A later GET reports the same address.
- A delete calls `stop` and `rm --force --volumes`. A reboot request calls `restart --time 10`.

One more check on the workstation. The Docker client 29.10.1 accepts two arguments of the form `--network name=<network>,ip=<address>` (it failed only at the connection to a socket path that does not exist). A wrong key fails before that.

Not tested, because this task allowed no container and no network on the workstation:

- That Docker 29.1.3 makes a container with these two arguments.
- Which network gives the default route, and what the image does with two interfaces.

## 5. CAPNICo

### The version and the image

- NVKE deploys CAPNICo v0.3.0-rc.1. The manifest is `deploy/nico/capnico/capnico.yaml`, and the same bytes are in `nvkectl` (`cli/internal/bootstrap/controllerdeploy/manifests/capnico.yaml`, `cmp` says equal).
- The image is `ghcr.io/dsx-ai-factory/cluster-api-provider-nico/controller:v0.3.0-rc.1`, digest `sha256:167b85fac27ceceb041b3a7378dddca95c5c0286a34a8537b7c16415f6453db7` (`cli/internal/bootstrap/manifest/bootstrap-manifest.yaml:123-127`, `deploy/nico/capnico/release.yaml:7`).
- The manifest is the public release asset `infrastructure-components.yaml` with one edit. The manager gets `--reboot-annotation=nvke.nvidia.com/reboot` and `--repair-annotation=nvke.nvidia.com/machine-health-issue` (`deploy/nico/capnico/capnico.yaml:1-42`, `:2170-2172`).
- NVKE compiles against the API types of v0.1.0 (`controller/go.mod:9`). v0.1.0 is the older one (2026-10-23). Two of its CRDs are equal to the CRDs of the manifest and three differ. `spec.siteID` is in the `NicoMachine` CRD of the manifest (`:908-913`).
- The simulator lanes of the repository do not use that manifest. They build CAPNICo from the source of the `go.mod` pin and install its chart (`controller/hack/nico-provider/install-capnico.sh:58-116`, `controller/deploy/capnico-e2e/nvke-deploy.yaml:15-26`). The design asks for the version that NVKE deploys, so the lab uses the manifest.

### The pull

- One pull on the workstation at 16:30 passed in 2 s. The workstation has no Docker login (no `~/.docker/config.json`). So the image needs no credential.
- The digest of the pull is the pinned digest.
- A comment in `controller/deploy/capnico-e2e/nvke-deploy.yaml:18-24` says that the released chart and image are in a private registry. That is not true for this image. `docs/operate/plan-installation.md:78` says that the image is public.
- The archive has one manifest, linux/amd64 (`sha256:708bae6b...`). Its name follows the rule of `bin/img-load.sh`, so that script finds it in `/root/kata-cp/dl/img/` and makes no pull on the machine.
- The public source of v0.1.0 in the Go module cache has a Dockerfile and a chart. The source of v0.3.0-rc.1 is not in the cache. Neither is needed.

### The files

| File | Content |
|---|---|
| `capnico/capnico.yaml` | The manifest as NVKE installs it, sha256 `8adb3ee1...`. Namespace `capnico-system`, five CRDs, the manager, one validating webhook for `nicomachinetemplates`, a Certificate and an Issuer of cert-manager |
| `capnico/nico-credentials.yaml.tmpl` | The Secret `nico-credentials` with the keys `endpoint`, `orgID`, `token`, `apiName`. Placeholders only |
| `capnico/install-capnico.sh` | `images`, `install`, `secret`, `status`, `remove`. Not run |

The values that the install script puts into the Secret are fake. The endpoint is `http://172.29.2.5:18080`. The organization is `novxwn552ssc`, which must be the one of the seed file (`default-seed.yaml:6`). The token is `example-token`. The simulator checks only that a token is not empty (`controller/nico-sim/internal/http/middleware.go:23-35`). The API name is `forge`.

The manifest needs cert-manager. The lab stack has it (lab note, `lab/phase1-second-machine/remote/d/stack/env.sh:63`). NVKE makes no `NicoMachineTemplate` object on the `infra` path (lab note, `lab/phase2-worker-run/result.md:56`), so the webhook gets no call (deduction).

## 6. The controller settings

The chart of the machine is equal to the chart of the lab tree (`diff -rq`). I rendered it with the values of the lab (`d/stack/values/controller-values.yaml`), the image tag `5c08484c` and a fake database password.

| Setting | Lab now | For this test | Reason |
|---|---|---|---|
| `supportedInfraProviders` | `infra` | The same | The mixed request is one `infra` request. The API accepts only the blocks in this list (`controller/deploy/charts/controller/values.yaml:357-358`) |
| `capi.rbac.create` | `true` | The same | RBAC for the Cluster API kinds |
| `capi.rbac.nico` | Not set, so the chart default `true` | The same | The render has the ClusterRole `nvke-controller-nico` and its binding. It gives create, delete, get, list, patch, update and watch on `nicoclusters` and `nicomachines`, and get on these two CRDs (`controller/deploy/charts/controller/templates/rbac-nico.yaml`). The machine has that ClusterRole with these rules, bound to the service account of the controller (machine fact, `facts-3.txt`). `kubectl auth can-i` said `no` for each verb there, because the API server does not know the kind before CAPNICo is installed. `install-capnico.sh status` repeats the check after the install |
| Rights for `nicomachinetemplates` | None | None | NVKE keeps the template in its database and applies a `NicoMachine` (`controller/internal/clients/capi/machine.go:62-77`) |
| `controllers.nico.enabled` | `false` | `false` for step A | See below |
| `nodeAgent.spireAttestationMethod` | `joinToken` | The same | One value for a deployment. Three parts must agree, which are the controller, the worker image and `NICO_CONTAINERS_SPIRE_ATTESTATION_METHOD`. A Kata pod and a container with no vTPM device have no TPM |
| `LOCAL_DEV_FORCE_DOCKER_MACHINE_BOOTSTRAP` | Not set, so `false` | Not set | See below |
| `spiffe.spire.serverAddress`, `serverPort` | `172.29.0.3`, `30081` | The same | A worker reaches it on `kata-bb` (deduction) |
| `cni.installAfterInit` | `true` | The same | The CNI comes from the package in the node image |
| `NODE_REBOOT_SOFT_REBOOT_ENABLED` | Not set, so `true` | Not set. `false` only for the reboot try | See below |

So the test needs no Helm change (deduction). The provider RBAC file of phase 2 for the pod kinds stays as it is.

### Must the NICo controllers of NVKE be on

No (deduction). `controllers.nico.enabled` starts two controllers (`controller/cmd/worker/main.go:388-420`).

- `NicoSpiffeController` writes the SPIRE agent path of a Machine from the TPM or DPU data of the `NicoMachine`. For the join token method it returns at once, because "the join-token path is set when the Machine is created" (`controller/internal/controllers/capi/nico_spiffe_controller.go:128-133`). The `capi` client sets that annotation (`controller/internal/clients/capi/machine.go:110-112`).
- `NicoProviderIDController` writes the provider ID and five labels (machine ID, site ID and name, VPC ID and name) on the Node of the new cluster (`controller/internal/controllers/capi/nico_provider_id_controller.go:143-198`).
- CAPNICo v0.1.0 writes the provider ID on the Node itself (`controllers/node_provider_id.go:54-125` of the module cache). I could not read that code for v0.3.0-rc.1.
- I found no step of the node flow that waits for the node reference of a Machine. The uses are in the bootstrap controllers, which are off (`grep` for `NodeRef` in `controller/internal`).

With the controllers off the Node of a worker has no NVKE topology labels. No pass rule needs them.
With `true` the controller stops at its start when the `NicoMachine` CRD is absent (`main.go:394-397`). The chart default is `true`, and the CI lane runs with the default.

### `LOCAL_DEV_FORCE_DOCKER_MACHINE_BOOTSTRAP`

A container worker does not need it (deduction).

- With the setting off, the preflight of a node asks the agent for the cloud-init status (`controller/internal/temporal/activities/node_preflight.go:116-119`). The worker image has a `cloud-init` program that reads the status file of the simulator (`controller/hack/capd-kindest-node/scripts/cloud-init-status-shim:33-49`). The simulator writes `running`, then `done` or `error` (`controller/nico-sim/internal/container/docker.go:136-221`).
- No file of the repository turns the setting on. The Tiltfile passes it only from a developer file (`controller/Tiltfile:1072-1080`). So the simulator lanes of CI run with it off.
- The kubeadm wrapper of the image adds `--ignore-preflight-errors=SystemVerification` to each join (`controller/hack/capd-kindest-node/scripts/kubeadm-systemverification-shim:34-54`). The image gives the kubelet `--fail-swap-on=false`.

With the setting on, each node of each cluster gets the container contract (`controller/internal/temporal/activities/capi_shared.go:27-29`). For the control plane pods that means the following.

- The preflight looks for the file `/run/cluster-api/bootstrap-success.complete` and does not ask for the cloud-init status (`node_preflight.go:112-114`, `:122-133`). The pod template then needs a command that writes the file.
- kubeadm skips its system check at init and join (`controller/internal/kubeadmconfig/init.go:195-197`, `join.go:276-278`).
- The kubelet of the cluster gets `failSwapOn: false` and reservations of 100m CPU and 256Mi. They replace the 512Mi of the request (`controller/internal/kubeadmconfig/render.go:358-372`).

Phase 2 treated a pod as a real machine. So the setting stays off.

The pool request has the two commands of the mock example that write the file (`cli/examples/nico-mock-nodepool.yaml:34-36`). They do nothing with the setting off.

### The reboot of a worker

With the default, NVKE asks the agent for a soft reboot first and waits up to 30 minutes for a new boot ID (lab note, `lab/phase2-worker-run/result.md`, W3). The reboot program of the image is a shim that powers the container off, and Docker starts it again with the same boot ID (`controller/hack/capd-kindest-node/Dockerfile:36-48`, `controller/nico-sim/internal/container/service.go:29-42`). So the soft reboot gives no new boot ID (deduction). The CI lane sets `NODE_REBOOT_SOFT_REBOOT_ENABLED=false` for that reason (`controller/deploy/capnico-e2e/controller/overlay.yaml:70-75`).

The two optional settings render with no error. The commands are in section 9.

## 7. The worker image

### What the container backend expects from the image

| Need | Source | In the base image |
|---|---|---|
| `/bin/sh`, `mount`, and `/usr/local/bin/entrypoint` with `/sbin/init` | The simulator replaces the entry point with `/bin/sh -c <its command>`. The command binds a boot ID file and ends with `exec /usr/local/bin/entrypoint /sbin/init` (`service.go:33-42`, `:271`, `:277`) | Yes. The image entry point is the same two words |
| A `/var` that Docker fills from the image | `--volume /var` (`service.go:269`) | Yes |
| systemd units for the agent on port 15005, the SPIRE agent, Open vSwitch, the network, the OVN images | `controller/hack/capd-kindest-node/Dockerfile` | Yes |
| The `cloud-init` shim | The agent asks `cloud-init status --long` | Yes |
| `python3` | The simulator reads the EK certificate file with it at each look (`docker.go:119-134`) | Yes |
| The kubeadm wrapper | A container cannot pass the system check of kubeadm | Yes |
| The kernel module `openvswitch` of the machine | The image loads it from the mounted `/lib/modules`. If it cannot, the unit stops before a fallback that removes the `bridge` module (`Dockerfile:95-109`) | The guard is there |
| The join token method | The SPIRE agent must not wait for a vTPM | Yes. No `swtpm-local` dependency |

The build checks each line of this table and stops at the first one that is absent (`image/worker-setup.sh`).

### What the worker image is

The tag is `nvke-node-nico:bcc4376f-w1`. It is the base image `nvke-node:bcc4376f-amd64` with three changes.

1. The agent binary of the lab build (`cafddb1d...`).
2. The two images that a node of the lab cannot pull, `pause:3.10.2` and the DNS cache, with the digest tag of the DNS cache. The step is the one of `p2-image/Dockerfile`. The files are on the machine in `/root/kata-cp/dl/img/inner/`.
3. A drop-in of the agent unit, `zz-p3-no-mlx5-rescan.conf`. It is not in the task text. I added it for the safety of the machine.

The reason for the drop-in:

- The base image starts the agent with `--disable-mlx5-rescan` in `/etc/default/nvke-agent` (`Dockerfile:254-257`, and the build check printed the line).
- NVKE replaces that file with its bootstrap data. Its `AGENT_ARGS` are `--secure-server-port 15005` only (`controller/internal/temporal/activities/activities.go:64-92`). The last command of the bootstrap data restarts the agent.
- Without the flag the agent runs a script at its start that can remove PCI devices of the vendor Mellanox and scan the PCI bus (`agent/internal/agent/agent.go:489-497`, `agent/internal/agent/rescan_mlx5.sh:205-263`).
- A pod of phase 2 was a Kata guest with its own kernel. A worker of phase 3 is a privileged container on the kernel of the machine.
- The script stops when `/sys/bus/pci/rescan` is not writable, and the entry point of the kind image mounts `/sys` read only (`rescan_mlx5.sh:82-97`, kind v0.33.0 `entrypoint:182`). So the script does nothing even with no drop-in (deduction). The drop-in makes it sure.
- The drop-in replaces `ExecStart` with `/usr/local/bin/nvke-agent $AGENT_ARGS --disable-mlx5-rescan`, in the way of the gate drop-in of the pod image. The build stops when the unit has another `ExecStart` line or when the binary has no such flag.

### What differs from the pod image

| Point | Pod image (p9, p10) | Worker image (w1) |
|---|---|---|
| Entry point | `podvm-entrypoint`. It mounts the two volume devices, keeps the node state and then starts the entry point of the base image | The entry command of the simulator, then the entry point of the base image |
| Bootstrap data | The program `podvm-bootstrap` and two units read the Secret copy | The simulator writes the files and runs the commands with `docker exec` |
| Volumes | `/var` and `/var/lib/etcd` on block devices of claims | `/var` on an anonymous Docker volume, `/var/lib/etcd` on a memory filesystem of at most 4 GB |
| Open vSwitch datapath | Built into the guest kernel. A drop-in accepts that | The module of the kernel of the machine. The guard of the base image stays |
| Kernel config for kubeadm | In `/boot` of the image | None. The kubeadm wrapper skips the check |
| OVN images | In the containerd store at build time (p3) | In a package file. A unit installs it at each start (34 to 57 s in the tests of p2, lab note) |
| Agent settings file | On the `/var` volume, through a link | `/etc/default/nvke-agent` of the container |
| Machine ID | A link, so each node has its own | The file of the base image, so each worker has the same machine ID as each other one (deduction from `p2-image/Dockerfile`). CI has the same |
| Health gate | Probe program and three agent flags | None. A worker is not behind the shared address |
| Readiness and startup probes | Of the pod | None. The instance is `Ready` when the container runs |
| mlx5 rescan | Runs in the guest and finds nothing | Off by the drop-in |
| Where the image must be | In the three host nodes | In Docker of the machine only |

### The build

- `image/build-worker.sh` builds on the machine with `docker build --network none`, as the lab scripts do. It needs `AGENT_SHA256`. It makes no archive and loads nothing into a kind node.
- A build check on the workstation at 16:51 passed in 7 s (tested here). It used the real base image, the real agent binary, the legacy builder (`DOCKER_BUILDKIT=0`) and no network. Each check of `worker-setup.sh` passed. The log is `/scratch/kata-cp/work/phase3/logs/worker-buildcheck.log`. I removed the check image.
- The check had no inner image files, so the import step did not run. That step is the step of `p2-image/Dockerfile`, which ran on the machine before.

Facts that the build check printed:

- The agent arguments of the base image are `--disable-mlx5-rescan --secure-server-port 15005 --bundle-server-url http://nvke-bundle-mirror/ --index-file-url http://nvke-bundle-mirror/index.json`.
- The OVN image package has 331 MB.
- The base image has no `--enable-spiffe` flag in its arguments, because this agent has no such flag.

## 8. The requests

`requests/render.sh` makes the files. It sends nothing.

| File | Call | Content |
|---|---|---|
| `cluster-request.json` | `POST /api/clusters` | The request of phase 2 plus `nodePools` with one pool |
| `pool-request.json` | `POST /api/nodePools` | The same pool for a cluster that exists |
| `pool-scale-<n>.json` | `PATCH /api/nodePools/<pool ID>` | `{"desiredNodeCount": n}` |

- Without `nodePools`, the rendered cluster request is equal to the rendered request of phase 2 (`p2-replace/request.json.tmpl` with the image p10). A `diff` of both says so.
- Each key of the request is in the API schema of the lab tree (`controller/api/openapi.yaml`, a check with `yq`).
- The pool is `nico-workers`, prefix `nw`, `systemReservedMemory` 512Mi. Its template is a `NicoMachineTemplate` with `siteID` and the fields of the mock example (`cli/examples/nico-mock-nodepool.yaml:38-54`).

The IDs are the ones of the container site of the seed file.

| Field | Value | Seed file line |
|---|---|---|
| `siteID` | `00000000-0000-0000-0000-000000000001` | 16 |
| `vpcID` | `00000000-0000-0000-0000-000000000002` | 28 |
| `interfaces[0].subnetID` | `00000000-0000-0000-0000-000000000003` | 38 |
| `sshKeyGroupIDs[0]` | `00000000-0000-0000-0000-000000000004` | 104 |
| `instanceTypeID` | `00000000-0000-0000-0000-000000000005` | 53 |

The simulator refuses another VPC, another subnet or another key group for a container (`controller/nico-sim/internal/container/convert.go:96-127`).

Add and remove a worker, as phase 2 found (lab note, `lab/phase2-worker-run/result.md`, W5):

- Add a worker with `PATCH /api/nodePools/<pool ID>` and a count that is one higher.
- Remove a worker with two calls. First `PATCH` the count to one lower, then `DELETE /api/nodes/<node ID>`. A lower count alone removes nothing. With the old count NVKE makes a new node after the delete.
- `DELETE /api/nodePools/<pool ID>` removes the pool with its workers.

`requests/examples/` has rendered files with the values of the lab. `pool-request.json` there has a cluster ID of zeros.

## 9. The order of work on the machine

Each change of the machine in this section is in section 6 of the design, apart from the points of section 12.
`P` is `/root/kata-cp/p3`, `L` is `/root/kata-cp/logs/p3`, `G` is `/root/kata-cp/p2-gaps`, `A` is `/root/kata-cp/d/stack/api.sh`.

### On the workstation

The commands run from `/scratch/kata-cp/work/phase3/remote/p3/`.

```
./ws-sync.sh scripts
./ws-sync.sh sim
./ws-sync.sh agent
./ws-sync.sh images
```

### Step 0, reads only

```
lsmod | grep -E '^(openvswitch|geneve|vport_geneve) '
find /lib/modules/$(uname -r) -name 'openvswitch.ko*' -o -name 'geneve.ko*' -o -name 'vport-geneve.ko*'
swapon --show
df -h /root
docker network inspect kata-bb kata-bb-node --format '{{.Name}} internal {{.Internal}} {{range .IPAM.Config}}{{.Subnet}} range {{.IPRange}}{{end}} {{range .Containers}}{{.Name}}={{.IPv4Address}} {{end}}'
docker ps -a --format '{{.Names}} {{.Image}} {{.Status}}'
docker image inspect nvke-node:bcc4376f-amd64 docker:29.1.3-cli --format '{{.RepoTags}} {{.Id}}'
ls -l /root/kata-cp/dl/img/inner/
$G/install-stack.sh status
$P/capnico/install-capnico.sh status
```

What to look for:

- No address `172.29.2.x` and no address `172.28.2.x` is in use. At 21:26 UTC the block `172.28.2.0/24` was free, and Docker had `.2` to `.5` in use on both networks (machine fact).
- The last command prints the ClusterRole `nvke-controller-nico` and its binding. The `can-i` lines below it say `no` while the five kinds are absent. They must say `yes` after step 4.

### Step 1, the cluster of phase 2 goes away through the NVKE API

This step is done. The preparation on the machine deleted `kata-cp1` (run folder c-5) through the NVKE API at 21:23:25 UTC, and 12 volumes are Available (machine fact, T4-02). The commands stay here for the record.

```
LOG_DIR=/root/kata-cp/logs/p2gaps/c-5 $G/run.sh delete
/root/kata-cp/p2-provider/storage.sh reset
```

### Step 2, the kernel module

```
modprobe openvswitch
ls -d /sys/module/openvswitch
lsmod | grep -E '^(openvswitch|geneve|vport_geneve|nf_conntrack|nf_nat) '
```

The first line is done. `modprobe openvswitch` ran at 21:24:55 UTC and loaded four modules, `psample`, `nf_conncount`, `nsh` and `openvswitch`. `geneve` is not loaded. The module tree has `vport-geneve.ko.zst` (machine fact, T4-03 and `facts-2.txt`).
`run-sim.sh start` refuses to start when `/sys/module/openvswitch` is absent. Section 12 has the point about the Geneve modules.

### Step 3, the images

```
docker load -q -i /root/kata-cp/dl/img/docker_29.1.3-cli.tar
$P/capnico/install-capnico.sh images
AGENT_SHA256=cafddb1d4d28c79f2a07e05539440fd04402842d7c2157be754be3826b1e8a33 $P/image/build-worker.sh
```

### Step 4, CAPNICo and its Secret

```
$P/capnico/install-capnico.sh install
```

The Secret names `http://172.29.2.5:18080`. CAPNICo reads the Secret when it works on a machine, so the simulator can start after it.

### Step 5, the controller

No command (deduction). The two optional settings are below. Each one is a Helm upgrade and a new start of the controller pods, and each one needs the word of Davanum (section 12).

```
/root/kata-cp/bin/helm upgrade nvke-controller /root/kata-cp/d/src/controller/deploy/charts/controller --namespace nvke-controller --reuse-values --set controllers.nico.enabled=true --wait --timeout 5m
/root/kata-cp/bin/helm upgrade nvke-controller /root/kata-cp/d/src/controller/deploy/charts/controller --namespace nvke-controller --reuse-values --set 'env[1].name=NODE_REBOOT_SOFT_REBOOT_ENABLED' --set-string 'env[1].value=false' --wait --timeout 5m
```

Both need the Helm environment of `install-stack.sh` (`KUBECONFIG` and the three `HELM_` folders). The first one is possible only after step 4. `install-stack.sh rollback <revision>` goes back.

### Step A, one network

The goal is the chain from the NVKE request over CAPNICo and the simulator to the node agent, its identity and `kubeadm join`, and the answer of NVKE to the mixed request.

```
$P/sim/run-sim.sh start a
mkdir -p $L/a-1
$P/requests/render.sh cluster $L/a-1 1
LOG_DIR=$L/a-1 $G/run.sh base
date -u +%FT%T.%3NZ >$L/a-1/post-time.txt
$A post /api/clusters $L/a-1/cluster-request.json | tee $L/a-1/post-response.txt
sed '$d' $L/a-1/post-response.txt | jq -r .id >$L/a-1/cluster-id.txt
```

The reads while the cluster comes up are below.

```
$A get "/api/nodes?clusterID=$(cat $L/a-1/cluster-id.txt)"
$A get "/api/nodePools?clusterID=$(cat $L/a-1/cluster-id.txt)"
docker exec kata-bb-control-plane kubectl --kubeconfig /etc/kubernetes/admin.conf -n nvke-system get machines.cluster.x-k8s.io,podvmmachines,nicomachines -o wide
$P/sim/run-sim.sh status
$P/sim/run-sim.sh logs
$P/capnico/install-capnico.sh status
```

What step A must show, in this order:

1. NVKE answers the mixed request with 201.
2. The three control plane nodes come up as in phase 2.
3. NVKE makes a `NicoMachine` with `siteID`, a Machine and a bootstrap Secret for the worker.
4. CAPNICo makes an instance with no `NicoCluster`. The `NicoMachine` gets a provider ID and an address.
5. The simulator makes one container on `kata-bb`.
6. The node agent answers NVKE on port 15005 with the join token identity, and the preflight passes with the cloud-init shim.
7. `kubeadm join` passes, and the Node registers.

Pod traffic between the worker and the control plane nodes fails in this step (deduction of the design). That is not a failure of step A.

Facts of the lab scripts for this step:

- `run.sh base` makes the namespace, the network attachment and the shared Service (`p2-provider/run.sh:61-97`).
- The `flow` step of the lab scripts posts the request of phase 2 and cannot post another file (`p2-gate/run.sh:383-398`). So the POST above uses `api.sh`.
- The checks `pool-wait` and `w2` read the workers from the `PodVMMachine` objects and count pods (`p2-worker/run.sh:40-63`, `:109`). They do not see a container worker (deduction). The checks of a container worker are new work for the test.
- If NVKE refuses the mixed request, the work stops and comes back to Davanum (design, section 8). The other way to the same objects is `run.sh flow` and then `$A post /api/nodePools` with `pool-request.json`. It does not prove pass rule 1.

The commands for the end of step A are below.

```
LOG_DIR=$L/a-1 $G/run.sh delete
/root/kata-cp/p2-provider/storage.sh reset
$P/sim/run-sim.sh status
$P/sim/run-sim.sh remove
```

After the delete, no worker container and no `NicoMachine` must be left. `run-sim.sh remove` refuses while a worker container exists.

### Step B, two networks

```
$P/sim/run-sim.sh start b
mkdir -p $L/b-1
$P/requests/render.sh cluster $L/b-1 2
LOG_DIR=$L/b-1 $G/run.sh base
date -u +%FT%T.%3NZ >$L/b-1/post-time.txt
$A post /api/clusters $L/b-1/cluster-request.json | tee $L/b-1/post-response.txt
sed '$d' $L/b-1/post-response.txt | jq -r .id >$L/b-1/cluster-id.txt
```

A first run with one worker (`render.sh cluster $L/b-1 1`) costs less when something fails.

Reads for the first worker, before the pass rules. `<w>` is the container name from `run-sim.sh status`.

```
tail -5 $P/state/docker-two-nets.log
docker inspect <w> --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}={{$v.IPAddress}} gateway {{$v.Gateway}}; {{end}}'
docker exec <w> ip -4 -o addr show
docker exec <w> ip -4 route show
docker exec <w> systemctl is-active nke-container-network ovs-vswitchd spire-agent nvke-agent
docker exec <w> systemctl show nvke-agent -p ExecStart --no-pager
docker exec <w> cat /etc/netplan/50-nke-container.yaml
docker exec <w> cat /kind/old-ipv4
docker exec <w> cat /var/lib/kubelet/kubeadm-flags.env
docker exec <w> ovs-vsctl show
```

What step B must show first:

1. The container has `172.28.2.11` on `kata-bb-node` and `172.29.2.11` on `kata-bb`.
2. The default route is the gateway of `kata-bb`, and the network unit is active.
3. NVKE has `172.28.2.11` as the address of the node, the kubelet has `--node-ip=172.28.2.11`, and the Node has it as InternalIP.
4. The tunnels of the worker and of each control plane node use the `172.28.x` addresses.

Then the pass rules 1 to 3 of the design, and after them the rules 4 to 6.

The commands to add a worker and to remove a worker (pass rule 4) are below.

```
$A get "/api/nodePools?clusterID=$(cat $L/b-1/cluster-id.txt)"
$P/requests/render.sh scale $L/b-1 3
$A patch /api/nodePools/<pool ID> $L/b-1/pool-scale-3.json
$P/requests/render.sh scale $L/b-1 2
$A patch /api/nodePools/<pool ID> $L/b-1/pool-scale-2.json
$A delete /api/nodes/<node ID>
$P/sim/run-sim.sh status
```

The container of the removed worker must be gone, and its address must be free in `docker-two-nets.log` for the next worker.

The reboot try (design, section 7). Read the two files before and after it.

```
docker exec <w> cat /kind/old-ipv4 /var/lib/kubelet/kubeadm-flags.env
docker exec <w> getent ahostsv4 <host name of the worker>
```

The delete of the cluster (pass rule 6) is the same as at the end of step A.

## 10. Deductions that the lab must prove first

1. NVKE accepts one `infra` request with a `PodVMCluster`, a `PodVMMachineTemplate` for the control plane and a pool with a `NicoMachineTemplate` (design). Step A, point 1.
2. CAPNICo v0.3.0-rc.1 makes an instance for a `NicoMachine` with `siteID` in a Cluster whose infrastructure object is a `PodVMCluster` (reading of v0.1.0 source). Step A, point 4.
3. The NVKE controller has the rights for `nicomachines`. The ClusterRole and its binding are on the machine (machine fact). The `can-i` check can pass only after step 4.
4. The NVKE controller finds the new kind `NicoMachine` with no restart. The kinds come after its start. If the first apply fails with "no matches for kind", the controller pods need a new start, and that needs the word of Davanum.
5. A worker joins with the NICo controllers of NVKE off. CAPNICo writes the provider ID of the Node.
6. A container worker passes the preflight with `LOCAL_DEV_FORCE_DOCKER_MACHINE_BOOTSTRAP` off.
7. The NVKE controller reaches port 15005 of a worker (reading). The other half is shown. A throwaway container on `kata-bb` reached the shared API address `172.29.255.220:6443` (`/readyz` 200) and the SPIRE node port `172.29.0.3:30081`, and it did not reach a fixed node address on `kata-bb-node` (machine fact, T4-01).
8. Docker 29.1.3 makes a container from a `create` call with two arguments `--network name=<network>,ip=<address>`, and `docker inspect` then has both networks under their names.
9. The default route of that container goes through `kata-bb`, because `kata-bb-node` is an internal network. Each kind node shows it for a container that joined the second network with `docker network connect`. Docker reports no gateway for `kata-bb-node` there (machine fact, `facts-1.txt`). A container with two `--network` arguments at `create` is not shown yet.
10. The network unit of the image passes with two interfaces. It needs one default route with a gateway and one address on that interface (`controller/hack/capd-kindest-node/scripts/prepare-container-network:25-39`). It writes a netplan file for that interface only and then runs `netplan apply`. The second interface must keep its address after that.
11. A worker on `kata-bb-node` reaches the fixed addresses `172.28.1.x` of the pods. The path is the bridge of that Docker network on the machine and the bridge `br-node` in each kind node (reading).
12. The kubelet and OVN use the node address `172.28.2.x`. The agent of a container node does not move the interface of the default route onto a bridge. It makes an empty `br-ex`, and Geneve leaves through the kernel route (`agent/internal/agent/open_vswitch.go:265-303`, `agent/internal/agent/cni.go:71-86`).
13. The first Geneve port makes the kernel of the machine load the Geneve modules by itself. They are not loaded now (machine fact).
14. The mlx5 rescan script does nothing in the container, and with the drop-in it does not run.
15. After a restart of a worker container, the entry point of the kind image finds the same first address for the host name. If it finds another one, it replaces the old address in `/var/lib/kubelet/kubeadm-flags.env` and `/etc/kubernetes/kubelet.conf` (kind v0.33.0 `entrypoint:486-524`). With two networks the order of the two addresses in `/etc/hosts` decides. If the first boot stored the node address and a later boot finds the `kata-bb` address first, the kubelet gets the wrong node address. The reads of the reboot try show it.

## 11. Open points

1. The reboot of a worker through NVKE. With the default setting NVKE waits 30 minutes for a soft reboot that gives no new boot ID (deduction). Then it sets the annotation. I do not know if CAPNICo then sends the instance patch that the simulator answers with `docker restart`, or the power call that the simulator does not have (reading, section 1).
2. The simulator gives each worker the restart policy `always` (`service.go:264`). The reboot shim of the image needs it. So a worker starts again by itself after a restart of Docker or of the machine. The simulator container has `--restart no`.
3. Each worker has the same machine ID. I do not know if a part of the cluster cares. CI runs that way.
4. A privileged worker sees each device of the machine, also the loop devices of the lab volumes (reading). It shares the kernel settings of the machine.
5. Disk. The worker image adds the agent binary to the 3.2 GB of the base image. Each worker has one anonymous volume for `/var` with the OVN images (the package has 331 MB). The reading estimates 1 to 3 GB for each worker.
6. A worker has no CPU limit and no memory limit. Its kubelet sees the whole machine.
7. The checks of the lab scripts for a worker are for a pod (section 9).
8. The webhook of CAPNICo and the NICo controllers of NVKE got no test thought beyond the source reading.
9. `docker-two-nets` takes each container of the machine into its list of addresses. With many containers the two Docker calls take longer. The lab has about ten.

## 12. Points to decide

1. The Geneve modules. The design allows the load of `openvswitch`. The first tunnel port needs `vport_geneve` and `geneve` too. Either the kernel loads them by itself at that moment (deduction), or step 2 loads them by hand with `modprobe geneve` and `modprobe vport-geneve`. Both are a module load that the design text does not name.
2. The NICo controllers of NVKE. Leave them off, which needs no controller change, or turn them on after step B to see the provider ID path and the labels of NVKE. On is one Helm upgrade and a new start of the controller.
3. `NODE_REBOOT_SOFT_REBOOT_ENABLED=false` for the reboot try, as the CI lane has it. Without it the try takes 30 minutes more. It is one Helm upgrade, and it acts on each cluster of the deployment.
4. The drop-in in the worker image that keeps `--disable-mlx5-rescan`. It is my addition. Without it the worker image is the base image with the agent and the two images, and the guard is the read only `/sys`.
5. The fixed address on `kata-bb` for a worker (`172.29.2.N`). The task asked only for the fixed node address. An empty `P3_API_IP_PREFIX` in `env-p3.sh` gives that address back to Docker.
6. The fixed address `172.29.2.5` of the simulator, and the ranges `172.28.2.11` to `.250` and `172.29.2.11` to `.250` for workers.
7. Step A with the mixed create request, as the design says, or with the `flow` of phase 2 and a pool request after it, which keeps each check of the lab scripts for the control plane.

## 13. Changes on the machine and how to remove them

From this task nothing is there. The preparation on the machine loaded the kernel module `openvswitch` and deleted the cluster of phase 2 (machine fact). The table is for the test.

| Change | Removal |
|---|---|
| Kernel module `openvswitch` (and the Geneve modules) | `modprobe -r` after the last worker is gone, or a restart of the machine |
| `/root/kata-cp/p3` and `/root/kata-cp/logs/p3` | Remove the folders |
| Two archives in `/root/kata-cp/dl/img/` | `unlink` |
| Images `docker:29.1.3-cli` and `nvke-node-nico:bcc4376f-w1` in Docker, the CAPNICo image in Docker and in the four kind nodes | `docker rmi`, `ctr -n k8s.io images rm` in each node |
| The build context `/root/kata-cp/work/p3-worker-image-ctx` | Remove the folder |
| CAPNICo in the lab cluster (namespace `capnico-system`, five CRDs, the webhook, cluster roles) and the Secret | `$P/capnico/install-capnico.sh remove` |
| The simulator container `p3-nico-sim` | `$P/sim/run-sim.sh remove` |
| Worker containers with their anonymous volumes | Through the NVKE API. The simulator runs `docker rm --force --volumes` |
| A cluster of the test | `LOG_DIR=<run folder> $G/run.sh delete`, then `storage.sh reset` |

## 14. What I did not do, and what failed

- I ran no command on the second machine. Each fact about it comes from the lab notes and from the machine facts of today, which another task recorded.
- I found the file `progress.txt` of that task in this folder at 17:01, after my work. I did not change it. Before that, section 6 said that `kubectl auth can-i` proves the rights before CAPNICo is there. That was wrong, and the text is corrected.
- The real worker image is not built. The two inner image files are on the machine only.
- `run-sim.sh`, `install-capnico.sh`, `build-worker.sh` and `ws-sync.sh` did not run. They passed `shellcheck`. `run-sim.sh command` ran against a copy of the lab settings file and printed the command of section 3.
- No real Docker saw the program `docker-two-nets`.
- I did not read the source of CAPNICo v0.3.0-rc.1. The module cache has v0.1.0.
- The first run of the wrapper test with the busybox of the workstation did not end. That busybox has no `flock` applet, and each `create` waited 60 s for the lock. I stopped the run, added a check for `flock` to the program, and ran the test with the busybox of the image itself.
- One check of the wrapper test was wrong in its first form (a count on a file that did not exist). I corrected the check.
- I did not build in the lab tree. The source was a `git archive` copy of the same commit, which is removed now.
- The archive of the image `docker:29.1.3-cli` and the busybox that I took out of it for the test are from a public image. The busybox ran on the workstation only as the shell of the wrapper test.
