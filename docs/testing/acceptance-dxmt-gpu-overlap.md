# GPU work overlap acceptance test (DXMT fork, sub-project 4, second slice)

Spec: `docs/superpowers/specs/2026-10-01-macneutron-gpu-overlap-design.md` §7. Manual, once per milestone, on a Mac
with D3DMetal (GPTK imported) and SMITE 2 installed. Record results at the bottom.

## Steps

1. **Tests:** `make dxmt-check` and `make test` pass.
2. **Install:** with SMITE 2 closed, `.build/release/macneutron install-dxmt build/dxmt`.
3. **Overlap run:** SMITE 2 with launch options `/usr/bin/env DXMT_D3D12_SM6=1 %command%`.
   - Start a practice match and stand still in one spot, the same spot in every run of the milestone (note it in the
     results).
   - Meanwhile: `python3 dxmt/tools/gpu-trace.py $(pgrep -f Hemingway-Win64-Shipping | head -1)`.
   - Play about two minutes, then quit to the desktop.
   - Run `python3 dxmt/tools/gpu-trace.py "<PEX_Timeline csv>"` with the newest `PEX_Timeline_*.csv` in
     `~/Library/Application Support/Steam/steamapps/compatdata/2437170/pfx/drive_c/users/crossover/AppData/Local/SMITE2Alpha/Saved/Logs`.
4. **Strict run (control):** the same, with `/usr/bin/env DXMT_D3D12_SM6=1 DXMT_D3D12_SERIAL=1 %command%`.
5. **Pass:**
   - The picture is the same in both runs, by eye: no flicker, no missing or corrupted surfaces.
   - GPU busy per frame is lower in step 3 than in step 4, and lower than §2's 12.5 ms. The channel sum exceeds the
     union by more in step 3 than in step 4.
   - The frame period is shorter in step 3 than in step 4.
   - A milestone that measures no gain is recorded as such, and the next milestone's plan says whether it still goes
     ahead.

F9 dumps run in strict order, so they can't show an M1 or M2 ordering bug. M3 and M4, which change the passes,
compare F9 dumps.

## Results

| Milestone | Date | Overlap (step 3) | Strict (step 4) | Notes |
|---|---|---|---|---|
| M1 | 2026-10-01 | Metal trace: period 16.14 ms (62 fps), GPU busy 12.32 ms, idle 3.81 ms; channels Compute 9.7%, Fragment 43.0%, Vertex 22.1%, sum 74.8% vs union 74.5%. PEX: median 16.22 ms, p90 22.04 ms (GPU 14.33 ms, RHI 15.28 ms) | Metal trace: period 15.52 ms (64 fps), GPU busy 13.20 ms, idle 2.31 ms; channels Compute 10.3%, Fragment 50.7%, Vertex 22.9%, sum 83.9% vs union 83.7%. PEX: median 15.81 ms, p90 20.63 ms (GPU 15.07 ms, RHI 14.90 ms) | Fork 7f8bb7e, macOS 26A434, a practice-match spot the user chose, the same in both runs; `DXMT_D3D12_SERIAL=1` confirmed in the control run's processes. **GPU time per frame fell 0.9 ms (7%) and is below §2's 12.5 ms, but the frame rate did not rise:** the time saved became GPU idle time (3.8 against 2.3 ms), so something other than GPU work now sets the pace; the channels barely overlap in either run. Picture comparison: pending the user's report. |
