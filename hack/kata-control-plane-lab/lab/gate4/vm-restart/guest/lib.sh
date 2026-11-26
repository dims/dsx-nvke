# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Functions of the restart test in the Lima VM. Source this file after env.sh, with LOG_DIR set.
# snapshot, node_checks and after_start_record come from lab/gate4/cold-start.sh. Changes:
# the addresses are 172.31.x, the Docker host is the VM, and the VM has no SPIRE server.
NODE_IP=172.31.0.2
IP_API=172.31.255.210
declare -A IPS=([a]=172.31.255.211 [b]=172.31.255.212 [c]=172.31.255.213)
KCN=(kubectl --kubeconfig /etc/kubernetes/admin.conf) # kubectl in the kind node

node() { docker exec "$KIND_NODE" "$@"; }
k() { node "${KCN[@]}" "$@"; }
say() { echo "== $*"; }

# One line for each node pod: name, UID, pod IP, restart count, container ID.
pod_lines() {
  k -n "$NS" get pods -o jsonpath='{range .items[*]}{.metadata.name}{" uid="}{.metadata.uid}{" ip="}{.status.podIP}{" restarts="}{.status.containerStatuses[0].restartCount}{" container="}{.status.containerStatuses[0].containerID}{"\n"}{end}'
}

# The state of the VM, of the kind node and of the pods, for the record.
snapshot() {
  local label=$1
  {
    say "snapshot $label at $(date -u +%FT%TZ), $(cut -d' ' -f1 /proc/uptime) s after kernel boot, boot ID of the VM $(cat /proc/sys/kernel/random/boot_id)"
    docker inspect -f 'container: status {{.State.Status}}, started {{.State.StartedAt}}, finished {{.State.FinishedAt}}, exit code {{.State.ExitCode}}, restarts {{.RestartCount}}, policy {{.HostConfig.RestartPolicy.Name}}:{{.HostConfig.RestartPolicy.MaximumRetryCount}}, address {{range .NetworkSettings.Networks}}{{.IPAddress}} mac {{.MacAddress}}{{end}}' "$KIND_NODE"
    free -m | sed -n 1,2p
    k get nodes -o wide || true
    k get pods -A -o wide || true
    k -n "$NS" get statefulset,svc,pvc,endpointslices -o wide || true
    pod_lines || true
    say "sandboxes and containers of the node pods in containerd (crictl)"
    node crictl pods --namespace "$NS" || true
    node crictl ps -a --label io.kubernetes.pod.namespace="$NS" || true
    say "Kata processes in the kind node (PID, start time, name)"
    node sh -c "ps -eo pid=,lstart=,args= | grep -E 'cloud-hypervisor|virtiofsd|containerd-shim-kata' | grep -v grep | awk '{n=split(\$7,a,\"/\"); print \$1, \$3, \$4, \$5, a[n]}'" || true
    say "loop devices of the VM (fixed devices of the lab, then the devices that the kubelet holds)"
    losetup -l -O NAME,BACK-FILE,DIO | grep -E 'NAME|/var/lib/vm-restart/disks/' || true
    losetup -a | grep volumeDevices | sort || true
    say "loop device nodes in the kind node"
    node sh -c 'ls /dev/loop[0-9]* | wc -l' || true
    say "modules"
    lsmod | grep -E '^(kvm|vhost)' || true
  } >"$LOG_DIR/snapshot-$label.txt" 2>&1
}

# Checks of the kind node itself after a start. Each line starts with OK or FAIL.
node_checks() {
  local x mac ok handlers
  {
    say "node checks at $(date -u +%FT%TZ)"
    x=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$KIND_NODE")
    if [ "$x" = "$NODE_IP" ]; then echo "OK address of the kind node: $x"; else echo "FAIL address of the kind node: $x, not $NODE_IP"; fi
    x=$(node sh -c 'ls /dev/kvm /dev/vhost-vsock /dev/vhost-net /dev/loop2[0-5] 2>/dev/null | wc -l')
    if [ "$x" = 9 ]; then echo "OK device nodes in the kind node: /dev/kvm, /dev/vhost-vsock, /dev/vhost-net, /dev/loop20 to /dev/loop25"; else echo "FAIL device nodes in the kind node: $x of 9"; fi
    x=$(node sh -c 'ls /dev/loop[0-9]* | wc -l')
    if [ "$x" -ge 128 ]; then echo "OK loop device nodes: $x"; else echo "FAIL loop device nodes: $x"; fi
    echo "   g4-loop-nodes.service: $(node systemctl is-active g4-loop-nodes.service || true), $(node sh -c 'journalctl --no-pager -b -u g4-loop-nodes.service | grep "loop device nodes" | tail -1' || true)"
    x=$(node sh -c 'systemctl is-active dbus.socket dbus.service | tr "\n" " "; [ -S /run/dbus/system_bus_socket ] && echo socket-present' || true)
    if [ "$x" = "active active socket-present" ]; then echo "OK D-Bus: $x"; else echo "FAIL D-Bus: $x"; fi
    handlers=$(k get node -o jsonpath='{.items[0].status.runtimeHandlers[*].name}')
    echo "$handlers" | tr ' ' '\n' | sort >"$LOG_DIR/handlers-after.txt"
    if diff "$LOG_DIR/handlers-before.txt" "$LOG_DIR/handlers-after.txt" >/dev/null; then
      echo "OK runtime handlers, the same $(grep -c . "$LOG_DIR/handlers-after.txt") as before: $handlers"
    else
      echo "FAIL runtime handlers changed: $(diff "$LOG_DIR/handlers-before.txt" "$LOG_DIR/handlers-after.txt" | tr '\n' ' ')"
    fi
    node sh -c 'grep -n imports /etc/containerd/config.toml' | sed 's/^/   /'
    # MetalLB. The status objects name the node that answers. Then one ping from the VM to each
    # address. A ping gets no echo answer from a Service address, but the VM must first ask
    # for the hardware address (ARP). The neighbor entry shows if MetalLB answered. No TCP.
    k -n metallb-system get servicel2statuses 2>&1 | sed 's/^/   /'
    mac=$(node cat /sys/class/net/eth0/address)
    for x in "$IP_API" "${IPS[a]}" "${IPS[b]}" "${IPS[c]}"; do
      ping -c 1 -W 1 "$x" >/dev/null 2>&1 || true
    done
    sleep 2
    for x in "$IP_API" "${IPS[a]}" "${IPS[b]}" "${IPS[c]}"; do
      ok=$(ip neigh show "$x" | head -1)
      case "$ok" in
        *"lladdr $mac "*REACHABLE* | *"lladdr $mac "*DELAY* | *"lladdr $mac "*STALE*) echo "OK MetalLB answers for $x: $ok" ;;
        *) echo "FAIL MetalLB for $x: neighbor entry '$ok', the kind node has $mac" ;;
      esac
    done
    x=$(docker port "$KIND_NODE")
    if echo "$x" | grep -v -- '-> 127\.0\.0\.1:' | grep -q .; then echo "FAIL published ports: $x"; else echo "OK published ports, 127.0.0.1 only: $x"; fi
    x=$(k get pods -A --no-headers 2>/dev/null | awk '$4 != "Completed" {split($3,a,"/"); if ($4 != "Running" || a[1] != a[2]) print $1 "/" $2 " " $3 " " $4}')
    if [ -z "$x" ]; then echo "OK all $(k get pods -A --no-headers | grep -v -c Completed) pods of the host cluster run and are ready (the 2 completed install pods of kata-deploy are not counted)"; else echo "FAIL pods of the host cluster that do not run: $x"; fi
    x=$(losetup -l -n -O NAME,BACK-FILE,DIO | awk 'index($2, "/var/lib/vm-restart/disks/") == 1' | sort -k2)
    if [ "$x" = "$(cat "$LOG_DIR/loop-map-before.txt")" ]; then echo "OK the six files have the same loop devices as before, with direct I/O"; else echo "FAIL loop devices changed: $x"; fi
    x=$(lsmod | awk '$1=="kvm_intel" || $1=="vhost_vsock" || $1=="vhost_net" {print $1}' | sort | tr '\n' ' ')
    if [ "$x" = "kvm_intel vhost_net vhost_vsock " ]; then echo "OK modules: $x"; else echo "FAIL modules: $x"; fi
  } 2>&1 | tee "$LOG_DIR/node-checks-after.txt"
}

# What the kubelet and containerd did with the dead Kata sandboxes and the old loop devices.
after_start_record() {
  {
    say "sandboxes and containers of the node pods after the start (crictl, all states)"
    node crictl pods --namespace "$NS" || true
    node crictl ps -a --label io.kubernetes.pod.namespace="$NS" || true
    say "the old container of each pod, from the pod status"
    k -n "$NS" get pods -o jsonpath='{range .items[*]}{.metadata.name}{" lastState="}{.status.containerStatuses[0].lastState}{"\n"}{end}' || true
    say "events of the node pods"
    k -n "$NS" get events --sort-by=.lastTimestamp 2>&1 | tail -40 || true
    say "containerd journal of this boot of the kind node: number of lines, then lines about the old sandboxes and containers"
    node sh -c 'journalctl --no-pager -b -u containerd | grep -c .' || true
    node sh -c 'journalctl --no-pager -b -u containerd | grep -i -E "fail|error|warn|recover|cleanup|dead|load (sandbox|container)|StopPodSandbox|RemovePodSandbox" | cut -c1-420 | head -80' || true
    say "kubelet journal of this boot of the kind node: lines about sandboxes, block volumes and loop devices"
    node sh -c 'journalctl --no-pager -b -u kubelet | grep -i -E "losetup|loop|MapVolume|MapBlockVolume|volumeDevices|SandboxChanged|sandbox.*(not ready|changed|dead)|orphan|killing" | cut -c1-420 | head -80' || true
    say "loop devices of the kubelet after the start"
    losetup -a | grep volumeDevices | sort || true
  } >"$LOG_DIR/after-start-record.txt" 2>&1
}
