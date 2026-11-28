# Phase 3 source reading: the NICo simulator and how the lab can use it

Date: 2026-11-27, 15:39 to 16:02 EST (from `date`). NVKE source: `/home/dsrinivas/go/src/github.com/nvidia/nvke` at `d625fcfa`. NICo provider for Cluster API (CAPNICo): `github.com/dsx-ai-factory/cluster-api-provider-nico` v0.1.0 from the Go module cache. `controller/go.mod:9` pins that version, at `d625fcfa` and at `bcc4376f`.

I read source and notes only. I ran no build, no test, no container, no cluster and no command on another machine. I did not read `context/`. I did not read the macOS backend, the web page of the simulator, and `controller/test/kubeadm/scripts/setup-ci-host.sh`.

How to read the note:

- `SIM/` is `controller/nico-sim/`. `C/` is `controller/`. `NODE/` is `controller/hack/capd-kindest-node/`. `SETUP` is `controller/nico-sim/scripts/setup-linux.sh`. Other paths start at the root of the NVKE checkout.
- `CAPNICO/` is `/home/dsrinivas/go/pkg/mod/github.com/dsx-ai-factory/cluster-api-provider-nico@v0.1.0/`.
- `NOTES/` is `/home/dsrinivas/notes/hosted/`. `REPORT` is `NOTES/lab/phase1-second-machine/report.md`.
- A reference that starts with `:` is in the file of the reference before it.
- A sentence with a file reference is a fact from that file.
- "(deduction)" marks a conclusion of mine. No file states it and no test proved it.
- "(lab note)" marks a fact from the lab notes.

## Main points

1. nico-sim is one process that answers the NICo REST API and makes a machine for each instance request. A machine is a libvirt virtual machine (backend nico-vms) or a privileged Docker container (backend nico-containers).
2. NVKE does not talk to the simulator. CAPNICo talks to it. One Secret with an endpoint, an organization and a token points CAPNICo at the simulator. The simulator accepts each token that is not empty.
3. The container backend runs the same node image that the lab pod image is built from. The lab has that image. The lab uses join tokens, and CI uses them too on a runner with no vTPM device.
4. The container backend fits the second machine better for a first test. It needs no package, no new bridge and no firewall rule. The VM backend needs all three.
5. CAPNICo v0.1.0 has a field `spec.siteID` on the machine. With that field the provider does not read a `NicoCluster`. So a `NicoMachine` can be in a cluster whose infrastructure object is a `PodVMCluster`, as far as CAPNICo is concerned.
6. A simulated worker must have an address on the node network of the control plane pods (`172.28.0.0/16`). Else the pod network between the worker and the control plane nodes does not work (deduction). The simulator gives a container one Docker network only.
7. No lane of the repository puts the control plane and the workers of one cluster on two providers. Whether NVKE accepts that on the `infra` path is a question for the other reading.

## 1. What nico-sim is

nico-sim is a stand-alone simulator of NICo instances for local development. One server and one API serve two backends, and both can run at the same time (`SIM/README.md:3-12`).

### What it simulates

The API is the NICo REST API with the types of the public NICo client library (`SIM/go.mod:6`, `SIM/internal/http/router.go:14`).

- Routes exist under `/v2/org/{org}/carbide/...`, under `/v2/org/{org}/forge/...` and under `/v1/orgs/{orgId}/...` (`SIM/internal/http/router.go:69-126`).
- Each route needs a bearer token, except `/healthz`, `/files/` and `/ui/`. The server checks only that the token is not empty (`SIM/internal/http/middleware.go:23-35`, `:77-83`).
- The catalog is read only and comes from a seed file. It has one tenant, two sites, two VPCs, two subnets, one VPC prefix, seven instance types, two SSH key groups, one IP block and one InfiniBand partition (`SIM/internal/seed/default-seed.yaml:4-121`). The routes are GET only (`SIM/internal/http/router.go:102-130`).
- Instances have create, get, list, patch and delete (`SIM/internal/http/router.go:82-93`, `SIM/internal/http/handler_instances.go:25-180`).
- The site of the VPC in the request selects the backend. The caller passes no backend flag (`SIM/internal/http/placement.go:18-57`, `SIM/internal/http/backend.go:71-80`).

The next table has the behaviors.

| Behavior | VM backend | Container backend |
|---|---|---|
| Create | The handler writes the desired state to SQLite. Four workers reconcile it (`SIM/internal/lifecycle/engine.go:238-291`, `:376-556`) | The handler runs `docker create` and `docker start` at once (`SIM/internal/container/service.go:210-299`) |
| Status | `Provisioning`, `Configuring`, `Ready`, `Terminating`, `Error` (`SIM/internal/http/convert.go:214-227`) | `Ready`, `Pending` or `Error` from `docker inspect` (`SIM/internal/container/convert.go:129-144`) |
| Reboot | A patch with `triggerReboot` reboots the domain (`SIM/internal/lifecycle/engine.go:707-733`) | The same patch runs `docker restart` and gives the node a new boot ID (`SIM/internal/container/service.go:179-188`, `SIM/README.md:376-386`) |
| Delete | The engine deletes the domain, the DHCP entry and the instance folder (`SIM/internal/lifecycle/engine.go:327-361`) | `docker stop`, then `docker rm --force --volumes` (`SIM/internal/container/docker.go:111-117`) |
| User data | Real cloud-init reads a metadata server or a seed image (`SIM/README.md:268-289`) | The simulator applies `write_files` and `runcmd` with `docker exec`. It reads no other key (`SIM/internal/container/docker.go:28-39`, `:136-198`) |
| TPM | A software TPM for each VM when `swtpm` is installed. The instance carries the EK certificate (`SIM/README.md:327-341`) | A software TPM in the container. The simulator reads the EK certificate file with `docker exec` (`SIM/internal/container/docker.go:119-134`) |
| Network | A host bridge, DHCP, a metadata server and a BGP speaker for kube-vip (`SIM/README.md:154-183`) | One Docker network that exists. Docker gives the address (`SIM/internal/container/service.go:265`, `SIM/internal/container/docker.go:96-109`) |
| Stop and start | Routes under `/sim` that NICo does not have (`SIM/internal/http/router.go:144-147`) | None |

Other parts that it simulates:

- A machine lookup. CAPNICo asks for the machine of an instance, and the simulator returns a machine with a made-up DPU machine ID, a hash of the first address (`SIM/internal/http/router.go:98-100`, `SIM/internal/http/handler_machines.go:67-97`).
- Capacity. Each instance type has 100 machines and one InfiniBand capability with the name `mlx5` (`SIM/internal/http/handler_instance_types.go:15-22`, `SIM/internal/http/convert.go:143-169`).
- Boot from an iPXE script, for a VM. The simulator parses the script, downloads the image that it names and boots it under UEFI (`SIM/internal/lifecycle/engine.go:779-806`).
- A file server without a token, diagnostics over SSH and a console log, for a VM (`SIM/README.md:303-325`, `:574-629`).

### What it does not simulate

- Physical inventory and failure domains. The machine list is empty by design (`SIM/internal/http/router.go:94-97`).
- The machine power API. The router has no such route. CAPNICo calls it for a graceful restart (`CAPNICO/internal/nico/client.go:265-277`). I did not read how CAPNICo reacts to the missing route.
- Create, change or delete of a VPC, a subnet or another catalog object. Only GET routes exist.
- GPUs. Each seeded instance type has `gpu_count: 0` (`SIM/internal/seed/default-seed.yaml:52-101`).
- NVLink partitions. The list is empty (`SIM/internal/http/router.go:110`, `:126`).
- For a VM, the simulator refuses a request with a chosen machine, a second VPC, NVLink interfaces, DPU extension services, an unhealthy machine, or a chosen address or device for an interface (`SIM/internal/http/backend_vm.go:98-120`).
- Network separation. A VPC is a name. All VMs are on one bridge, and all containers are on one Docker network (deduction from `SIM/internal/lifecycle/engine.go:508-520` and `SIM/internal/container/service.go:265`).
- Checks of the token, or of a tenant boundary beyond the one seeded tenant.

The VM backend also has a mock runtime with no machine at all. Each state change is instant (`SIM/internal/vm/mock.go:11-100`, `SIM/README.md:37-43`). The container lanes run the VM backend in that mock mode.

## 2. The two backends

| Point | VM backend (nico-vms) | Container backend (nico-containers) |
|---|---|---|
| A machine is | A libvirt domain `nico-vm-<instance ID>` (`SIM/internal/lifecycle/engine.go:496`, `SIM/internal/vm/libvirt/virsh.go:82-122`). On macOS a QEMU process | A Docker container `<name>-<first 8 characters of the ID>` with the instance name as hostname (`SIM/internal/container/service.go:211`, `:254-273`) |
| Image | A qcow2 file. With no iPXE script it is the base image, a stock Ubuntu cloud image in the tests (`SIM/internal/config/config.go:183`, `SIM/cmd/nico-sim/testserver.go:198-203`). With an iPXE script it is the image that the script names. The NVKE lanes boot the NVKE node image that way (`C/test/fixtures/releases/nvke-nico-vms-24.04-amd64-fde-machineimage.yaml:14-31`) | `cwe-capd-kindest-node:local` by default (`SIM/internal/config/config.go:214`). One image for all nodes |
| Who builds the image | `os-image/` builds the node image with Packer and QEMU. The prebuilt images are private (`os-image/README.md:12-15`, `:21-24`). The CI lane pulls one from GHCR (`C/hack/ci/nico-vms-e2e.sh:418-470`) | `NODE/build-image.sh` builds it from `kindest/node:v1.36.4` (`NODE/Dockerfile:18-22`). `make -C controller capd-image` starts the build (`C/Makefile.dev:684`). The agent comes from the checkout (`NODE/build-image.sh:302-334`) |
| What runs inside | A full operating system with systemd, cloud-init, `nvke-agent` and `spire-agent` (`os-image/README.md:3-7`). The diagnostics list also names the kubelet and containerd (`SIM/README.md:305-314`) | systemd, containerd and the kubelet of the kind node image, `nvke-agent` on port 15005, `spire-agent`, Open vSwitch, a `cloud-init` shim and a kubeadm wrapper (`NODE/Dockerfile:24-26`, `:50-67`, `:75-90`, `:153-175`, `:241-257`) |
| Kernel | Its own kernel | The kernel of the Docker host. Open vSwitch uses the kernel datapath of the host and loads the module from the mounted `/lib/modules` (`NODE/Dockerfile:92-112`, `NODE/scripts/nvke-agent-container-ovs.conf:4-9`) |
| Needs KVM | Yes, for a usable speed. With no `/dev/kvm` the domain runs in software emulation, about 10 times slower (`SIM/internal/vm/libvirt/virsh.go:315-320`, `C/test/kubeadm/README.md:183-199`) | No |
| Privilege | The simulator binary needs `CAP_NET_ADMIN` for the bridge and the routes (`SIM/Makefile:32-36`, `:61-63`). The host setup needs root | Each node is `--privileged`, with seccomp and AppArmor off (`SIM/internal/container/service.go:258-260`). The simulator needs the Docker CLI and the Docker daemon (`SIM/internal/container/docker.go:289-303`) |
| CPU and memory | 2 vCPUs and 2048 MiB by default (`SIM/internal/config/config.go:119-126`). The instance type overrides both (`SIM/internal/lifecycle/engine.go:457-475`). The sample cluster uses 4 CPUs and 8 GiB for a control plane node and 4 CPUs and 6 GiB for a worker (`C/hack/create-nico-vms-cluster.sh:12-16`, `:56-63`) | No limit on the container (`SIM/internal/container/service.go:254-273`). The catalog type says 2 CPUs and 2 GiB, and nothing enforces it (deduction) |
| Disk | An overlay over the base image, 20 GiB by default and 30 to 60 GiB by instance type (`SIM/internal/config/config.go:127-130`, `SIM/internal/seed/default-seed.yaml:60-101`). The node image file has about 3.1 GB (`.github/workflows/nico-vms-e2e.yml:330-331`) | The image, one anonymous Docker volume for `/var`, and a memory filesystem of at most 4 GB for `/var/lib/etcd` (`SIM/internal/container/service.go:263`, `:268-269`). The lab build of the image has 3.22 GB (lab note, `NOTES/runlog.md:119`) |
| TPM | A software TPM when `swtpm` is on the host (`SIM/internal/vm/libvirt/virsh.go:340-347`) | A software TPM that needs the device `/dev/vtpmx` of the host kernel, module `tpm_vtpm_proxy` (`NODE/scripts/local-start-vtpm-proxy:5-9`, `C/hack/ensure-vtpm-proxy.sh:32-35`). Not needed with join tokens |
| Ready rule | Port 22 answers, or cloud-init called back when the request asks for it (`SIM/internal/lifecycle/engine.go:586-650`) | The container runs. With the TPM method the EK certificate must also exist (`SIM/internal/container/convert.go:129-144`) |

Facts about the container backend that a lab plan needs:

- The container starts with an entry command of the simulator, not with the entry point of the image. The command sets the boot ID and then runs `/usr/local/bin/entrypoint /sbin/init` (`SIM/internal/container/service.go:33-42`, `:271`, `:277`).
- The container has `--restart always`, a mount of `/lib/modules` of the host and one `--network` argument (`SIM/internal/container/service.go:254-273`).
- The seed must have exactly one container site with one VPC, one subnet and one instance type (`SIM/internal/state/queries_static.go:330-357`). A request for another VPC or tenant fails (`SIM/internal/container/service.go:144-146`).
- The image guards the host. If the Open vSwitch module cannot load, a unit step fails before a fallback of Open vSwitch that removes the `bridge` module and with it each bridge of the host (`NODE/Dockerfile:95-98`, `:107-109`). The lab pod image keeps that guard (lab note, `NOTES/lab/phase2-node-image/ovs-datapath-check:1-11`).

## 3. How NVKE talks to the simulator

NVKE does not talk to it. The path has three steps.

1. NVKE writes Cluster API objects, among them a `NicoMachine` and a bootstrap Secret.
2. CAPNICo reads the `NicoMachine` and calls the NICo API.
3. The endpoint of that API is the simulator.

Facts:

- I found no import of the NICo client library in `controller/internal`, `controller/cmd`, `cli/internal`, `agent` or `auth`. `controller/go.mod` has no such requirement. So the controller has no setting for a NICo endpoint.
- CAPNICo reads one Secret, `nico-credentials` in the namespace `capnico-system`, with the keys `endpoint`, `orgID`, `token` and `apiName` (`CAPNICO/internal/nico/config.go:24-35`, `:115-176`, `CAPNICO/cmd/main.go:32-33`).
- The repository says that the Secret "is the ONLY difference between a nico-sim lane and a NICo site" (`C/deploy/capnico-e2e/nvke-base-config/20-nico-credentials.yaml.tmpl:10-13`).
- The credentials are fake. The organization is `novxwn552ssc`, the token is `nico-simctl-token`, and the API name is `forge` (`C/hack/nico-provider/Tiltfile:13-14`, `:40-46`). The deploy file says that nothing in it is secret on that lane (`C/deploy/capnico-e2e/nvke-deploy.yaml:28-31`).
- The endpoint is `http://<host>:18080`. With Tilt on Linux the host is the gateway address of the kind Docker network (`C/hack/nico-provider/Tiltfile:142-148`, `:172-175`, `C/Tiltfile:330-333`). In the CI deploy path the host is the address of a runner container on that network (`C/hack/ci/backend-e2e.sh:1159-1173`, `:1202`).

How CAPNICo is installed:

- `C/hack/nico-provider/install-capnico.sh` builds the image from a source folder, loads it into kind and installs the chart of that folder with Helm (`:58-116`). It then sets the reboot and repair annotation names of NVKE on the manager (`:125-129`).
- The source folder is a copy of the pinned module from the Go module cache (`docs/get-started/quickstart-local.md:81-113`, `.github/workflows/nico-vms-e2e.yml:184-190`).
- The chart has five CRDs, the manager, a validating webhook and a certificate from cert-manager (`CAPNICO/chart/templates/`).

The next table has the settings of the NVKE controller that concern the path.

| Setting | Use | Reference |
|---|---|---|
| `supportedInfraProviders` | The API accepts only the provider blocks in the list. The container lane needs `infra`, and the VM lane needs `nico` | `C/deploy/charts/controller/values.yaml:357-358`, `C/deploy/capnico-e2e/controller/overlay.yaml:35-45`, `C/Tiltfile:142-153` |
| `controllers.nico.enabled` | Runs the controllers that watch `NicoMachine` objects. The controller exits when the value is true and the CRD is absent | `C/deploy/charts/controller/values.yaml:85-87`, `C/Tiltfile:1111-1114` |
| `capi.rbac.create`, `capi.rbac.nico` | RBAC for the Cluster API kinds and for the NICo kinds | `C/deploy/charts/controller/values.yaml:434-440` |
| `nodeAgent.spireAttestationMethod` | `tpm`, `joinToken` or `dsxImds`, for each new node of the deployment | `C/deploy/charts/controller/values.yaml:109-115` |
| `spiffe.spire.serverAddress` | The SPIRE address that NVKE writes into the agent configuration of each node | `C/Tiltfile:385-392`, `:1138` |

The smallest working setup has seven parts. The list comes from the scripts that run the simulator with no Tilt (`C/hack/nico-provider/run-nico-sim.sh:36-59`, `hack/local-site.sh:445-487`).

1. The simulator binary, built with cgo because the store is SQLite (`C/test/kubeadm/README.md:98-106`). `make -C controller/nico-sim build-static` builds a static binary (`SIM/Makefile:56-59`).
2. The seed file. The default path is relative, so the process needs `NICO_SIM_SEED_PATH` or the simulator folder as working directory (`SIM/internal/config/config.go:188`, `C/hack/nico-provider/run-nico-sim.sh:36-38`).
3. The settings for containers only. They are `NICO_VMS_VM_BACKEND=mock`, `NICO_VMS_BGP_ENABLED=false`, `NICO_CONTAINERS_ENABLED=true`, `NICO_CONTAINERS_NODE_IMAGE`, `NICO_CONTAINERS_NODE_NETWORK`, `NICO_CONTAINERS_REQUIRE_HEALTHY=true` and `NICO_VMS_CONSOLE_SSH_PORT=-1` (`C/hack/nico-provider/run-nico-sim.sh:47-59`, `hack/local-site.sh:472-476`).
4. `NICO_CONTAINERS_SPIRE_ATTESTATION_METHOD`, equal to the method of the node image and of the controller. The default is `tpm` (`SIM/internal/config/config.go:215`). The README table does not list the variable.
5. CAPNICo with its CRDs, and the Secret.
6. A controller with `infra` or `nico` in `supportedInfraProviders`.
7. A request with the seeded IDs. `C/hack/create-local-nico-cluster.sh:35-133` has the full body for the `infra` block.

In that mode the simulator makes no bridge and starts no metadata server and no BGP speaker. It opens the API port, and the console port unless the value is `-1` (`SIM/internal/app/app.go:108-129`, `:170-195`, `SIM/internal/vm/mock.go:31`).

The workstation needs one caution. `C/hack/nico-provider/run-nico-sim.sh:82` and `cli/e2e/bootstrap/run-nico.sh:377` test the port with the bash network socket device. Do not copy those lines into a command on the workstation. `hack/local-site.sh:482-483` does the same test with `curl` on `/healthz`.

## 4. How the repository uses the simulator today

| Use | Start | Backend | Cluster shape | Provider block |
|---|---|---|---|---|
| Local development | `make -C controller capd-up`, then `tilt up` in `controller/` with the providers `capi_core`, `bgp-containers`, `nico` (`C/tilt_config.json.example`, `docs/get-started/quickstart-local.md:117-167`) | Containers by default (`SIM/Tiltfile:69-70`) | 1 control plane node and 1 worker in the quickstart (`docs/get-started/quickstart-local.md:210`). The Tilt button makes 1 and 0 (`C/hack/nico-provider/Tiltfile:246-266`) | `infra` with `NicoCluster` and `NicoMachineTemplate` (`C/hack/create-local-nico-cluster.sh:41-129`) |
| Local development with VMs | `sudo SETUP`, then Tilt with `nico_sim_backends: ["vm"]` | VMs | 1 and 1 (`C/hack/create-nico-vms-cluster.sh:66-67`) | `nico` (`C/hack/create-nico-vms-cluster.sh:134-177`) |
| Local site | `make local-site-setup` (`Makefile:718`, `hack/local-site.sh:445-487`) | Containers | 1 and 1 | `nico` (`deploy/examples/local-site/tenant-amd64.yaml:22-51`) |
| CI lane "NICo E2E" | `.github/workflows/nico-e2e.yml`, body `C/hack/ci/backend-e2e.sh` | Containers. The simulator runs in a runner container on the kind network (`C/hack/ci/backend-e2e.sh:1163-1173`) | 1 and 1 for a pull request. 3 and 1, 3 and 0, 1 and 0 in the full run (`C/test/e2e/tenant_test.go:163-171`, `:234-248`, `:278-333`) | `infra` (`C/test/e2e/internal/nvke/request.go:327-380`, `:416-476`) |
| CI lane "NICo VMs E2E" | `.github/workflows/nico-vms-e2e.yml`, body `C/hack/ci/nico-vms-e2e.sh`, on the host with Tilt in the background | VMs with KVM | 3 and 1 in the happy path, 1 and 1 in two smaller entries (`C/test/e2e/tenant_test.go:249-274`, `:334-372`) | `nico` (`C/test/e2e/internal/nvke/request.go:637-660`) |
| CI lane "Kubeadm Bringup E2E" | `.github/workflows/kubeadm-bringup-e2e.yml`, test in `C/test/kubeadm/` | VMs. No NVKE controller and no CAPNICo | 2 stock Ubuntu VMs. The test calls the agent, which runs `kubeadm init` on the first and joins the second as a worker (`C/test/kubeadm/README.md:3-10`, `C/test/kubeadm/internal/nicovms/launch.go:133-216`, `:307-367`) | None |
| `nvkectl bootstrap site` lane | `cli/e2e/bootstrap/run-nico.sh` | Containers through `nerdctl`, with the TPM method (`:5-24`, `:347-373`) | The control plane nodes of a management cluster | Site spec with `infra.provider: nico` |
| Tests of the simulator | `make test`, `make test-integration-mock`, `make test-integration-libvirt` (`SIM/Makefile:76-105`) | Mock, libvirt, QEMU | No cluster | None |

In each cluster of each use, the control plane nodes and the workers come from the simulator, from one backend. I found no test that puts the two roles of one cluster on two providers.

The same builder makes the request for the container backend and for a real NICo site. The source says that the manifests are identical and that only the identifiers and two payloads differ (`C/test/e2e/internal/nvke/request.go:271-305`).

The next table has the times that the source states. I measured none.

| What | Time | Reference |
|---|---|---|
| 1 control plane node and 1 worker as containers, to "Provisioned" | About 8 minutes | `docs/get-started/local-site.md:161` |
| 1 control plane node and 1 worker as VMs with KVM, a healthy create | About 8.5 minutes | `C/test/e2e/tenant_test.go:264-265` |
| Wait limit of the tests for a create | 15 minutes with containers, 30 minutes with VMs | `C/test/e2e/tenant_test.go:240`, `:266`, `:293`, `:347` |
| The whole VM lane, happy path | 41 minutes on arm64, 1 hour 31 minutes on amd64 | `.github/workflows/nico-vms-e2e.yml:122-123` |
| The first local site setup | About 20 minutes, most of it the Open vSwitch packages and the node image | `docs/get-started/local-site.md:69` |
| One VM with a stock Ubuntu image under libvirt | 60 to 120 seconds | `SIM/docs/e2e-testing.md:27-32` |

## 5. The network of the simulated machines

### What the simulator makes or expects

The VM backend in bridge mode, the default, needs these parts on the host:

- A host bridge `controllerbr0` with `172.30.0.0/24` and the gateway `172.30.0.1` (`SETUP:419-429`).
- The address `169.254.169.254/32` on the bridge for the metadata server (`SETUP:431-437`).
- A dnsmasq process for DHCP from `.10` to `.254` and for DNS. It resolves `carbide-pxe.forge` to the gateway (`SETUP:499-515`).
- Ten iptables rules. Five INPUT accept rules on the bridge, a MASQUERADE rule for the bridge range, two FORWARD rules, and two REDIRECT rules, port 80 to 7777 and port 179 to 10179 (`SETUP:461-473`, `:530-566`).
- Two sysctl values, `net.ipv4.ip_forward=1` and `net.ipv4.fib_multipath_hash_policy=1` (`SETUP:530-531`).
- A range for the control plane VIPs, `172.31.0.0/24`, that is not on the bridge. The speaker puts a blackhole route for the range and one `/32` route with several next hops for each announced VIP into the host routing table (`SIM/README.md:172-181`, `SIM/internal/bgp/speaker.go:533-585`).

A VM gets its address in one of two ways. With no iPXE script the simulator takes the first free address of the subnet and writes it into the seed image. With an iPXE script the VM asks dnsmasq, and the simulator reads the lease (`SIM/internal/lifecycle/engine.go:412-430`, `:593-615`, `SIM/internal/ipam/ipam.go:12-54`). The hardware address comes from the instance ID (`SIM/internal/lifecycle/engine.go:938-955`).

In libvirt network mode the VM joins a libvirt network that exists, and libvirt gives the address. The simulator makes no bridge and no rule, and the BGP speaker does not start (`SIM/README.md:185-228`, `SIM/internal/app/app.go:126-129`).

The container backend makes no network. It names one Docker network that exists, `kind` by default, and Docker gives the address (`SIM/internal/config/config.go:213`, `SIM/internal/container/service.go:265`). The simulator reports the address of the container on that network. If the container has no address there, it reports the address of another network of the container (`SIM/internal/container/docker.go:96-109`).

### The control plane VIP

- With VMs, each control plane node runs kube-vip in BGP mode with the ASN 65100. kube-vip peers with the bridge gateway on port 179, and a rule sends the port to the speaker of the simulator (ASN 4294967000) on port 10179. The speaker installs the routes on the host (`SIM/README.md:163-170`, `SIM/internal/config/config.go:141-159`).
- With containers, the simulator has no speaker. The provider `bgp-containers` starts an FRR container with `--network host`. FRR listens on port 179 of the host and puts the routes into the host routing table. kube-vip finds the kind gateway as its peer (`C/hack/bgp-containers/up.sh:87-99`, `C/hack/bgp-containers/frr.conf.tmpl:17-25`, `C/hack/bgp-containers/README.md:86-125`). The tests use the VIP `172.31.2.1` (`C/test/e2e/tenant_test.go:1776-1779`).
- The local site tenant has no VIP. kubeadm then uses the address of the control plane node, and no BGP part is needed (`deploy/examples/local-site/tenant-amd64.yaml:19-20`).

A cluster with its control plane in pods has no kube-vip. Its endpoint is the LoadBalancer address in `controlPlaneEndpoint` (lab note, `NOTES/summary.md:24`). So phase 3 needs neither speaker (deduction).

### The pod network

The tests ask for OVN-Kubernetes by default, and Calico is the other choice (`C/test/e2e/tenant_test.go:1385`, `:1790`). In a container node, Open vSwitch uses the kernel datapath of the host, and Geneve leaves through the kernel route of the node interface (`NODE/scripts/nvke-agent-container-ovs.conf:4-9`). The lab cluster also runs OVN-Kubernetes with Geneve tunnels between the fixed addresses (lab note, `NOTES/lab/phase2-worker-run/result.md:113-114`).

### How the repository joins two container networks

The local site puts the site node and the tenant nodes on two bridges. The setup adds two FORWARD accept rules and one accept rule in the raw table, because Docker 28 drops a packet for a container that arrives on another interface than its bridge (`hack/local-site.sh:411-431`). The `nvkectl` lane does the same between the kind bridge and its node bridge (`cli/e2e/bootstrap/run-nico.sh:17-21`). So the answer of the repository to two networks is a firewall rule.

### The three things of the lab

The lab notes give these facts. The kind nodes and the LoadBalancer addresses are on the Docker network `kata-bb`, `172.29.0.0/16`. The shared API address of a cluster is `172.29.255.220`. The fixed node addresses of the pods are on the Docker network `kata-bb-node`, `172.28.0.0/16`, which is internal. The provider gives out `172.28.1.0/24`. The SPIRE address in each node is `172.29.0.3:30081` (`REPORT:57`, `:103-107`, `:182`, `NOTES/lab/phase2-provider-run/result.md:32-33`).

| Target | Container worker on `kata-bb` only | Container worker on both lab networks | VM on `controllerbr0` |
|---|---|---|---|
| The shared API address `172.29.255.220:6443` | Reachable. It is on the same bridge, and MetalLB answers ARP there (deduction from the lab test B4, `REPORT:133-149`) | Reachable, the same way (deduction) | Not reachable with no rule. The packet must cross from one bridge to a Docker bridge (deduction) |
| The SPIRE server `172.29.0.3:30081` | Reachable (deduction) | Reachable (deduction) | Not reachable with no rule (deduction) |
| The fixed node addresses `172.28.1.x` | Not reachable. The network is internal, and Docker separates its networks (deduction) | Reachable on the same bridge (deduction) | Not reachable (deduction) |
| Geneve between the worker and the control plane nodes | Fails. The control plane nodes use `172.28.1.x` as tunnel addresses (deduction) | Works when the node address of the worker is its `172.28.0.x` address (deduction) | Fails (deduction) |
| NVKE controller to the agent on port 15005 | Reachable. The controller pod goes through its kind node, which is on that bridge (deduction) | Reachable. The lab controller already reaches `172.28.x` addresses through its kind node (`REPORT:56`) | Not judged for that machine |

What would let a simulated worker reach all three:

1. The worker container joins both lab networks. `kata-bb` gives the default route, the API address and SPIRE. `kata-bb-node` gives the node address and the tunnels.
2. The simulator must report the `172.28.0.x` address, because NVKE stores the first address as the node address (lab note, `NOTES/phase2-design.md:56`). The simulator prefers the address on the configured network, so `NICO_CONTAINERS_NODE_NETWORK` must be `kata-bb-node` (`SIM/internal/container/docker.go:100-101`).
3. The simulator passes one `--network` argument and starts the container at once (`SIM/internal/container/service.go:265`, `:279-283`). So a second network needs one of the two things in the next list (deduction).
   - A small change of the simulator, a setting with more networks to connect between `docker create` and `docker start`.
   - No change of the simulator. `NICO_CONTAINERS_DOCKER_BINARY` names the Docker CLI that the simulator calls for each step (`SIM/internal/config/config.go:216`, `SIM/internal/container/docker.go:257-269`, `:289-303`). A lab wrapper script in that place passes each call to `docker`, and before a `start` call it runs `docker network connect kata-bb <container>`. The `nvkectl` lane already puts `nerdctl` into the setting (`cli/e2e/bootstrap/run-nico.sh:370`).
4. The second network must be there before systemd starts. A unit of the image reads the default route at boot and fails with no default route (`NODE/scripts/prepare-container-network:25-33`). An internal Docker network gives no default route (deduction).

Open points of that layout, all deductions:

- The image unit expects one default route and one address on that interface. Two interfaces with one default route meet the rule as I read it. The lab pod has the same layout, a default route on the first interface and the node address on the second, but in a Kata guest.
- Docker gives the worker the next free address of `172.28.0.0/16`. Docker does not know the range `172.28.1.0/24` of the provider. A collision needs many containers, but nothing prevents it.
- Docker can give a container another address after a restart. The lab saw it with kind nodes (lab note, `REPORT:168`). NVKE stores the node address one time.
- A container on a lab bridge reaches no registry on that machine (lab note, `REPORT:108`). The worker image must carry each image that the node needs, as the pod image does.

## 6. The node agent and its identity on a simulated machine

The method is one setting for the whole deployment, and three parts must agree on it. The parts are the controller (`nodeAgent.spireAttestationMethod`), the node image (`CAPD_SPIRE_ATTESTATION_METHOD` at build time) and the simulator (`NICO_CONTAINERS_SPIRE_ATTESTATION_METHOD`).

The TPM method is the default. It has five steps:

1. The node has a software TPM. In a VM, libvirt attaches it. In a container, a unit starts `swtpm` on the vTPM proxy of the host kernel before the SPIRE agent (`NODE/systemd/swtpm-local.service:8-18`).
2. The simulator returns the EK certificate in the instance (`SIM/internal/http/convert.go:49-51`, `SIM/internal/container/convert.go:62-69`).
3. CAPNICo writes the hash of the EK public key to `NicoMachine.status.tpmEkPubHash` (`CAPNICO/controllers/nicomachine_controller.go:418-427`).
4. The NVKE controller fills the allow list of the SPIRE server from the `NicoMachine`. The `nvkectl` lane checks exactly that (`cli/e2e/bootstrap/run-nico.sh:22-24`).
5. The SPIRE agent attests with the TPM, and `nvke-agent` uses the socket of the SPIRE agent.

The join token method has these steps:

1. The CI lanes pick the method when the runner has no `/dev/vtpmx` (`C/hack/backend-e2e-lib.sh:40-46`). The image then has no dependency on the TPM unit (`NODE/Dockerfile:190-222`, `:296-300`).
2. NVKE makes one join token for each node and puts it into the bootstrap data (`C/internal/clients/capi/machine.go:79-92`).
3. CAPNICo sends the bootstrap data as the user data of the instance (`CAPNICO/controllers/nicomachine_controller.go:229-252`, `:286`).
4. The container backend writes the files and runs the commands with `docker exec` (`SIM/internal/container/docker.go:136-198`). The agent waits for the answer of the `cloud-init` shim, which reads a status file of the simulator (`NODE/scripts/cloud-init-status-shim:33-49`).
5. With the join token method the instance is `Ready` as soon as the container runs (`SIM/internal/container/convert.go:136-143`).

The settings must match. An image built for join tokens under a simulator in the default `tpm` mode stays `Pending` with no end, because no EK certificate appears (deduction from `SIM/internal/container/convert.go:139-140`).

The lab deployment uses `joinToken` and has the NICo controllers off (lab note, `NOTES/lab/phase1-second-machine/remote/d/stack/values/controller-values.yaml:60-64`, `:82-84`). The lab base image uses the join token method "as CI does" (lab note, `NOTES/runlog.md:119-120`).

Does the controller reach port 15005 of the machine?

- The agent listens with `--secure-server-port 15005` (`NODE/Dockerfile:26`, `:255`).
- NVKE dials the address of the machine. For a `NicoMachine` that is the first IPv4 address of the instance (`CAPNICO/controllers/nicomachine_controller.go:411-416`).
- With containers the answer is yes in the lanes. The node containers are on the kind Docker network, and so is the management cluster (`C/Tiltfile:340-343`, `SIM/internal/config/config.go:213`).
- With VMs the answer is yes in the VM lane. The host routes between the kind bridge and `controllerbr0` (deduction from `SIM/README.md:174` and the rules of `SETUP:530-547`).
- In the lab, a worker with a `172.28.0.x` address is on the network where the controller already reaches the agents of the pods (deduction from the lab note `REPORT:56`).

## 7. The simulator beside the lab on the second machine

The lab notes give these facts about the machine. It runs Ubuntu 26.04 with the kernel 7.0.0-43 and Docker 29.1.3 with no `daemon.json`. The firewall drops a forwarded new connection from a Docker bridge and rejects a call from a container to the machine. Two containers on one bridge reach each other. `br_netfilter` is not loaded (`REPORT:99-119`). The disk has 224 GB of 300 GB in use, and 32 GB of memory are in use (`NOTES/lab/phase2-gaps-run/result.md:370`).

### Can it run there

The container backend can, with no change of the Docker configuration, no new bridge and no firewall rule (deduction). The form that fits the machine is the form of the CI deploy path.

- The simulator runs in a container on `kata-bb`, with the Docker socket of the machine mounted. CI does that with the image `docker:29.1.3-cli` (`C/hack/ci/backend-e2e.sh:34`, `:73-78`, `:941-948`, `:1168-1173`).
- CAPNICo, a pod of the kind cluster, then reaches the simulator from a kind node over the same bridge. A simulator as a process of the machine is not reachable, because the firewall rejects a call from a container to the machine (deduction).
- The simulator has no listener on an outside interface in that form. The `nvkectl` lane warns that the simulator "accepts any bearer token and runs a request's commands as root in privileged containers" (`cli/e2e/bootstrap/run-nico.sh:355-358`). Each pod and container on `kata-bb` can then start a privileged container on the machine through the simulator (deduction). The lab API of NVKE is open in the same way (lab note, `NOTES/lab/phase1-second-machine/remote/d/stack/values/controller-values.yaml:104-106`).
- The default network name `kind` does not exist in the lab. The setting `NICO_CONTAINERS_NODE_NETWORK` is necessary (lab note, `REPORT:107`).

The VM backend can run there only with host changes that the lab avoided so far. The next table has them.

### What must be there, and what could collide

| Point | Container backend | VM backend |
|---|---|---|
| Packages on the machine | None, when the binary and the images come from the workstation (deduction) | QEMU, libvirt, dnsmasq, swtpm, OVMF and more (`SETUP:170-190`) |
| Images and binaries | A static simulator binary and the seed file. A small image with the Docker CLI. The worker node image. The CAPNICo image | The same, and a node image as qcow2. The prebuilt ones are private, and a build needs Packer and QEMU (`os-image/README.md:12-15`, `:36-45`) |
| Docker networks and ranges | Uses the lab networks. Docker gives the addresses and does not know the provider range `172.28.1.0/24` | `172.30.0.0/24` and `172.31.0.0/24`. No overlap with `172.28` and `172.29`. Both are in the default pool of Docker, so a later Docker network with no subnet can take them (`SIM/README.md:242-245`) |
| Bridges | None new | `controllerbr0`. libvirt also makes its own bridge (deduction, not from the repository) |
| Firewall | No rule | Ten iptables rules and a dnsmasq on the bridge (`SETUP:461-473`, `:530-566`). The lab note says that the DNS server of the machine already listens on port 53 of the lab bridges (`REPORT:119`) |
| Docker configuration | No change. One anonymous volume and one container for each node | No change by the simulator. `SETUP` can install Docker, start it and open the socket file (`:99-130`) |
| Other tools | None | `SETUP` replaces a Go that differs from `go.mod` and a Helm 3 (`:228-263`). It writes a sudoers rule, changes AppArmor and the libvirt log settings (`:314-383`, `:568-626`). Do not run it on the lab machine |
| KVM | Not used | Each VM uses `/dev/kvm` beside the Kata guests of the kind nodes. I found no exclusive use (deduction). Each VM is a second level guest, as a Kata guest is |
| Kernel modules | `openvswitch`, and Geneve with it, in the kernel of the machine. The node loads the module from `/lib/modules` (`NODE/Dockerfile:95-109`). CI checks that first (`C/hack/backend-e2e-lib.sh:272-304`). `tpm_vtpm_proxy` only with the TPM method | `kvm`, which is there |
| Kernel settings | The node shares the kernel settings of the machine. The kubeadm wrapper keeps kube-proxy from a change of the conntrack limit at `kubeadm init` (`NODE/scripts/update-kubeadm-config-for-containers:76-82`). The lab worker ran no kube-proxy (lab note, `NOTES/lab/phase2-worker-run/result.md:102`) | `ip_forward` and `fib_multipath_hash_policy` (`SETUP:530-531`) |
| Devices | A privileged container sees each device of the machine, also the loop devices of the lab volumes (deduction) | None |
| Ports | 18080 inside the simulator container. Port 2222 is off with `-1` | 18080, 2222, 7777 on two addresses, 10179, and 53 and 67 on the bridge (`docs/get-started/quickstart-local.md:26`, `SIM/internal/lifecycle/network.go:125-131`) |
| Parts of the repository that the lab must not start | `bgp-containers`, which takes port 179 of the machine and writes host routes. `make capd-up`, which makes a second kind cluster and registry containers | `SETUP`, Tilt |

### How much room

- A container worker needs the node image one time. The lab base image has 3.22 GB and is on the machine as the base of the pod images (deduction from the lab notes `NOTES/runlog.md:119` and `NOTES/lab/phase2-node-image/result.md:29`). Each worker adds a `/var` volume with the CNI images, about 1 to 3 GB (deduction). A worker with OVN needs about 2 to 4 GB of memory (deduction, from the 1800 MiB request of the OVN node pod in `C/hack/create-nico-vms-cluster.sh:12-16`).
- A VM worker needs 6 GiB of memory and 4 vCPUs for the usual worker type, a node image of about 3 GB, an overlay that grows with use, and the packages.
- The disk is the narrow point, not memory or CPU. The local site page asks for less than 70 percent of the disk in use, because the kubelet of a container node sees the disk of the host (`docs/get-started/local-site.md:20`). The lab disk is at 75 percent.

### Which backend first

The container backend. Reasons:

1. It adds no bridge, no firewall rule and no package to a machine where the lab made none so far.
2. Its node image is the base of the lab pod image. The agent, Open vSwitch, kubeadm and the `cloud-init` shim are the same parts that the lab ran in phases 1 and 2.
3. A container can sit on the two lab Docker networks. A VM sits on a third bridge behind the firewall of the machine.
4. The container lanes of CI run with join tokens when the runner has no vTPM device. The lab uses the same method.
5. A container node starts in seconds, and the image needs no build chain with Packer.

The container backend also shows less. The worker has no kernel of its own, no boot, no real cloud-init and, with join tokens, no TPM. Section 9 has the list.

The plan needs four read-only checks on the machine first. I ran none of them.

- Is `openvswitch` loaded, and does the module tree of the running kernel have it and the Geneve module?
- Does the machine have swap? The image sets the kubelet flag for it (`NODE/Dockerfile:234-239`).
- The free disk, and the Docker networks with their ranges.
- The ClusterRole of the NVKE controller for `nicomachines`.

## 8. The smallest phase 3 test

The goal is one cluster with three control plane nodes as pods of `cluster-api-provider-podvm`, and one worker that the simulator makes as a container. The request stays on the `infra` path.

### Parts that exist

- The lab has the host cluster, Kata, the provider, NVKE with `controlPlaneEndpoint`, and the cluster c-5 with three control plane pods and one worker pod (lab note, `NOTES/lab/phase2-gaps-run/result.md:35`).
- The worker flow of NVKE on the `infra` path. It ran with a pod worker (lab note, `NOTES/lab/phase2-worker-run/result.md:60-79`).
- The simulator with the container backend. A worker on one network needs no code change.
- CAPNICo v0.1.0 with a site on the machine. `NicoMachine.spec.siteID` "overrides NicoCluster settings", and with it "the controller does not read a NicoCluster" (`CAPNICO/api/v1alpha1/nicomachine_types.go:99-103`, `CAPNICO/controllers/nicomachine_controller.go:728-740`). The credentials then come from the provider Secret (`CAPNICO/api/v1alpha1/nicomachine_types.go:105-108`). An older version in the module cache does not have the field. It always reads a `NicoCluster` (`cluster-api-provider-nico@v0.1.0-rc.2.0.20260929174319-72784d3eaafc/controllers/nicomachine_controller.go:700-708`).
- CAPNICo sets the provider ID on the Node of the new cluster by itself, through the kubeconfig Secret of the cluster (`CAPNICO/controllers/node_provider_id.go:54-125`).
- The generic client of NVKE. It renders the infra machine from the template of the pool, makes the join token, the bootstrap Secret and the Machine. It has a branch for the case that the template renders a `NicoMachine` (`C/internal/clients/capi/machine.go:62-147`).
- The node image. The lab base image `nvke-node:bcc4376f-amd64` is the container node image of the repository with join tokens (lab note, `NOTES/runlog.md:119-122`).

### Parts that are missing

1. CAPNICo in the lab cluster. It needs the image in the four kind nodes, the chart with its CRDs and webhook, and the Secret `nico-credentials` with the address of the simulator container.
2. The simulator. It needs a static binary, the seed file, and a container on `kata-bb` with the Docker socket and the settings of section 3.
3. A worker image for Docker. It is the base image with the agent of the lab branch and with the two images that a node cannot pull on that machine (lab notes, `REPORT:51`, `NOTES/phase2-design.md:136`). It has no pod entry point.
4. The second network for the worker, by a wrapper in `NICO_CONTAINERS_DOCKER_BINARY` or by a small change of the simulator (section 5).
5. The Open vSwitch module in the kernel of the machine, if it is not loaded.
6. RBAC of the NVKE controller for `nicomachines`, if the lab ClusterRole does not have it. The chart grants it when `capi.rbac.create` and `capi.rbac.nico` are true (`C/deploy/charts/controller/values.yaml:434-440`).
7. The pool request. The sketch below comes from `C/hack/create-local-nico-cluster.sh:99-127` with one more field, `siteID`. I did not run it.

```json
{
  "apiVersion": "infrastructure.cluster.x-k8s.io/v1alpha1",
  "kind": "NicoMachineTemplate",
  "metadata": {"name": "kata-cp1-simworker-template"},
  "spec": {"template": {"spec": {
    "siteID": "00000000-0000-0000-0000-000000000001",
    "vpcID": "00000000-0000-0000-0000-000000000002",
    "instanceTypeID": "00000000-0000-0000-0000-000000000005",
    "cloudInitInjectHostname": true,
    "ipxeScript": "#!ipxe\necho local-nico-worker\n",
    "sshKeyGroupIDs": ["00000000-0000-0000-0000-000000000004"],
    "interfaces": [{"subnetID": "00000000-0000-0000-0000-000000000003"}]
  }}}
}
```

### Points that I cannot judge without the other reading

1. Does NVKE accept a pool whose template is a `NicoMachineTemplate` in a cluster whose infrastructure object is a `PodVMCluster`? The lab note says that the check on the `infra` path asks only for a valid manifest of the infrastructure API group (`NOTES/lab/phase2-worker-run/result.md:37`). I did not read that code at `d625fcfa`.
2. Does a later step of NVKE read the `NicoCluster`, or take the NICo client for a `NicoMachine`, for the failure domain, the reboot annotation or the release?
3. Does a `NicoMachine` with a join token need the NICo controllers of NVKE (`controllers.nico.enabled`)? The lab has them off. One of them works on the SPIRE agent path of a `NicoMachine` (`C/internal/controllers/capi/nico_spiffe_controller.go:46-56`, `:90-119`).
4. Which address NVKE gives the kubelet and Open vSwitch when the node has two interfaces.
5. The product path. The API takes exactly one provider block for a pool, and a cluster has one provider (lab notes, `NOTES/lab/phase2-worker-run/result.md:36-37`, `NOTES/summary.md:86`). A worker pool with the `nico` block under a control plane of another provider is a change of NVKE.

### A possible order (proposal, not run)

1. Step A, one network. The worker joins `kata-bb` only, with no wrapper. The step tests the chain from the NVKE pool request over CAPNICo and the simulator to the agent, the identity and `kubeadm join`. The node can register. Pod traffic to the control plane nodes fails (deduction, section 5).
2. Step B, two networks. The wrapper adds `kata-bb`, and the simulator reports the `172.28.0.x` address. The step repeats the worker tests of phase 2, which are pod traffic in each direction, the tunnel addresses, `kubectl logs` and `kubectl exec` through each API server, and a delete of the node and of the pool through the API.
3. A second worker, and a reboot through NVKE, when step B passes.

## 9. What a test with the simulator does not show

About a real site with NICo:

- DPUs. The simulator returns a made-up DPU machine ID and nothing else. No DPU does the network of the node.
- The real network. The test has no VPC separation, no fabric, no real BGP peer and no ECMP on switches. The README of the BGP helper lists the same gaps for itself (`C/hack/bgp-containers/README.md:212-216`).
- GPU nodes. The test has no GPU, no GPU driver and no InfiniBand or NVLink device. The capability data is fixed.
- Boot time and boot path. The test has no firmware, no iPXE chain and no disk imaging. The VM backend boots the image file directly and never loads the boot loader of the script (`C/test/kubeadm/internal/nicovms/launch.go:282-285`). A container has no boot at all.
- Capacity and placement. Each type has 100 machines. The simulator has no failure domain, no inventory and no machine health.
- Machine power control and repair. The simulator has no power route, and a repair flag at delete is only a log line (`SIM/internal/container/service.go:200-206`).
- Credentials. The simulator has no token check, no OAuth and no TLS. The lanes use plain HTTP.
- With the container backend the test also has no kernel of the node, no kernel settings of its own, no real cloud-init, no full disk encryption, no TPM with join tokens and no reboot of a machine. The kubeadm system check is off in the wrapper (`NODE/scripts/kubeadm-systemverification-shim:51-54`).
- With the VM backend the CPU model is a fixed old model, and the disks and the network card are virtual (`SIM/internal/vm/libvirt/domain_xml.go:53-55`, `:66-104`).

About the lab itself:

- The worker and the control plane pods share one machine. A real worker reaches the control plane over a routed network.
- The node network of the test is a Docker bridge. A real site needs a network that the bare metal workers and the pods of the host cluster share. No source that I read says how NICo gives a worker an address on such a network.
- A real worker reaches the shared API address through a load balancer of the site, not through MetalLB on a bridge.

## Points where I was not sure

1. An internal Docker network gives no default route, and a container with two networks takes the default route of the other network. I know it from Docker in general. No file of the repository states it.
2. The network unit and the Open vSwitch step of the agent with two interfaces in a Docker container. The lab pod has that layout only in a Kata guest.
3. The kernel of the second machine. I do not know if it has the Open vSwitch and Geneve modules, or if one is loaded now.
4. How NVKE handles a pool of another provider kind. It is the question of the other reading.
5. How CAPNICo behaves when the simulator has no power route. A reboot of a simulated worker through NVKE is not judged.
6. The memory and the volume size of a container worker. Both numbers are estimates.
7. Whether the lab ClusterRole of the controller covers `nicomachines`.
8. Whether the pod image itself can run under the container backend. The simulator replaces the entry point, so the pod entry point does not run. I did not read what the two bootstrap units of the pod image do with no bootstrap Secret.
9. The VM backend on that machine. I do not know if the firewall forwards from a plain bridge, or what a libvirt install adds on Ubuntu 26.04. I did not look further, because the container backend avoids both.
10. The host changes of the VM backend come from `SETUP`. CI uses a shorter script, `C/test/kubeadm/scripts/setup-ci-host.sh`, which I did not read.
11. The times in section 4 come from documents and comments. I measured none.
12. A comment in `C/hack/nico-provider/run-nico-sim.sh:52-54` says that the bridge range has no default. The code sets `172.30.0.0/24` when the value is empty (`SIM/internal/config/config.go:456-459`). The setting is harmless either way.
