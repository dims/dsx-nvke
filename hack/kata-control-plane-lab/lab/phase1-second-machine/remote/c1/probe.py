# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# One TCP connect to an address each 0.1 s, for a number of seconds. One line for each change of the
# result, with the time, so that a gap has its start and its end. Usage: probe.py <address> <port> <seconds>
import socket, sys, time
addr, port, seconds = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
end = time.time() + seconds
last = None
n = ok = 0
while time.time() < end:
    t = time.time()
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(0.3)
    try:
        s.connect((addr, port))
        res = "ok"
    except Exception as e:
        res = "fail"
    finally:
        s.close()
    n += 1
    ok += res == "ok"
    if res != last:
        print("%.2f %s" % (t, res), flush=True)
        last = res
    time.sleep(max(0.0, 0.1 - (time.time() - t)))
print("%.2f end: %d tries, %d ok" % (time.time(), n, ok), flush=True)
