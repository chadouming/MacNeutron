# Sub-project 3 (Ship-base Wine): research, 2026-10-04

Evidence behind `docs/superpowers/specs/2026-10-04-macneutron-ship-base-wine-design.md`.

- `brief.md`: the decision brief from six investigations (x18, msync, FreeType/gnutls, lsteamclient, JIT memory, licences), with the skeptic verification of its load-bearing claims appended (§10; its corrections win where they differ).
- `maps-summaries.md`: each investigation's own summary.
- `spec-review.md`: the adversarial review of the first draft of the spec (facts, feasibility, consistency, each re-checked by a sceptic); the revised spec answers every surviving finding. It also corrects the brief's §1: gnutls's own build (and Homebrew's) gives 7 x18 hits, all data words after `ret` in three CRYPTOGAMS routines, not 0 (an interactive `grep` wrapper hid them; use `/usr/bin/grep`).
- `licences_check.sh`: the scratch licence check (red on the sub-project 2 bundle: 37 missing); becomes `wine-arm64/tests/licences_test.sh`.
- `msync-on-11.19-trial.diff`: the trial merge of CrossOver `cx/wine1117`'s msync hunks onto Wine 11.19 + patches 0001-0014 (one conflict, in `loader.c`).
- `probes/`: x18 toggle cost (`x18cost.c`), the toggle-imbalance trap passing through a handler (`trappass.c`), MAP_JIT limits (`mapjit-*.c`), msync's private APIs across two processes (`msyncprobe.c`) and a pipe round-trip baseline (`piperoundtrip.c`). All ran unentitled on the M5 Pro, macOS 27.0.1.
