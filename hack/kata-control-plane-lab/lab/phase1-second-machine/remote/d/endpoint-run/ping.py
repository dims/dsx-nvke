# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# ICMP echo with a raw socket, because the test image has no ping. Usage: ping.py <address> [count]
import os, socket, struct, sys, time


def checksum(data):
    total = 0
    for i in range(0, len(data), 2):
        total += (data[i] << 8) + (data[i + 1] if i + 1 < len(data) else 0)
    total = (total >> 16) + (total & 0xFFFF)
    total += total >> 16
    return ~total & 0xFFFF


dst = sys.argv[1]
count = int(sys.argv[2]) if len(sys.argv) > 2 else 3
sock = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_ICMP)
ident = os.getpid() & 0xFFFF
payload = b"p1dry" * 4
answers = []
for seq in range(count):
    header = struct.pack("!BBHHH", 8, 0, 0, ident, seq)
    packet = struct.pack("!BBHHH", 8, 0, checksum(header + payload), ident, seq) + payload
    start = time.time()
    sock.sendto(packet, (dst, 0))
    while time.time() - start < 1.0:
        sock.settimeout(max(0.01, 1.0 - (time.time() - start)))
        try:
            data, _ = sock.recvfrom(2048)
        except socket.timeout:
            break
        ihl = (data[0] & 0x0F) * 4
        kind, _, _, rid, rseq = struct.unpack("!BBHHH", data[ihl:ihl + 8])
        if kind == 0 and rid == ident and rseq == seq:
            answers.append((time.time() - start) * 1000)
            break
rtt = (", rtt ms " + " ".join("%.2f" % a for a in answers)) if answers else ""
print("%d of %d answers%s" % (len(answers), count, rtt))
sys.exit(0 if answers else 1)
