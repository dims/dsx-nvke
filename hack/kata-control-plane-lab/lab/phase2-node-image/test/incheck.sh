#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Runs inside a node pod (kubectl exec -i ... bash -s). It prints one line
# "CHECK <rule> ok|FAIL <facts>" for each pass rule of T1 and T2, and the facts for T3.
# Variables: MACHINE, MODE (first or repeat), EXPECT_STATUS (done or error), EXPECTED (the
# lines "sha256 mode owner path" of the test data), ADDRESS, MAC, WANT_COUNT, WANT_WRITTEN.
set -u
ok() { echo "CHECK $1 ok   $2"; }
bad() { echo "CHECK $1 FAIL $2"; }
rule() { if [ "$2" = 0 ]; then ok "$1" "$3"; else bad "$1" "$3"; fi; }
echo "--- machine $MACHINE, mode $MODE, at $(date -u +%FT%T.%3NZ), uptime $(cut -d' ' -f1 /proc/uptime) s, kernel $(uname -r)"

# 1. systemd is up, with no failed unit.
state=$(timeout 240 systemctl is-system-running --wait 2>&1)
failed=$(systemctl --failed --no-legend --plain | awk '{print $1}' | tr '\n' ' ')
want_state=running want_failed=""
if [ "$EXPECT_STATUS" = error ]; then want_state=degraded want_failed="podvm-bootstrap-final.service "; fi
[ "$state" = "$want_state" ] && [ "$failed" = "$want_failed" ]
rule systemd $? "state $state, failed units [$failed] (rule: $want_state, [$want_failed])"
for u in podvm-bootstrap podvm-bootstrap-final spire-agent nvke-agent ovsdb-server ovs-vswitchd containerd kubelet nke-container-network nke-container-cni-images etcd-data-dir; do
  printf '      %-28s active=%-12s sub=%-13s result=%-10s restarts=%s\n' "$u" "$(systemctl is-active "$u" 2>&1 | head -1)" \
    "$(systemctl show -p SubState --value "$u")" "$(systemctl show -p Result --value "$u")" "$(systemctl show -p NRestarts --value "$u")"
done

# 2. The hostname is the Machine name.
[ "$(hostname)" = "$MACHINE" ] && [ "$(cat /etc/hostname)" = "$MACHINE" ]
rule hostname $? "hostname $(hostname), /etc/hostname $(cat /etc/hostname), env file: $(tr '\n' ' ' </run/podvm/env)"

# 3. The two volumes, and the node state on the /var volume.
v=$(findmnt -n -o SOURCE,FSTYPE /var | tr -s ' ')
e=$(findmnt -n -o SOURCE,FSTYPE /var/lib/etcd | tr -s ' ')
[ "$v" = "/dev/podvm-var ext4" ] && [ "$e" = "/dev/podvm-etcd ext4" ] && [ "$(stat -c %a /var/lib/etcd)" = 700 ] && [ -e /var/.podvm-var-copied ]
rule volumes $? "/var: $v, label $(blkid -o value -s LABEL /dev/podvm-var), $(df -h --output=size,used /var | tail -1 | tr -s ' '); /var/lib/etcd: $e, label $(blkid -o value -s LABEL /dev/podvm-etcd), mode $(stat -c %a /var/lib/etcd), content [$(ls -A /var/lib/etcd | tr '\n' ' ')]"
st=0
for p in /etc/kubernetes /kind /etc/spire-agent; do
  s=$(findmnt -n -o SOURCE "$p")
  case "$s" in /dev/podvm-var\[/lib/podvm/state/*) ;; *) st=1 ;; esac
  echo "      $p: $s"
done
[ "$(readlink -f /etc/default/nke-agent)" = /var/lib/podvm/agent/nvke-agent ] || st=1
rule state-on-var $st "/etc/default/nke-agent is $(readlink -f /etc/default/nke-agent)"
[ "$(cat /etc/machine-id)" = "$(tr -d - </var/lib/podvm/state/machine-uuid)" ]
rule machine-id $? "machine ID $(cat /etc/machine-id), UUID on the /var volume $(tr -d - </var/lib/podvm/state/machine-uuid)"
echo "MARKER machine-id $(cat /etc/machine-id)"

# 4. The files of the bootstrap data, with mode and owner.
n=0 badn=0
while read -r sha mode owner path; do
  [ -n "$sha" ] || continue
  n=$((n + 1))
  got="$(sha256sum <"$path" 2>/dev/null | cut -d' ' -f1) $(stat -L -c '%a %U:%G' "$path" 2>/dev/null)"
  if [ "$got" = "$sha $mode $owner" ]; then
    echo "      file ok  $mode $owner $path ($(findmnt -n -o SOURCE -T "$(readlink -f "$path")" | cut -c1-40))"
  else
    echo "      file BAD $path: is [$got], rule [$sha $mode $owner]"
    badn=$((badn + 1))
  fi
done <<<"$EXPECTED"
[ "$n" -ge 3 ] && [ "$badn" = 0 ]
rule files $? "$n files of the bootstrap data, $badn wrong"

# 5. The commands ran one time, for this Machine.
cnt=$(grep -c . /var/lib/nico-containers/helper-test/runcmd.count 2>/dev/null || true)
[ "${cnt:-0}" = "$WANT_COUNT" ]
rule command-count $? "the counter file of the test command has ${cnt:-0} lines (rule: $WANT_COUNT)"
want_marker="done $MACHINE"
[ "$EXPECT_STATUS" = error ] && want_marker="failed $MACHINE"
[ "$(cat /var/lib/podvm/bootstrap/machine)" = "$MACHINE" ] && [ "$(cat /var/lib/podvm/bootstrap/commands)" = "$want_marker" ]
rule marker $? "machine marker [$(cat /var/lib/podvm/bootstrap/machine)], commands marker [$(cat /var/lib/podvm/bootstrap/commands)]"
echo "MARKER machine $(stat -c 'inode %i changed %Y' /var/lib/podvm/bootstrap/machine) content $(cat /var/lib/podvm/bootstrap/machine)"
echo "MARKER commands $(stat -c 'inode %i changed %Y' /var/lib/podvm/bootstrap/commands) content $(cat /var/lib/podvm/bootstrap/commands)"
echo "MARKER output-log $(sha256sum </var/lib/podvm/bootstrap/output.log | cut -c1-16) lines $(grep -c . /var/lib/podvm/bootstrap/output.log)"
echo "MARKER counter $(stat -c 'inode %i changed %Y' /var/lib/nico-containers/helper-test/runcmd.count 2>/dev/null) lines ${cnt:-0}"
j=$(journalctl -b --no-pager -o short-precise -u podvm-bootstrap -u podvm-bootstrap-final | grep -E 'RESULT|podvm-bootstrap:')
echo "$j" | sed 's/^/      journal: /'
if [ "$MODE" = first ]; then
  echo "$j" | grep -q "RESULT first files=$n written=$n" && echo "$j" | grep -q -E 'RESULT first( commands=|: command)'
  rule run-first $? "the journal of this boot has a first run of the files and of the commands"
else
  echo "$j" | grep -q "RESULT repeat files=$n written=$WANT_WRITTEN (only absent files)" && echo "$j" | grep -q 'RESULT repeat: .*none runs'
  rule run-repeat $? "the journal of this boot has a repeat run: $WANT_WRITTEN absent files written, no command"
fi
sed 's/^/      output.log: /' /var/lib/podvm/bootstrap/output.log | cut -c1-200

# 6. The cloud-init answer that the agent reads.
ci=$(cloud-init status --long 2>&1)
[ "$(echo "$ci" | awk '$1=="status:" {print $2; exit}')" = "$EXPECT_STATUS" ]
rule cloud-init $? "cloud-init status --long: $(echo "$ci" | tr '\n' ';' | cut -c1-160) file [$(cat /var/lib/nico-containers/cloud-init/status 2>&1)]"

# 7. The agent runs with the settings of the bootstrap data.
args=""
for i in 1 2 3 4 5 6; do
  args=$(ps -o args= -C nvke-agent | head -1)
  [ -n "$args" ] && break
  sleep 2
done
case "$args" in *"--secure-server-port 15005"*) a=0 ;; *) a=1 ;; esac
case "$args" in *bundle-server-url*) a=1 ;; esac
rule agent-settings $a "agent process [$args], settings file [$(tr '\n' ' ' </etc/default/nke-agent)]"

# 8. What the entry point and the image changes give.
k=0
[ -c /dev/kmsg ] || k=1
[ "$(cat /proc/sys/net/ipv4/ip_forward)" = 1 ] || k=1
[ -s "/boot/config-$(uname -r)" ] || k=1
[ "$(cat /proc/sys/fs/inotify/max_user_instances)" -ge 8192 ] || k=1
[ "$(findmnt -n -o FSTYPE /run)" = tmpfs ] && [ "$(findmnt -n -o FSTYPE /tmp)" = tmpfs ] || k=1
# PID 1 has its own cgroup namespace (the entry point), and systemd moved itself to init.scope in it.
grep -q -x 1 /sys/fs/cgroup/init.scope/cgroup.procs && [ -d /sys/fs/cgroup/system.slice ] && [ "$(readlink /proc/1/ns/cgroup)" != "$(readlink /proc/self/ns/cgroup)" ] || k=1
rule kernel-settings $k "/dev/kmsg $(stat -c '%t:%T' /dev/kmsg 2>&1), ip_forward $(cat /proc/sys/net/ipv4/ip_forward), /boot [$(ls /boot | tr '\n' ' ')], inotify instances $(cat /proc/sys/fs/inotify/max_user_instances) watches $(cat /proc/sys/fs/inotify/max_user_watches), /run $(findmnt -n -o FSTYPE /run), /tmp $(findmnt -n -o FSTYPE /tmp), PID 1 in init.scope of its own cgroup namespace: $(grep -c -x 1 /sys/fs/cgroup/init.scope/cgroup.procs)"
o=0
[ "$(systemctl is-active ovs-vswitchd)" = active ] || o=1
ovs-vsctl --timeout=5 show >/dev/null 2>&1 || o=1
rule open-vswitch $o "ovs-vswitchd $(systemctl is-active ovs-vswitchd), /sys/module/openvswitch $([ -e /sys/module/openvswitch ] && echo present || echo absent), built in symbol $(grep -c ' ovs_dp_process_packet$' /proc/kallsyms), ExecStartPre [$(systemctl show ovs-vswitchd -p ExecStartPre --value | grep -o 'path=[^ ]*' | tr '\n' ' ')], agent datapath setting [$(systemctl show nvke-agent -p Environment --value | grep -o 'NKE_OVS_DATAPATH_TYPE=[a-z]*')]"
im=$(crictl images 2>/dev/null | awk '$1 ~ /pause|k8s-dns-node-cache/ {print $1 ":" $2}' | sort | tr '\n' ' ')
case "$im" in *"registry.k8s.io/dns/k8s-dns-node-cache:1.26.8"*"registry.k8s.io/pause:3.10.2"*) i=0 ;; *) i=1 ;; esac
ctr -n k8s.io images ls -q 2>/dev/null | grep -q 'k8s-dns-node-cache@sha256:bc6e64e2c85956af2fcc0aa720086410d41b4f31f378c9a92646fecc85cd4739' || i=1
rule images $i "images in containerd: $im, and the DNS cache image by its digest name"
ad=$(ip -o -4 addr show dev net1 2>/dev/null | awk '{print $4}')
hw=$(cat /sys/class/net/net1/address 2>/dev/null)
[ "$ad" = "$ADDRESS" ] && [ "$hw" = "$MAC" ]
rule address $? "net1 has $ad with the hardware address $hw (rule: $ADDRESS, $MAC)"

# T3: the Secret volume and the times of this start.
echo "T3 secret volume: $(findmnt -n -o SOURCE,FSTYPE,OPTIONS -T /etc/podvm/bootstrap | tr -s ' ' | cut -c1-160)"
ls -la --time-style=full-iso /etc/podvm/bootstrap/ | sed 's/^/T3   /'
echo "T3 data file: $(stat -L -c '%s bytes, changed %y, mode %a' /etc/podvm/bootstrap/value), sha256 $(sha256sum </etc/podvm/bootstrap/value | cut -c1-16)"
echo "T3 kernel start: $(date -u -d "@$(( $(date +%s) - $(cut -d. -f1 /proc/uptime) ))" +%T) (now minus uptime)"
echo "T3 PID 1 start:  $(date -u -d "$(ps -o lstart= -p 1)" +%T) UTC"
for u in podvm-bootstrap podvm-bootstrap-final; do
  echo "T3 unit $u: start $(date -u -d "$(systemctl show -p ExecMainStartTimestamp --value "$u")" +%T.%3N), end $(date -u -d "$(systemctl show -p ExecMainExitTimestamp --value "$u")" +%T.%3N), result $(systemctl show -p Result --value "$u")"
done
echo "T3 first line of the SPIRE agent in the journal: $(journalctl -b --no-pager -o short-precise -u spire-agent | grep -v '^-- ' | head -1 | cut -c1-110)"
echo "T3 first line of the agent in the journal:       $(journalctl -b --no-pager -o short-precise -u nvke-agent | grep -v '^-- ' | head -1 | cut -c1-110)"
echo "--- end"
