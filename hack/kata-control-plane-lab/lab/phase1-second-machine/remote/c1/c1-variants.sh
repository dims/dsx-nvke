#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Block C1: the replace of a pod with a fixed address, in five forms, one after the other. Each form
# has two replaces (same host node, other host node), with an ARP capture on the bridge of the machine.
#   plain   a new hardware address at each replace, no announcement from the guest
#   runc    the same with the default runtime for the replaced pod (what the CNI plugin announces with no Kata)
#   mac     a fixed hardware address in the Multus annotation
#   garp    the pod sends gratuitous ARP at its start (garp.py, the same as "arping -U")
#   notify  the pod sets arp_notify for net1 and takes the link down and up
. /root/kata-cp/bin/env.sh
cd "$W"
for m in plain runc mac garp notify; do
  SHORT=1 MODE=$m c1/c1-test.sh "c1-v-$m" >"logs/c1/c1-v-$m.out" 2>&1
  echo "$(utc) $m: $(tail -1 "logs/c1/c1-v-$m.out")"
done
echo "C1 VARIANTS DONE"
