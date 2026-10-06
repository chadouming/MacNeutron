#!/usr/bin/env python3
# GPU time per frame of a running game, from a Metal System Trace (GPU overlap spec §7):
#   python3 dxmt/tools/gpu-trace.py <pid> [seconds]         records <seconds> (default 5) of the process, then reports
#   python3 dxmt/tools/gpu-trace.py <file.trace>            reports an existing trace
#   ... [--label SUBSTR]                                    also the intervals whose label has SUBSTR (see below)
#   python3 dxmt/tools/gpu-trace.py <PEX_Timeline_*.csv>    Unreal's frame times: median and 90th percentile
# A trace report: frame period and GPU busy and idle time per frame (medians), and each GPU channel's busy share of
# the window with its intervals added up (more: passes of that channel side by side), then the channels' sum against
# their union (more: different channels side by side).
# Then the GPU's idle time per frame by where it falls: between encoders, between command buffers, waiting for the CPU.
# --label: per frame, the GPU time of the intervals whose label (Instruments' or the encoder's) has SUBSTR, and the
# GPU's idle time just before the first of them and just after the last (none labelled: the labels there are). MetalFX
# labels its own passes: a temporal upscale's are MetalFX_Temporal_*, the presenter's spatial ones MetalFX_Scale and
# MetalFX_Sharpen.
import bisect, collections, csv, itertools, os, re, statistics as st, subprocess, sys, tempfile
import xml.etree.ElementTree as ET


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


def fmt(el):
    return el.attrib.get('fmt', '') if el is not None else ''


def labelled(mine, label):
    # mine: (start, end, channel, frame, cmdbuffer, label) of the game's intervals, sorted
    first = {}
    for iv in mine:
        first.setdefault(iv[3], iv[0])  # each frame's start: its first interval comes first
    whole = set(sorted(first, key=first.get)[1:-1])  # whole frames only, as trace()
    hits = collections.defaultdict(list)
    for iv in mine:
        if iv[3] in whole and label in iv[5]:
            hits[iv[3]].append(iv)
    if not hits:
        bare = lambda name: re.sub(r'Command Buffer \d+:|\s*\(\w+ \(\d+\)\)|\s*0x[0-9a-f]+|\d+', '', name)
        names = collections.Counter(bare(iv[5]) for iv in mine)
        sys.exit(f"no interval labelled '{label}'; labels: " +
                 ', '.join(f"{n!r} {c}" for n, c in names.most_common(12)))
    starts = [iv[0] for iv in mine]
    ends = list(itertools.accumulate((iv[1] for iv in mine), max))  # ends[i]: the latest end of mine[:i + 1]
    gpu, before, after = [], [], []
    for v in hits.values():
        first, last = min(a for a, *_ in v), max(b for _, b, *_ in v)
        gpu.append(union([(a, b) for a, b, *_ in v]) / 1e6)
        i = bisect.bisect_left(starts, first)  # mine[:i] start before the first labelled interval
        before.append(max(0, first - ends[i - 1]) / 1e6 if i else 0)
        k = bisect.bisect_left(starts, last)  # mine[k] is the first to start once the last labelled one has ended
        after.append(max(0, starts[k] - max(last, ends[k - 1])) / 1e6 if k < len(mine) else 0)
    n = sum(len(v) for v in hits.values()) / len(hits)
    m = lambda v: f"median {st.median(v):.2f} ms (p90 {sorted(v)[int(0.9 * (len(v) - 1))]:.2f})"
    print(f"'{label}': {len(hits)} frames, {n:.1f} intervals per frame; GPU time per frame {m(gpu)}; "
          f"GPU idle just before {m(before)}, just after {m(after)}")


def trace(path, label=None):
    xml = os.path.join(tempfile.mkdtemp(), 'intervals.xml')
    with open(xml, 'w') as out:
        subprocess.run(['xcrun', 'xctrace', 'export', '--input', path, '--xpath',
                        '/trace-toc/run[@number="1"]/data/table[@schema="metal-gpu-intervals"]'],
                       check=True, stdout=out, stderr=subprocess.DEVNULL)
    # Every interval, nested ones too: Instruments puts some of our encoders' intervals one level down (about 0.6 ms
    # of GPU work per frame in SMITE 2), and they are GPU work all the same.
    # (start, end, channel, frame, cmdbuffer, label: Instruments' label and the encoder's)
    by_process = collections.defaultdict(list)
    for r in rows(xml):
        if len(r) <= 10 or r[3] is None:
            continue
        start = int(r[0].text)
        by_process[fmt(r[10])].append(
            (start, start + int(r[1].text), r[2].text, r[3].text, r[15].text if len(r) > 15 and r[15] is not None else None,
             ' | '.join(x for x in (fmt(r[6]), fmt(r[12]) if len(r) > 12 else '') if x)))
    if not by_process:
        sys.exit('no GPU intervals in the trace')
    mine = max(by_process.values(), key=lambda v: sum(b - a for a, b, *_ in v))  # the game: the most GPU time
    window = max(b for _, b, *_ in mine) - min(a for a, *_ in mine)
    by_frame = collections.defaultdict(list)
    for a, b, _, f, *_ in mine:
        by_frame[f].append((a, b))
    frames = sorted((min(a for a, _ in v), union(v)) for v in by_frame.values())[1:-1]  # whole frames only
    period = [(b[0] - a[0]) / 1e6 for a, b in zip(frames, frames[1:])]
    busy = [u / 1e6 for _, u in frames[:-1]]
    idle = [p - u for p, u in zip(period, busy)]
    print(f"frames {len(frames)}, frame period median {st.median(period):.2f} ms ({1000 / st.median(period):.0f} fps)")
    print(f"GPU busy per frame median {st.median(busy):.2f} ms, idle {st.median(idle):.2f} ms")
    # Busy share of the window per channel, and its intervals added up: more than the busy share is passes of that
    # channel running side by side (render passes overlapping each other show as Fragment and Vertex intervals).
    channels = sorted({c for _, _, c, *_ in mine})
    busy_share = {ch: 100 * union([(a, b) for a, b, c, *_ in mine if c == ch]) / window for ch in channels}
    summed = {ch: 100 * sum(b - a for a, b, c, *_ in mine if c == ch) / window for ch in channels}
    print('channels ' + ', '.join(f"{ch} {busy_share[ch]:.1f}% (intervals {summed[ch]:.1f}%)" for ch in channels) +
          f"; sum {sum(busy_share.values()):.1f}%, union {100 * union([(a, b) for a, b, *_ in mine]) / window:.1f}%")
    # Where the GPU idles: waiting for the CPU to commit the next command buffer (committed over 20 us after the GPU
    # went idle), between command buffers committed in time, or between encoders inside one command buffer.
    submissions = os.path.join(os.path.dirname(xml), 'submissions.xml')
    with open(submissions, 'w') as out:
        subprocess.run(['xcrun', 'xctrace', 'export', '--input', path, '--xpath',
                        '/trace-toc/run[@number="1"]/data/table[@schema="metal-application-command-buffer-submissions"]'],
                       check=True, stdout=out, stderr=subprocess.DEVNULL)
    committed = {}
    for r in rows(submissions):
        if len(r) > 14 and r[14] is not None and r[0] is not None:
            committed[r[14].text] = int(r[0].text) + (int(r[1].text) if r[1] is not None and r[1].text else 0)
    idle = collections.Counter()
    ordered = sorted(mine)
    end, before = ordered[0][1], ordered[0]
    for iv in ordered[1:]:
        if iv[0] > end:
            if committed.get(iv[4], 0) > end + 20000:
                idle['waiting for the CPU'] += iv[0] - end
            elif iv[4] != before[4]:
                idle['between command buffers'] += iv[0] - end
            else:
                idle['between encoders'] += iv[0] - end
        if iv[1] > end:
            end, before = iv[1], iv
    print('GPU idle per frame: ' + ', '.join(f"{k} {idle[k] / 1e6 / len(by_frame):.2f} ms"
                                             for k in ('between encoders', 'between command buffers', 'waiting for the CPU')))
    if label is not None:
        labelled(ordered, label)


args = sys.argv[1:]
label = None
if '--label' in args:
    i = args.index('--label')
    if i + 1 == len(args):
        sys.exit('usage: gpu-trace.py <pid> [seconds] | <file.trace> | <PEX_Timeline_*.csv> [--label SUBSTR]')
    label = args[i + 1]
    del args[i:i + 2]
arg = args[0]
if arg.endswith('.csv'):
    pex(arg)
elif arg.endswith('.trace'):
    trace(arg, label)
else:
    out = os.path.join(tempfile.mkdtemp(), 'gpu.trace')
    subprocess.run(['xcrun', 'xctrace', 'record', '--template', 'Metal System Trace', '--attach', arg,
                    '--time-limit', f"{args[1] if len(args) > 1 else 5}s", '--output', out],
                   check=True, stdout=subprocess.DEVNULL)
    print(f"trace {out}")
    trace(out, label)
