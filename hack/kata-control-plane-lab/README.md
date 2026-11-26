# Kata control plane lab, phase 0

This folder is the record of a lab. The lab tests if one NVKE control plane node can run as one Kata pod: systemd, containerd, the kubelet and `nvke-agent` in the guest of a Kata VM, with the kubeadm static pods inside it. The pods run on a host cluster, and NVKE joins them as hosts that exist.

It is a lab record, not product code. No build and no CI job uses it.

## State on 2026-11-26

| Gate | State |
|---|---|
| 1. The kubelet and containerd run in the Kata guest | Pass |
| 2. etcd sync time on a raw block volume | Pass |
| 3. The agent gets its identity in a Kata pod | Pass with a join token and with a service account token. The host socket fails with Cloud Hypervisor |
| 4. A LoadBalancer IP as the node address, with recovery after a cold start and a machine restart | Pass |
| 5. Running pods continue through a restart of containerd, the kubelet and Kata on the host, and through a Kata upgrade | Pass |

Phase 0 is complete. Start with `results/phase0-results.md`. It has the gate table, the recommendation, the numbers, each defect with its fix, and what the lab cannot answer.

## Content

| Path | Content |
|---|---|
| `lab/00-host-setup.sh`, `lab/01-node-prep.sh`, `lab/kind-config.yaml`, `lab/kata-deploy-values.yaml`, `lab/20-metallb-pool.yaml` | The host cluster: one kind node with its own Docker network, Kata 4.4.0 with Cloud Hypervisor, MetalLB |
| `lab/gate1/` | One pod as a kubeadm control plane node, with runc and with Kata |
| `lab/gate1-nvke/` | The NVKE node image as a Kata pod, with `kubeadm init` through `nvke-agent` over SPIFFE mTLS. `client/` is a small Go client for the agent |
| `lab/gate2/` | The etcd disk test and the load with fake nodes |
| `lab/gate3/` | The host socket test and the service account token test for SPIRE |
| `lab/gate4/` | Three replicas with a LoadBalancer IP as the node address, the pod replace, the cold start, and the machine restart test in a VM (`vm-restart/`) |
| `lab/gate5/` | The restart tests of containerd, the kubelet and `kata-deploy`, and the upgrade from Kata 4.3.1 to 4.4.0 |
| `lab/patches/` | Two patches to the Kata agent. The same commits are on the branch `lab/agent-kill-child-cgroups` of `github.com/dims/kata-containers` |
| `results/` | The results of phase 0 and the source readings |

Each gate folder has a `report.md` with the method, the versions, the numbers and what is not tested.

## Versions

NVKE at commit `bcc4376f`, Kubernetes v1.36.4, kind v0.34.0 with `kindest/node:v1.36.4`, Kata Containers 4.4.0 with Cloud Hypervisor v54.1 and guest kernel 6.18.62, MetalLB 0.16.2, SPIRE 1.14.1.

## Before you run a script

- The scripts have the paths of the lab machine. The work folder is `/scratch/kata-cp`, and some lines name a notes folder in a home directory. Change them first.
- The reports link to a plan, a run log and an evidence file. Those files are not in this folder.
- The three Go programs (`lab/gate1-nvke/client`, `lab/gate2/patcher`, `lab/gate3/uds-probe`) are separate modules and are not in `go.work`. Build each one with `GOWORK=off go build`. The client uses the agent module of this repository through a `replace` line.
- `lab/gate1-nvke/run.sh` and `lab/gate3/nvke-harness/run.sh` check a port with the socket device path of bash. An endpoint security tool can read that as a reverse shell and stop the shell. Replace that line with `nc -z` or `curl` on such a machine.
- The lab machine is one workstation. The reports have its addresses and device names.

## Repository checks on this branch

- `make license-header-check` passes. The source files got the Apache-2.0 header of the repository with `addlicense`.
- `make coverage-check` passes.
- `make docs-check` fails for this folder. The reports link to files that are not here, and the check reads the etcd text about cluster size as a statement about the merge gate. A pull request needs both corrected, or the folder left out of that check.
