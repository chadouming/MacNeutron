#!/usr/bin/env python3
# GPU time per frame of a running game, from a Metal System Trace (GPU overlap spec §7):
#   python3 dxmt/tools/gpu-trace.py <pid> [seconds]         records <seconds> (default 5) of the process, then reports
#   python3 dxmt/tools/gpu-trace.py <file.trace>            reports an existing trace
#   python3 dxmt/tools/gpu-trace.py <PEX_Timeline_*.csv>    Unreal's frame times: median and 90th percentile
# A trace report: frame period and GPU busy and idle time per frame (medians), and each GPU channel's share of the
# window with their sum against their union. A sum above the union is work running side by side.
import collections, csv, os, statistics as st, subprocess, sys, tempfile, xml.etree.ElementTree as ET


def rows(path):
    ids = {}
    for _, el in ET.iterparse(path, events=('end',)):
        if 'id' in el.attrib:
            ids[el.attrib['id']] = el
        if el.tag == 'row':
            yield [ids.get(c.attrib['ref']) if 'ref' in c.attrib else c for c in el]
            el.clear()


def union(intervals):
    total, start, end = 0, None, None
    for a, b in sorted(intervals):
        if start is None or a > end:
            total += end - start if start is not None else 0
            start, end = a, b
        else:
            end = max(end, b)
    return total + (end - start if start is not None else 0)


def pex(path):
    frames = sorted(float(r['FrameTime']) for r in csv.DictReader(open(path)) if r['IgnoredForSummary'] == '0')
    print(f"frames {len(frames)}, frame time median {st.median(frames):.2f} ms, "
          f"p90 {frames[int(0.9 * (len(frames) - 1))]:.2f} ms")


def trace(path):
    xml = os.path.join(tempfile.mkdtemp(), 'intervals.xml')
    with open(xml, 'w') as out:
        subprocess.run(['xcrun', 'xctrace', 'export', '--input', path, '--xpath',
                        '/trace-toc/run[@number="1"]/data/table[@schema="metal-gpu-intervals"]'],
                       check=True, stdout=out, stderr=subprocess.DEVNULL)
    by_process = collections.defaultdict(list)  # top-level intervals: (start, end, channel, frame)
    for r in rows(xml):
        if len(r) <= 10 or r[3] is None or (r[5] is not None and r[5].text not in ('0', None)):
            continue
        start = int(r[0].text)
        by_process[r[10].attrib.get('fmt', '') if r[10] is not None else ''].append((start, start + int(r[1].text), r[2].text, r[3].text))
    if not by_process:
        sys.exit('no GPU intervals in the trace')
    mine = max(by_process.values(), key=lambda v: sum(b - a for a, b, *_ in v))  # the game: the most GPU time
    window = max(b for _, b, *_ in mine) - min(a for a, *_ in mine)
    by_frame = collections.defaultdict(list)
    for a, b, _, f in mine:
        by_frame[f].append((a, b))
    frames = sorted((min(a for a, _ in v), union(v)) for v in by_frame.values())[1:-1]  # whole frames only
    period = [(b[0] - a[0]) / 1e6 for a, b in zip(frames, frames[1:])]
    busy = [u / 1e6 for _, u in frames[:-1]]
    idle = [p - u for p, u in zip(period, busy)]
    print(f"frames {len(frames)}, frame period median {st.median(period):.2f} ms ({1000 / st.median(period):.0f} fps)")
    print(f"GPU busy per frame median {st.median(busy):.2f} ms, idle {st.median(idle):.2f} ms")
    shares = {ch: 100 * union([(a, b) for a, b, c, _ in mine if c == ch]) / window
              for ch in sorted({c for _, _, c, _ in mine})}
    print('channels ' + ', '.join(f"{ch} {s:.1f}%" for ch, s in shares.items()) +
          f"; sum {sum(shares.values()):.1f}%, union {100 * union([(a, b) for a, b, *_ in mine]) / window:.1f}%")


arg = sys.argv[1]
if arg.endswith('.csv'):
    pex(arg)
elif arg.endswith('.trace'):
    trace(arg)
else:
    out = os.path.join(tempfile.mkdtemp(), 'gpu.trace')
    subprocess.run(['xcrun', 'xctrace', 'record', '--template', 'Metal System Trace', '--attach', arg,
                    '--time-limit', f"{sys.argv[2] if len(sys.argv) > 2 else 5}s", '--output', out],
                   check=True, stdout=subprocess.DEVNULL)
    trace(out)
