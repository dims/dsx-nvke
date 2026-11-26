#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Test steps of nvke-lab-bootstrap-helper in the lab cluster kata-cp. Each kubectl call runs
# in the kind node, so the host opens no connection to the API server.
#
#   ./run.sh setup                     namespace, wrapper ConfigMap, two host pods
#   ./run.sh secret NODE FORM          Secret NODE-bootstrap-data from test/fixtures/FORM.userdata.yaml
#   ./run.sh static "NODE HOST" ...    ConfigMap with the static machine list
#   ./run.sh deploy [static]           the helper, from deploy/render.sh, all in the test namespace
#   ./run.sh helper-log                the log of the helper
#   ./run.sh check POD FORM            compare the files in the pod with test/fixtures/FORM.expected
#   ./run.sh state POD                 status file, marker, counter, agent unit, container start mark
#   ./run.sh restart-container POD     stop systemd in the pod, the kubelet starts a new container
#   ./run.sh restart-helper            delete the helper pod, the Deployment makes a new one
#   ./run.sh clean                     delete the test namespace
set -o errexit -o nounset -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS=${NS:-phase1-helper-test}
KIND_NODE=${KIND_NODE:-kata-cp-control-plane}
STATE=/var/lib/nico-containers/cloud-init

K() { docker exec -i "$KIND_NODE" kubectl --kubeconfig /etc/kubernetes/admin.conf "$@"; }
# Run a shell text in the node container of a pod. The text goes through stdin.
in_pod() {
  local pod=$1
  shift
  K -n "$NS" exec -i "$pod" -c node -- sh -s -- "$@"
}

case "${1:-}" in
  setup)
    K create namespace "$NS" --dry-run=client -o yaml | K apply -f -
    K -n "$NS" create configmap helper-test-wrapper --from-file=wrapper.sh=/dev/stdin --dry-run=client -o yaml <"$HERE/wrapper.sh" | K apply -f -
    for n in 1 2; do
      sed -e "s/__NAME__/helper-test-pod-$n/" -e "s/__HOST__/helper-test-host-$n/" -e "s/__NS__/$NS/" "$HERE/host-pod.yaml.tmpl" | K apply -f -
    done
    K -n "$NS" wait --for=condition=Ready pod/helper-test-pod-1 pod/helper-test-pod-2 --timeout=180s
    ;;
  secret)
    node=$2 form=$3
    K -n "$NS" create secret generic "$node-bootstrap-data" --from-file=value=/dev/stdin --dry-run=client -o yaml \
      <"$HERE/fixtures/$form.userdata.yaml" | K apply -f -
    ;;
  static)
    shift
    {
      echo "machines:"
      for entry in "$@"; do
        set -- $entry
        printf '  - {name: %s, host: %s, secret: %s-bootstrap-data}\n' "$1" "$2" "$1"
      done
    } | K -n "$NS" create configmap helper-test-static --from-file=machines.yaml=/dev/stdin --dry-run=client -o yaml | K apply -f -
    ;;
  deploy)
    static=""
    [ "${2:-}" = static ] && static=helper-test-static
    HELPER_NS=$NS CAPI_NS=$NS HOSTS_NS=$NS STATIC_CONFIGMAP=$static "$HERE/../deploy/render.sh" | K apply -f -
    K -n "$NS" rollout status deployment/nvke-lab-bootstrap-helper --timeout=120s
    ;;
  helper-log)
    K -n "$NS" logs deployment/nvke-lab-bootstrap-helper --tail="${2:-100}"
    ;;
  check)
    pod=$2 form=$3
    in_pod "$pod" <<EOF
fail=0
while read -r sum mode owner path; do
  got_sum=\$(sha256sum "\$path" 2>/dev/null | cut -d' ' -f1)
  got_mode=\$(stat -L -c '%a' "\$path" 2>/dev/null)
  got_owner=\$(stat -L -c '%U:%G' "\$path" 2>/dev/null)
  if [ "\$got_sum" = "\$sum" ] && [ "\$got_mode" = "\$mode" ] && [ "\$got_owner" = "\$owner" ]; then
    echo "OK    \$mode \$owner \$path"
  else
    echo "FAIL  \$path: content \$([ "\$got_sum" = "\$sum" ] && echo same || echo differs), mode \${got_mode:-none} (want \$mode), owner \${got_owner:-none} (want \$owner)"
    fail=1
  fi
done <<'LIST'
$(cat "$HERE/fixtures/$form.expected")
LIST
exit \$fail
EOF
    ;;
  state)
    pod=$2
    in_pod "$pod" <<EOF
echo "container start mark: \$(cat /.helper-test-container-start 2>/dev/null || echo none)"
echo "systemd: \$(systemctl is-system-running 2>/dev/null)"
echo "status file: \$(cat $STATE/status 2>/dev/null || echo absent)"
echo "cloud-init shim: \$(cloud-init status --long 2>&1 | head -n 1)"
echo "marker: \$(cat $STATE/nvke-lab-bootstrap-helper.machine 2>/dev/null || echo absent)"
echo "counter lines: \$(wc -l </var/lib/nico-containers/helper-test/runcmd.count 2>/dev/null || echo 0)"
echo "state folder: \$(ls $STATE 2>/dev/null | tr '\n' ' ')"
echo "output.log: \$(cat $STATE/output.log 2>/dev/null | tr '\n' '|')"
echo "nvke-agent: \$(systemctl show nvke-agent.service -p ActiveState -p SubState -p MainPID -p NRestarts -p ActiveEnterTimestamp | tr '\n' ' ')"
echo "nvke-agent command: \$(tr '\0' ' ' </proc/\$(systemctl show nvke-agent.service -p MainPID --value)/cmdline 2>/dev/null)"
echo "spire-agent: \$(systemctl show spire-agent.service -p ActiveState -p SubState -p NRestarts | tr '\n' ' ')"
echo "env file link: \$(ls -l /etc/default/nke-agent | sed 's/.*nke-agent/nke-agent/')"
echo "env file content: \$(tr '\n' '|' </etc/default/nvke-agent)"
echo "spire files: \$(ls -l --time-style=+%H:%M:%S /etc/spire-agent | tail -n +2 | awk '{print \$1, \$3":"\$4, \$6, \$7}' | tr '\n' '|')"
echo "helper files in /run: \$(ls /run | grep -c nvke-lab-bootstrap-helper || true)"
EOF
    ;;
  restart-container)
    pod=$2
    K -n "$NS" get pod "$pod" -o jsonpath='{.status.containerStatuses[0].containerID} restarts={.status.containerStatuses[0].restartCount}{"\n"}'
    K -n "$NS" exec "$pod" -c node -- systemctl poweroff || true
    ;;
  restart-helper)
    K -n "$NS" delete pod -l app=nvke-lab-bootstrap-helper --wait=true
    K -n "$NS" rollout status deployment/nvke-lab-bootstrap-helper --timeout=120s
    ;;
  clean)
    K delete namespace "$NS" --wait=true --timeout=180s
    ;;
  *)
    sed -n '2,15p' "$0"
    exit 2
    ;;
esac
