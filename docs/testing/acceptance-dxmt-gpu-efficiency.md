# GPU efficiency acceptance test (DXMT fork, sub-project 4, third slice)

Spec: `docs/superpowers/specs/2026-10-02-macneutron-gpu-efficiency-design.md`. Manual, once per milestone, on a Mac with
SMITE 2 installed. Record results at the bottom.

## Steps

1. **Tests:** `make dxmt-check` and `make test` pass.
2. **Install:** with SMITE 2 closed, `.build/release/macneutron install-dxmt build/dxmt`.
3. **Run:** SMITE 2 with
   `/usr/bin/env DXMT_D3D12_SM6=1 DXMT_STATS=1 DXMT_DXIL_DUMP=/Users/<you>/dxil-smite2 %command%` (pass labels for
   the per-pass table), at the GPU efficiency spot (the M4/M5 spot of the GPU overlap acceptance test).
   - Standing still: `python3 dxmt/tools/gpu-trace.py $(pgrep -f Hemingway-Win64-Shipping | head -1)`.
   - Play about two minutes, quit, and read the newest `PEX_Timeline_*.csv` with `gpu-trace.py`.
4. **Pass:** the picture looks the same; GPU busy per frame is lower than the previous milestone's. A milestone that
   measures no gain is recorded as such.

## Results

| Milestone | Date | Run | Control | Notes |
|---|---|---|---|---|
| Baseline | 2026-10-02 | DXMT (fork 72193e9, labelled): period 14.25 ms (70 fps), GPU busy 13.84 ms, idle 0.37 ms | D3DMetal at the same spot: period 10.14 ms (99 fps), GPU busy 9.87 ms | Per pass (ms per frame): base pass 7c+d 4.77, 1c 2.38, 1c+d 1.95, 0c+d 1.40, compute 1.31, clear 0.78, blit 0.29. Reporting D3DMetal's adapter identity: 14.19 ms (no change). |
| E1 | 2026-10-02 | Fork d2ec0b0, labelled: **period 12.05 ms (83 fps), GPU busy 11.60 ms**, idle 0.39 ms; channels Compute 12.9%, Fragment 51.9%, Vertex 28.5%. PEX: median 12.43 ms, p90 16.02 ms (GPU 11.94 ms, RHI 11.19 ms) | The baseline row | **2.2 ms less GPU work per frame, 18% more frames.** Per pass: base pass 4.77 → 3.96, 1c 2.38 → 2.06, 1c+d 1.95 → 1.45, clear 0.78 → 0.22, 3c+d 0.22 → 0.09; depth-only unchanged (depth was already compressed). The picture looked the same. |
