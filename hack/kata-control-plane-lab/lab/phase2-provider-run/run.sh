#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Phase 2, steps 4 and 5: a cluster through the real NVKE controller with cluster-api-provider-podvm.
# This script makes NO pod, NO claim and NO Secret copy. It makes the pod namespace with the network
# attachment and the shared endpoint Service, sends one request to the NVKE API, and then watches,
# checks and records. The provider makes the pods.
#
# It loads the functions of block D (d/endpoint-run/run.sh) and of T4 (p2-image/test/t4.sh) and
# replaces the ones that make a pod or name one.
#
# Usage: LOG_DIR=<run folder> run.sh <step>
#   base         namespace, network attachment, shared Service; checks of the start state
#   post         one POST /api/clusters with infra.cluster (PodVMCluster) and the PodVMMachineTemplate
#   wait-pods    wait for the three pods of the provider and record which Machine has which address
#   wait, wait-nodes, check, record, evidence, endpoint, reach, etcd, names, patch-check   as block D and T4
#   provider     the objects of the provider against the pod table of its README
#   times        WaitForCAPIMachineReady, NodePreflight and its attempts, from the Temporal history
#   traffic, tunnels   the measurements of block D
#   lost-pod <a|b|c|first|other>   delete one pod by hand and watch the provider make it again (other = not the first node)
#   reboot <a|b|c>   the reboot request of NVKE (a label on the Node of the new cluster)
#   delete       DELETE through the NVKE API and nothing else; wait, then list what is left
#   flow         base, post, wait-pods, wait, wait-nodes, check, record, evidence, endpoint, reach, etcd, names, provider, times
set -euo pipefail
. /root/kata-cp/bin/env.sh
P="$(cd "$(dirname "$0")" && pwd)"
export NS=${NS:-d}                                   # the pod namespace (spec.podNamespace)
export LOG_DIR=${LOG_DIR:-$W/logs/p2s4/run-1}
SC=${SC:-podvm-local-block}
RANGE_CIDR=${RANGE_CIDR:-172.28.1.0/24}
NODE_IMAGE_REF=${NODE_IMAGE_REF:-docker.io/library/nvke-node-podvm:bcc4376f-p2}
PROVIDER_NS=podvm-system

# The functions of block D and of T4, without their command dispatch.
# shellcheck disable=SC1090
source <(sed '/^step=\${1:-}$/,$d' "$W/p2-image/test/t4.sh")
HERE=$D
check_devices() { :; }   # storage.sh owns the devices in this step

# --- which Machine is host a, b, c -------------------------------------------------------------
# Block D named its hosts a, b and c. Here the provider gives the addresses, so the three Machines
# get the letters in the order of their addresses, after the provider made the pods.
PODMAP=$LOG_DIR/podmap.txt   # one line for each Machine: <letter> <machine> <address> <host node>
load_podmap() {
  local r m ip hn
  [ -s "$PODMAP" ] || return 0
  while read -r r m ip hn; do PODS[$r]=$m; IPS[$r]=$ip; HOST_NODES[$r]=$hn; done <"$PODMAP"
}
load_podmap
pvmm_json() { k -n "$CAPI_NS" get podvmmachines -l "cluster.x-k8s.io/cluster-name=$CLUSTER_NAME" -o json; }
write_podmap() {
  local i=0 m ip hn letters=(a b c)
  : >"$PODMAP.new"
  while read -r ip m; do
    hn=$(k -n "$NS" get pod "$m" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)
    echo "${letters[$i]} $m $ip ${hn:-none}" >>"$PODMAP.new"
    i=$((i + 1))
  done < <(pvmm_json | jq -r '.items[] | select(.status.address) | "\(.status.address) \(.metadata.name)"' | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n)
  mv "$PODMAP.new" "$PODMAP"
  load_podmap
}

cmd_base() {
  local n free
  say "memory and load of the machine"
  free -g
  uptime
  say "provider: manager and leader lease"
  k -n "$PROVIDER_NS" get pods -o wide
  k -n "$PROVIDER_NS" get lease -o custom-columns=NAME:.metadata.name,HOLDER:.spec.holderIdentity,RENEWED:.spec.renewTime
  say "storage: class $SC and the volumes"
  k get storageclass "$SC" -o custom-columns=NAME:.metadata.name,PROVISIONER:.provisioner,BINDING:.volumeBindingMode,RECLAIM:.reclaimPolicy
  "$P/storage.sh" status
  for n in $WORKERS; do
    free=$(k get pv -l "podvm.lab/host-node=$n" -o json | jq -r '[.items[] | select(.status.phase=="Available") | .metadata.labels["podvm.lab/use"]] | group_by(.) | map("\(.[0])=\(length)") | join(" ")')
    echo "$n: free volumes $free"
    case "$free" in *etcd=*var=*) ;; *) die "host node $n has no free place for a Machine" ;; esac
  done
  say "pod namespace $NS, the node network, the shared API Service. No ConfigMap, no pod, no claim, no Secret."
  k create namespace "$NS" --dry-run=client -o yaml | nodei "${KC[@]}" apply -f -
  NS=$NS envsubst '$NS' <"$D/nad.yaml.tmpl" | nodei "${KC[@]}" apply -f -
  NS=$NS IP_API=$IP_API ETP=$ETP CLUSTER_NAME=$CLUSTER_NAME envsubst '$NS $IP_API $ETP $CLUSTER_NAME' <"$P/api-service.yaml.tmpl" >"$LOG_DIR/service-cp-api.yaml"
  nodei "${KC[@]}" apply -f - <"$LOG_DIR/service-cp-api.yaml"
  k -n "$NS" wait --for=jsonpath='{.status.loadBalancer.ingress[0].ip}'="$IP_API" service/cp-api --timeout=60s
  k -n "$NS" get svc -o wide | tee "$LOG_DIR/services.txt"
  say "what must be absent before the request"
  echo "in $NS: pods [$(k -n "$NS" get pods -o name | tr '\n' ' ')] claims [$(k -n "$NS" get pvc -o name | tr '\n' ' ')] Secrets [$(k -n "$NS" get secrets -o name | tr '\n' ' ')] ConfigMaps [$(k -n "$NS" get configmaps -o name | grep -v kube-root-ca.crt | tr '\n' ' ')]"
  echo "lab bootstrap helper: [$(k -n "$HELPER_NS" get deployments,pods -o name 2>&1 | tr '\n' ' ')]"
  echo "objects of the cluster in $CAPI_NS: [$(k -n "$CAPI_NS" get clusters.cluster.x-k8s.io,machines.cluster.x-k8s.io,podvmclusters,podvmmachines,podvmmachinetemplates -o name 2>/dev/null | tr '\n' ' ')]"
  echo "NVKE clusters: $(api get /api/clusters | api_body | jq -c '[.clusters[]? | .name]')"
  echo "node image in the host nodes: $(for n in $WORKERS; do docker exec "$n" crictl inspecti -o json "$NODE_IMAGE_REF" 2>/dev/null | jq -r '.status.id' | cut -c8-19; done | tr '\n' ' ')"
  say "the address range $RANGE_CIDR on the node network: who holds an address of it now"
  # 1. pods of the lab cluster with an address of the range in their network annotation
  echo "pods with an address of the range: [$(k get pods -A -o json | jq -r --arg p "${RANGE_CIDR%.*}." '.items[] | select((.metadata.annotations["k8s.v1.cni.cncf.io/networks"] // "") | contains($p)) | "\(.metadata.namespace)/\(.metadata.name)"' | tr '\n' ' ')]"
  # 2. one echo request to each address of the range, from the machine on the bridge of the node network
  echo "answers to an echo request, 254 addresses: [$({ for i in $(seq 1 254); do (ping -c1 -W1 "${RANGE_CIDR%.*}.$i" >/dev/null 2>&1 && echo "${RANGE_CIDR%.*}.$i") & done; wait; } 2>/dev/null | sort -t. -k4n | tr '\n' ' ')]"
  echo "neighbor entries of the range on the machine: [$(ip neigh show | grep -F "${RANGE_CIDR%.*}." | grep -v -E 'FAILED|INCOMPLETE' | awk '{print $1 "=" $5 "(" $NF ")"}' | tr '\n' ' ')]"
  for n in $NODES; do echo "neighbor entries of the range in $n: [$(docker exec "$n" ip neigh show | grep -F "${RANGE_CIDR%.*}." | grep -v -E 'FAILED|INCOMPLETE' | awk '{print $1 "=" $5 "(" $NF ")"}' | tr '\n' ' ')]"; done
  echo "source address of the machine for the range: $(ip route get "${RANGE_CIDR%.*}.1" | head -1)"
}

cmd_post() {
  export NS IP_API POD_CIDR SERVICE_CIDR CLUSTER_NAME RUNTIME_CLASS CPU MEMORY SC RANGE_CIDR NODE_IMAGE_REF
  envsubst '$NS $IP_API $POD_CIDR $SERVICE_CIDR $CLUSTER_NAME $RUNTIME_CLASS $CPU $MEMORY $SC $RANGE_CIDR $NODE_IMAGE_REF' <"$P/request.json.tmpl" >"$LOG_DIR/request.json"
  jq -e . "$LOG_DIR/request.json" >/dev/null || die "the request is not JSON"
  say "POST /api/clusters ($CLUSTER_NAME)"
  stamp post
  date -u +%FT%T.%3NZ >"$LOG_DIR/post-time.txt"
  api post /api/clusters "$LOG_DIR/request.json" >"$LOG_DIR/post-response.txt" 2>&1 || true
  tail -1 "$LOG_DIR/post-response.txt"
  grep -q '^HTTP 20[012]$' "$LOG_DIR/post-response.txt" || { cat "$LOG_DIR/post-response.txt"; die "the API did not accept the request"; }
  api_body <"$LOG_DIR/post-response.txt" | jq -r '.id' >"$LOG_DIR/cluster-id.txt"
  say "cluster ID $(cluster_id)"
  api_body <"$LOG_DIR/post-response.txt" | jq -c '{name, id, controlPlaneEndpoint}' || true
}

# One line for each look: what the provider made so far.
provider_line() {
  local j
  j=$(pvmm_json 2>/dev/null || echo '{"items":[]}')
  printf '%s machines=%s with-address=%s provisioned=%s | pods=%s running=%s started=%s | claims bound=%s | secrets=%s\n' "$(date -u +%T)" \
    "$(jq '.items | length' <<<"$j")" "$(jq '[.items[] | select(.status.address)] | length' <<<"$j")" \
    "$(jq '[.items[] | select(.status.initialization.provisioned==true)] | length' <<<"$j")" \
    "$(k -n "$NS" get pods -o name 2>/dev/null | grep -c . || true)" \
    "$(k -n "$NS" get pods -o json 2>/dev/null | jq '[.items[] | select(.status.phase=="Running")] | length')" \
    "$(k -n "$NS" get pods -o json 2>/dev/null | jq '[.items[] | select(.status.containerStatuses[0].started==true)] | length')" \
    "$(k -n "$NS" get pvc -o json 2>/dev/null | jq '[.items[] | select(.status.phase=="Bound")] | length')" \
    "$(k -n "$NS" get secrets -o name 2>/dev/null | grep -c . || true)"
}

# Wait until the provider made three pods and their containers are started (the startup probe passed).
cmd_wait_pods() {
  local end line r i=0
  end=$(( $(date +%s) + ${PODS_TIMEOUT:-900} ))
  say "wait for the three pods of the provider (one look each 5 s, limit ${PODS_TIMEOUT:-900} s)"
  while [ "$(date +%s)" -lt "$end" ]; do
    line=$(provider_line)
    echo "$line" | tee -a "$LOG_DIR/provider-timeline.txt"
    i=$((${i:-0} + 1))
    if [ $((i % 2)) = 1 ]; then poll_line | tee -a "$LOG_DIR/timeline.txt" | sed -E 's/ -- last error.*//' | cut -c1-200; fi
    case "$line" in *"pods=3 "*) [ -f "$LOG_DIR/.pods-seen" ] || { stamp pods-exist; touch "$LOG_DIR/.pods-seen"; } ;; esac
    case "$line" in *"pods=3 running=3 started=3 "*) stamp pods-started; break ;; esac
    sleep 5
  done
  write_podmap
  cat "$PODMAP"
  [ "$(grep -c . "$PODMAP")" = 3 ] || { say "FAIL: not three Machines with an address"; return 1; }
  grep -q ' none$' "$PODMAP" && { say "FAIL: a Machine has no pod on a host node"; return 1; }
  k -n "$NS" get pods -o wide
  say "POST to three pods: $(between post pods-exist) s, to three started containers: $(between post pods-started) s"
}

# The objects of the provider against the pod table of its README (pass rule 3).
cmd_provider() {
  local label=${1:-final} out fail=0 r m h
  out="$LOG_DIR/provider-$label.txt"
  {
    say "objects of the provider ($label) at $(date -u +%FT%TZ)"
    h=$(admin_host) || h=a
    k -n "$CAPI_NS" get podvmcluster "$CLUSTER_NAME" -o json >"$LOG_DIR/.pvmc.json"
    pvmm_json >"$LOG_DIR/.pvmm.json"
    k -n "$CAPI_NS" get machines.cluster.x-k8s.io -l "cluster.x-k8s.io/cluster-name=$CLUSTER_NAME" -o json >"$LOG_DIR/.machines.json"
    k -n "$NS" get pods -o json >"$LOG_DIR/.pods.json"
    k -n "$NS" get pvc -o json >"$LOG_DIR/.pvc.json"
    k get pv -l podvm.lab/use -o json >"$LOG_DIR/.pv.json"
    ik "$h" get nodes -o json >"$LOG_DIR/.inner-nodes.json"
    say "PodVMCluster"
    jq -r '"spec: \(.spec | tojson)", "provisioned: \(.status.initialization.provisioned), failure domains: \([.status.failureDomains[]? | "\(.name) controlPlane=\(.controlPlane)"] | join(", "))", "conditions: \([.status.conditions[]? | "\(.type)=\(.status) \(.reason // "")"] | join("; "))", "finalizers: \(.metadata.finalizers // [] | tojson), owner: \([.metadata.ownerReferences[]? | "\(.kind)/\(.name)"] | join(","))"' "$LOG_DIR/.pvmc.json"
    [ "$(jq -r '.status.initialization.provisioned' "$LOG_DIR/.pvmc.json")" = true ] || { echo "FAIL the PodVMCluster is not provisioned"; fail=1; }
    [ "$(jq -r '[.status.failureDomains[]?.name] | sort | join(" ")' "$LOG_DIR/.pvmc.json")" = "$(echo $WORKERS | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')" ] && echo "ok   the failure domains are the three host nodes that take pods" || { echo "FAIL the failure domains are not the three workers"; fail=1; }
    say "Machines, PodVMMachines, pods, Nodes"
    for r in "${REPLICAS[@]}"; do
      m=$(pn "$r")
      echo "--- host $r: Machine $m"
      jq -r --arg m "$m" '.items[] | select(.metadata.name==$m) | "Machine: failureDomain \(.spec.failureDomain // "none"), providerID \(.spec.providerID // "none"), infra \(.spec.infrastructureRef.kind)/\(.spec.infrastructureRef.name), bootstrap Secret \(.spec.bootstrap.dataSecretName), phase \(.status.phase), infrastructureProvisioned \(.status.initialization.infrastructureProvisioned // "-"), nodeRef \(.status.nodeRef.name // "none")"' "$LOG_DIR/.machines.json"
      jq -r --arg m "$m" '.items[] | select(.metadata.name==$m) | "PodVMMachine: providerID \(.spec.providerID // "none"), provisioned \(.status.initialization.provisioned // false), addresses \(.status.addresses // [] | tojson), address \(.status.address) hardwareAddress \(.status.hardwareAddress), pod \(.status.podNamespace)/\(.status.podName), lastRebootRequest \(.status.lastRebootRequest // "none"), conditions \([.status.conditions[]? | "\(.type)=\(.status) \(.reason // "")"] | join("; ")), finalizers \(.metadata.finalizers // [] | tojson)"' "$LOG_DIR/.pvmm.json"
      jq -r --arg m "$m" '.items[] | select(.metadata.name==$m) | .spec as $s | $s.containers[0] as $c |
        "pod: node \($s.nodeName), uid \(.metadata.uid), phase \(.status.phase), started \(.status.containerStatuses[0].started), ready \(.status.containerStatuses[0].ready), restarts \(.status.containerStatuses[0].restartCount), pod IP \(.status.podIP)",
        "pod: containers \([$s.containers[].name] | join(",")), image \($c.image), pull policy \($c.imagePullPolicy), privileged \($c.securityContext.privileged), command \($c.command // "none"), args \($c.args // "none"), class \($s.runtimeClassName), hostname field \($s.hostname // "none")",
        "pod: limits \($c.resources.limits | tojson) requests \($c.resources.requests | tojson), token \($s.automountServiceAccountToken), service links \($s.enableServiceLinks), restart policy \($s.restartPolicy), grace \($s.terminationGracePeriodSeconds), tty \($c.tty // false)",
        "pod: devices \([$c.volumeDevices[] | "\(.devicePath)=\(.name)"] | join(" ")), mounts \([$c.volumeMounts[] | "\(.mountPath)=\(.name) ro=\(.readOnly)"] | join(" ")), volumes \([$s.volumes[] | .name + "=" + (.persistentVolumeClaim.claimName // (.secret | "\(.secretName) items \(.items | tojson)"))] | join(" "))",
        "pod: env \([$c.env[] | "\(.name)=\(.value)"] | join(" "))",
        "pod: networks \(.metadata.annotations["k8s.v1.cni.cncf.io/networks"])",
        "pod: network status \(.metadata.annotations["k8s.v1.cni.cncf.io/network-status"] | fromjson | map(.name + " " + (.interface // "-") + " " + ((.ips // []) | join(",")) + " " + (.mac // "-")) | join("; "))",
        "pod: labels \(.metadata.labels | to_entries | map(.key + "=" + .value) | join(" "))",
        "pod: startup probe \($c.startupProbe | tojson), readiness probe \($c.readinessProbe | tojson)",
        "pod: affinity \($s.affinity | tojson)"' "$LOG_DIR/.pods.json"
      jq -r --arg m "$m" '.items[] | select(.metadata.name | startswith($m + "-")) | "claim \(.metadata.name): \(.status.phase), mode \(.spec.volumeMode), class \(.spec.storageClassName), request \(.spec.resources.requests.storage), volume \(.spec.volumeName), uid \(.metadata.uid)"' "$LOG_DIR/.pvc.json"
      jq -r --arg m "$m" '.items[] | select((.spec.claimRef.name // "") | startswith($m + "-")) | "volume \(.metadata.name): \(.spec.local.path) on \(.metadata.labels["podvm.lab/host-node"]), \(.spec.capacity.storage), claim \(.spec.claimRef.name)"' "$LOG_DIR/.pv.json"
      echo "Secret copy: $(k -n "$NS" get secret "$m-bootstrap" -o json | jq -r '"\(.metadata.name), type \(.type), keys \(.data | keys | join(",")), labels \(.metadata.labels | to_entries | map(.key + "=" + .value) | join(" "))"')"
      echo "in the guest: $(pod "$r" sh -c 'echo "hostname $(hostname), net1 $(ip -o -4 addr show dev net1 | awk "{print \$4}") $(cat /sys/class/net/net1/address), boot ID $(cat /proc/sys/kernel/random/boot_id), cloud-init $(cloud-init status | head -1), systemd $(systemctl is-system-running), failed units $(systemctl --failed --no-legend --plain | wc -l)"' 2>&1)"
      jq -r --arg m "$m" '.items[] | select(.metadata.name==$m) | "Node: providerID \(.spec.providerID // "none"), address \([.status.addresses[] | select(.type=="InternalIP") | .address] | join(",")), boot ID \(.status.nodeInfo.bootID), machine ID \(.status.nodeInfo.machineID), Ready \([.status.conditions[] | select(.type=="Ready") | .status] | join(""))"' "$LOG_DIR/.inner-nodes.json"
      # The rules of the pod table.
      jq -e --arg m "$m" --arg ns "$NS" --arg ip "${IPS[$r]}" --arg cl "$CLUSTER_NAME" --arg img "$NODE_IMAGE_REF" --arg rc "$RUNTIME_CLASS" --arg cpu "$CPU" --arg mem "$MEMORY" '
        .items[] | select(.metadata.name==$m) | .spec as $s | $s.containers[0] as $c
        | (.metadata.annotations["k8s.v1.cni.cncf.io/networks"] | fromjson) as $n
        | [ (.metadata.namespace == $ns),
            ($s.containers | length == 1), ($c.name == "node"), ($c.securityContext.privileged == true), ($c.image == $img), ($c.command == null), ($c.args == null),
            ($s.runtimeClassName == $rc),
            ($c.resources.limits.cpu == $cpu), ($c.resources.limits.memory == $mem), ($c.resources.requests == $c.resources.limits),
            ([$c.volumeDevices[] | "\(.devicePath)=\(.name)"] | sort == ["/dev/podvm-etcd=etcd", "/dev/podvm-var=var"]),
            ([$s.volumes[] | select(.persistentVolumeClaim) | .persistentVolumeClaim.claimName] | sort == [$m + "-etcd", $m + "-var"]),
            ([$s.volumes[] | select(.secret) | .secret.secretName] == [$m + "-bootstrap"]),
            ([$c.volumeMounts[] | select(.mountPath == "/etc/podvm/bootstrap" and .readOnly == true)] | length == 1),
            ([$c.env[] | "\(.name)=\(.value)"] | sort == ["PODVM_MACHINE_NAME=" + $m, "PODVM_NODE_ADDRESS=" + $ip + "/16", "PODVM_NODE_INTERFACE=net1"]),
            ($n | length == 1), ($n[0].name == "nodenet"), ($n[0].namespace == $ns), ($n[0].ips == [$ip + "/16"]),
            (.metadata.labels["cluster.x-k8s.io/cluster-name"] == $cl), (.metadata.labels["cluster.x-k8s.io/control-plane"] == ""),
            (.metadata.labels["podvm.infrastructure.cluster.x-k8s.io/machine-name"] == $m),
            ($c.startupProbe.tcpSocket.port == 15005), ($c.startupProbe.periodSeconds == 2),
            ($c.readinessProbe.httpGet.path == "/readyz"), ($c.readinessProbe.httpGet.port == 6443), ($c.readinessProbe.httpGet.scheme == "HTTPS"), ($c.readinessProbe.periodSeconds == 2),
            ($s.automountServiceAccountToken == false), ($s.enableServiceLinks == false),
            (.status.containerStatuses[0].started == true) ]
        | if all then "ok   pod \($m): \(length) rules of the pod table hold" else error("pod rules: \(tojson)") end' -r "$LOG_DIR/.pods.json" 2>&1 || { echo "FAIL pod $m does not have the form of the pod table"; fail=1; }
      # The hardware address: 02:00 and the four bytes of the address.
      want=$(mac_of "${IPS[$r]}")
      got=$(jq -r --arg m "$m" '.items[] | select(.metadata.name==$m) | .metadata.annotations["k8s.v1.cni.cncf.io/networks"] | fromjson | .[0].mac' "$LOG_DIR/.pods.json")
      inguest=$(pod "$r" sh -c 'echo "$(ip -o -4 addr show dev net1 | awk "{print \$4}") $(cat /sys/class/net/net1/address)"' 2>/dev/null || true)
      [ "$got" = "$want" ] && [ "$inguest" = "${IPS[$r]}/16 $want" ] && echo "ok   address ${IPS[$r]} and hardware address $want, in the annotation and on net1 of the guest" || { echo "FAIL address or hardware address: annotation $got, guest [$inguest], rule $want"; fail=1; }
      # The provider ID on the Machine, the PodVMMachine and the Node.
      pid="podvm://$NS/$m"
      [ "$(jq -r --arg m "$m" '.items[] | select(.metadata.name==$m) | .spec.providerID' "$LOG_DIR/.machines.json")" = "$pid" ] &&
        [ "$(jq -r --arg m "$m" '.items[] | select(.metadata.name==$m) | .spec.providerID' "$LOG_DIR/.pvmm.json")" = "$pid" ] &&
        [ "$(jq -r --arg m "$m" '.items[] | select(.metadata.name==$m) | .spec.providerID' "$LOG_DIR/.inner-nodes.json")" = "$pid" ] &&
        echo "ok   provider ID $pid on the Machine, the PodVMMachine and the Node" || { echo "FAIL the provider ID is not $pid on all three"; fail=1; }
      # The two claims are bound to volumes of the host node of the pod.
      hn=$(jq -r --arg m "$m" '.items[] | select(.metadata.name==$m) | .spec.nodeName' "$LOG_DIR/.pods.json")
      [ "$(jq -r --arg m "$m" --arg hn "$hn" '[.items[] | select((.spec.claimRef.name // "") | startswith($m + "-")) | select(.metadata.labels["podvm.lab/host-node"]==$hn)] | length' "$LOG_DIR/.pv.json")" = 2 ] && echo "ok   both claims are bound to volumes of the host node $hn" || { echo "FAIL the claims are not on $hn"; fail=1; }
      fd=$(jq -r --arg m "$m" '.items[] | select(.metadata.name==$m) | .spec.failureDomain // ""' "$LOG_DIR/.machines.json")
      if [ -n "$fd" ]; then [ "$fd" = "$hn" ] && echo "ok   failure domain $fd of the Machine is the host node of the pod" || { echo "FAIL failure domain $fd, host node $hn"; fail=1; }; else echo "note the Machine has no failure domain; the pod runs on $hn"; fi
    done
    say "three different addresses, hardware addresses and host nodes"
    echo "addresses: $(jq -r '[.items[].status.address] | sort | join(" ")' "$LOG_DIR/.pvmm.json"); hardware addresses: $(jq -r '[.items[].status.hardwareAddress] | sort | join(" ")' "$LOG_DIR/.pvmm.json"); host nodes: $(jq -r '[.items[].spec.nodeName] | sort | join(" ")' "$LOG_DIR/.pods.json"); failure domains of the Machines: $(jq -r '[.items[] | .spec.failureDomain // "none"] | sort | join(" ")' "$LOG_DIR/.machines.json")"
    [ "$(jq -r '[.items[].status.address] | unique | length' "$LOG_DIR/.pvmm.json")" = 3 ] && [ "$(jq -r '[.items[].status.hardwareAddress] | unique | length' "$LOG_DIR/.pvmm.json")" = 3 ] || { echo "FAIL the addresses are not different"; fail=1; }
    [ "$(jq -r '[.items[].spec.nodeName] | unique | length' "$LOG_DIR/.pods.json")" = 3 ] && echo "ok   the three pods run on three host nodes" || echo "note the three pods do not run on three host nodes"
    say "what else is in the pod namespace"
    k -n "$NS" get pods,pvc,secrets,configmaps,services,network-attachment-definitions -o name | grep -v kube-root-ca.crt | tr '\n' ' '
    echo
    say "storage"
    "$P/storage.sh" status
    [ "$fail" = 0 ] && echo "RESULT provider $label: PASS" || echo "RESULT provider $label: FAIL"
  } 2>&1 | tee "$out"
  grep -q "RESULT provider $label: PASS" "$out"
}

# One activity of a node workflow, from the raw Temporal history: scheduled, done, seconds, attempts.
activity_line() { # <history json> <activity name>
  jq -r --arg a "$2" '(.events // .) as $e
    | [$e[] | select(.eventType|test("ACTIVITY_TASK_SCHEDULED$")) | select(.activityTaskScheduledEventAttributes.activityType.name==$a)] as $s
    | $s[] | (.eventId|tostring) as $id | .eventTime as $t0
    | ([$e[] | select(.eventType|test("ACTIVITY_TASK_STARTED$")) | select((.activityTaskStartedEventAttributes.scheduledEventId|tostring)==$id)][0]) as $st
    | ([$e[] | select(.eventType|test("ACTIVITY_TASK_COMPLETED$")) | select((.activityTaskCompletedEventAttributes.scheduledEventId|tostring)==$id)][0]) as $c
    | def secs($t): ($t | sub("Z$"; "") | split(".")) as $p | (($p[0] + "Z") | fromdateiso8601) + (if ($p | length) > 1 then (("0." + $p[1]) | tonumber) else 0 end);
      "\($a): scheduled \($t0[11:23]) done \(($c.eventTime // "-")[11:23]) = \(if $c then ((secs($c.eventTime) - secs($t0)) * 10 | round / 10) else "-" end) s, attempts \($st.activityTaskStartedEventAttributes.attempt // "?")"' "$1" 2>/dev/null
}

# Pass rule 4: the times of this run from the Temporal history, against block D run 2 and T4.
cmd_times() {
  local out="$LOG_DIR/times-table.txt" r m id f
  one() { # <label> <log dir> <secrets dir>
    local ld=$2 sd=$3 n id f
    echo "## $1"
    echo "POST to provisioned: $(awk '$2=="post" {x=$1} $2=="provisioned" {y=$1} END {if (x && y) printf "%.1f", y-x; else printf "-"}' "$ld/times.txt") s, to three provisioned nodes: $(awk '$2=="post" {x=$1} $2=="nodes-provisioned" {y=$1} END {if (x && y) printf "%.1f", y-x; else printf "-"}' "$ld/times.txt") s, to three Ready nodes: $(awk '$2=="post" {x=$1} $2=="nodes-ready-final" {y=$1} END {if (x && y) printf "%.1f", y-x; else printf "-"}' "$ld/times.txt") s"
    for id in $(jq -r '(.nodes // [])[] | .id' "$ld/record-final/api-nodes.json"); do
      n=$(jq -r --arg i "$id" '(.nodes // [])[] | select(.id==$i) | .name' "$ld/record-final/api-nodes.json")
      f="$sd/workflow-provision-node-$id.json"
      [ -s "$f" ] || { echo "$n: no history file"; continue; }
      echo "$n: $(activity_line "$f" CreateCAPIInfraMachineForNode | sed 's/^[A-Za-z]*: /create machine /; s/, attempts.*//')"
      echo "$n: $(activity_line "$f" WaitForCAPIMachineReady)"
      echo "$n: $(activity_line "$f" NodePreflight)"
    done
  }
  {
    say "times at $(date -u +%FT%TZ)"
    one "this run ($(basename "$LOG_DIR"), provider podvm)" "$LOG_DIR" "$SEC"
    [ -d "$W/logs/p2/t4-run-1/record-final" ] && one "T4 (image for pods, provisioned provider, pod made by the script after the POST)" "$W/logs/p2/t4-run-1" "$W/secrets/d-t4-run-1"
    [ -d "$W/logs/d/d-run-2/record-final" ] && one "block D run 2 (pods before the POST, lab helper)" "$W/logs/d/d-run-2" "$W/secrets/d-d-run-2"
    say "this run: the provider and the pods"
    echo "POST to three pods: $(between post pods-exist) s, to three started containers: $(between post pods-started) s"
    for r in "${REPLICAS[@]}"; do
      m=$(pn "$r")
      echo "host $r ($m, ${IPS[$r]}, ${HOST_NODES[$r]}):"
      k -n "$CAPI_NS" get podvmmachine "$m" -o json | jq -r '"    PodVMMachine created \(.metadata.creationTimestamp), Ready since \([.status.conditions[]? | select(.type=="Ready") | .lastTransitionTime] | join(""))"'
      k -n "$NS" get pod "$m" -o json | jq -r '"    pod created \(.metadata.creationTimestamp), scheduled \([.status.conditions[] | select(.type=="PodScheduled") | .lastTransitionTime] | join("")), container running \(.status.containerStatuses[0].state.running.startedAt), pod Ready \([.status.conditions[] | select(.type=="Ready") | .lastTransitionTime] | join(""))"'
      k -n "$NS" logs "$m" 2>/dev/null | grep -a 'PODVM:' | tr -d '\r' | grep -E 'start at|state is ready' | sed 's/^/    /' | cut -c1-150
      pod "$r" sh -c 'journalctl --no-pager -o short-precise -u podvm-bootstrap -u podvm-bootstrap-final | grep RESULT | cut -c1-200; echo "boot: $(systemd-analyze 2>&1 | head -1); slowest unit: $(systemd-analyze blame --no-pager 2>/dev/null | head -1 | tr -s " ")"; journalctl --no-pager -o short-precise -u nvke-agent | grep -m1 "setting up SPIFFE mTLS" | cut -c1-28 | sed "s/\$/ agent sets up its listener/"; journalctl --no-pager -o short-precise -u nvke-agent | grep -m1 "\"rpc\":\"ExecuteNodePreflight\"" | cut -c1-28 | sed "s/\$/ first ExecuteNodePreflight call/"' 2>&1 | sed 's/^/    /'
    done
    say "the provider log: when it wrote the addresses"
    k -n "$PROVIDER_NS" logs deployment/podvm-controller-manager --since-time="$(cat "$LOG_DIR/post-time.txt")" 2>/dev/null | jq -r 'select(.msg) | "\(.time[11:23]) \(.msg) \(.PodVMMachine.name // .name // "")"' 2>/dev/null | grep -v -i "starting\|lease" | head -60
  } 2>&1 | tee "$out"
}

# What identifies the pod, the claims, the Secret copy and the machine of one host. One line each.
identity() { # <host letter> <observer letter>
  local r=$1 o=$2 m
  m=$(pn "$r")
  k -n "$NS" get pod "$m" -o json | jq -r '"pod: name \(.metadata.name) node \(.spec.nodeName) networks \(.metadata.annotations["k8s.v1.cni.cncf.io/networks"])"'
  k -n "$NS" get pod "$m" -o json | jq -r '"pod-uid: \(.metadata.uid) pod IP \(.status.podIP) created \(.metadata.creationTimestamp)"'
  k -n "$NS" get pvc "$m-var" "$m-etcd" -o json | jq -r '.items[] | "claim: \(.metadata.name) uid \(.metadata.uid) volume \(.spec.volumeName) \(.status.phase)"'
  k -n "$NS" get secret "$m-bootstrap" -o json | jq -r '"secret: \(.metadata.name) uid \(.metadata.uid)"'
  k -n "$CAPI_NS" get podvmmachine "$m" -o json | jq -r '"machine: address \(.status.address) hardwareAddress \(.status.hardwareAddress) addresses \(.status.addresses | tojson) providerID \(.spec.providerID) provisioned \(.status.initialization.provisioned) pod \(.status.podNamespace)/\(.status.podName)"'
  k -n "$CAPI_NS" get podvmmachine "$m" -o json | jq -r '"machine-ready: \([.status.conditions[]? | "\(.type)=\(.status) \(.reason // "") since \(.lastTransitionTime)"] | join("; ")) lastRebootRequest \(.status.lastRebootRequest // "none")"'
  echo "node-boot-id: $(ik "$o" get node "$m" -o jsonpath='{.status.nodeInfo.bootID}' 2>/dev/null)"
}

# Step 5, point 5: delete one control plane pod by hand. The provider must make it again with the
# same name, claims and address, with no other step. "first" names the node that ran kubeadm init.
cmd_lost_pod() {
  local r=${1:?host letter or first} o out fail=0 watch=${LOST_WATCH:-240} pollpid m t0 hb i okk=0 oke=0 since
  if [ "$r" = first ]; then r=$(init_host) || die "no init node in the NVKE API"; fi
  if [ "$r" = other ]; then o=$(init_host) || die "no init node in the NVKE API"; for r in "${REPLICAS[@]}"; do [ "$r" != "$o" ] && break; done; fi
  for o in "${REPLICAS[@]}"; do [ "$o" != "$r" ] && break; done
  m=$(pn "$r")
  out="$LOG_DIR/lost-pod-$r.txt"
  {
    say "lost pod of the Machine $m (host $r, address ${IPS[$r]}, host node ${HOST_NODES[$r]}) at $(date -u +%FT%TZ). Observer host: $o. First node of the cluster: $(init_host || true)"
    say "before"
    poll_line | sed -E 's/\[[^]]*\]//g'
    etcdctl "$o" member list -w simple || true
    k -n "$NS" get endpointslices -l kubernetes.io/service-name=cp-api -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{" ready="}{.conditions.ready}{" "}{.targetRef.name}{"\n"}{end}'
    identity "$r" "$o" | tee "$LOG_DIR/.lost-before-$r"
    cmd_probe_start "lost-$r" $((watch + 120))
    cmd_probe_start "lost-node-$r" $((watch + 120)) "${IPS[$r]}:6443"
    sleep 10
    ( end=$(( $(date +%s) + watch )); while [ "$(date +%s)" -lt "$end" ]; do poll_line >>"$LOG_DIR/lost-$r-nvke-timeline.txt" 2>&1; sleep "$POLL"; done ) &
    pollpid=$!
    since=$(date -u +%FT%TZ)
    stamp "lost-$r-start"
    say "the one step by hand: delete pod $m at $(date -u +%T)"
    k -n "$NS" delete pod "$m" --wait=true
    stamp "lost-$r-old-pod-gone"
    k -n "$NS" wait --for=create "pod/$m" --timeout=120s || { echo "FAIL the provider did not make the pod again in 120 s"; fail=1; }
    stamp "lost-$r-new-pod"
    k -n "$NS" wait --for=jsonpath='{.status.phase}'=Running "pod/$m" --timeout=300s || fail=1
    wait_node 300 "${KC[*]} -n $NS exec $m -- systemctl is-active containerd >/dev/null 2>&1" || { echo "FAIL containerd of host $r"; fail=1; }
    stamp "lost-$r-node-up"
    if wait_node 600 "[ \"\$(${KC[*]} -n $NS get pod $m -o jsonpath='{.status.containerStatuses[0].started}')\" = true ]"; then stamp "lost-$r-started"; else echo "FAIL the startup probe did not pass"; fail=1; fi
    if k -n "$NS" wait --for=condition=Ready "pod/$m" --timeout=300s; then stamp "lost-$r-readyz"; else echo "FAIL /readyz of host $r"; fail=1; fi
    t0=$(awk -v k="lost-$r-old-pod-gone" '$2==k {print int($1)}' "$LOG_DIR/times.txt")
    for i in $(seq 1 60); do
      hb=$(ik "$o" get node "$m" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{" "}{.status.conditions[?(@.type=="Ready")].lastHeartbeatTime}' 2>/dev/null || true)
      if [ "${hb%% *}" = True ] && [ "$(date -u -d "${hb##* }" +%s 2>/dev/null || echo 0)" -gt "$t0" ]; then okk=1; break; fi
      sleep 5
    done
    if [ "$okk" = 1 ]; then stamp "lost-$r-nodes-ready"; echo "node $m: Ready with the heartbeat ${hb##* }"; else echo "FAIL node $m has no new Ready heartbeat: $hb"; fail=1; fi
    for i in $(seq 1 36); do
      if etcdctl "$o" endpoint health --cluster >/dev/null 2>&1; then oke=1; break; fi
      sleep 5
    done
    if [ "$oke" = 1 ]; then stamp "lost-$r-etcd-healthy"; else echo "FAIL etcd health"; fail=1; fi
    ik "$o" get nodes -o wide || true
    say "times after the delete (s): old pod gone $(between "lost-$r-start" "lost-$r-old-pod-gone"), new pod of the provider $(between "lost-$r-start" "lost-$r-new-pod"), systemd up $(between "lost-$r-start" "lost-$r-node-up"), startup probe passed $(between "lost-$r-start" "lost-$r-started"), /readyz of the pod $(between "lost-$r-start" "lost-$r-readyz"), new kubelet heartbeat seen $(between "lost-$r-start" "lost-$r-nodes-ready"), etcd healthy $(between "lost-$r-start" "lost-$r-etcd-healthy")"
    say "after"
    identity "$r" "$o" | tee "$LOG_DIR/.lost-after-$r"
    # Same name, node, network annotation (address and hardware address), claims, Secret copy and machine record. New pod UID and new boot ID.
    if diff <(grep -E '^(pod|claim|secret|machine):' "$LOG_DIR/.lost-before-$r") <(grep -E '^(pod|claim|secret|machine):' "$LOG_DIR/.lost-after-$r"); then echo "ok   same pod name, host node, address, hardware address, claims, Secret copy and machine record"; else echo "FAIL something of the identity changed"; fail=1; fi
    [ "$(grep '^pod-uid:' "$LOG_DIR/.lost-before-$r" | cut -d' ' -f2)" != "$(grep '^pod-uid:' "$LOG_DIR/.lost-after-$r" | cut -d' ' -f2)" ] && echo "ok   the pod has a new UID" || { echo "FAIL the pod UID is the same"; fail=1; }
    [ "$(grep '^node-boot-id:' "$LOG_DIR/.lost-before-$r")" != "$(grep '^node-boot-id:' "$LOG_DIR/.lost-after-$r")" ] && echo "ok   the Node has a new boot ID" || { echo "FAIL the boot ID is the same"; fail=1; }
    say "the new pod: entry point, bootstrap units, cloud-init answer"
    k -n "$NS" logs "$m" 2>/dev/null | grep -a 'PODVM:' | tr -d '\r' | grep -E 'start at|first use|state is ready' | cut -c1-160
    pod "$r" sh -c 'journalctl -b --no-pager -o short-precise -u podvm-bootstrap -u podvm-bootstrap-final | grep RESULT | cut -c1-260; echo "cloud-init: $(cloud-init status | head -1); systemd: $(systemctl is-system-running), failed units $(systemctl --failed --no-legend --plain | wc -l)"' 2>&1 || true
    pod "$r" sh -c 'journalctl -b --no-pager -u podvm-bootstrap -u podvm-bootstrap-final | grep -c "RESULT repeat"' | grep -q -x 2 && echo "ok   two repeat runs (files, commands), no first run" || { echo "FAIL not a repeat run"; fail=1; }
    say "what the provider logged since the delete"
    k -n "$PROVIDER_NS" logs deployment/podvm-controller-manager --since-time="$since" 2>/dev/null | jq -r 'select(.msg) | "\(.time[11:23]) \(.level) \(.msg) \(.PodVMMachine.name // "") \(.kind // "") \(.name // "") \(.error // "")"' 2>/dev/null | head -30
    say "events of the pod namespace since the delete (pod $m)"
    k -n "$NS" get events --field-selector "involvedObject.name=$m" --sort-by=.lastTimestamp -o custom-columns=TIME:.lastTimestamp,REASON:.reason,MESSAGE:.message 2>/dev/null | tail -14 | cut -c1-200
    say "wait for the end of the NVKE poll ($watch s after the delete)"
    wait "$pollpid" || true
    cmd_probe_stop "lost-$r"
    cmd_probe_stop "lost-node-$r"
    grep -q 'failed: 0$' "$LOG_DIR/probe-lost-$r-summary.txt" && echo "ok   the shared address answered each call" || { echo "FAIL the shared address has failed calls"; fail=1; }
    say "what NVKE reported each $POLL s: lines of the node, and of the cluster"
    grep -F "ip=${IPS[$r]} " "$LOG_DIR/lost-$r-nvke-timeline.txt" | sed -E 's/\[[^]]*\]//g' | sort | uniq -c
    grep ' cluster: ' "$LOG_DIR/lost-$r-nvke-timeline.txt" | sed -E 's/^[0-9:]+ //' | sort | uniq -c
    [ "$(grep ' cluster: ' "$LOG_DIR/lost-$r-nvke-timeline.txt" | grep -v -c 'provisioned\[Provisioned cluster\]' || true)" = 0 ] && echo "ok   NVKE reported the cluster as provisioned in each poll" || { echo "FAIL NVKE did not keep the cluster provisioned"; fail=1; }
    say "after: NVKE, etcd, endpoints of cp-api, workflows that started after the delete"
    poll_line | sed -E 's/\[[^]]*\]//g'
    etcdctl "$o" member list -w simple || true
    etcdctl "$o" endpoint health --cluster 2>&1 || true
    k -n "$NS" get endpointslices -l kubernetes.io/service-name=cp-api -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{" ready="}{.conditions.ready}{" "}{.targetRef.name}{"\n"}{end}'
    temporal workflow list --query "StartTime > \"$since\"" 2>&1 | head -20 || true
    [ "$fail" = 0 ] && echo "RESULT lost-pod $r: PASS" || echo "RESULT lost-pod $r: FAIL"
  } 2>&1 | tee "$out"
  grep -q "RESULT lost-pod $r: PASS" "$out"
}

# Step 5, point 6: the reboot request of NVKE. The API has no reboot call (controller/api/openapi.yaml).
# The request is the label nvke.nvidia.com/reboot on the Node of the new cluster: the node remediation
# controller of NVKE reads it and starts the workflow reboot-node-<node ID>
# (controller/internal/controllers/tenant/noderemediation/remediation.go).
cmd_reboot() {
  local r=${1:?host letter} o out m id wid i since watch=${REBOOT_WATCH:-300} st
  for o in "${REPLICAS[@]}"; do [ "$o" != "$r" ] && break; done
  m=$(pn "$r")
  id=$(api get "/api/nodes?clusterID=$(cluster_id)" | api_body | jq -r --arg n "$m" '(.nodes // [])[] | select(.name==$n) | .id')
  wid="reboot-node-$id"
  out="$LOG_DIR/reboot-$r.txt"
  view() {
    echo "$(date -u +%T) node labels [$(ik "$o" get node "$m" -o json | jq -r '.metadata.labels | to_entries | map(select(.key | test("reboot|terminate"))) | map(.key + "=" + .value) | join(" ")')] boot ID $(ik "$o" get node "$m" -o jsonpath='{.status.nodeInfo.bootID}' | cut -c1-8) | Machine annotations [$(k -n "$CAPI_NS" get machine.cluster.x-k8s.io "$m" -o json | jq -r '.metadata.annotations // {} | to_entries | map(select(.key | test("reboot"))) | map(.key + "=" + .value) | join(" ")')] | PodVMMachine lastRebootRequest $(k -n "$CAPI_NS" get podvmmachine "$m" -o jsonpath='{.status.lastRebootRequest}') | pod uid $(k -n "$NS" get pod "$m" -o jsonpath='{.metadata.uid}' | cut -c1-8) restarts $(k -n "$NS" get pod "$m" -o jsonpath='{.status.containerStatuses[0].restartCount}') | workflow $(temporal workflow describe --workflow-id "$wid" --output json 2>/dev/null | jq -r '.workflowExecutionInfo.status // "none"' 2>/dev/null || echo none)"
  }
  {
    say "reboot request for the node $m (host $r, NVKE node ID $id) at $(date -u +%FT%TZ)"
    say "before"
    view
    api get "/api/nodes/$id" | api_body | jq -c '{name, controlPlane, conditions: [.conditions | to_entries[] | select(.value.status=="True") | .key]}'
    since=$(date -u +%FT%TZ)
    stamp "reboot-$r-request"
    say "the request: label nvke.nvidia.com/reboot=p2s4-test on the Node $m of the new cluster, at $(date -u +%T)"
    ik "$o" label node "$m" nvke.nvidia.com/reboot=p2s4-test
    for i in $(seq 1 $((watch / 10))); do
      sleep 10
      view
      st=$(temporal workflow describe --workflow-id "$wid" --output json 2>/dev/null | jq -r '.workflowExecutionInfo.status // "none"' 2>/dev/null || echo none)
      # Three more looks after the workflow has ended, then stop.
      case "$st" in *COMPLETED* | *FAILED* | *CANCELED* | *TERMINATED* | *TIMED_OUT*) end_seen=$((${end_seen:-0} + 1)) ;; esac
      [ "${end_seen:-0}" -ge 3 ] && break
    done
    stamp "reboot-$r-end"
    say "the workflow $wid"
    temporal workflow describe --workflow-id "$wid" 2>&1 | grep -E '^ *(Status|Type|StartTime|CloseTime|ExecutionTime|RunTime|HistoryLength)' || echo "no workflow with this ID"
    LOG_DIR="$LOG_DIR" workflow_timeline "$wid" || true
    cat "$LOG_DIR/workflow-$wid.txt" 2>/dev/null | cut -c1-200
    say "what the controller logged for the reboot"
    k -n nvke-controller logs deployment/nvke-controller --since-time="$since" 2>/dev/null | grep -i -E 'reboot' | mask | cut -c1-330 | head -12
    say "what the provider logged since the request"
    k -n "$PROVIDER_NS" logs deployment/podvm-controller-manager --since-time="$since" 2>/dev/null | jq -r 'select(.msg) | "\(.time[11:23]) \(.level) \(.msg) \(.PodVMMachine.name // "")"' 2>/dev/null | head -20
    say "after"
    view
    api get "/api/nodes/$id" | api_body | jq -c '{name, controlPlane, conditions: [.conditions | to_entries[] | select(.value.status=="True") | .key]}'
    ik "$o" get node "$m" -o json | jq -r '"all labels of the node with reboot in the key: \(.metadata.labels | to_entries | map(select(.key | test("reboot"))) | map(.key + "=" + .value) | join(" "))"'
  } 2>&1 | tee "$out"
}

# Step 5, point 7: delete the cluster through the NVKE API and do nothing else.
delete_line() {
  local c n code
  api get "/api/clusters/$(cluster_id)" >"$LOG_DIR/.del.txt" 2>/dev/null || true
  code=$(tail -1 "$LOG_DIR/.del.txt")
  if [ "$code" = "HTTP 404" ]; then c="no cluster row"; else c=$(api_body <"$LOG_DIR/.del.txt" | jq -r '.conditions.deleting.message // "?"' 2>/dev/null || echo "?"); fi
  n=$(api get "/api/nodes?clusterID=$(cluster_id)" 2>/dev/null | api_body | jq -r '(.nodes // []) | length' 2>/dev/null || echo "?")
  printf 'deleting=[%s] node-rows=%s machines=%s podvmmachines=%s podvmcluster=%s | pods=%s claims=%s secrets=%s | pending=[%s]\n' "$c" "$n" \
    "$(k -n "$CAPI_NS" get machines.cluster.x-k8s.io -l "cluster.x-k8s.io/cluster-name=$CLUSTER_NAME" -o name 2>/dev/null | grep -c . || true)" \
    "$(k -n "$CAPI_NS" get podvmmachines -o name 2>/dev/null | grep -c . || true)" \
    "$(k -n "$CAPI_NS" get podvmclusters -o name 2>/dev/null | grep -c . || true)" \
    "$(k -n "$NS" get pods -o name 2>/dev/null | grep -c . || true)" "$(k -n "$NS" get pvc -o name 2>/dev/null | grep -c . || true)" "$(k -n "$NS" get secrets -o name 2>/dev/null | grep -c . || true)" \
    "$(temporal workflow describe --workflow-id "teardown-cluster-$(cluster_id)" --output json 2>/dev/null | jq -r '[(.pendingActivities // [])[] | "\(.activityType.name) attempt \(.attempt // 1)"] | join(", ")' 2>/dev/null || echo "?")"
}

cmd_delete() {
  local out="$LOG_DIR/delete.txt" end line fail=0 ids id d gone=0 extra=0 since
  d="$LOG_DIR/record-delete"
  mkdir -p "$d"
  {
    say "DELETE through the NVKE API, cluster $CLUSTER_NAME, ID $(cluster_id), at $(date -u +%FT%TZ). No other step."
    api get "/api/nodes?clusterID=$(cluster_id)" | api_body | jq . >"$d/api-nodes-before.json" 2>/dev/null || true
    delete_line
    since=$(date -u +%FT%TZ)
    stamp delete-post
    api delete "/api/clusters/$(cluster_id)" 2>&1 | tee "$d/delete-response.txt" | tail -1
    grep -q '^HTTP 20[0-9]$' "$d/delete-response.txt" || { echo "the API did not accept the DELETE"; exit 1; }
    end=$(( $(date +%s) + ${DELETE_LIMIT:-2400} ))
    say "one look each $POLL s (limit ${DELETE_LIMIT:-2400} s)"
    while [ "$(date +%s)" -lt "$end" ]; do
      line=$(delete_line)
      echo "$(date -u +%T) $line" | tee -a "$d/timeline.txt"
      case "$line" in *'deleting=[no cluster row]'*)
        [ "$gone" = 1 ] || { stamp delete-row-gone; gone=1; }
        # The row is gone. Give the objects up to one more minute, then stop.
        case "$line" in *'machines=0 podvmmachines=0 podvmcluster=0 | pods=0 claims=0 secrets=0 '*) stamp delete-objects-gone; break ;; esac
        extra=$((extra + 1))
        [ "$extra" -ge 6 ] && break
        ;;
      esac
      sleep "$POLL"
    done
    say "the teardown workflow of the cluster"
    temporal workflow describe --workflow-id "teardown-cluster-$(cluster_id)" 2>&1 | grep -E '^ *(Status|StartTime|CloseTime|RunTime|HistoryLength)' || true
    LOG_DIR="$d" workflow_timeline "teardown-cluster-$(cluster_id)" || true
    for id in $(jq -r '(.nodes // [])[] | .id' "$d/api-nodes-before.json" 2>/dev/null); do LOG_DIR="$d" workflow_timeline "teardown-node-$id" || true; done
    cat "$d/workflow-teardown-cluster-$(cluster_id).txt" 2>/dev/null | cut -c1-160
    temporal workflow list --query "StartTime > \"$since\"" 2>&1 | head -20 | tee "$d/temporal-workflows.txt" || true
    k -n "$PROVIDER_NS" logs deployment/podvm-controller-manager --since-time="$since" >"$d/podvm-provider.log" 2>&1 || true
    k -n nvke-controller logs deployment/nvke-controller --since-time="$since" >"$SEC/nvke-controller-delete.log" 2>&1 || true
    say "what the provider logged for the delete"
    jq -r 'select(.msg) | "\(.time[11:23]) \(.level) \(.msg) \(.PodVMMachine.name // "") \(.kind // "") \(.name // "") \(.error // "")"' "$d/podvm-provider.log" 2>/dev/null | head -40
    say "check: what is left"
    api get "/api/clusters/$(cluster_id)" | tail -1 | grep -q '^HTTP 404$' && echo "ok   no cluster row (GET gives 404)" || { echo "FAIL the cluster row exists"; fail=1; }
    [ "$(api get "/api/nodes?clusterID=$(cluster_id)" | api_body | jq -r '(.nodes // []) | length')" = 0 ] && echo "ok   no node row" || { echo "FAIL node rows exist"; fail=1; }
    temporal workflow describe --workflow-id "teardown-cluster-$(cluster_id)" 2>&1 | grep -E '^ *Status' | grep -q -i 'COMPLETED' && echo "ok   the teardown workflow of the cluster is completed" || { echo "FAIL the teardown workflow is not completed"; fail=1; }
    [ -z "$(k -n "$NS" get pods -o name)" ] && echo "ok   no pod in $NS" || { echo "FAIL pods: $(k -n "$NS" get pods -o name | tr '\n' ' ')"; fail=1; }
    [ -z "$(k -n "$NS" get pvc -o name)" ] && echo "ok   no claim in $NS" || { echo "FAIL claims: $(k -n "$NS" get pvc -o name | tr '\n' ' ')"; fail=1; }
    [ -z "$(k -n "$NS" get secrets -o name)" ] && echo "ok   no Secret copy in $NS" || { echo "FAIL Secrets: $(k -n "$NS" get secrets -o name | tr '\n' ' ')"; fail=1; }
    [ -z "$(k -n "$CAPI_NS" get podvmmachines,podvmclusters -o name 2>/dev/null)" ] && echo "ok   no PodVMMachine and no PodVMCluster" || { echo "FAIL $(k -n "$CAPI_NS" get podvmmachines,podvmclusters -o name | tr '\n' ' ')"; fail=1; }
    [ -z "$(k -n "$CAPI_NS" get clusters.cluster.x-k8s.io,machines.cluster.x-k8s.io -o name 2>/dev/null | grep -F "$CLUSTER_NAME")" ] && echo "ok   no Cluster and no Machine of the cluster" || { echo "FAIL Cluster API objects of the cluster exist"; fail=1; }
    echo "other objects with the name of the cluster in $CAPI_NS: [$(k -n "$CAPI_NS" get all,secrets,configmaps,podvmmachinetemplates -o name 2>/dev/null | grep -F "$CLUSTER_NAME" | tr '\n' ' ')]"
    ids=$(jq -r '(.nodes // [])[] | .id' "$d/api-nodes-before.json" 2>/dev/null || true)
    for id in $ids; do
      k get clusterstaticentry "host-$id" >/dev/null 2>&1 && echo "note the SPIRE entry host-$id exists" || echo "ok   no SPIRE entry host-$id"
    done
    k get namespace "$NS" >/dev/null 2>&1 && k -n "$NS" get network-attachment-definition nodenet >/dev/null 2>&1 && k -n "$NS" get service cp-api >/dev/null 2>&1 && echo "ok   the namespace $NS, the network attachment and the shared Service stay" || { echo "FAIL the namespace, the network attachment or the Service is gone"; fail=1; }
    echo "endpoints of cp-api: [$(k -n "$NS" get endpointslices -l kubernetes.io/service-name=cp-api -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{" "}{end}')]"
    say "what is left of the volumes"
    "$P/storage.sh" status
    echo "filesystem signatures on the devices: $(node sh -c 'for d in /dev/loop6[0-9] /dev/loop7[01]; do t=$(blkid -p -o value -s TYPE $d 2>/dev/null); l=$(blkid -p -o value -s LABEL $d 2>/dev/null); echo "${d#/dev/}=${t:-none}${l:+($l)}"; done' | tr '\n' ' ')"
    [ "$fail" = 0 ] && echo "RESULT delete: PASS (row gone $(between delete-post delete-row-gone) s after the DELETE, objects gone $(between delete-post delete-objects-gone) s)" || echo "RESULT delete: FAIL"
  } 2>&1 | tee "$out"
  grep -q 'RESULT delete: PASS' "$out"
}

cmd_flow() {
  local rc=0 r
  cmd_base
  cmd_probe_start run 1500 || true
  cmd_post
  cmd_wait_pods || rc=1
  if [ "$rc" = 0 ]; then cmd_wait || rc=1; fi
  if [ "$rc" = 0 ]; then cmd_wait_nodes || rc=1; fi
  if [ "$rc" = 0 ]; then write_podmap; cmd_check final || rc=1; fi
  cmd_probe_stop run || true
  times || true
  cmd_record final || true
  provider_record final || true
  cmd_evidence final || true
  if [ "$rc" = 0 ]; then cmd_endpoint final || rc=1; fi
  if [ "$rc" = 0 ]; then cmd_reach final || rc=1; fi
  if [ "$rc" = 0 ]; then cmd_etcd final || rc=1; fi
  if [ "$rc" = 0 ]; then cmd_names || rc=1; fi
  cmd_provider final || rc=1
  cmd_times || true
  if [ "$rc" = 0 ]; then echo "RESULT flow: PASS"; else echo "RESULT flow: FAIL"; fi
  return "$rc"
}

times() {
  say "times (seconds)"
  {
    echo "POST to three pods of the provider: $(between post pods-exist)"
    echo "POST to three started containers (startup probe passed): $(between post pods-started)"
    echo "POST to provisioned: $(between post provisioned)"
    echo "POST to three provisioned nodes: $(between post nodes-provisioned)"
    echo "POST to three Ready nodes in the new cluster: $(between post nodes-ready-final)"
  } | tee "$LOG_DIR/summary-times.txt"
}

# The record of block D, plus the objects and the log of the provider.
provider_record() {
  local label=${1:-final} d since
  d="$LOG_DIR/record-$label"
  mkdir -p "$d"
  since=$(cat "$LOG_DIR/post-time.txt" 2>/dev/null || date -u +%FT%TZ)
  k -n "$PROVIDER_NS" logs deployment/podvm-controller-manager --since-time="$since" >"$d/podvm-provider.log" 2>&1 || true
  k -n "$CAPI_NS" get podvmclusters,podvmmachines,podvmmachinetemplates -o wide >"$d/podvm-objects.txt" 2>&1 || true
  k -n "$CAPI_NS" get podvmclusters,podvmmachines,podvmmachinetemplates,machines.cluster.x-k8s.io,clusters.cluster.x-k8s.io -o yaml 2>/dev/null | mask >"$d/podvm-objects.yaml" || true
  k -n "$NS" get pods -o yaml >"$d/pods.yaml" 2>&1 || true
  k -n "$NS" get pods,pvc -o wide >"$d/pod-namespace.txt" 2>&1 || true
  k -n "$NS" get secrets -o custom-columns=NAME:.metadata.name,TYPE:.type,CREATED:.metadata.creationTimestamp >>"$d/pod-namespace.txt" 2>&1 || true
  k -n "$NS" get events --sort-by=.lastTimestamp >"$d/pod-namespace-events.txt" 2>&1 || true
  k get pv -l podvm.lab/use -o wide >"$d/volumes.txt" 2>&1 || true
}

step=${1:-}
shift || true
case "$step" in
  base | post | wait-pods | wait | wait-nodes | check | endpoint | patch-check | reach | probe-start | probe-stop | names | etcd | provider | times | flow | units | lost-pod | reboot | delete)
    "cmd_${step//-/_}" "$@" 2>&1 | tee -a "$LOG_DIR/run.log"
    exit "${PIPESTATUS[0]}"
    ;;
  record | evidence)
    { "cmd_$step" "$@"; provider_record "$@"; } 2>&1 | tee -a "$LOG_DIR/run.log"
    exit "${PIPESTATUS[0]}"
    ;;
  traffic | tunnels)
    node_names
    # shellcheck disable=SC1091
    . "$D/measure.sh"
    "cmd_$step" "$@" 2>&1 | tee -a "$LOG_DIR/run.log"
    exit "${PIPESTATUS[0]}"
    ;;
  poll) poll_line ;;
  podmap) write_podmap; cat "$PODMAP" ;;
  summary-times) times ;;
  *) sed -n '2,24p' "$0"; exit 1 ;;
esac
