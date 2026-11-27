#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

"""The health gate of one test, node by node, from two files of the machine:
  the gate lines of the agents (agent-gate-watch.sh) and the pod and EndpointSlice watch (ep-watch.sh).
For each time an agent closed its gate: the time (UTC), the seconds from the closed gate to the pod
not ready (the event of the pod watch, and the time that the kubelet wrote), to the pod out of the
ready endpoints of the shared Service, to the end of the withdrawal, to the open gate, and to the pod
in the ready endpoints again. Also the number of sockets that the agent closed.
Usage: gate-report.py <agent gate file> <ep watch file>"""
import json
import re
import sys
from datetime import datetime, timezone


def ts(s):
    m = re.match(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(\.\d+)?(Z|[+-]\d\d:\d\d)?$", s or "")
    if not m:
        return None
    t = datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc).timestamp()
    if m.group(2):
        t += float(m.group(2))
    z = m.group(3)
    if z and z != "Z":
        hh, mm = z[1:].split(":")
        t -= (1 if z[0] == "+" else -1) * (int(hh) * 3600 + int(mm) * 60)
    return t


def hms(t):
    return datetime.fromtimestamp(t, timezone.utc).strftime("%H:%M:%S.%f")[:-3]


def rel(t, t0):
    return "-" if t is None else "%+.1f s" % (t - t0)


agent = {}
try:
    for line in open(sys.argv[1]):
        pod, _, rest = line.rstrip("\n").partition(" ")
        try:
            o = json.loads(rest)
        except ValueError:
            continue
        t = ts(o.get("time", ""))
        if t is not None:
            agent.setdefault(pod, []).append((t, o.get("msg", ""), o))
except OSError:
    pass
pods, eps = [], []
try:
    for line in open(sys.argv[2]):
        f = line.split()
        if len(f) < 3:
            continue
        t = ts(f[0])
        if t is None:
            continue
        if f[1] == "pod":
            d = dict(x.split("=", 1) for x in f[3:] if "=" in x)
            pods.append((t, f[2], d.get("ready"), ts(d.get("since"))))
        elif f[1] == "eps":
            m = re.search(r" ready=\[([^\]]*)\]", line)
            eps.append((t, set(x.split("@")[0] for x in m.group(1).split(",") if x) if m else set()))
except OSError:
    pass

CLOSED = "closed the control plane endpoint gate"
rows = []
for pod, evs in agent.items():
    evs.sort(key=lambda e: e[0])
    cur = None
    for t, msg, o in evs:
        if msg == CLOSED:
            cur = {"pod": pod, "tc": t, "sockets": 0, "none": False, "quiet": None, "tw": None, "to": None, "fail": None, "owner": o.get("owner", "")}
            rows.append(cur)
            continue
        if cur is None:
            continue
        if msg == "closing stale remote VIP socket":
            cur["sockets"] += 1
        elif msg.startswith("no stale remote VIP sockets"):
            cur["none"] = True
        elif msg == "no new remote VIP sockets observed":
            cur["quiet"] = t
        elif msg.startswith("withdrew this node from the control plane endpoint"):
            cur["tw"] = t
        elif msg == "opened the control plane endpoint gate":
            cur["to"] = t
        text = msg + " " + str(o.get("error", "")) + " " + str(o.get("err", ""))
        if "quiet window failed" in text and cur["fail"] is None:
            cur["fail"] = (t, text[:400])
rows.sort(key=lambda r: r["tc"])
print("gate closed (UTC) | node | pod not ready, event | pod not ready, kubelet time | out of the ready endpoints | sockets closed | withdrawal done | gate opened | in the ready endpoints again")
for r in rows:
    tc, pod = r["tc"], r["pod"]
    ev = next(((t, since) for t, p, ready, since in pods if p == pod and ready == "False" and t >= tc - 0.5), None)
    out = next((t for t, ready in eps if t >= tc - 0.5 and pod not in ready), None)
    back = None
    if r["to"] is not None:
        back = next((t for t, ready in eps if t >= r["to"] - 0.5 and pod in ready), None)
    print(" | ".join([
        hms(tc), pod,
        rel(ev[0] if ev else None, tc),
        rel(ev[1] if ev and ev[1] else None, tc),
        rel(out, tc),
        str(r["sockets"]) + (" (the agent found none)" if r["none"] and r["sockets"] == 0 else ""),
        rel(r["tw"], tc) if r["fail"] is None else "FAILED " + rel(r["fail"][0], tc),
        rel(r["to"], tc),
        rel(back, tc),
    ]))
    if r["fail"] is not None:
        print("    " + r["fail"][1])
if not rows:
    print("no agent closed a gate in this test")
