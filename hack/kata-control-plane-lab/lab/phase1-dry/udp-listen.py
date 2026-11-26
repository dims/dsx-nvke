# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Print the source address of each UDP datagram that arrives on a port. Usage: udp-listen.py <port> <seconds>
import socket, sys, time

port, seconds = int(sys.argv[1]), float(sys.argv[2])
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(("0.0.0.0", port))
end = time.time() + seconds
seen = 0
while time.time() < end:
    sock.settimeout(max(0.05, end - time.time()))
    try:
        data, addr = sock.recvfrom(2048)
    except socket.timeout:
        break
    seen += 1
    print("datagram %d: source %s:%d, payload %r" % (seen, addr[0], addr[1], data[:40]), flush=True)
print("datagrams: %d" % seen)
