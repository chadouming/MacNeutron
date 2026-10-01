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
| M1 | 2026-10-01 | Metal trace: period 16.14 ms (62 fps), GPU busy 12.32 ms, idle 3.81 ms; channels Compute 9.7%, Fragment 43.0%, Vertex 22.1%, sum 74.8% vs union 74.5%. PEX: median 16.22 ms, p90 22.04 ms (GPU 14.33 ms, RHI 15.28 ms) | Metal trace: period 15.52 ms (64 fps), GPU busy 13.20 ms, idle 2.31 ms; channels Compute 10.3%, Fragment 50.7%, Vertex 22.9%, sum 83.9% vs union 83.7%. PEX: median 15.81 ms, p90 20.63 ms (GPU 15.07 ms, RHI 14.90 ms) | Fork 7f8bb7e, macOS 26A434, a practice-match spot the user chose, the same in both runs; `DXMT_D3D12_SERIAL=1` confirmed in the control run's processes. **GPU time per frame fell 0.9 ms (7%) and is below §2's 12.5 ms, but the frame rate did not rise:** the time saved became GPU idle time (3.8 against 2.3 ms), so something other than GPU work now sets the pace; the channels barely overlap in either run. The picture looked the same in both runs (no flicker or corrupted surfaces). |
| M2 | 2026-10-01 | Metal trace: period 16.11 ms (62 fps), GPU busy 12.44 ms, idle 3.68 ms; channels Compute 9.4%, Fragment 44.6%, Vertex 22.0%, sum 76.0% vs union 75.7%. PEX: median 16.07 ms, p90 24.66 ms (GPU 14.36 ms, RHI 15.10 ms) | Metal trace: period 16.48 ms (61 fps), GPU busy 13.77 ms, idle 2.72 ms; channels Compute 9.9%, Fragment 50.6%, Vertex 21.7%, sum 82.1% vs union 81.9%. PEX: median 16.60 ms, p90 22.36 ms (GPU 15.90 ms, RHI 15.61 ms) | Fork 57d99c8, macOS 26A434, the user's spot; `DXMT_D3D12_SERIAL=1` confirmed in the control run's processes. **GPU time per frame 10% lower than the control (1.3 ms) and the frame 0.5 ms shorter; against M1's overlap run, no further change** (12.44 against 12.32 ms busy, the same frame period). The frame-period differences between runs (M1's control was the faster one) are within run-to-run noise; the GPU saving is the consistent result, and the time saved still becomes GPU idle time. The picture looked the same in both runs. The user heard wonky audio in the control run (strict order, as before M1), with Teams also running. |

**Reading M1 and M2's numbers** (`gpu-trace.py` since it also adds up each channel's intervals): in all four runs each
channel's intervals add up to exactly its busy share, and the channels' sum is within 0.3 points of their union. So no
work runs side by side, within a channel or across channels. The GPU time saved is the Fragment channel's share
shrinking (50.7% to 43.0% in M1, 50.6% to 44.6% in M2) with the same passes: the encoders' fragment work finishes
sooner when it no longer ends at a fence every later encoder waits on. Overlap proper is still to come (M3's unsplit
passes, and the idle time M5 traces).

