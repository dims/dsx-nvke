# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Send gratuitous ARP for an address of this host: three ARP requests with the address as sender and as
# target, to the broadcast hardware address. A neighbor that has an entry for the address takes the new
# hardware address at once. Usage: garp.py <interface> <address> [count]
import socket, struct, sys, time
ifname, addr = sys.argv[1], sys.argv[2]
count = int(sys.argv[3]) if len(sys.argv) > 3 else 3
s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0806))
s.bind((ifname, 0x0806))
mac = s.getsockname()[4]
ip = socket.inet_aton(addr)
frame = b"\xff" * 6 + mac + struct.pack("!H", 0x0806) + struct.pack("!HHBBH", 1, 0x0800, 6, 4, 1) + mac + ip + b"\x00" * 6 + ip
for i in range(count):
    s.send(frame)
    time.sleep(0.3)
print("gratuitous ARP for %s on %s from %s: %d frames" % (addr, ifname, ":".join("%02x" % b for b in mac), count), flush=True)
