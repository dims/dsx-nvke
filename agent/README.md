# agent

gRPC agent that runs as a systemd service on each NVKE node. An orchestrator
calls it to drive kubeadm lifecycle, package/CNI install, API encryption, and
related node-local operations — without interactive SSH.

| Doc | Purpose |
|-----|---------|
| [AGENTS.md](AGENTS.md) | Build, test, proto, versioning, and contributor conventions |
| [docs/DESIGN.md](docs/DESIGN.md) | Architecture and API surface |
| [docs/SECURITY.md](docs/SECURITY.md) | Security context (reporting: repo-root `SECURITY.md`) |
| [pkg/agent/proto/node_agent.proto](pkg/agent/proto/node_agent.proto) | Canonical RPC definitions |
| [config.env.example](config.env.example) | Build/runtime artifact endpoint knobs |

**Module:** `github.com/dsx-ai-factory/nvke/agent`

## Quick start

```bash
# From the monorepo root
./build/agent.sh test
./build/agent.sh build

# Or from this directory
make test
make build
```

Install a release tarball on a node (as root):

1. Extract the package on the host
2. Run `scripts/agent-installer.sh` (or the bundled installer from the release)
3. Configure flags via `/etc/default/nvke-agent` (see below)

## Configuration

Copy `config.env.example` → `config.env` (gitignored) for local build/publish
overrides. On nodes, set flags via `/etc/default/nvke-agent`.

Important flags (also settable via env; see `AGENT_ARGS`):

| Flag | Notes |
|------|--------|
| `--bundle-server-url` | Optional. Bundle source for InstallBundle (`https://`, `http://`, `file://`, or `oci://`). Also `NKE_BUNDLE_SERVER_URL`. Prefer apt when unset. |
| `--index-file-url` | Optional absolute index URL (`NKE_BUNDLE_INDEX_URL`); otherwise derived from the bundle server + OS |
| `--cni-image-registry` | Optional OCI prefix for CNI helm `global.registry` (`NKE_CNI_IMAGE_REGISTRY`) |
| `--disable-mtls` | Plaintext gRPC (**development only**) |
| `--spiffe-socket-path` | SPIFFE workload API socket. Used for the gRPC server's mTLS unless `--disable-mtls` is set, and always by the SPIRE agent RPCs |
| `--secure-server-port` | gRPC listen port (default `15005`) |
| `--control-plane-endpoint-gate-file` | Optional. Absolute path of the control plane endpoint gate file. Empty means no gate. See [Control plane endpoint gate](#control-plane-endpoint-gate) |
| `--control-plane-endpoint-backend-interface` | Interface on which the connections of the load balancer arrive. Required with the gate file |
| `--control-plane-endpoint-gate-settle` | Time between closing the gate and closing the established connections (default `10s`) |
| `--version` | Print build version and exit |

Example:

```bash
# Apt-first (no bundle server required)
AGENT_ARGS="--disable-mtls"

# Optional: enable legacy HTTP/OCI bundle installs
AGENT_ARGS="--bundle-server-url https://artifacts.example.com/ --disable-mtls"
# OCI bundles:
# AGENT_ARGS="--bundle-server-url oci://registry.example.com/nvke/bundles --disable-mtls"
```

There is no built-in artifact host. When using bundles, consumers must point the
agent at their own S3/HTTP or OCI layout. Index entries use paths relative to
the bundle server URL (for example
`nke_bundles/Ubuntu_24.04/kubeadm_v1.30.0.tgz`).

gRPC reflection is enabled on the same port (useful with `grpcurl`).

### Control plane endpoint gate

A control plane node can sit behind a load balancer that the node does not run,
for example a Service of another cluster. Such a node has no kube-vip, so the
kube-vip withdrawal has nothing to do there. The control plane endpoint gate is
the withdrawal for that case. There is no gate unless
`--control-plane-endpoint-gate-file` is set, and the agent then withdraws only
kube-vip.

```bash
AGENT_ARGS="--control-plane-endpoint-gate-file /var/lib/nvke/control-plane-endpoint.gate --control-plane-endpoint-backend-interface eth0 --control-plane-endpoint-gate-settle 10s"
```

When a node is withdrawn, by `StartK8sControlPlaneNodeGracefulShutdown` or by
`StartEtcdDefrag`, the agent:

1. Reads the IPv4 address of the backend interface.
2. Closes the gate: it creates the gate file.
3. Waits for the settle time, so the load balancer can stop sending new
   connections to this node.
4. Closes the established connections of remote clients on the backend address
   and port 6443 (`ss -K`). The clients connect again and reach another node.
5. Checks for 30 seconds that no new connection arrives on the backend address.
   If one arrives, the withdrawal fails and the operation does not start.

`StartKubeVipRestore` opens the gate: it removes the gate file. A node with
kube-vip and a gate leaves both, the gate first, and returns to both.

The agent cannot see the load balancer. The deployment has to provide these
things:

- **A health check that reads the gate.** It fails for this node while the gate
  file exists. It passes only when the file does not exist and `/readyz` of the
  local API server answers 200, because the agent opens the gate without
  waiting for the API server.
- **A health check that does not connect to the backend address from another
  host.** Run it on the node, or point it at another address. Step 5 sees a
  connection from another host to the backend address as a new connection.
- **A backend interface that carries only the connections of the load
  balancer.** Clients in the cluster have to reach the API server on another
  address, such as an advertise address on a second interface. Otherwise step 5
  fails each time.
- **One global IPv4 address on the backend interface.** With none or with more
  than one the withdrawal fails before the gate closes. Connections over IPv6
  are not closed and not checked.
- **A kernel with `INET_DIAG_DESTROY`**, which `ss -K` needs.
- **A settle time longer than the health check needs** to take the node out,
  which is its period multiplied by its failure threshold, plus the time the
  load balancer needs to act.

The gate file holds one line that says who opens the gate:

| Content | Closed by | Opened by |
|---------|-----------|-----------|
| `/etc/kubernetes/manifests-backup` | `StartK8sControlPlaneNodeGracefulShutdown` | `StartKubeVipRestore`. The gate stays closed until then, also after a restart of the agent, and after a restart of the node when the file is on a disk that survives it |
| `/etc/kubernetes/manifests-backup/etcd-defrag` | `StartEtcdDefrag` | The agent, when the defragmentation ends. If the agent stopped before that, it opens the gate when it starts again |
| Anything else, such as a file made by hand | An operator | `StartKubeVipRestore` |

A defragmentation that leaves the node out of service because etcd did not come
back healthy hands the gate to the caller, as it does with the parked manifests.
A withdrawal that fails after the gate closed leaves it closed. The restore that
follows it opens the gate.

### Logs

| Path | Purpose |
|------|---------|
| `/var/log/nvke-agent-audit.log` | Audit log (`--audit-log-file`); records are also mirrored to the service journal |
| `/var/log/nvke-execute-scripts.log` | `ExecuteScript` / `StreamExecuteScript` results |
| `journalctl -u nvke-agent` | Service journal |

`GetSupportBundle` returns a tarball with state, journals, and related diagnostics.

## Core capabilities

- **Kubeadm:** init, join, reset, preflight, join strings, kubeconfig
- **CNI:** `InstallCNI` after packages are present; prefer `noCniInstall: true` on init for new orchestration (legacy in-init CNI remains when `noCniInstall` is false)
- **Packages / collections:** apt packages, apt repos, bundles, collections
- **Encryption:** Kubernetes API/etcd encryption-at-rest
- **Control-plane ops:** graceful shutdown / kube-vip restore, control plane endpoint gate, apiserver manifest patch
- **Utilities:** script execution, file upload, support bundle

Full RPC list: `pkg/agent/proto/node_agent.proto` and [docs/DESIGN.md](docs/DESIGN.md).

## Example: create a small cluster (grpcurl)

Examples below use **obviously fake** tokens, hashes, and keys so scanners do not
treat them as live credentials. Replace with values from your environment.

```bash
# Init first control-plane (TEST-NET address 192.0.2.10 is documentation-only)
grpcurl -plaintext -d '{
  "podNetworkCidr": "10.244.0.0/16",
  "serviceCidr": "10.96.0.0/12",
  "noCniInstall": true
}' 192.0.2.10:15005 proto.NodeAgent.ExecuteKubeadmInit

# Poll status / join strings
grpcurl -plaintext 192.0.2.10:15005 proto.NodeAgent.GetKubeadmStatus
grpcurl -plaintext 192.0.2.10:15005 proto.NodeAgent.GetKubeadmJoinString

# Join another node (placeholders — not real kubeadm material)
grpcurl -plaintext -d '{
  "kubeadmJoinString": "join 192.0.2.10:6443 --token abcdef.0123456789abcdef --discovery-token-ca-cert-hash sha256:0000000000000000000000000000000000000000000000000000000000000000 --control-plane --certificate-key 0000000000000000000000000000000000000000000000000000000000000000"
}' 192.0.2.11:15005 proto.NodeAgent.ExecuteKubeadmJoin
```

Install CNI after packages are on the control-plane host (`InstallPackages`), then:

```bash
grpcurl -plaintext -d '{
  "cniVariant": "CNI_VARIANT_OVN",
  "podNetworkCidr": "10.244.0.0/16",
  "serviceCidr": "10.96.0.0/12"
}' 192.0.2.10:15005 proto.NodeAgent.InstallCNI
```

More sample clients and manifests: [`samples/`](samples/) and [`sample-clients/`](sample-clients/).

## Encryption (sketch)

API encryption is a multi-step flow; see DESIGN.md and the proto comments.
When posting example keys in docs or tickets, use clearly invalid material, e.g.:

```text
encryptionKey: "EXAMPLEONLY_not-a-real-secretbox-key_000000000000="
```

Never paste production tokens, certificate keys, or encryption keys into the README.

## mTLS

Production should use SPIFFE mTLS (default). `--disable-mtls` is for local/dev only.
Clients need a matching SPIFFE identity (path prefix `/nke-service/`).

## Build notes

```bash
make build          # linux/amd64 + linux/arm64
make package        # release tarballs under release/
make protos         # regenerate *.pb.go via buf
make setup-hooks    # monorepo-aware proto pre-commit hook
```

Version comes from `git describe --tags --always --dirty --match 'v*'`, the
repository's release tags (see [AGENTS.md](AGENTS.md)). Override with
`VERSION=...` when needed.

## Published artifacts

### Binaries (GHCR)

Every commit on `main` and every `vX.Y.Z` release tag publishes the binaries to
`ghcr.io/dsx-ai-factory/nvke/agent` as OCI artifacts, joined by a multi-arch index
(`.github/workflows/agent-artifact.yml`). Pull one by platform:

```bash
oras pull ghcr.io/dsx-ai-factory/nvke/agent:v0.3.0 --platform linux/arm64   # release
oras pull ghcr.io/dsx-ai-factory/nvke/agent:edge   --platform linux/amd64   # tip of main
```

These are binaries, **not** container images — `docker pull` will fetch one but
there is nothing to run. Use `oras`.

⚠️ **The path changed twice.** Releases `agent/v0.2.1-rc.1` to `agent/v0.2.1-rc.4`
were published before the repository moved to `dsx-ai-factory` on 2026-09-12 and
are at `ghcr.io/nvidia/nke/agent`. Releases up to and including `agent/v0.2.1-rc.0`
are at the older `ghcr.io/nvidia/nvke-agent`. Both are frozen and still serve them.

Tags are `edge`, `sha-<commit>`, and `vX.Y.Z`, each with `-amd64` / `-arm64`
single-platform variants underneath. These are artifacts, not container images
— the layer is the executable itself, so `docker pull` is not the way in.

### Debian packages (apt intake)

Every `vX.Y.Z` and `vX.Y.Z-beta.N` tag also builds native amd64 and arm64
`.deb`s and uploads them to the apt-publisher S3 intake
(`.github/workflows/agent-deb-publish.yml`, via
`scripts/upload-s3-apt-intake.sh`); a beta does not enter the intake's
`index.json`. Main merges and branch workflow runs do not ingest — only
`refs/tags/v*`. A release's packages are also published to GHCR as an OCI
artifact:

```bash
oras pull ghcr.io/dsx-ai-factory/nvke/agent-deb:v0.3.0 --platform linux/amd64
```

Apt remains the node install path; the OCI binary above is the same executable
without the packaging/systemd unit. The reference OS image (`os-image/`) installs the
`.deb` built from this checkout. The package spec and maintainer scripts live in
`os-image/packages/nvke-agent/packaging/`; `make -C agent deb-amd64` or
`deb-arm64` builds it with the shared pinned nfpm.

The intake destination comes from the GitHub `apt-intake` environment
(`APT_INTAKE_S3_URI`, `APT_INTAKE_AWS_ROLE_ARN`, …) — nothing bucket-specific
is committed here. Once apt-publisher is pointed at that intake, cut over from
the previous GitLab package source.

