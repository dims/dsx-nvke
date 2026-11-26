# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Print the source address AND the destination address of each UDP datagram that arrives on a port.
# It is udp-listen.py of the dry run with IP_PKTINFO, which gives the destination address of a datagram.
# Usage: udp-listen-dst.py <port> <seconds>
import socket, struct, sys, time
port, seconds = int(sys.argv[1]), float(sys.argv[2])
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.setsockopt(socket.IPPROTO_IP, socket.IP_PKTINFO, 1)
sock.bind(("0.0.0.0", port))
end = time.time() + seconds
seen = 0
while time.time() < end:
    sock.settimeout(max(0.05, end - time.time()))
    try:
        data, anc, _, addr = sock.recvmsg(2048, 256)
    except socket.timeout:
        break
    dst = "?"
    for level, kind, value in anc:
        if level == socket.IPPROTO_IP and kind == socket.IP_PKTINFO:
            dst = socket.inet_ntoa(value[8:12])
    seen += 1
    print("datagram %d: source %s:%d, destination %s:%d, payload %r" % (seen, addr[0], addr[1], dst, port, data[:40]), flush=True)
print("datagrams: %d" % seen)
