#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Measurements of the phase 1 dry run (open point 2 of the design). run.sh loads this file, so it
# uses the functions and the variables of run.sh. Nothing here is a pass rule.

# The test pods: one on each node, with one Service for each.
traffic_pods() {
  local r
  cki -n default create configmap p1-probe --from-file=ping.py=/dev/stdin --dry-run=client -o yaml <"$HERE/ping.py" | cki apply -f - >/dev/null
  for r in "${REPLICAS[@]}"; do
    render traffic-pod.yaml.tmpl "$r" >"$LOG_DIR/traffic-pod-$r.yaml"
    cki apply -f - <"$LOG_DIR/traffic-pod-$r.yaml" >/dev/null
  done
  for r in "${REPLICAS[@]}"; do
    ck -n default wait --for=condition=Ready "pod/p1-t-$r" --timeout=180s || echo "the test pod on node $r is not Ready"
  done
}
tpod_ip() { ck -n default get pod "p1-t-$1" -o jsonpath='{.status.podIP}'; }
tsvc_ip() { ck -n default get service "p1-t-$1" -o jsonpath='{.spec.clusterIP}'; }
texec() { local r=$1; shift; ck -n default exec "p1-t-$r" -- "$@"; }

# Pod traffic between the nodes: ICMP echo and TCP to the pod address, and TCP to a ClusterIP
# Service whose only endpoint is the pod on the other node. Also the API Service and a name lookup.
cmd_traffic() {
  local label=${1:-traffic} out s d
  local -A PIP SIP
  out="$LOG_DIR/traffic-$label.txt"
  {
    say "pod traffic between nodes ($label) at $(date -u +%FT%TZ)"
    traffic_pods
    ck -n default get pods,services -o wide
    for s in "${REPLICAS[@]}"; do PIP[$s]=$(tpod_ip "$s"); SIP[$s]=$(tsvc_ip "$s"); done
    say "matrix: source node -> destination node (same letter = the pod calls its own address or Service)"
    for s in "${REPLICAS[@]}"; do
      for d in "${REPLICAS[@]}"; do
        printf '%s -> %s: ping %s [%s] | pod tcp %s:8080 [%s] | service %s:80 [%s]\n' "$s" "$d" "${PIP[$d]}" \
          "$(texec "$s" python3 /probe/ping.py "${PIP[$d]}" 3 2>&1 | tail -1)" "${PIP[$d]}" \
          "$(texec "$s" curl -s -m 3 -o /dev/null -w 'http %{http_code} in %{time_total} s' "http://${PIP[$d]}:8080/ping.py" 2>&1 | tail -1)" "${SIP[$d]}" \
          "$(texec "$s" curl -s -m 3 -o /dev/null -w 'http %{http_code} in %{time_total} s' "http://${SIP[$d]}:80/ping.py" 2>&1 | tail -1)"
      done
    done
    say "from each test pod: the API Service $API_SVC_IP:443 and a name lookup through the cluster DNS"
    for s in "${REPLICAS[@]}"; do
      printf 'node %s: api [%s] | dns [%s]\n' "$s" \
        "$(texec "$s" curl -sk -m 5 -o /dev/null -w 'http %{http_code} remote %{remote_ip}' "https://$API_SVC_IP:443/version" 2>&1 | tail -1)" \
        "$(texec "$s" timeout 12 getent hosts kubernetes.default.svc.cluster.local 2>&1 | tail -1 || true)"
    done
    say "where the DNS pods are"
    ck -n kube-system get pods -l dns-role=cluster-dns -o wide
    ck -n kube-system get endpointslices -l kubernetes.io/service-name=kube-dns -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{" ready="}{.conditions.ready}{" node="}{.nodeName}{" "}{.targetRef.name}{"\n"}{end}'
  } 2>&1 | tee "$out"
}

# The nft probe: a table that records the source and destination address of each UDP packet to the
# Geneve port that arrives at the node (prerouting hook), and that leaves a local socket (output hook).
probe_on() {
  podi "$1" nft -f - <<'NFT'
table inet p1probe {
  set geneve_in {
    type ipv4_addr . ipv4_addr
    flags dynamic
    size 256
  }
  set geneve_out {
    type ipv4_addr . ipv4_addr
    flags dynamic
    size 256
  }
  chain pre {
    type filter hook prerouting priority -350; policy accept;
    udp dport 6081 counter update @geneve_in { ip saddr . ip daddr }
  }
  chain out {
    type filter hook output priority -350; policy accept;
    udp dport 6081 counter update @geneve_out { ip saddr . ip daddr }
  }
}
NFT
}
probe_read() { pod "$1" nft list table inet p1probe 2>&1 | grep -E 'counter|elements|set |[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ \.' || true; }
probe_off() { pod "$1" nft delete table inet p1probe 2>/dev/null || true; }

# The tunnel endpoints of OVN, the tunnel ports of Open vSwitch, and the source address of a packet
# to the Geneve port when it arrives at the other node.
cmd_tunnels() {
  local label=${1:-tunnels} out r s d sb
  out="$LOG_DIR/tunnels-$label.txt"
  {
    say "tunnel endpoints ($label) at $(date -u +%FT%TZ)"
    say "1. node annotations of OVN"
    ck get nodes -o json | jq -r '.items[] | .metadata.name as $n | .metadata.annotations | to_entries[] | select(.key | test("k8s.ovn.org/(node-encap-ips|node-chassis-id|host-cidrs|node-primary-ifaddr|node-subnets|zone-name|node-transit-switch-port-ifaddr|l3-gateway-config|node-id)")) | "\($n) \(.key) = \(.value)"'
    for r in "${REPLICAS[@]}"; do
      say "2. node $r (${NAMES[$r]}, pod IP $(pod_ip "$r"), node address ${IPS[$r]}): Open vSwitch"
      pod "$r" sh -c 'echo "external_ids: $(ovs-vsctl --timeout=5 get Open_vSwitch . external_ids)"
        echo "--- tunnel interfaces"; ovs-vsctl --timeout=5 --columns=name,type,options,ofport,error find interface type=geneve
        echo "--- ovs/route/show"; ovs-appctl --timeout=5 ovs/route/show
        echo "--- tnl/ports/show"; ovs-appctl --timeout=5 tnl/ports/show -v
        echo "--- tnl/neigh/show"; ovs-appctl --timeout=5 tnl/neigh/show
        echo "--- datapath ports"; ovs-appctl --timeout=5 dpctl/show | grep -E "port [0-9]+"
        echo "--- sockets on the Geneve port"; ss -lunH | grep -c ":6081 " || true' 2>&1 || true
      say "2. node $r: chassis and encap rows of the local southbound database"
      sb=$(pod "$r" sh -c 'crictl ps --name "^sb-ovsdb$" -q | head -1')
      pod "$r" crictl exec "$sb" ovn-sbctl --no-leader-only --columns=name,hostname,encaps,other_config list chassis 2>&1 | grep -v '^$' || true
      pod "$r" crictl exec "$sb" ovn-sbctl --no-leader-only --columns=chassis_name,ip,type,options list encap 2>&1 | grep -v '^$' || true
    done

    say "3. a UDP datagram to the Geneve port of the other node: which source address arrives"
    say "   (the node has no socket on the port, because the userspace datapath opens none, so a test listener can take it)"
    for pair in "a b" "b a" "a c"; do
      # shellcheck disable=SC2086 # two words
      set -- $pair
      s=$1 d=$2
      podi "$d" sh -c 'cat >/run/p1-udp-listen.py' <"$HERE/udp-listen.py"
      podi "$s" sh -c 'cat >/run/p1-udp-send.py' <"$HERE/udp-send.py"
      ( pod "$d" python3 /run/p1-udp-listen.py 6081 8 >"$LOG_DIR/.udp-$s-$d.txt" 2>&1 ) &
      sleep 2
      echo "node $s (pod IP $(pod_ip "$s"), node address ${IPS[$s]}) -> ${IPS[$d]}:6081 (node $d, pod IP $(pod_ip "$d"))"
      pod "$s" python3 /run/p1-udp-send.py "${IPS[$d]}" 6081 "default-source-from-$s" 2>&1 || true
      pod "$s" python3 /run/p1-udp-send.py "${IPS[$d]}" 6081 "node-address-source-from-$s" "${IPS[$s]}" 2>&1 || true
      pod "$s" python3 /run/p1-udp-send.py "$(pod_ip "$d")" 6081 "to-the-pod-ip-from-$s" 2>&1 || true
      wait
      sed 's/^/   at the listener: /' "$LOG_DIR/.udp-$s-$d.txt"
    done

    say "4. real tunnel packets: an nft probe on each node counts UDP packets to port 6081, then each test pod calls the pods on the other nodes"
    for r in "${REPLICAS[@]}"; do probe_on "$r" || echo "no probe on node $r"; done
    for s in "${REPLICAS[@]}"; do
      for d in "${REPLICAS[@]}"; do
        [ "$s" = "$d" ] || texec "$s" curl -s -m 2 -o /dev/null "http://$(tpod_ip "$d"):8080/ping.py" 2>/dev/null || true
      done
    done
    for r in "${REPLICAS[@]}"; do
      echo "--- node $r: probe (pre = packets that arrive, out = packets from a local socket)"
      probe_read "$r"
      probe_off "$r"
    done

    say "5. what Open vSwitch does with a packet from the test pod on node a to the test pod on node b (ofproto/trace)"
    trace a b
  } 2>&1 | tee "$out"
}

# trace <s> <d>: ofproto/trace on node s for an ICMP echo from the test pod on s to the test pod on d.
trace() {
  local s=$1 d=$2 sip dip gw gwmac
  sip=$(tpod_ip "$s")
  dip=$(tpod_ip "$d")
  gw="${sip%.*}.1"
  # OVN-Kubernetes gives a router port the MAC 0a:58 followed by the four bytes of its IPv4 address.
  gwmac=$(printf '0a:58:%02x:%02x:%02x:%02x' ${gw//./ })
  pod "$s" sh -c "port=\$(ovs-vsctl --timeout=5 --bare --columns=name find interface external_ids:iface-id=default_p1-t-$s)
    mac=\$(ovs-vsctl --timeout=5 get interface \"\$port\" external_ids:attached_mac | tr -d '\"')
    echo \"port \$port mac \$mac, $sip -> $dip, router MAC $gwmac\"
    ovs-appctl --timeout=10 ofproto/trace br-int \"in_port=\$port,icmp,dl_src=\$mac,dl_dst=$gwmac,nw_src=$sip,nw_dst=$dip,nw_ttl=64,icmp_type=8,icmp_code=0\"" >"$LOG_DIR/.trace-$s-$d.txt" 2>&1 || true
  head -1 "$LOG_DIR/.trace-$s-$d.txt"
  echo "trace lines: $(wc -l <"$LOG_DIR/.trace-$s-$d.txt") (full text in $LOG_DIR/.trace-$s-$d.txt)"
  grep -n -i -E 'tunnel|tnl_|geneve|native|drop|Final flow|Datapath actions|output:|ovn-' "$LOG_DIR/.trace-$s-$d.txt" | tail -25 || true
}

# Delete the pod of node r. The StatefulSet makes a new pod with a new pod IP, the same LoadBalancer
# address and the same volumes. Follow the return of the node, of its etcd member and of OVN.
cmd_replace() {
  local r=$1 n=${NAMES[$1]} out o fail=0 before_ip
  out="$LOG_DIR/replace-$r.txt"
  # A node that is not the replaced one, for etcdctl and for the view of the other zones.
  o=$FIRST
  [ "$r" != "$FIRST" ] || o=b
  {
    say "replace of the pod of node $r ($n) at $(date -u +%FT%TZ). Observer node: $o"
    before_ip=$(pod_ip "$r")
    etcdctl "$o" member list -w simple | sort >"$LOG_DIR/.members-before"
    cat "$LOG_DIR/.members-before"
    replace_view "$r" "$o" | tee "$LOG_DIR/.view-before"
    stamp "replace-$r-start"
    k -n "$NS" delete pod "$(pn "$r")" --wait=true
    stamp "replace-$r-old-pod-gone"
    k -n "$NS" wait --for=create "pod/$(pn "$r")" --timeout=60s
    k -n "$NS" wait --for=jsonpath='{.status.phase}'=Running "pod/$(pn "$r")" --timeout=300s
    wait_node 300 "${KC[*]} -n $NS exec $(pn "$r") -- systemctl is-active containerd >/dev/null 2>&1" || { echo "FAIL containerd"; fail=1; }
    stamp "replace-$r-node-up"
    say "pod IP: $before_ip before, $(pod_ip "$r") now"
    k -n "$NS" logs "$(pn "$r")" 2>/dev/null | grep -a 'WRAP:' | tr -d '\r' | grep -E 'node address|repair|P1:|etcd patch' || true
    if k -n "$NS" wait --for=condition=Ready "pod/$(pn "$r")" --timeout=300s; then stamp "replace-$r-readyz"; else echo "FAIL /readyz of node $r"; fail=1; fi
    if wait_node 300 "[ \"\$(${KC[*]} -n $NS exec $(pn "$o") -- sh -c '$ETCDCTL endpoint health --cluster 2>&1 | grep -c \"is healthy\"')\" = 3 ]"; then
      stamp "replace-$r-etcd-healthy"
    else
      echo "FAIL etcd: not three healthy endpoints"; fail=1
    fi
    # The Node object keeps its old Ready state until the new kubelet reports. Wait for the new OVN container first.
    wait_node 300 "${KC[*]} -n $NS exec $(pn "$r") -- sh -c 'test \$(crictl ps --state running --name ovnkube-controller -q | wc -l) -ge 1' >/dev/null 2>&1" || { echo "FAIL the OVN container of node $r did not start"; fail=1; }
    stamp "replace-$r-ovn-container"
    # The OVN pod of a node that is not the first node is never Ready in this design (its readiness check needs
    # the cluster DNS, which is on another node), so the test does not wait for it. A new test pod on the node
    # shows that the kubelet and the CNI of the node work again.
    ck wait --for=condition=Ready "node/$n" --timeout=300s || { echo "FAIL the Node of $r is not Ready"; fail=1; }
    ck -n default delete pod "p1-t-$r" --ignore-not-found --wait=true >/dev/null 2>&1 || true
    traffic_pods
    if ck -n default get pod "p1-t-$r" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q True; then
      stamp "replace-$r-test-pod-ready"
    else
      echo "FAIL a new pod on node $r is not Ready"; fail=1
    fi
    say "times after the delete (s): old pod gone $(between "replace-$r-start" "replace-$r-old-pod-gone"), node up $(between "replace-$r-start" "replace-$r-node-up"), /readyz $(between "replace-$r-start" "replace-$r-readyz"), three healthy etcd endpoints $(between "replace-$r-start" "replace-$r-etcd-healthy"), OVN container runs $(between "replace-$r-start" "replace-$r-ovn-container"), a new pod on the node is Ready $(between "replace-$r-start" "replace-$r-test-pod-ready")"
    say "what the controller sees from the agent of node $r after the replace"
    client "$r" -steps status 2>&1 | grep GetKubeadmStatus || true
    say "etcd members after"
    etcdctl "$o" member list -w simple | sort >"$LOG_DIR/.members-after"
    if diff "$LOG_DIR/.members-before" "$LOG_DIR/.members-after"; then echo "etcd member list: no difference"; else echo "FAIL etcd member list changed"; fail=1; fi
    say "view after"
    replace_view "$r" "$o" | tee "$LOG_DIR/.view-after"
    say "difference of the view (before, after)"
    diff "$LOG_DIR/.view-before" "$LOG_DIR/.view-after" || true
    ck get nodes -o wide
    ck get pods -A -o wide --field-selector "spec.nodeName=$n"
    cmd_units "$r" after-replace || true
    say "the new test pod on node $r: the API Service and a name lookup"
    echo "api [$(texec "$r" curl -sk -m 5 -o /dev/null -w 'http %{http_code} remote %{remote_ip}' "https://$API_SVC_IP:443/version" 2>&1 | tail -1)] dns [$(texec "$r" timeout 12 getent hosts kubernetes.default.svc.cluster.local 2>&1 | tail -1 || true)]"
    [ "$fail" = 0 ] && echo "RESULT replace-$r: PASS" || echo "RESULT replace-$r: FAIL"
  } 2>&1 | tee "$out"
  grep -q "RESULT replace-$r: PASS" "$out"
}

# replace_view <r> <o>: what identifies node r for OVN, on node r itself and in the database of node o.
replace_view() {
  local r=$1 o=$2 n=${NAMES[$1]} sb
  ck get node "$n" -o json | jq -r '.metadata.annotations | to_entries[] | select(.key | test("k8s.ovn.org/(node-encap-ips|node-chassis-id|host-cidrs|node-primary-ifaddr)")) | "annotation \(.key) = \(.value)"'
  pod "$r" sh -c 'echo "node itself: system-id $(ovs-vsctl --timeout=5 get Open_vSwitch . external_ids:system-id) encap-ip $(ovs-vsctl --timeout=5 get Open_vSwitch . external_ids:ovn-encap-ip)"' 2>&1 || true
  sb=$(pod "$o" sh -c 'crictl ps --name "^sb-ovsdb$" -q | head -1')
  echo "southbound database of node $o, chassis with the hostname $n:"
  pod "$o" crictl exec "$sb" ovn-sbctl --no-leader-only --bare --columns=name,hostname find chassis "hostname=$n" 2>&1 | grep -v '^$' | tr '\n' ' ' || true
  echo
  echo "southbound database of node $o, encap rows:"
  pod "$o" crictl exec "$sb" ovn-sbctl --no-leader-only --columns=chassis_name,ip list encap 2>&1 | grep -v '^$' | paste - - | sort || true
  echo "tunnel ports of node $o:"
  pod "$o" sh -c 'ovs-vsctl --timeout=5 --columns=name,options find interface type=geneve' 2>&1 | grep -v '^$' | paste - - | sort || true
}
