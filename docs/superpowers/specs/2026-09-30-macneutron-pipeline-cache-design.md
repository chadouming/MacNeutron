# MacNeutron — DXMT Fork, Sub-project 4 (first slice): D3D12 Shader Pre-Caching

- **Date:** 2026-09-30
- **Status:** Draft for review
- **Builds on:**
  - `2026-09-28-macneutron-dxmt-fork-design.md`: roadmap §2 item 4 (performance); the fork, `make dxmt`, `make dxmt-check`, capture mode.
  - `2026-09-29-macneutron-dxil-translator-design.md`: DXIL shaders through airconv (`SM50Initialize`/`SM50Compile`).
  - `2026-09-29-macneutron-d3d12-stubs-design.md`: SMITE 2 plays on our DXMT; its acceptance run traced the match glitches to pipeline creation cost.
- **Scope:** the Steam-for-Vulkan model of shader pre-caching, applied to our D3D12 path. Two milestones, in this order:
  - **Milestone 1, the translation cache:** a persistent cache of translated D3D12 shader functions and their reflection, in DXMT's existing per-game sqlite store; a cache version that follows the fork's build; an opt-in switch that reports the SM6 capabilities without capture mode.
  - **Milestone 2, record and replay:** our `d3d12.dll` records every new pipeline description (Fossilize's role); a replayer, `dxmt-replay.exe`, rebuilds them (`fossilize_replay`'s role); MacNeutron's launcher runs it before the game when the DXMT build or macOS changed (Steam's "Processing Vulkan shaders" step).
  - **Out:**
    - sharing recordings between Macs or players (Valve's server side: we have none, and a game's shaders aren't ours to redistribute);
    - recording D3D11 games;
    - a DXVK-style in-process pipeline cache, whose pipelines the game's own creation calls would return;
    - `MTLBinaryArchive`, and an in-memory cache of Metal functions;
    - a skip button during replay (Steam's Stop button ends it, §3.9);
    - real `GetCachedBlob` / pipeline library contents (D3DMetal returns empty blobs; this cache sits below them).

## 1. Goal

A D3D12 game on our DXMT never translates a shader it has translated before. After a DXMT or macOS update, MacNeutron rebuilds every pipeline the game has ever created before the game starts, as Steam does for Vulkan games. Unreal's pipeline precaching then keeps up, and pipelines created mid-match stop stalling the frame.

**Done when** §7 passes:
- every test in §5 failed first and now passes; rendered output matches D3DMetal on cold, warm and replayed runs;
- `make dxmt-check` and `make test` are green;
- SMITE 2's second launch logs far fewer PSO creation hitches than the 150 of the 2026-09-29 run. After a simulated update, the launcher's replay leaves the game as warm as a second launch.

### Decisions made during brainstorming

| Decision | Choice |
|---|---|
| Model | Steam's shader pre-caching for Vulkan: record pipeline descriptions, replay them through the driver before launch. Not DXVK's in-process state cache |
| What the replay warms | Our translation cache (milestone 1) and Metal's framework cache, which DXMT points at `dxmt/<exe>/com.apple.metal` |
| Translation cache store | DXMT's existing sqlite cache (`ShaderCache`, `dxmt/<exe>/shaders_<metal version>.db`), shared with D3D11 |
| Translation cache key | Hash of every shader bytecode involved + hash of every compile argument, walked generically; unknown argument types are not cached |
| Translation cache version | Hash of `AIRCONV_VERSION` and the build's `git describe`, for D3D11 and D3D12 alike; tables of other versions are dropped |
| Entry validation | A domain tag in each key (D3D12 function / D3D12 reflection) instead of a header in each value; a reflection must be exactly the struct's size; a function must load in Metal and contain its entry point |
| Recording | An append-only file per game executable, `<compatdata>/dxmt-pipelines/<exe>.pipelines`: shader and root signature blobs stored once, pipeline descriptions field by field. It outlives cache invalidations, as Fossilize's `.foz` files outlive driver updates |
| When to replay | Before launch, blocking, only when the DXMT build or the macOS build changed since the last replay, with a notification |
| Replay failure | Best effort: logged, then the game starts; the next replay waits for the next update |
| SM6 capabilities | `DXMT_D3D12_SM6=1` reports them without dumping; capture mode keeps reporting them too. Default capabilities unchanged for other games |
| Delivery | One spec, one plan, milestone 1 then milestone 2 |

## 2. Evidence (2026-09-30; fork `d048cfa`, M5 Pro)

**Where pipeline creation time goes.** A timed copy of `dxil-translate` over 200 SMITE 2 shaders:

| Step | First run | Second run |
|---|---|---|
| Translation, DXIL → metallib | 828 ms: 85 ms parsing (`SM50Initialize`), 743 ms compiling (`SM50Compile`) | 828 ms: nothing is cached |
| Metal, `newLibrary` | 2304 ms | 37 ms |

Translation costs about 4.1 ms per shader on every launch. Metal's compile is already cached across launches: SMITE 2's `com.apple.metal` folder holds 505 MB, and no `shaders_*.db` exists for it, because only D3D11 uses `ShaderCache`.

**Metal's cache is shared by folder, not by process.** The same tool built under two names, pointed by `MTLSetShaderCachePath` (what DXMT's `WMTSetMetalShaderCachePath` calls) at one folder:

| Run | Metal time |
|---|---|
| `procA`, empty folder | 3557 ms |
| `procB`, the folder `procA` filled | 33 ms |
| `procB`, another empty folder (control) | 3554 ms |

So a replay process warms the game's Metal cache, provided both resolve the same folder.

**What Unreal logs.** SMITE 2's `Hemingway.log` of the 2026-09-29 run (lobby, then a practice match):
- `LogPSOHitching: Encountered 150 PSO creation hitches so far (145 graphics, 5 compute). 53 of them were precached`: a pipeline Unreal precached still stalled a frame, because precaching hadn't finished it.
- 119 `PSO PRECACHING MISS:` blocks: pipelines Unreal didn't predict, created when first drawn.
- Unreal skips a draw whose pipeline is still being precached (`r.PSOPrecaching 1`): the black hedges of the pass dump.

**How many pipelines.** Capture mode's `pipelines.txt` for SMITE 2 holds 82,768 creations over several sessions (63,861 graphics, 18,907 compute), 14,378 distinct by the fields it logs.

**Capture mode costs every pipeline.** `DXMT_DXIL_DUMP` is today the only way through Unreal's SM6 check. For every pipeline it hashes each shader byte by byte, checks a file per shader, and appends a line to `pipelines.txt` under one process-wide lock, so Unreal's precaching threads wait on each other.

**One choke point.** Every pipeline, whether from `CreateGraphicsPipelineState`, `CreateComputePipelineState`, `CreatePipelineState` (streams) or a pipeline library, is built by the free functions `dxmt::CreateGraphicsPipelineState` / `dxmt::CreateComputePipelineState`. Nothing there serializes creation: Unreal's precaching threads compile at the same time.

## 3. Design

### 3.1 Units

**Milestone 1**

| Unit | Where (fork) | Does |
|---|---|---|
| `D3D12ShaderCache` | new `src/d3d12/d3d12_shader_cache.hpp/.cpp` | Looks up and stores functions and reflections; counts hits and misses |
| `CachedShader` | same file | One shader stage's bytecode: its SHA-1, its reflection (cached or parsed), the airconv shader parsed only when a function misses |
| `HashCompileArgs` | same file | The variant digest of an airconv argument chain; `nullopt` for an argument type it doesn't know |
| Graphics, geometry and compute pipelines | `d3d12_pipeline_graphics.cpp`, `d3d12_pipeline_compute.cpp` | Get their functions through `D3D12ShaderCache` instead of four copies of initialize → compile → `SM50GetCompiledBitcode` → `newLibrary` → `newFunction` |
| Cache version | `src/dxmt/dxmt_shader_cache.hpp/.cpp` | `kDXMTShaderCacheVersion` becomes the 64-bit FNV-1a of `AIRCONV_VERSION` and `DXMT_VERSION` (from the generated `version.h`, which `dxmt_lib` already depends on) |
| Stale tables | `src/winemetal/unix/cache.c`, `CacheWriter` open | Drops every `cache_%` table but the current version's, then `VACUUM`s if it dropped one |
| SM6 switch | `src/d3d12/d3d12_device.cpp`, `d3d12_dxil_dump.cpp` | `SM6Caps()` = capture mode or `DXMT_D3D12_SM6=1`; the capability answers that read `DXILCaptureMode()` read it instead |

**Milestone 2**

| Unit | Where | Does |
|---|---|---|
| Recording format | fork, new `src/d3d12/d3d12_pipeline_record.hpp/.cpp` | Writes and reads `.pipelines` files (§3.5); shared by the recorder and the replayer |
| Recorder | same file, called from `dxmt::CreateGraphicsPipelineState` / `dxmt::CreateComputePipelineState` | Appends each pipeline description not recorded before, after its creation succeeded |
| Cache identity | fork, `src/util/util_env.hpp/.cpp` | `env::getCacheExeName()`: `DXMT_CACHE_EXE` if set, else `getExeName()`. Used by `ShaderCache`'s path and `InitializeMetalCachePath`, and by the recorder for the file name |
| Replayer | fork, new `src/replay/dxmt_replay.cpp`, a meson executable `dxmt-replay.exe` installed beside the DLLs | Rebuilds every recorded pipeline on all cores (§3.6) |
| Launcher step | MacNeutron, new `Sources/MacNeutronCore/ShaderPrecache.swift`; `Launcher.swift`, `LaunchEnvironment.swift` | Sets the recording folder; replays before `waitforexitandrun` when needed; keeps the stamp (§3.7) |
| Installer | MacNeutron, `DXMTInstaller.swift`, `ToolLayout.swift` | Installs `dxmt-replay.exe` into `Libraries/DXMT/x64/`; `ToolLayout.dxmtReplay` points at it |

### 3.2 Translation cache keys

A key is the store's existing pair of SHA-1 digests.

- **First digest:** SHA-1 of the shader bytecode, as `Sha1HashState::compute` already gives for the pixel shader's name. For the geometry path's two functions, SHA-1 of the vertex bytecode followed by the geometry bytecode.
- **Second digest:**
  - **Reflection:** SHA-1 of the tag `d3d12-reflection`.
  - **Function:** SHA-1 of the tag `d3d12-function`, the function name, and `HashCompileArgs(args)`.

`HashCompileArgs` walks the `next` chain and hashes, for each argument, its `type` and then its contents, following pointers to what they point at:

| Argument | Hashed |
|---|---|
| `SM50_SHADER_COMMON` | `flags`, `metal_version` |
| `SM50_SHADER_ROOT_SIGNATURE` | the `bytecode_length` bytes at `bytecode` (the root signature blob, or the shader's embedded one) |
| `SM50_SHADER_IA_INPUT_LAYOUT` | `index_buffer_format`, `slot_mask`, `num_elements`, then each `SM50_IA_INPUT_ELEMENT` field by field |
| `SM50_SHADER_PSO_PIXEL_SHADER` | `sample_mask`, `dual_source_blending`, `disable_depth_output`, `unorm_output_reg_mask`, `pixel_formats[]` |
| `SM50_SHADER_PSO_GEOMETRY_SHADER` | `strip_topology` |
| any other type | nothing: `HashCompileArgs` returns `nullopt` and the function compiles uncached, as today |

Fields are hashed one by one, never as whole structs, so padding never enters a key.

### 3.3 Translation cache flow

```
CachedShader(bytecode)                  SHA-1 once
  .Reflection()  → cache hit: copy the stored MTL_SHADER_REFLECTION
                 → miss: SM50Initialize, store the reflection, keep the parsed shader
D3D12ShaderCache::Function(shaders, args, name)
  key = (bytecode digest, function digest)      nullopt digest → compile, no store
  → hit: newLibrary(stored metallib) → newFunction(name); a nil library or function is a miss (§4)
  → miss: parse the shaders not parsed yet, SM50Compile (or the geometry pipeline compiles),
          SM50GetCompiledBitcode, store the metallib, newLibrary → newFunction
```

- A pipeline whose shaders all hit never enters airconv: no `SM50Initialize`, no LLVM.
- `ExtractMTLInputLayoutElements` still reads the vertex shader's input signature (it parses the container, not the DXIL), and its output is part of the key.
- The pixel shader's key needs the render target formats `InitializePSO` fills, and `InitializePSO` needs the pixel shader's reflection: `Reflection()` answers it from the cache without parsing.
- The store is `ShaderCache::getInstance(device's WMTMetalVersion)`, the one D3D11 uses: one database per game and Metal version.
- Lookups and stores run on the calling thread, like D3D11's. `// ponytail: one reader connection behind one lock; a connection per thread if the lock shows up in profiles.`
- The geometry path's lazily compiled variants (strip topology × index format) go through the same `Function` call.

### 3.4 Counters

`D3D12ShaderCache` counts function hits, function misses, reflection hits and reflection misses in process-wide atomics. It logs them at info level every 1000 function lookups and when the process exits (`d3d12.dll`'s `DLL_PROCESS_DETACH`), because games and test programs often exit without releasing their device. A process that made no lookups logs nothing:

```
d3d12 shader cache: functions <hits> hit <misses> missed, reflections <hits> hit <misses> missed
```

A function that compiles uncached (`nullopt` key, or the cache disabled) counts as neither.

### 3.5 Recording

**Where.** When `DXMT_PIPELINE_RECORD` holds an absolute Unix path (converted to a Windows path as `DXMT_DXIL_DUMP`'s folder is), the recorder appends to `<that folder>/<getCacheExeName()>.pipelines`, creating the folder and file if needed. Unset, empty or `0`: no recording.

**Format.** An 8-byte magic `DXMTPRC1`, then records. Each record has a header: `uint32 kind`, `uint32 payload size`, `uint64` FNV-1a of the payload, a 20-byte SHA-1 id. The payload follows.

| Kind | Id | Payload |
|---|---|---|
| 1, blob | SHA-1 of the bytes | the bytes: a shader's bytecode or a root signature blob |
| 2, graphics pipeline | SHA-1 of the payload | `D3D12_GRAPHICS_PIPELINE_STATE_DESC` field by field: the root signature's blob id (zero: none, the shader's embedded one); VS, PS and GS blob ids (zero: none); every field of `BlendState`, `SampleMask`, `RasterizerState` and `DepthStencilState`; the input layout (element count, then per element the semantic name's length and bytes, `SemanticIndex`, `Format`, `InputSlot`, `AlignedByteOffset`, `InputSlotClass`, `InstanceDataStepRate`); `IBStripCutValue`, `PrimitiveTopologyType`, `NumRenderTargets`, `RTVFormats[8]`, `DSVFormat`, `SampleDesc`, `NodeMask`, `Flags` |
| 3, compute pipeline | SHA-1 of the payload | root signature blob id, CS blob id, `NodeMask`, `Flags` |

Integers are little-endian; fields are written one by one, never as whole structs, so padding never enters an id. `CachedPSO` is not recorded. Hull, domain and stream output never reach the recorder, because those pipelines fail creation.

**Recorder.**
- On its first use, it reads the file's record headers: it keeps the ids in a set, and truncates the file after the last complete record, dropping the torn tail a killed game leaves. It checks sizes only, not checksums, so a game doesn't pay to hash a large file while it loads.
- After a pipeline's creation succeeds, it serializes the description and takes its id. If the id is new, it appends the blobs the pipeline uses that are new too, then the pipeline record, all in one write.
- Shader blob ids reuse the SHA-1 `CachedShader` computed; a root signature's is computed once, when the root signature is created.
- `// ponytail: one lock and one write per new pipeline; a writer thread if recording shows in the first session's profiles.`
- Recording failures (disk full, no access) are logged once and turn recording off for the process. The pipeline is unaffected.

### 3.6 Replayer

`dxmt-replay.exe <recording>`, run under Wine in the game's prefix:
1. Sets `DXMT_CACHE_EXE` to the recording's file name minus `.pipelines`, and clears `DXMT_PIPELINE_RECORD`. Only then does it load `dxgi.dll` and `d3d12.dll` (`LoadLibrary`), so DXMT resolves the game's translation cache and Metal cache folders.
2. Reads every record, verifying sizes and checksums. A bad or incomplete record is counted and skipped, and so is a pipeline whose blobs are missing.
3. Creates a D3D12 device and one root signature per recorded root signature blob.
4. Creates the pipelines on `std::thread::hardware_concurrency()` threads, which take indices from an atomic counter; each pipeline is released as soon as it exists. A failed creation is counted.
5. Prints a progress line every 10% and a final line, then exits 0; a missing file or no device exits 1:

```
replay: <n> pipelines (<g> graphics, <c> compute), <ok> created, <failed> failed, <bad> bad records, <ms> ms
```

### 3.7 Launcher step

- **Recording on.** `LaunchEnvironment` sets `DXMT_PIPELINE_RECORD=<compatdata>/dxmt-pipelines` when the backend is DXMT with D3D12, unless `MACNEUTRON_PRECACHE=0`.
- **Stamp.** `<compatdata>/dxmt-pipelines/replayed` holds `<ToolLayout.dxmtVersion> <macOS build (sysctl kern.osversion)>`: the builds the recordings were last compiled for.
- **Before `waitforexitandrun` starts the game** (after `prefix.prepare`):
  - If the folder has `*.pipelines` files and the stamp is present but differs from the current builds:
    - Posts a notification ("MacNeutron: preparing shaders for this game").
    - Runs `wine <dxmtReplay> Z:<recording>` for each recording, with the game's environment minus `DXMT_PIPELINE_RECORD`, appending its output to the MacNeutron log.
    - Then writes the current builds into the stamp, whatever the replayer's exit status.
  - Otherwise it does nothing.
- **After the game exits:** if the stamp is missing, writes the current builds. The pipelines of that session were compiled by these builds, so the first session never triggers a needless replay.
- **`run`, `runinprefix` and the path verbs** neither replay nor write the stamp. Steam starts SMITE 2 with `waitforexitandrun` (41 of 41 launches in the MacNeutron log).

### 3.8 Performance rules

- One SHA-1 per shader bytecode per pipeline, reused by the reflection key, the function key and the recorder.
- No copy of a hit's metallib: the `DispatchData` from the store goes to `newLibrary` as is.
- A hit costs two sqlite reads per shader (reflection, function) plus Metal's cached library and pipeline builds.
- After the first session, recording costs a set lookup per pipeline creation.
- The replayer uses every core. It does the same work as the game's own creation calls, so it fills exactly the entries the game will look up.
- Capture mode's per-pipeline costs stay as they are; `DXMT_D3D12_SM6` is how a game runs without them.

### 3.9 What the player sees

- **First launch:** nothing new; recording starts.
- **Later launches:** nothing new, unless DXMT or macOS changed.
- **After an update:** one notification, then the game starts once the replay is done. Steam shows the game as running meanwhile, and Steam's Stop button ends the replay (the launcher's `terminate` kills the prefix's processes).
- `MACNEUTRON_PRECACHE=0` in the game's launch options turns recording and replay off.

## 4. Error handling

- **No translation cache:** `DXMT_SHADER_CACHE=0`, a path that can't be opened or written, or a reader or writer that failed to open. Pipelines compile exactly as today.
- **Bad reflection entry** (size ≠ `sizeof(MTL_SHADER_REFLECTION)`): a miss; the shader is parsed and the entry overwritten.
- **Bad function entry** (Metal refuses the library, or it has no function of that name): warn once per process (`d3d12 shader cache: rejected a cached function, recompiling`), count a miss, compile, overwrite.
- **Failed translation or failed Metal pipeline:** fails the pipeline as today; nothing is stored or recorded.
- **Cache write failure:** logged by `CacheWriter` as today; the pipeline is unaffected.
- **Stale cache versions:** never read; their tables are dropped when the writer opens.
- **Recording:** a torn tail is truncated on the next open. A write failure turns recording off for the process, with one log line. A record the replayer can't read is skipped and counted.
- **Replay:** a crash, a failure exit or a missing `dxmt-replay.exe` is logged. The stamp is still written and the game starts.

## 5. Tests

All in `make dxmt-check` (C++ under Wine) or `make test` (Swift), test-first, compared with D3DMetal where D3DMetal has an answer.

**Harness:** `dxmt/tests/run.sh` and `dxmt/check.sh` point `DXMT_SHADER_CACHE_PATH` at a fresh folder for each run, so no test reads entries left by an earlier build, whose `git describe` a dirty tree shares. Runs that share a cache below share a folder on purpose. `run.sh` also copies `dxmt-replay.exe` with the DLLs.

### 5.1 Milestone 1

**`d3d12_cache`** (new, `dxmt/tests/d3d12_cache.cpp`, with `QuadPipeline`/`Load` from `d3d12_common.hpp`). It draws with a vertex and pixel shader pair and a compute shader, and prints what it reads back. Modes:
- `a`: the pipelines with render target `R32G32B32A32_FLOAT`, input layout A, and root signature A (constant buffer as root parameter 0).
- `b`: the same shaders with render target `R32G32B32A32_UINT`, input layout B (the same element at another offset, with the vertex data laid out to match), and root signature B (the constant buffer as root parameter 1). Each change alone gives other pixels or no pipeline if the wrong function is reused.

`check.sh` runs, on one cache folder:

| Run | Checks |
|---|---|
| 1. `a`, cold | pixels = D3DMetal's `a`; the counter line reports only misses |
| 2. `a`, warm | pixels = D3DMetal's `a`; only hits, no misses |
| 3. `b` | pixels = D3DMetal's `b`; function misses for the changed pipelines (a dropped key field turns this red) |
| 4. `a`, after `sqlite3` overwrote every stored value with one zero byte | pixels = D3DMetal's `a`; misses and the `rejected a cached function` warning |
| 5. `a`, after `sqlite3` added a `cache_1` table | the `cache_1` table is gone afterwards; pixels = D3DMetal's `a` |

`check.sh` also prints, for information only, the time runs 1 and 2 spent creating pipelines. These are `timing` lines the test prints, left out of the D3DMetal comparison.

**Geometry path:** the existing geometry-shader run of `d3d12_triangle` (`triangle2` vertex, pixel and geometry shaders) runs a second time on the same folder: pixels = D3DMetal's, only hits.

**`HashCompileArgs`:** run 3 covers the argument types D3D12 uses today. An unknown type is covered by reading the code: §3.2's table is exhaustive for the fork's compile sites.

**SM6 switch:** `d3d12_clear`, run with `DXMT_D3D12_SM6=1` and no dump folder, prints the capability lines capture mode prints (shader model 6.6, binding tier 3, feature level 12_1, wave ops, 64-bit atomics). Without the switch, check 2's lines (shader model 5.1) are unchanged.

**Existing tests:** every D3D12 and D3D11 test still passes, now through the cache (cold, fresh folder per run).

### 5.2 Milestone 2

`check.sh`, with `DXMT_PIPELINE_RECORD` pointed at a fresh recording folder:

| Run | Checks |
|---|---|
| 6. `d3d12_cache a` with recording, cache folder A | `d3d12_cache.exe.pipelines` exists |
| 7. `a` again with recording, cache folder A | the recording's size is unchanged (no duplicates) |
| 8. `dxmt-replay` of the recording, fresh cache folder B | `replay:` line: the test's graphics and compute counts, all created, 0 failed, 0 bad records |
| 9. `a` on cache folder B, no recording | only hits, no misses; pixels = D3DMetal's `a`. The replay rebuilt exactly what the game looks up |
| 10. The recording truncated by 10 bytes; `dxmt-replay` on a fresh folder | one pipeline fewer, 1 bad record |
| 11. `a` with recording, then `dxmt-replay` | the torn tail was repaired: full counts, 0 bad records |
| 12. `d3d12_triangle` with the geometry shader, recorded; replayed on a fresh folder; run again on it | only hits; pixels = D3DMetal's |

**Swift (`make test`)**, with the existing fake process runner and a temporary folder:
- `LaunchEnvironment` sets `DXMT_PIPELINE_RECORD` for DXMT with D3D12. It doesn't set it with `MACNEUTRON_PRECACHE=0`, with the GPTK backend, or without our D3D12.
- **No recordings:** no replay and no stamp before the game. After the game, the stamp holds the current builds.
- **Recordings but no stamp:** no replay (they were compiled by the current builds, §3.7).
- **Stamp equals the current builds:** no replay.
- **Stamp differs:**
  - `dxmt-replay.exe` runs once per recording, before the game, with `Z:<recording>` and without `DXMT_PIPELINE_RECORD`.
  - A notification is posted and the stamp is rewritten.
  - A failing replayer still leads to the stamp and the game.
- **`run` verb:** no replay.

## 6. Delivery

- Fork commits on `macneutron`, pushed before `dxmt/pins` moves (LGPL).
- MacNeutron: tests, `check.sh`, `run.sh`, the pin, the launcher and installer changes, and `docs/testing/acceptance-dxmt-pipeline-cache.md`. The README gets:
  - pre-caching in the feature list;
  - troubleshooting: `DXMT_SHADER_CACHE=0` disables the translation cache; `MACNEUTRON_PRECACHE=0` disables recording and replay; deleting `$(getconf DARWIN_USER_CACHE_DIR)dxmt/<exe>/shaders_*.db` clears the cache; deleting `<compatdata>/dxmt-pipelines/` clears the recordings.
- SMITE 2's launch options become `/usr/bin/env DXMT_D3D12_SM6=1 %command%`: the user changes them.
- Milestone 1 lands, with its tests green, before milestone 2 starts.

## 7. Acceptance

Manual, recorded in `docs/testing/acceptance-dxmt-pipeline-cache.md`:

1. `make dxmt-check` and `make test` pass.
2. Install: `.build/release/macneutron install-dxmt build/dxmt`.
3. **First launch** of SMITE 2 with `DXMT_D3D12_SM6=1` (no capture mode): lobby, then a practice match of about five minutes. Keep `Hemingway.log`. `<compatdata>/dxmt-pipelines/Hemingway-Win64-Shipping.exe.pipelines` exists and the stamp is written.
4. **Second launch**, the same route and length: no replay in the MacNeutron log. From `Hemingway.log`, the last `LogPSOHitching: Encountered N PSO creation hitches` line and the count of `PSO PRECACHING MISS:` blocks. From `steam-2437170.log`, the `d3d12 shader cache` line.
5. **Simulated update.** Delete SMITE 2's `shaders_*.db` and its `com.apple.metal` folder, and edit the stamp. Launch the same route and length: the notification appears, and the MacNeutron log has the `replay:` line with its time. Then take step 4's numbers again.
6. **Pass:**
   - Step 4's hitch count is well under step 3's and under 150, and step 5's is close to step 4's.
   - The shader cache line shows function hits outnumbering misses in steps 4 and 5.
   - The replay reports 0 failed.
   - The lobby and match render as before, the hedges included.
   - Precaching misses count pipelines Unreal didn't predict and may stay near 119; they are recorded, not judged.
