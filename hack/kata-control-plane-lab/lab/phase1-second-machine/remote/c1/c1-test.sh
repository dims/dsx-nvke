#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Block C1, the tests of the node network: a fixed address on a second interface for a pod (Multus,
# bridge plugin on br-node, static address). Stand-in pods with the class of record take the place
# of the control plane pods. The pass rules are those of the brief (1 to 5).
# Usage: c1-test.sh [label]
set -uo pipefail
. /root/kata-cp/bin/env.sh
. /root/kata-cp/c1/env-c.sh
label=${1:-c1}
# MODE=plain (default) | mac (fx-b has a fixed hardware address in its annotation) | garp (each fixed pod
# sends gratuitous ARP for its address when it starts, as a node image or a wrapper can do) | notify (the pod
# sets arp_notify for net1 and takes the link down and up, so the guest kernel sends the gratuitous ARP) |
# runc (fx-b runs with the default runtime, to compare what the peers see at a pod create without Kata)
MODE=${MODE:-plain}
NS=c1
OUT=$W/logs/c1/$label
mkdir -p "$OUT"
exec > >(tee "$OUT/c1-test.txt") 2>&1
RC=kata-clh-runtime-rs-fix-direct
IMG=docker.io/library/python:3.13-alpine
declare -A IP=([fx-a]=172.28.1.31 [fx-b]=172.28.1.32 [fx-c]=172.28.1.33) # not the addresses of the control plane replicas (172.28.1.11 to 13, 21 to 23)
fail=0
k() { kubectl -n "$NS" "$@"; }
say() { echo "== $*"; }
now() { date +%s.%N; }
bad() { echo "FAIL: $*"; fail=1; }

# mkpod <name> <node> <fixed address or ""> <runtime class or "">
mkpod() {
  local name=$1 node=$2 ip=$3 rc=$4
  cat <<YAML | k apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $name
  namespace: $NS
  labels: {app: $name}
$([ -n "$ip" ] && printf "  annotations:\n    k8s.v1.cni.cncf.io/networks: '[{\"name\": \"nodenet\", \"ips\": [\"%s/16\"]%s}]'\n" "$ip" "$([ "$MODE" = mac ] && printf ', \"mac\": \"02:00:ac:1c:01:%02x\"' "${ip##*.}")")
spec:
$([ -n "$rc" ] && echo "  runtimeClassName: $rc")
  nodeSelector: {kubernetes.io/hostname: $node}
  terminationGracePeriodSeconds: 2
  containers:
    - name: c
      image: $IMG
      imagePullPolicy: Never
      command: ["sh", "-c", "$([ "$MODE" = garp ] && [ -n "$ip" ] && echo "python3 /scripts/garp.py net1 $ip; ")$([ "$MODE" = notify ] && [ -n "$ip" ] && echo "sysctl -w net.ipv4.conf.net1.arp_notify=1; ip link set net1 down; ip link set net1 up; ")exec python3 -m http.server 8080 --directory /scripts"]
      securityContext: {privileged: $([ "$MODE" = notify ] && [ -n "$ip" ] && echo true || echo false), capabilities: {add: [NET_RAW]}}
      resources:
        limits: {cpu: "1", memory: 512Mi}
      volumeMounts: [{name: scripts, mountPath: /scripts}]
  volumes:
    - name: scripts
      configMap: {name: c1-scripts}
YAML
}
x() { local p=$1; shift; k exec "$p" -- "$@" 2>&1; }
mac() { x "$1" cat /sys/class/net/net1/address; }
http() { x "$1" python3 -c "
import urllib.request,sys,time
t=time.time()
try:
    r=urllib.request.urlopen('http://$2:8080/probe.py',timeout=3); print('http %d in %.3f s' % (r.status, time.time()-t))
except Exception as e:
    print('no answer: %s' % e)"; }

say "C1 test $label at $(utc). Class $RC, image $IMG, mode $MODE"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
NS=$NS envsubst '$NS' <"$W/c1/nad.yaml.tmpl" | kubectl apply -f -
k create configmap c1-scripts --from-file="$W/c1/ping.py" --from-file="$W/c1/udp-send.py" --from-file="$W/c1/udp-listen-dst.py" --from-file="$W/c1/probe.py" --from-file="$W/c1/garp.py" --dry-run=client -o yaml | k apply -f - >/dev/null
k delete pod --all --wait=true >/dev/null 2>&1
t0=$(now)
mkpod fx-a kata-bb-worker "${IP[fx-a]}" "$RC"
RCB=$RC
[ "$MODE" != runc ] || RCB=""
mkpod fx-b kata-bb-worker2 "${IP[fx-b]}" "$RCB"
mkpod fx-c kata-bb-worker "${IP[fx-c]}" "$RC"
mkpod rc-w kata-bb-worker "" ""
mkpod rc-w2 kata-bb-worker2 "" ""
k wait --for=condition=Ready pod fx-a fx-b fx-c rc-w rc-w2 --timeout=180s >/dev/null || bad "a pod is not ready"
echo "five pods ready $(awk -v a="$t0" -v b="$(now)" 'BEGIN {printf "%.1f", b-a}') s after the create"
k get pods -o wide | awk '{print $1, $2, $3, $6, $7}'

say "rule 1: the Kata guest has the interface and the address"
for p in fx-a fx-b fx-c; do
  a=$(x "$p" sh -c "ip -o -4 addr show | awk '{print \$2 \"=\" \$4}' | tr '\n' ' '")
  echo "$p: kernel $(x "$p" uname -r), addresses $a, net1 MAC $(mac "$p"), routes: $(x "$p" sh -c "ip route | tr '\n' ';'")"
  case "$a" in *"net1=${IP[$p]}/16"*) ;; *) bad "$p has not ${IP[$p]} on net1" ;; esac
  echo "   network status from Multus: $(k get pod "$p" -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}' | tr -d '\n ' | cut -c1-330)"
done
echo "the bridge br-node of each node: $(for n in $NODES; do printf '%s: %s ports; ' "${n#kata-bb-}" "$(docker exec "$n" sh -c 'ls /sys/class/net/br-node/brif | wc -l')"; done)"

say "rule 3: two pods with a fixed address reach each other (ICMP with ping.py, HTTP on port 8080)"
for pair in "fx-a fx-b different-nodes" "fx-b fx-a different-nodes" "fx-a fx-c same-node" "fx-c fx-a same-node" "fx-c fx-b different-nodes"; do
  set -- $pair
  r1=$(x "$1" python3 /scripts/ping.py "${IP[$2]}" 3 | tail -1)
  r2=$(http "$1" "${IP[$2]}")
  echo "$1 (${IP[$1]}) to $2 (${IP[$2]}), $3: ping $r1; $r2"
  case "$r1" in "3 of 3"*) ;; *) bad "ping $1 to $2" ;; esac
  case "$r2" in "http 200"*) ;; *) bad "http $1 to $2" ;; esac
done

say "rule 4: a runc pod of the host cluster reaches the fixed address (no second interface in these pods)"
for pair in "rc-w fx-a same-node" "rc-w fx-b other-node" "rc-w2 fx-a other-node" "rc-w2 fx-b same-node"; do
  set -- $pair
  r1=$(x "$1" python3 /scripts/ping.py "${IP[$2]}" 3 | tail -1)
  r2=$(http "$1" "${IP[$2]}")
  echo "$1 ($(k get pod "$1" -o jsonpath='{.status.podIP}') on $(k get pod "$1" -o jsonpath='{.spec.nodeName}')) to $2 (${IP[$2]}), $3: ping $r1; $r2"
  case "$r1" in "3 of 3"*) ;; *) bad "ping $1 to $2" ;; esac
  case "$r2" in "http 200"*) ;; *) bad "http $1 to $2" ;; esac
done
for n in $NODES; do
  echo "node ${n#kata-bb-} itself to fx-a and fx-b: $(docker exec "$n" curl -s -m 3 -o /dev/null -w 'http %{http_code} from %{local_ip}' "http://${IP[fx-a]}:8080/probe.py"); $(docker exec "$n" curl -s -m 3 -o /dev/null -w 'http %{http_code} from %{local_ip}' "http://${IP[fx-b]}:8080/probe.py")"
done
echo "the machine itself to fx-a: $(curl -s -m 3 -o /dev/null -w 'http %{http_code} from %{local_ip}' "http://${IP[fx-a]}:8080/probe.py")"

say "rule 5: a UDP datagram between two fixed addresses (port 6081): source and destination at arrival"
for pair in "fx-a fx-b" "fx-b fx-a" "fx-a fx-c"; do
  set -- $pair
  ( x "$2" python3 /scripts/udp-listen-dst.py 6081 5 >"$OUT/.udp-$1-$2.txt" ) &
  sleep 1.5
  x "$1" python3 /scripts/udp-send.py "${IP[$2]}" 6081 "from-$1-to-$2" >/dev/null
  wait
  r=$(grep '^datagram 1' "$OUT/.udp-$1-$2.txt")
  echo "$1 to $2: ${r:-no datagram}"
  case "$r" in *"source ${IP[$1]}:"*"destination ${IP[$2]}:6081"*) ;; *) bad "UDP $1 to $2: not the fixed addresses" ;; esac
done
echo "a datagram from the runc pod rc-w2 (other node) to fx-a, for the comparison:"
( x fx-a python3 /scripts/udp-listen-dst.py 6081 5 >"$OUT/.udp-rc-w2-fx-a.txt" ) &
sleep 1.5
x rc-w2 python3 /scripts/udp-send.py "${IP[fx-a]}" 6081 "from-rc-w2" >/dev/null
wait
echo "   $(grep '^datagram 1' "$OUT/.udp-rc-w2-fx-a.txt" || echo 'no datagram') (the source is the address of the host node on the node network)"

# replace <new node> <label>: delete fx-b, make it again on a node, and follow two probes.
replace() {
  local node=$1 what=$2 t_del t_gone t_new t_ready m0 m1 f g
  m0=$(mac fx-b)
  # ARP frames for the address on the bridge of the machine: a broadcast from a node reaches this bridge.
  ( timeout 72 tcpdump -i "$NODEBR_HOST" -e -nn -l -tt "arp and arp host ${IP[fx-b]}" >"$OUT/arp-$what.txt" 2>/dev/null ) &
  ( x fx-a python3 /scripts/probe.py "${IP[fx-b]}" 8080 70 >"$OUT/probe-$what-from-fx-a.txt" ) &
  ( x rc-w python3 /scripts/probe.py "${IP[fx-b]}" 8080 70 >"$OUT/probe-$what-from-rc-w.txt" ) &
  sleep 3
  t_del=$(now)
  k delete pod fx-b --wait=true >/dev/null
  t_gone=$(now)
  mkpod fx-b "$node" "${IP[fx-b]}" "$RCB"
  t_new=$(now)
  k wait --for=condition=Ready pod fx-b --timeout=120s >/dev/null || bad "fx-b not ready after the replace ($what)"
  t_ready=$(now)
  wait
  m1=$(mac fx-b)
  echo "replace of fx-b, $what: now on $(k get pod fx-b -o jsonpath='{.spec.nodeName}'), address $(x fx-b sh -c "ip -o -4 addr show net1 | awk '{print \$4}'"), pod IP $(k get pod fx-b -o jsonpath='{.status.podIP}'), net1 MAC before $m0, after $m1"
  case "$(x fx-b sh -c "ip -o -4 addr show net1 | awk '{print \$4}'")" in "${IP[fx-b]}/16") ;; *) bad "fx-b has not its address after the replace ($what)" ;; esac
  echo "   times after the delete (s): old pod gone $(awk -v a="$t_del" -v b="$t_gone" 'BEGIN {printf "%.1f", b-a}'), new pod made $(awk -v a="$t_del" -v b="$t_new" 'BEGIN {printf "%.1f", b-a}'), new pod Ready $(awk -v a="$t_del" -v b="$t_ready" 'BEGIN {printf "%.1f", b-a}')"
  for f in fx-a rc-w; do
    g="$OUT/probe-$what-from-$f.txt"
    echo "   probe from $f (one TCP connect each 0.1 s): $(awk -v d="$t_del" -v n="$t_new" -v r="$t_ready" '$2=="fail" && !ff {ff=$1} $2=="ok" && ff && !back {back=$1} /end:/ {e=$3 " " $4 " " $5 " " $6} END {if (!ff) print "no failed connect; " e; else if (!back) print "first failed connect " sprintf("%.1f", ff-d) " s after the delete, NO return; " e; else printf "first failed connect %.1f s after the delete, reaches the address again %.1f s after the delete (%.1f s after the new pod was made, %.1f s after it was Ready); %s\n", ff-d, back-d, back-n, back-r, e}' "$g")"
    grep -q ' ok' "$g" || bad "probe from $f has no good connect ($what)"
  done
  echo "   neighbor entry for ${IP[fx-b]} in fx-a: $(x fx-a sh -c "ip neigh show ${IP[fx-b]}")"
  echo "   ARP frames with the address ${IP[fx-b]} as sender, seen on the bridge of the machine (seconds after the delete, source hardware address, text):"
  awk -v d="$t_del" -v ip="${IP[fx-b]}" '{t=$1-d; txt=""; for (i=10;i<=NF;i++) txt=txt " " $i} index(txt, "tell " ip) || index(txt, "Reply " ip) {printf "      %.1f s %s%s\n", t, $2, txt}' "$OUT/arp-$what.txt" | sed 's/, length [0-9]*$//' | awk '{k=$3 $5 $6 $7 $8 $9; n[k]++; if (n[k]<=2) print} END {}' | head -8
  [ -s "$OUT/arp-$what.txt" ] || echo "      none"
}
say "rule 2: the address after a replace, and the time until a peer reaches it again"
replace kata-bb-worker2 same-node
replace kata-bb-worker3 other-node
if [ "${SHORT:-0}" != 1 ]; then
  replace kata-bb-worker same-node-as-the-peer
  replace kata-bb-worker2 back-to-the-first-node
fi

say "end state"
k get pods -o wide | awk '{print $1, $2, $3, $6, $7}'
echo "br_netfilter loaded: $(lsmod | grep -c '^br_netfilter'). Lab rule in the firewall: $(nft list chain inet cm_filter forward | grep -c -E 'br-kata') (0 = none)"
[ "$fail" = 0 ] && echo "RESULT $label: PASS" || echo "RESULT $label: FAIL"
