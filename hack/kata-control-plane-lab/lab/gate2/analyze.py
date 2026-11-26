#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

"""Gate 2, part 2: compute the results of one test from the sample files.

Usage: analyze.py <log folder of a target> [window label ...]

The folder has marks.txt (time marks of load.sh) and samples/<pod>.<n>.txt (sampler.sh).
A window "w355" is the time from the mark "w355-start" to the mark "w355-end". The script takes
the first and the last sample in the window and computes each number from the difference.
A percentile comes from the histogram buckets, with a straight line in the bucket (the method of
Prometheus). The buckets double (1, 2, 4, 8, 16 ms), so the script also prints the bucket shares.
"""
import glob
import json
import math
import os
import re
import sys
from collections import defaultdict

LINE = re.compile(r'^([a-zA-Z_:][a-zA-Z0-9_:]*)(\{(.*)\})?\s+(\S+)$')
LABEL = re.compile(r'([a-zA-Z_][a-zA-Z0-9_]*)="((?:[^"\\]|\\.)*)"')


def parse_metrics(lines):
    out = {}
    for line in lines:
        m = LINE.match(line)
        if not m:
            continue
        labels = tuple(sorted(LABEL.findall(m.group(3) or '')))
        try:
            out[(m.group(1), labels)] = float(m.group(4))
        except ValueError:
            pass
    return out


def parse_sample(path):
    sections = defaultdict(list)
    times = []
    head = {}
    section = None
    for line in open(path, errors='replace'):
        line = line.rstrip('\n')
        if line.startswith('### '):
            parts = line.split()
            tag = parts[1]
            if tag == 'time':
                times.append(float(parts[2]))
            elif tag in ('loadavg', 'nodeload', 'podcgroup', 'sample'):
                head[tag] = parts[2:]
                section = tag
            else:
                section = tag
            continue
        if section:
            sections[section].append(line)
    if len(times) < 3 or 'end' not in sections and 'podcgroup' not in head:
        return None
    s = {'t_etcd': times[0], 't_api': times[1], 't': times[0]}
    s['etcd'] = parse_metrics(sections['etcd'])
    s['api'] = parse_metrics(sections['apiserver'])
    s['cgroup'] = {}
    for line in sections['cgroup']:
        p = line.split()
        if len(p) >= 7:
            s['cgroup'][p[0]] = {'usage_usec': int(p[2]), 'throttled_usec': int(p[4]), 'memory_current': int(p[6])}
    s['meminfo'] = {}
    for line in sections['meminfo']:
        p = line.replace(':', '').split()
        s['meminfo'][p[0]] = int(p[1]) * 1024
    s['disk'] = {}
    for line in sections['diskstats']:
        p = line.split()
        if len(p) >= 20:
            s['disk'][p[2]] = {'writes': int(p[7]), 'write_ms': int(p[10]), 'flushes': int(p[18]), 'flush_ms': int(p[19])}
    s['pod'] = {}
    for line in sections['podcgroup']:
        p = line.split()
        if p[0] in ('memory.current', 'memory.peak', 'memory.max'):
            s['pod'][p[0]] = p[1]
        else:
            s['pod'][p[0]] = dict(zip(p[1::2], p[2::2]))
    s['loadavg'] = head.get('loadavg', [])
    s['nodeload'] = head.get('nodeload', [])
    return s


def histogram(sample, name):
    """Return the sorted list of (upper bound, cumulative count), and the sum."""
    b = []
    for (metric, labels), v in sample.items():
        if metric == name + '_bucket':
            le = dict(labels)['le']
            b.append((math.inf if le == '+Inf' else float(le), v))
    return sorted(b), sample.get((name + '_sum', ()), 0.0)


def hist_delta(a, b, name):
    ha, sa = histogram(a, name)
    hb, sb = histogram(b, name)
    da = dict(ha)
    return [(le, c - da.get(le, 0)) for le, c in hb], sb - sa


def quantile(q, buckets):
    total = buckets[-1][1] if buckets else 0
    if total <= 0:
        return None
    rank = q * total
    prev_le, prev_c = 0.0, 0.0
    for le, c in buckets:
        if c >= rank:
            if le == math.inf:
                return prev_le
            if c == prev_c:
                return le
            return prev_le + (le - prev_le) * (rank - prev_c) / (c - prev_c)
        prev_le, prev_c = le, c
    return prev_le


def share_above(buckets, bound):
    total = buckets[-1][1]
    for le, c in buckets:
        if abs(le - bound) < 1e-9:
            return 1 - c / total if total else 0.0
    return None


def ms(x):
    return 'n/a' if x is None else f'{x * 1000:.2f}'


def hist_report(a, b, name, dt):
    buckets, total_sum = hist_delta(a, b, name)
    n = buckets[-1][1] if buckets else 0
    r = {'count': n, 'rate': n / dt, 'mean': total_sum / n if n else None}
    for q in (0.5, 0.9, 0.99, 0.999):
        r[f'p{q * 100:g}'] = quantile(q, buckets)
    for bound in (0.001, 0.002, 0.004, 0.008, 0.016, 0.032, 0.064):
        r[f'above_{bound * 1000:g}ms'] = share_above(buckets, bound)
    # The count of each bucket, for the record.
    prev = 0
    r['buckets'] = {}
    for le, c in buckets:
        if c - prev:
            r['buckets']['inf' if le == math.inf else f'{le * 1000:g}ms'] = int(c - prev)
        prev = c
    return r


def metric(sample, name, **want):
    total = 0.0
    for (m, labels), v in sample.items():
        if m == name and all(dict(labels).get(k) == w for k, w in want.items()):
            total += v
    return total


def requests(a, b, dt):
    rates = defaultdict(float)
    for (m, labels), v in b.items():
        if m != 'apiserver_request_total':
            continue
        d = dict(labels)
        res = d.get('resource', '')
        if d.get('subresource'):
            res = (res + '/' if res else '') + d['subresource'].lstrip('/')
        res = res or '(none)'
        rates[(d.get('verb', ''), res)] += (v - a.get((m, labels), 0.0)) / dt
    return rates


def load_pod(folder, pod):
    out = []
    for path in sorted(glob.glob(os.path.join(folder, 'samples', f'{pod}.*.txt'))):
        s = parse_sample(path)
        if s and s['etcd'] and s['api']:
            out.append(s)
    return out


def analyze(folder, label):
    marks = {}
    for line in open(os.path.join(folder, 'marks.txt')):
        t, name = line.split()
        marks[name] = float(t)
    if label == 'idle':
        t0, t1 = marks['idle-start'], marks['idle-end']
    else:
        # load.sh stops the sample loop and the load pods 5 seconds after the end mark, so a
        # sample that is up to 4 seconds after the mark is still under the full load.
        t0, t1 = marks[f'{label}-start'], marks[f'{label}-end'] + 4.0
    pods = sorted({os.path.basename(p).rsplit('.', 2)[0] for p in glob.glob(os.path.join(folder, 'samples', '*.txt')) if not p.endswith('pods.txt')})
    result = {'window': label, 'pods': {}, 'requests': defaultdict(float)}
    for pod in pods:
        samples = [s for s in load_pod(folder, pod) if t0 <= s['t'] <= t1]
        if len(samples) < 2:
            result['pods'][pod] = {'error': f'{len(samples)} samples in the window'}
            continue
        a, b = samples[0], samples[-1]
        dt = b['t_etcd'] - a['t_etcd']
        dta = b['t_api'] - a['t_api']
        r = {'seconds': dt, 'samples': len(samples)}
        r['wal_fsync'] = hist_report(a['etcd'], b['etcd'], 'etcd_disk_wal_fsync_duration_seconds', dt)
        r['backend_commit'] = hist_report(a['etcd'], b['etcd'], 'etcd_disk_backend_commit_duration_seconds', dt)
        # The p99 of each interval between two samples, to show the spread in time.
        p99s = []
        for x, y in zip(samples, samples[1:]):
            buckets, _ = hist_delta(x['etcd'], y['etcd'], 'etcd_disk_wal_fsync_duration_seconds')
            q = quantile(0.99, buckets)
            if q is not None:
                p99s.append(q)
        r['wal_fsync_p99_by_interval'] = {'min': min(p99s), 'median': sorted(p99s)[len(p99s) // 2], 'max': max(p99s), 'at_or_above_10ms': sum(1 for q in p99s if q >= 0.010), 'intervals': len(p99s)}
        r['etcd_cpu_cores'] = (metric(b['etcd'], 'process_cpu_seconds_total') - metric(a['etcd'], 'process_cpu_seconds_total')) / dt
        r['apiserver_cpu_cores'] = (metric(b['api'], 'process_cpu_seconds_total') - metric(a['api'], 'process_cpu_seconds_total')) / dta
        for name in ('etcd', 'kube-apiserver'):
            if name in a['cgroup'] and name in b['cgroup']:
                r[f'{name}_cgroup_cpu_cores'] = (b['cgroup'][name]['usage_usec'] - a['cgroup'][name]['usage_usec']) / 1e6 / dt
                r[f'{name}_cgroup_throttled_s'] = (b['cgroup'][name]['throttled_usec'] - a['cgroup'][name]['throttled_usec']) / 1e6
                r[f'{name}_cgroup_memory_mib'] = b['cgroup'][name]['memory_current'] / 2**20
        r['etcd_rss_mib'] = metric(b['etcd'], 'process_resident_memory_bytes') / 2**20
        r['apiserver_rss_mib'] = metric(b['api'], 'process_resident_memory_bytes') / 2**20
        r['db_size_mib'] = metric(b['etcd'], 'etcd_mvcc_db_total_size_in_bytes') / 2**20
        r['db_in_use_mib'] = metric(b['etcd'], 'etcd_mvcc_db_total_size_in_use_in_bytes') / 2**20
        r['db_size_start_mib'] = metric(a['etcd'], 'etcd_mvcc_db_total_size_in_bytes') / 2**20
        r['proposals_applied_per_s'] = (metric(b['etcd'], 'etcd_server_proposals_applied_total') - metric(a['etcd'], 'etcd_server_proposals_applied_total')) / dt
        for name in ('etcd_server_leader_changes_seen_total', 'etcd_server_slow_apply_total', 'etcd_server_heartbeat_send_failures_total', 'etcd_server_proposals_failed_total'):
            r[name] = metric(b['etcd'], name) - metric(a['etcd'], name)
        r['is_leader'] = metric(b['etcd'], 'etcd_server_is_leader')
        r['meminfo_mib'] = {k: v / 2**20 for k, v in b['meminfo'].items()}
        r['pod_cgroup'] = b['pod']
        r['pod_cgroup_cpu_cores'] = (int(b['pod']['cpu.stat']['usage_usec']) - int(a['pod']['cpu.stat']['usage_usec'])) / 1e6 / dt
        r['pod_memory_current_mib_max'] = max(int(s['pod']['memory.current']) for s in samples) / 2**20
        r['guest_loadavg_end'] = b['loadavg'][:3]
        r['node_loadavg'] = {'start': a['nodeload'][:3], 'end': b['nodeload'][:3], 'max_1min': max(float(s['nodeload'][0]) for s in samples)}
        r['disk'] = {}
        for dev in b['disk']:
            if dev in a['disk']:
                f = b['disk'][dev]['flushes'] - a['disk'][dev]['flushes']
                w = b['disk'][dev]['writes'] - a['disk'][dev]['writes']
                if f > 0 or w > 0:
                    r['disk'][dev] = {'writes_per_s': w / dt, 'flushes_per_s': f / dt, 'flush_ms_avg': (b['disk'][dev]['flush_ms'] - a['disk'][dev]['flush_ms']) / f if f else None}
        for key, rate in requests(a['api'], b['api'], dta).items():
            result['requests'][key] += rate
        result['pods'][pod] = r
    return result


def print_report(res):
    print(f"\n#### window {res['window']}")
    for pod, r in res['pods'].items():
        if 'error' in r:
            print(f"{pod}: {r['error']}")
            continue
        w, c = r['wal_fsync'], r['backend_commit']
        print(f"-- {pod}: {r['seconds']:.0f} s, {r['samples']} samples, etcd leader={int(r['is_leader'])}")
        print(f"   WAL fsync: {w['count']:.0f} syncs ({w['rate']:.1f}/s) mean {ms(w['mean'])} p50 {ms(w['p50'])} p90 {ms(w['p90'])} p99 {ms(w['p99'])} p99.9 {ms(w['p99.9'])} ms")
        print(f"     share above 2 ms {w['above_2ms']:.2%}, 4 ms {w['above_4ms']:.2%}, 8 ms {w['above_8ms']:.3%}, 16 ms {w['above_16ms']:.3%}, 32 ms {w['above_32ms']:.3%}. Buckets {w['buckets']}")
        i = r['wal_fsync_p99_by_interval']
        print(f"     p99 of each interval: min {ms(i['min'])} median {ms(i['median'])} max {ms(i['max'])} ms, {i['at_or_above_10ms']} of {i['intervals']} intervals at or above 10 ms")
        print(f"   backend commit: {c['count']:.0f} ({c['rate']:.1f}/s) mean {ms(c['mean'])} p50 {ms(c['p50'])} p90 {ms(c['p90'])} p99 {ms(c['p99'])} p99.9 {ms(c['p99.9'])} ms. Above 8 ms {c['above_8ms']:.2%}, 16 ms {c['above_16ms']:.2%}, 32 ms {c['above_32ms']:.2%}. Buckets {c['buckets']}")
        print(f"   CPU cores: kube-apiserver {r['apiserver_cpu_cores']:.3f} (cgroup {r.get('kube-apiserver_cgroup_cpu_cores', float('nan')):.3f}), etcd {r['etcd_cpu_cores']:.3f} (cgroup {r.get('etcd_cgroup_cpu_cores', float('nan')):.3f}), whole pod cgroup on the node {r['pod_cgroup_cpu_cores']:.3f}")
        print(f"   memory MiB: kube-apiserver RSS {r['apiserver_rss_mib']:.0f}, etcd RSS {r['etcd_rss_mib']:.0f}. Kernel of the pod: total {r['meminfo_mib'].get('MemTotal', 0):.0f}, available {r['meminfo_mib'].get('MemAvailable', 0):.0f}, cached {r['meminfo_mib'].get('Cached', 0):.0f}")
        p = r['pod_cgroup']
        print(f"   pod cgroup: current {int(p['memory.current']) / 2**20:.0f} MiB (maximum in the window {r['pod_memory_current_mib_max']:.0f}), peak {int(p['memory.peak']) / 2**20:.0f}, limit {p['memory.max']}, oom_kill {p['memory.events'].get('oom_kill')}, shmem {int(p['memory.stat'].get('shmem', 0)) / 2**20:.0f}, anon {int(p['memory.stat'].get('anon', 0)) / 2**20:.0f}, file {int(p['memory.stat'].get('file', 0)) / 2**20:.0f}")
        print(f"   etcd: db {r['db_size_mib']:.1f} MiB (in use {r['db_in_use_mib']:.1f}, at window start {r['db_size_start_mib']:.1f}), proposals applied {r['proposals_applied_per_s']:.1f}/s, leader changes {r['etcd_server_leader_changes_seen_total']:.0f}, slow applies {r['etcd_server_slow_apply_total']:.0f}, heartbeat send failures {r['etcd_server_heartbeat_send_failures_total']:.0f}, failed proposals {r['etcd_server_proposals_failed_total']:.0f}")
        print(f"   load average: in the pod {' '.join(r['guest_loadavg_end'])}, kind node start {' '.join(r['node_loadavg']['start'])} end {' '.join(r['node_loadavg']['end'])} max 1 min {r['node_loadavg']['max_1min']}")
        disks = ', '.join(f"{d} {v['writes_per_s']:.0f} w/s {v['flushes_per_s']:.0f} flush/s" + (f" {v['flush_ms_avg']:.2f} ms/flush" if v['flush_ms_avg'] is not None else '') for d, v in sorted(r['disk'].items()))
        print(f"   disks: {disks}")
    rates = res['requests']
    total = sum(rates.values())
    writes = sum(v for (verb, _), v in rates.items() if verb in ('POST', 'PUT', 'PATCH', 'DELETE'))
    print(f"-- requests each second, all API servers: total {total:.1f}, writes {writes:.1f}")
    for (verb, resource), v in sorted(rates.items(), key=lambda kv: -kv[1]):
        if v >= 0.05:
            print(f"   {verb:8s} {resource:40s} {v:8.2f}")


def main():
    folder = sys.argv[1]
    labels = sys.argv[2:] or ['idle', 'w355', 'w756']
    out = []
    for label in labels:
        try:
            res = analyze(folder, label)
        except KeyError as e:
            print(f'window {label}: no mark {e}')
            continue
        print_report(res)
        res['requests'] = {f'{verb} {resource}': v for (verb, resource), v in res['requests'].items() if v >= 0.01}
        out.append(res)
    with open(os.path.join(folder, 'analysis.json'), 'w') as f:
        json.dump(out, f, indent=1, default=str)


if __name__ == '__main__':
    main()
