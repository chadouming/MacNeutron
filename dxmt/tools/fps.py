#!/usr/bin/env python3
"""Frame rate from an Unreal log (SMITE 2's Hemingway.log), by the frame counter on each line:
  python3 dxmt/tools/fps.py <Hemingway.log> [--map SUBSTR] [--wait 20] [--window 60] [--gap SECONDS]
The window starts at the first line at or after the map's LoadMap + wait seconds and ends at the first line at or after
that + window seconds. Unreal prints GFrameCounter % 1000, so the frames between two lines are known only while fewer
than 1000 can pass between them. A pair of lines further apart than the gap limit could hide whole wraps: its frames
and its time are left out, and the skipped seconds printed. The limit (or --gap) is the time 1000 frames take at 1.5x
the window's highest rate between lines 0.5-2 s apart (those can't wrap below 500 FPS); 2 s when there are none.
(scratchpad sp5/perf/fps4.py counted every gap mod 1000: 35.60 FPS for a 118-121 FPS match with 9-29 s gaps.)"""
import datetime as dt, re, sys

a = sys.argv
if len(a) < 2:
    sys.exit(__doc__)
opt = lambda k, d: a[a.index(k) + 1] if k in a else d
MAP = opt('--map', 'L_MainLobby_P')
WAIT, W = float(opt('--wait', 20)), float(opt('--window', 60))
rx = re.compile(r'^\[(\d{4})\.(\d{2})\.(\d{2})-(\d{2})\.(\d{2})\.(\d{2}):(\d{3})\]\[\s*(\d+)\](.*)')
rows, t_map = [], None  # rows: (time, frame counter)
for line in open(a[1], errors='replace'):
    m = rx.match(line)
    if not m:
        continue
    y, mo, d, h, mi, s, ms, fr = (int(x) for x in m.groups()[:8])
    rows.append((dt.datetime(y, mo, d, h, mi, s, ms * 1000), fr))
    if t_map is None and 'LoadMap:' in m.group(9) and MAP in m.group(9):
        t_map = rows[-1][0]
if t_map is None:
    sys.exit('map not reached')
start = t_map + dt.timedelta(seconds=WAIT)
i0 = next((i for i, r in enumerate(rows) if r[0] >= start), None)
i1 = next((i for i, r in enumerate(rows) if r[0] >= start + dt.timedelta(seconds=W)), len(rows) - 1)
if i0 is None or rows[i1][0] <= rows[i0][0]:
    sys.exit('no window')
pairs = [((t1 - t0).total_seconds(), (f1 - f0) % 1000) for (t0, f0), (t1, f1) in zip(rows[i0:i1], rows[i0 + 1:i1 + 1])]
fmax = max((n / g for g, n in pairs if 0.5 <= g <= 2), default=0)
GAP = float(opt('--gap', 1000 / (1.5 * fmax) if fmax else 2))
frames, secs, skipped = 0, 0.0, 0.0
for gap, n in pairs:
    if gap > GAP:
        skipped += gap
    else:
        frames, secs = frames + n, secs + gap
span = (rows[i1][0] - rows[i0][0]).total_seconds()
rate = f'{frames / secs:.2f} FPS' if secs else 'no FPS (every line pair skipped)'
print(f'{MAP}: LoadMap {t_map.time()}  window {rows[i0][0].time()}..{rows[i1][0].time()} ({span:.1f}s)  '
      f'frames {frames} in {secs:.1f}s (gaps over {GAP:.1f}s skipped: {skipped:.1f}s)  -> {rate}')
