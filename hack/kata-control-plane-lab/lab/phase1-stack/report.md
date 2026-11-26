# Phase 1, step 3: the NVKE stack in the lab cluster

Date: 2026-11-26, 10:12 to 10:24 local time. A test agent made the plan, ran the install and returned its reports as text. The main session wrote this file. Scripts: this folder, with the originals in `/scratch/kata-cp/work/phase1-stack/`. Logs: `/scratch/kata-cp/logs/phase1-stack/`, with one line for each step in `progress.txt`.

## Result

All 14 steps pass, in about 11.5 minutes. `check.sh` gives 67 passes, 0 failures and 0 warnings. The stack is NVKE at commit `bcc4376f` (version `v0.24.0-beta.18`): the controller, PostgreSQL, Temporal, SPIRE, cert-manager, Cluster API v1.13.6 with the two kubeadm providers, and `cluster-api-provider-provisioned`.

## Why not Tilt

Tilt is the way of the quickstart. It does not fit this machine:

- It keeps kubectl loops and port forwards on the host, with about one new connection each second while it runs. A VPN agent on this machine holds each new TCP connection of the host, and a burst breaks networking for the whole machine.
- It builds with Go on the host, and it writes into the source tree.
- Its make targets change the kubectl context, start two registry containers with `--restart=always`, and patch the Cluster API Deployments. The default providers need the Docker socket in the node and a kernel module on the host.
- A short provider list gives no `infra` provider, and `allowControlPlaneWithoutVIP` has no Tilt setting.

The way that ran: Helm, kubectl and clusterctl by hand, in the order of `nvkectl` (`cli/internal/bootstrap/controllerdeploy/controllerdeploy.go`), from a toolbox container on the Docker network `kata-cp`. The toolbox is the local image `debian:trixie-slim` with the helm and kubectl programs of the host mounted read only. It calls the API server at the node name over the bridge. The host opens no connection to the API server and publishes no port. Davanum approved clusterctl v1.13.6 in `/scratch/kata-cp/bin` in place of Tilt.

## Steps

| Step | Time | Result | Main fact |
|---|---|---|---|
| 00 preflight | 1 s | Pass | The toolbox reaches the API server. NodePort 30081 was free |
| 01 clusterctl | 4 s | Pass | v1.13.6, with the digest of `make/tool-versions.mk:119` |
| 02 charts | 2 s | Pass | temporal 0.74.0, spire-crds 0.6.1, spire 0.30.1, each with the digest of `cli/internal/bootstrap/manifest/bootstrap-manifest.yaml` |
| 03 controller image | 46 s | Pass | `nvke-controller:bcc4376f`, 168 MB, built in a container |
| 04 provider image | 28 s | Pass | `cluster-api-provider-provisioned:bcc4376f`, 96 MB |
| 05 import | 2 s | Pass | `docker save` and `ctr images import` in the kind node |
| 06 pulls | 34 s | Pass | 11 images by the kind node, one at a time |
| 07 PostgreSQL | 10 s | Pass | 1 pod with a 2Gi volume |
| 08 Temporal | 46 s | Pass | The servers have no readiness probe. The step waits for the schema job and the health state |
| 09 SPIRE | 41 s and 10 s | Pass on the second run | The first run installed SPIRE with no join token attestor, a fault of the script. The second run set it |
| 10 Cluster API | 23 s | Pass | Core, kubeadm bootstrap, kubeadm control plane, and cert-manager v1.21.1 |
| 11 provider | 1 s | Pass | 4 kinds, the Deployment is ready |
| 12 controller | 12 s | Pass | `/readyz`: `{"status":"ok","checks":{"database":"ok","temporal":"ok"}}` |
| 13 check | 13 s | Pass on the second run | The first run had 1 failure from a wrong check (it looked for a Deployment of the SPIRE controller manager, which is a container of the server pod) |

## What the check proves

- The API answers with no token: `/api/version` gives `v0.24.0-beta.18`, and `GET /api/clusters` gives an empty list.
- The Temporal worker of the controller runs and polls its task queue.
- The controller has its SPIFFE identity in the trust domain `kata-cp.nvke.local`. That ID is an admin ID of the SPIRE server, so the controller can make join tokens.
- The SPIRE server has the node attestors `join_token` and `k8s_psat`.
- The SPIRE address that NVKE writes into the `agent.conf` of each node is `172.30.0.2:30081` (the kind node address and a NodePort). A runc pod and a Kata pod (`kata-clh-runtime-rs-fix-direct`) each made a TLS connection to it and got the certificate of `spiffe://kata-cp.nvke.local/spire/server`.
- The six controller settings are active: `supportedInfraProviders: infra`, `allowControlPlaneWithoutVIP: true`, `cni.installAfterInit: true`, `spiffe.enabled: true`, `nodeAgent.spireAttestationMethod: joinToken`, `capi.rbac.create: true`. The controller may create `provisionedclusters`, `machines` and `clusterstaticentries`.

## How to call the API

- From the host: `/scratch/kata-cp/work/phase1-stack/api.sh post /api/clusters <file>`. It runs curl in the kind node against the ClusterIP. No host port.
- From a pod: `http://nvke-controller.nvke-controller.svc.cluster.local:8080/api/clusters`.

## What the stack added to the cluster

- Namespaces: `postgres`, `temporal`, `spire-server`, `cert-manager`, `capi-system`, `capi-kubeadm-bootstrap-system`, `capi-kubeadm-control-plane-system`, `provisioned-system`, `nvke-controller`, `nvke-system`.
- 18 pods with a working set of 731 MiB.
- One NodePort (30081). A SPIRE agent DaemonSet and the SPIFFE CSI driver on the kind node. Two volumes of the local-path class.
- Images: 2 built on the host Docker, 4 base images pulled by the host Docker, 17 pulled by the kind node. Docker Hub images come through `mirror.gcr.io`.
- No published port, and no change to MetalLB, to the Kata install or to the other namespaces.

Removal: `/scratch/kata-cp/work/phase1-stack/uninstall.sh all`. It stops when a Cluster API Cluster object exists, because the provisioned provider refuses the delete of a bound Machine.

## Limits and not tested

- Lab limit: the NVKE API has no authentication. Each pod of the lab cluster can call it with full rights.
- The busybox image for one init container of the SPIRE server has another digest through the mirror than the digest in `bootstrap-manifest.yaml`. The chart pins the tag only.
- The default registration of the SPIRE chart made entries for each pod of the cluster. They do nothing for a pod with no CSI volume.
- The controller log has 7 ERROR lines of the database logger in the first 2 seconds ("transaction has already been committed or rolled back") and no restart. The cause is not examined.
- Not tested: a join token made by the controller, the node agent with SPIRE 1.14.1 against the SPIRE server 1.15.3, and the uninstall script.
