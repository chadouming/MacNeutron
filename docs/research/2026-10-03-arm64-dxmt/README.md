# Sub-project 2 (DXMT for arm64): exploration evidence (2026-10-03)

Evidence behind `docs/superpowers/specs/2026-10-03-macneutron-arm64-dxmt-design.md`. Where a report and the spec disagree, the spec wins.

| File | What |
|---|---|
| `brief.md` | The synthesized design-input brief (build recipe, window binding, bundle layout, tests, upstream state), with its corrections table |
| `maps.md` | The five underlying reports: build, window, tests, bundle, upstream |
| `0013-winemac.drv-Export-macdrv_functions-so-DXMT-can-present.patch` | The draft Wine patch 13 (applies to wine-11.19 + patches 1-12; never run with DXMT yet) |
| `dlsym_test.c` | Probe: does `dlsym(RTLD_DEFAULT, "macdrv_functions")` find the table once winemac.so is loaded |
