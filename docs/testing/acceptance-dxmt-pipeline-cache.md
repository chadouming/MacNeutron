# Shader pre-caching acceptance test (DXMT fork, sub-project 4, first slice)

Spec: `docs/superpowers/specs/2026-09-30-macneutron-pipeline-cache-design.md` §7. Manual, on a Mac with D3DMetal
(GPTK imported) and SMITE 2 installed. Record results at the bottom.

## Steps

1. **Tests:** `make dxmt-check` and `make test` pass.
2. **Install:** `.build/release/macneutron install-dxmt build/dxmt`.
3. **First launch:** SMITE 2 with launch options `/usr/bin/env DXMT_D3D12_SM6=1 %command%` (no capture mode).
   - Play the lobby, then a practice match of about five minutes. Keep `Hemingway.log`
     (`…/compatdata/2437170/pfx/drive_c/users/crossover/AppData/Local/SMITE2Alpha/Saved/Logs`).
   - `…/compatdata/2437170/dxmt-pipelines/Hemingway-Win64-Shipping.exe.pipelines` exists, and so does `replayed`.
4. **Second launch,** the same route and length.
   - No `precache:` line in `~/Library/Logs/MacNeutron/launcher.log`.
   - From `Hemingway.log`: the last `LogPSOHitching: Encountered N PSO creation hitches` line, and the count of
     `PSO PRECACHING MISS:` blocks.
   - From `steam-2437170.log` (with `MACNEUTRON_LOG=1` added to the launch options), the last `d3d12 shader cache` line.
5. **Simulated update.**
   - Delete `$(getconf DARWIN_USER_CACHE_DIR)dxmt/Hemingway-Win64-Shipping.exe/shaders_*.db` and the `com.apple.metal`
     folder beside it, and write `old` into `dxmt-pipelines/replayed`.
   - Launch the same route and length. The notification appears, and `launcher.log` has
     `precache: Hemingway-Win64-Shipping.exe.pipelines exit=0 replay: …` with the time it took.
   - Take step 4's numbers again.
6. **Pass:**
   - Step 4's hitch count is well under step 3's and under 150, and step 5's is close to step 4's.
   - The shader cache line shows function hits outnumbering misses in steps 4 and 5.
   - The replay line reports 0 failed.
   - The lobby and match render as before, the hedges included.
   - Precaching misses count pipelines Unreal didn't predict; they are recorded, not judged.

## Results

| Date | Steps passed | Notes |
|---|---|---|
