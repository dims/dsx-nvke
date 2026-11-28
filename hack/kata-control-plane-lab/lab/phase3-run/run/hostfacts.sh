# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# hostfacts <run> <label>: read-only facts of the machine that a privileged worker container could change.
run=$1; label=$2; D=/root/kata-cp/logs/p3/$run
{
echo "== facts of the machine ($label) at $(date -u +%FT%TZ). Read only."
echo "worker containers: [$(docker ps --filter label=nvidia.com/nico-containers.managed=true --format '{{.Names}}' | tr '\n' ' ')]"
echo "kernel settings that are not per network namespace: $(for s in vm.overcommit_memory vm.panic_on_oom kernel.panic kernel.panic_on_oops kernel.keys.root_maxkeys kernel.keys.root_maxbytes fs.inotify.max_user_watches fs.inotify.max_user_instances vm.max_map_count kernel.pid_max; do printf '%s=%s ' "$s" "$(sysctl -n $s 2>/dev/null)"; done)"
echo "kernel settings of the root network namespace: $(for s in net.ipv4.ip_forward net.ipv4.conf.all.rp_filter net.ipv4.conf.all.route_localnet net.bridge.bridge-nf-call-iptables net.netfilter.nf_conntrack_max net.netfilter.nf_conntrack_tcp_be_liberal net.ipv4.vs.conntrack; do printf '%s=%s ' "$s" "$(sysctl -n $s 2>/dev/null || echo absent)"; done)"
echo "nft tables of the root network namespace: $(nft list tables 2>/dev/null | awk '{print $2 ":" $3}' | sort | tr '\n' ' ')"
echo "nft chains of the root network namespace: $(nft -a list chains 2>/dev/null | grep -c 'chain ') chains; names sha256 $(nft list chains 2>/dev/null | grep 'chain ' | awk '{print $2}' | grep -v -E '^(KUBE-SVC|KUBE-SEP|KUBE-EXT|KUBE-FW|KUBE-SVL|cali-|cni-)' | sort | sha256sum | cut -c1-16) (without the per Service and per pod chains of the own cluster of the machine)"
echo "iptables filter chains with DOCKER in the name: $(iptables -S 2>/dev/null | grep -c -E '^-N DOCKER') ; rules that name a 172.28.2 or 172.29.2 address: $(iptables-save 2>/dev/null | grep -c -E '172\.2[89]\.2\.')"
echo "interfaces of the root network namespace with geneve or ovs in the type or name: [$(ip -d -o link show 2>/dev/null | grep -E 'geneve|openvswitch|genev_sys|ovs-system|br-int' | awk -F': ' '{print $2}' | tr '\n' ' ')]"
echo "swap: $(swapon --show --noheadings | wc -l) devices; memory available $(awk '/MemAvailable/ {printf "%.0f GB", $2/1048576}' /proc/meminfo); load $(cut -d' ' -f1-3 /proc/loadavg)"
echo "disk: $(df -h /root | tail -1 | awk '{print $3 " in use, " $4 " free"}'); Docker: $(docker system df --format '{{.Type}}={{.Size}}' | tr '\n' ' ')"
} 2>&1 | tee "$D/hostfacts-$label.txt" | cut -c1-600
