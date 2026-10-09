#!/usr/bin/env python3
"""The measurement lanes (batch Task 2): x64-sync and arm64-xcall as ARM64, ARM64EC and x64 programs. Measured, not gated.

Usage: lanes_report.py <dir> [<after-dir>] | --self-test
Each directory holds run1.log..run3.log, copies of check.sh's lanes.log, whose lines `info <exe> <row> <ns>` are read
(<exe>: arm64-sync arm64ec-sync x64-sync arm64-xcall arm64ec-xcall x64-xcall) and the rest ignored. Every run has to
hold the same (exe, row) set. The lane is the exe's prefix, the program the rest. One directory: a markdown table, a
line per program row, cells `median (min–max)` of the runs per lane, then arm64ec − arm64 and x64 − arm64ec on the
medians. Two: per lane, before and after, Δ % = (after − before) / before × 100 on the medians, and `yes` when the two
min–max ranges don't overlap (outside the band).
"""
import re
import sys
import tempfile
from statistics import median

RUNS = 3
LANES = ('arm64', 'arm64ec', 'x64')
LINE = re.compile(r'info (arm64|arm64ec|x64)-(sync|xcall) (\S+) ([0-9]+(?:\.[0-9]+)?)')


def load(folder):
    """{(program, row): {lane: [ns, one per run]}}, in run1.log's order."""
    runs = []
    for i in range(1, RUNS + 1):
        path = f'{folder}/run{i}.log'
        with open(path) as f:
            got = {m.group(1, 2, 3): float(m[4]) for m in map(LINE.fullmatch, f.read().splitlines()) if m}
        if not got:
            sys.exit(f'lanes_report: {path} has no `info <exe> <row> <ns>` lines')
        if runs and got.keys() != runs[0].keys():
            odd = sorted(got.keys() ^ runs[0].keys())
            sys.exit(f'lanes_report: {path} has {len(got)} rows, not run1.log\'s; differing: '
                     + ' '.join(f'{lane}-{prog} {row}' for lane, prog, row in odd[:5]))
        runs.append(got)
    rows = {}
    for lane, prog, row in runs[0]:
        rows.setdefault((prog, row), {})[lane] = [r[lane, prog, row] for r in runs]
    return rows


def fmt(v):
    return f'{v:.0f}' if abs(v) >= 100 else f'{v:.1f}'


def cell(values):
    return f'{fmt(median(values))} ({fmt(min(values))}–{fmt(max(values))})'


def diff(rows, a, b):
    """lane a's median − lane b's, or — when either is missing."""
    if a not in rows or b not in rows:
        return '—'
    d = median(rows[a]) - median(rows[b])
    return ('+' if d > 0 else '') + fmt(d)


def delta_pct(before, after):
    return f'{(median(after) - median(before)) / median(before) * 100:+.1f}'


def outside(before, after):
    return 'yes' if max(before) < min(after) or max(after) < min(before) else 'no'


def self_test():
    assert median([30.0, 10.0, 20.0]) == 20.0
    assert cell([1234.0, 1100.0, 1300.0]) == '1234 (1100–1300)'
    assert cell([2.24, 2.0, 3.5]) == '2.2 (2.0–3.5)'
    assert diff({'arm64': [10.0] * 3, 'arm64ec': [12.5] * 3}, 'arm64ec', 'arm64') == '+2.5'
    assert diff({'arm64': [10.0] * 3}, 'x64', 'arm64ec') == '—'
    assert delta_pct([100.0] * 3, [110.0, 90.0, 120.0]) == '+10.0'
    assert delta_pct([200.0] * 3, [150.0] * 3) == '-25.0'
    assert outside([1.0, 2.0, 3.0], [3.0, 4.0, 5.0]) == 'no'  # touching ranges overlap
    assert outside([1.0, 2.0, 3.0], [3.5, 4.0, 5.0]) == 'yes'
    assert outside([5.0, 6.0, 7.0], [1.0, 2.0, 4.9]) == 'yes'
    with tempfile.TemporaryDirectory() as d:
        lines = ['PASS boot', 'info arm64-sync: pulse-event 4 of 4 waiters woke', 'info x64-sync qpc-like 7 extra',
                 'info arm64-sync cs-uncontended 12', 'info x64-xcall qpc 40.5']
        for i in range(1, RUNS + 1):
            with open(f'{d}/run{i}.log', 'w') as f:
                f.write('\n'.join(lines[:4 if i == 2 else 5]) + '\n')
        try:
            load(d)
        except SystemExit as e:
            assert 'run2.log' in str(e), e
        else:
            raise AssertionError('a run with a missing row was accepted')
        with open(f'{d}/run2.log', 'w') as f:
            f.write('\n'.join(lines) + '\n')
        assert load(d) == {('sync', 'cs-uncontended'): {'arm64': [12.0] * 3},
                           ('xcall', 'qpc'): {'x64': [40.5] * 3}}
    print('PASS lanes_report self-test')


def main(argv):
    if argv == ['--self-test']:
        self_test()
        return 0
    if len(argv) not in (1, 2):
        sys.exit(__doc__.strip())
    before = load(argv[0])
    if len(argv) == 1:
        print('| row | arm64 | arm64ec | x64 | arm64ec − arm64 | x64 − arm64ec |')
        print('|---|---|---|---|---|---|')
        for (prog, row), lanes in before.items():
            cells = [cell(lanes[lane]) if lane in lanes else '—' for lane in LANES]
            print(f'| {prog} {row} | {" | ".join(cells)} | {diff(lanes, "arm64ec", "arm64")} | '
                  f'{diff(lanes, "x64", "arm64ec")} |')
        return 0
    after = load(argv[1])
    keys = lambda rows: {(k, lane) for k, lanes in rows.items() for lane in lanes}
    if keys(before) != keys(after):
        sys.exit(f'lanes_report: {argv[0]} and {argv[1]} hold different rows')
    print('| row | lane | before | after | Δ % | outside the band |')
    print('|---|---|---|---|---|---|')
    for (prog, row), lanes in before.items():
        for lane in (lane for lane in LANES if lane in lanes):
            b, a = lanes[lane], after[prog, row][lane]
            print(f'| {prog} {row} | {lane} | {cell(b)} | {cell(a)} | {delta_pct(b, a)} | {outside(b, a)} |')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
