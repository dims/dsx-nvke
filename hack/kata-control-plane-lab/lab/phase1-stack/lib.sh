# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Shared functions of the phase 1 stack scripts. Source env.sh first.
#
# Where a command runs:
#   host      docker build, docker pull, docker save, docker exec in the kind node, one curl download.
#   toolbox   helm, kubectl and clusterctl. The toolbox is a container on the Docker network of the
#             lab, so each API call stays on the bridge and opens no host socket.

log()  { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '%s WARN %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf '%s ERROR %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

in_toolbox() { [ "${IN_TOOLBOX:-0}" = "1" ]; }

# tb CMD ARG...: run one command in a new toolbox container, then remove the container.
# No published port. The work folder is /work, the NVKE source is /src (read only).
tb() {
  in_toolbox && die "tb is a host function"
  local args=(run --rm --network "$DOCKER_NET" --user "$(id -u):$(id -g)"
    -e IN_TOOLBOX=1
    -e HOME=/tmp
    -e KUBECONFIG=/work/secrets/kubeconfig.internal
    -e HELM_CACHE_HOME=/work/cache/helm/cache
    -e HELM_CONFIG_HOME=/work/cache/helm/config
    -e HELM_DATA_HOME=/work/cache/helm/data
    -e XDG_CONFIG_HOME=/work/cache/xdg
    -e CLUSTERCTL_DISABLE_VERSIONCHECK=true
    -e KIND_NODE -e DOCKER_NET -e NODE_IP
    -e PROBE_RUNTIME_CLASS -e PROBE_IMAGE
    -e FORCE -e ALLOW_CHART_SHA_MISMATCH -e SKIP_KATA_PROBE
    -v "$STACK_DIR:/work"
    -v "$NVKE_SRC:/src:ro"
    -v "$HELM_BIN:/usr/local/bin/helm:ro"
    -v "$KUBECTL_BIN:/usr/local/bin/kubectl:ro"
    -v "$CA_BUNDLE:/etc/ssl/certs/ca-certificates.crt:ro"
    -w /work)
  if [ -x "$CLUSTERCTL_BIN" ]; then
    args+=(-v "$CLUSTERCTL_BIN:/usr/local/bin/clusterctl:ro")
  fi
  docker "${args[@]}" "$TOOLBOX_IMAGE" "$@"
}

# node CMD ARG...: run one command in the kind node. It uses the Docker socket only.
node() { docker exec "$KIND_NODE" "$@" </dev/null; }

# Folders that the scripts write: the work folder, and the log folder of the lab on the host.
make_dirs() {
  mkdir -p "$STACK_DIR/cache/charts" "$STACK_DIR/cache/helm" "$STACK_DIR/cache/xdg" "$STACK_DIR/tmp"
  mkdir -p -m 700 "$STACK_DIR/secrets"
  if ! in_toolbox; then
    mkdir -p "$LOG_DIR"
  fi
}

# fact TEXT: the main fact of the step that runs. run_step writes it into progress.txt.
# The file is in the work folder, so a step part in the toolbox can set it too.
fact() { printf '%s\n' "$*" > "$STACK_DIR/tmp/fact.txt"; }

# progress STEP RESULT TEXT: one line in progress.txt.
progress() {
  printf '%s  %s  %s  %s\n' "$(date '+%F %T')" "$1" "$2" "$3" >> "$PROGRESS_FILE"
}

# mirror_ref REF: a Docker Hub reference with the mirror in place of docker.io. A tag and a
# digest stay. Another registry stays as it is.
#   docker.io/golang:1.27.4@sha256:x   ->  mirror.gcr.io/library/golang:1.27.4@sha256:x
#   docker.io/temporalio/server:1.30.3 ->  mirror.gcr.io/temporalio/server:1.30.3
mirror_ref() {
  local ref="$1" rest
  case "$ref" in
    docker.io/*) rest="${ref#docker.io/}" ;;
    *) printf '%s' "$ref"; return 0 ;;
  esac
  case "${rest%%[:@]*}" in
    */*) printf '%s/%s' "$DOCKERHUB_MIRROR" "$rest" ;;
    *) printf '%s/library/%s' "$DOCKERHUB_MIRROR" "$rest" ;;
  esac
}

# The kubeconfig of the toolbox. admin.conf of the kind node has the server
# https://kata-cp-control-plane:6443, which the Docker network resolves. The host kubeconfig
# /scratch/kata-cp/kubeconfig does not change.
make_kubeconfig() {
  in_toolbox && die "make_kubeconfig is a host function"
  local f="$STACK_DIR/secrets/kubeconfig.internal"
  ( umask 077; docker exec "$KIND_NODE" cat /etc/kubernetes/admin.conf > "$f.tmp" </dev/null )
  grep -q "server: https://${KIND_NODE}:6443" "$f.tmp" || { rm -f "$f.tmp"; die "admin.conf of the node has no server https://${KIND_NODE}:6443"; }
  mv "$f.tmp" "$f"
  chmod 600 "$f"
}

# One database password for PostgreSQL, Temporal and the controller, as
# controllerdeploy.go:524-531 does. The password stays in secrets/db-password. A new password
# with an old PostgreSQL volume does not work, so the file is never made again.
make_secret_values() {
  local d="$STACK_DIR/secrets" pw
  ( umask 077
    if [ ! -s "$d/db-password" ]; then
      head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$d/db-password"
    fi
    pw="$(cat "$d/db-password")"
    [ "${#pw}" -eq 32 ] || die "secrets/db-password does not have 32 characters"
    printf 'auth:\n  password: "%s"\n' "$pw" > "$d/postgres-secret-values.yaml"
    printf 'server:\n  config:\n    persistence:\n      default:\n        sql:\n          password: "%s"\n      visibility:\n        sql:\n          password: "%s"\n' "$pw" "$pw" > "$d/temporal-secret-values.yaml"
    printf 'appDb:\n  postgresPassword: "%s"\n' "$pw" > "$d/controller-secret-values.yaml"
  )
}

# The Defender rule of the lab: no script may use the network socket device path of bash.
defender_check() {
  local hits
  hits="$(grep -rnE '/dev/(t|u)[cd]p/' "$STACK_DIR"/*.sh "$STACK_DIR"/values "$STACK_DIR"/manifests 2>/dev/null || true)"
  [ -z "$hits" ] || die "a file uses the network socket device path of bash: $hits"
}

# sha256_ok FILE SHA: true when the file has that SHA-256.
sha256_ok() {
  [ -s "$1" ] || return 1
  [ "$(sha256sum "$1" | cut -d' ' -f1)" = "$2" ]
}
