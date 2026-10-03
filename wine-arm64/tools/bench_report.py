#!/usr/bin/env python3
"""Gate G4 (native arm64 spec §8): x64-bench under FEX against Rosetta. Measured, not gated.

Usage: bench_report.py <fex-dir> <rosetta-dir> | --self-test
Each directory holds run1.txt..run5.txt, x64-bench's output: `row <name> <seconds>` or `row <name> skipped`. Every
file has to hold the same rows. Prints each row's median times and their ratio, FEX time / Rosetta time, then the
ratios' geometric means per group (rows named mt_* are multithreaded, call_* call-heavy, the rest single-threaded) and
the five worst rows. A row skipped on either side has no ratio and counts in neither.
"""
import sys
from statistics import geometric_mean as geomean, median

RUNS = 5
GROUPS = ('single-threaded', 'multithreaded', 'calls')


def group(name):
    return 'multithreaded' if name.startswith('mt_') else 'calls' if name.startswith('call_') else 'single-threaded'


def load(folder):
    """{row: [seconds, one per run; None when skipped]}, in the rows' order."""
    runs = []
    for i in range(1, RUNS + 1):
        path = f'{folder}/run{i}.txt'
        rows = {}
        with open(path) as f:
            for line in f:
                p = line.split()
                if len(p) == 3 and p[0] == 'row':
                    rows[p[1]] = None if p[2] == 'skipped' else float(p[2])
        if not rows or (runs and rows.keys() != runs[0].keys()):
            sys.exit(f'bench_report: {path} has rows {" ".join(rows) or "(none)"}, not those of run1.txt')
        runs.append(rows)
    return {name: [r[name] for r in runs] for name in runs[0]}


def mid(times):
    return None if None in times else median(times)


def report(fex, rosetta):
    """{row: median FEX time / median Rosetta time, or None when either side skipped the row}."""
    return {name: (None if None in (mid(t), mid(rosetta[name])) else mid(t) / mid(rosetta[name]))
            for name, t in fex.items()}


def self_test():
    assert median([3.0, 1.0, 2.0, 5.0, 4.0]) == 3.0
    assert geomean([2.0, 0.5]) == 1.0
    assert report({'a': [2.0] * 5}, {'a': [1.0] * 5})['a'] == 2.0
    assert report({'b': [None] * 5}, {'b': [1.0] * 5})['b'] is None
    assert [group(n) for n in ('popcnt', 'mt_xadd_4', 'call_virtual')] == list(GROUPS)
    print('PASS bench_report self-test')


def main(argv):
    if argv == ['--self-test']:
        self_test()
        return 0
    if len(argv) != 2:
        sys.exit(__doc__.strip())
    fex, rosetta = load(argv[0]), load(argv[1])
    if fex.keys() != rosetta.keys():
        sys.exit(f'bench_report: FEX rows {" ".join(fex)} differ from Rosetta rows {" ".join(rosetta)}')
    ratios = report(fex, rosetta)
    show = lambda s: 'skipped' if s is None else f'{s:.4f}'
    for name, r in ratios.items():
        print(f'{name} fex={show(mid(fex[name]))} rosetta={show(mid(rosetta[name]))} '
              f'ratio={"n/a" if r is None else f"{r:.3f}"}')
    means = []
    for g in GROUPS:
        rs = [r for n, r in ratios.items() if r is not None and group(n) == g]
        means.append(f'{g}={geomean(rs):.3f}' if rs else f'{g}=n/a')
    print('geomean ' + ' '.join(means))
    worst = sorted(((r, n) for n, r in ratios.items() if r is not None), reverse=True)[:5]
    print('worst: ' + ' '.join(f'{n}={r:.3f}' for r, n in worst))
    print('ratio > 1 means FEX is slower')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
