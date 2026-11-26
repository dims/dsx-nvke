#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

"""Gate 2, part 2: one table from the analysis.json files of the targets, and the ratios.

Usage: summary.py <log folder of a target> ...
Each folder has the analysis.json that analyze.py writes. The first two folders are the Kata
control plane and the runc control plane, and the script prints the ratio of the first to the second.
"""
import json
import os
import sys


def ms(x):
    return 'n/a' if x is None else f'{x * 1000:.2f}'


def rows(folder):
    name = os.path.basename(folder.rstrip('/')).replace('etcd-', '')
    for res in json.load(open(os.path.join(folder, 'analysis.json'))):
        for pod, r in res['pods'].items():
            if 'error' in r:
                continue
            yield name, res['window'], pod, r, res['requests']


def main():
    table = {}
    print('| Control plane | Level | etcd member | WAL syncs/s | mean | p50 | p90 | p99 | p99.9 | above 8 ms | above 16 ms | commit p50 | commit p99 | apiserver cores | etcd cores | pod cgroup cores | db MiB | writes/s |')
    print('|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|')
    for folder in sys.argv[1:]:
        for name, window, pod, r, req in rows(folder):
            w, c = r['wal_fsync'], r['backend_commit']
            writes = sum(v for k, v in req.items() if k.split()[0] in ('POST', 'PUT', 'PATCH', 'DELETE'))
            leader = ' (leader)' if r['is_leader'] else ''
            print(f"| {name} | {window} | {pod}{leader} | {w['rate']:.1f} | {ms(w['mean'])} | {ms(w['p50'])} | {ms(w['p90'])} | {ms(w['p99'])} | {ms(w['p99.9'])} | {w['above_8ms']:.2%} | {w['above_16ms']:.3%} | {ms(c['p50'])} | {ms(c['p99'])} | {r['apiserver_cpu_cores']:.2f} | {r['etcd_cpu_cores']:.2f} | {r['pod_cgroup_cpu_cores']:.2f} | {r['db_size_mib']:.0f} | {writes:.0f} |")
            table[(name, window)] = r
    names = [os.path.basename(f.rstrip('/')).replace('etcd-', '') for f in sys.argv[1:3]]
    if len(names) == 2:
        a, b = names
        print(f'\nRatio of {a} to {b}:')
        for window in ('idle', 'w355', 'w756'):
            if (a, window) not in table or (b, window) not in table:
                continue
            x, y = table[(a, window)], table[(b, window)]
            parts = []
            for key in ('mean', 'p50', 'p90', 'p99', 'p99.9'):
                if x['wal_fsync'][key] and y['wal_fsync'][key]:
                    parts.append(f"{key} {x['wal_fsync'][key] / y['wal_fsync'][key]:.2f}")
            commit = []
            for key in ('mean', 'p50', 'p99'):
                if x['backend_commit'][key] and y['backend_commit'][key]:
                    commit.append(f"{key} {x['backend_commit'][key] / y['backend_commit'][key]:.2f}")
            cpu = f"apiserver CPU {x['apiserver_cpu_cores'] / y['apiserver_cpu_cores']:.2f}, etcd CPU {x['etcd_cpu_cores'] / y['etcd_cpu_cores']:.2f}"
            diff = (x['wal_fsync']['mean'] - y['wal_fsync']['mean']) * 1000
            print(f"  {window}: WAL fsync {', '.join(parts)} (mean difference {diff:+.2f} ms). Backend commit {', '.join(commit)}. {cpu}")


if __name__ == '__main__':
    main()
