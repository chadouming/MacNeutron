# Native arm64 stack: research (2026-10-02)

Evidence behind `docs/superpowers/specs/2026-10-02-macneutron-native-arm64-design.md`. These are reports from research
workflows and probes, kept because `build/` and session scratchpads get wiped. Claims are tagged VERIFIED / INFERRED (or
CONFIRMED / REFUTED after a sceptic pass). Where a report and the spec disagree, the spec wins: it carries the corrections.

| File | What |
|---|---|
| `stack-map.md` | Every x86_64/Rosetta assumption in this repo, D3D9 and 32-bit options, state of the art, first roadmap |
| `wine-11.19-survey.md` | What upstream Wine 11.19 has and lacks on macOS arm64; the unentitled patch series (now superseded) |
| `entitled-trial.md` | The throwaway trial: wine-11.19 as an entitled 4K-page `wine.app`, six patches |
| `entitled-trial-verified.md` | A second agent's re-run of the trial, with its corrections |
| `x18-boundaries.md` | Every Windows↔Unix transition in Wine 11.19's arm64 dispatchers, and the strict x18 toggling design |
| `spec-review.md` | The three-lens review of the spec's first draft (facts, consistency, feasibility) |
| `trial-patches/` | The trial's six Wine patches (`git format-patch` on `wine-11.19`) |
| `probes/entitlement-probe.c` | What the cross-architecture entitlement changes (low memory, 4K spawn, x18, RWX, TSO litmus) |
| `probes/mkbundle.sh` | Wraps a probe in an entitled, Developer ID-signed bundle |
| `probes/x18-probe.c` | x18 across context switches, faults, sigreturn and new threads |
| `probes/jit-memory-probe.c` | RW + RX alias via `mach_vm_remap`, `MAP_JIT` toggle cost |
| `probes/dualmap.c` | ARM64 PE: one section mapped RW + RX vs an RWX page through the W^X flip |
| `probes/x18-cache-scan.sh` | Scans the dyld shared cache for code that touches x18; rerun on each macOS beta |
