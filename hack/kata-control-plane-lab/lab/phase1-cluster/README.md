# Phase 1, step 5: the cluster request to NVKE

State on 2026-11-26: a draft. It is not sent yet. The dry run with three nodes (`phase1-dry`) and the bootstrap helper come first.

`request.json` is the body of `POST /api/clusters` for the NVKE controller of the lab stack (`lab/phase1-stack/`). Its form follows the request that `nvkectl` builds for the provisioned provider (`cli/internal/bootstrap/sitecluster/sitecluster.go:45-195` in NVKE at `bcc4376f`), with these choices:

- No `controlPlaneVIP`. With the deployment setting `allowControlPlaneWithoutVIP`, the endpoint is the address of the first node.
- `infra.cluster` is a `ProvisionedCluster` with three hosts. Each `ipAddress` is the LoadBalancer address of the Service of one host pod. The `hostname` is a name of the lab, and the helper finds the pod by it. The Kubernetes node name comes from NVKE.
- The pod and Service ranges are not the ranges of the host cluster (10.244.0.0/16 and 10.96.0.0/16). The default Service range of NVKE (10.96.0.0/12) would hide the DNS address of the host cluster from the guest.
- `systemReservedMemory` is small. The default of 16Gi is more than the guest memory. NVKE adds 2Gi and 1 CPU of kube reserved, which the request cannot change.
- `etcdEncrypted` is false in the first run.

Send it from the host with `/scratch/kata-cp/work/phase1-stack/api.sh post /api/clusters request.json`.
