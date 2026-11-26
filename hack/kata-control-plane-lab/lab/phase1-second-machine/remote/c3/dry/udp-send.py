# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Send one UDP datagram. Usage: udp-send.py <destination> <port> <text> [source address]
import socket, sys

dst, port, text = sys.argv[1], int(sys.argv[2]), sys.argv[3]
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
if len(sys.argv) > 4:
    sock.bind((sys.argv[4], 0))
sock.sendto(text.encode(), (dst, port))
print("sent %r to %s:%d from %s" % (text, dst, port, sock.getsockname()[0] if len(sys.argv) > 4 else "the default source"))
