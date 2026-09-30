# MacNeutron — DXMT Fork, Sub-project 4 (first slice): D3D12 Translation Cache

- **Date:** 2026-09-30
- **Status:** Draft for review
- **Builds on:**
  - `2026-09-28-macneutron-dxmt-fork-design.md`: roadmap §2 item 4 (performance); the fork, `make dxmt`, `make dxmt-check`, capture mode.
  - `2026-09-29-macneutron-dxil-translator-design.md`: DXIL shaders through airconv (`SM50Initialize`/`SM50Compile`).
  - `2026-09-29-macneutron-d3d12-stubs-design.md`: SMITE 2 plays on our DXMT; its acceptance run traced the match glitches to pipeline creation cost.
- **Scope:**
  - **In:** a persistent cache of translated D3D12 shader functions and their reflection, in DXMT's existing per-game sqlite store; a cache version that follows the fork's build; an opt-in switch that reports the SM6 capabilities without capture mode.
  - **Out (later, decided from this slice's measurements):**
    - a Fossilize/DXVK-style state cache that rebuilds whole pipelines in the background at launch (Unreal already replays its own pipeline list; after this slice it would save about 1 ms per pipeline Unreal didn't predict);
    - pre-caching before the first launch;
    - an in-memory cache of Metal functions (Metal's own cache makes a library cost 0.19 ms);
    - `MTLBinaryArchive`;
    - real `GetCachedBlob` / pipeline library contents (D3DMetal returns empty blobs; this cache sits below them).

## 1. Goal

From the second launch on, creating a D3D12 pipeline never runs the DXIL translator for a shader it has translated before, so Unreal's pipeline precaching keeps up and pipelines created mid-match stop stalling the frame.

**Done when** §7 passes:
- every test in §5 failed first and now passes; rendered output matches D3DMetal on cold and warm runs;
- `make dxmt-check` is green;
- SMITE 2's second launch logs far fewer PSO creation hitches than the 150 of the 2026-09-29 run, with the lobby and a match rendering as before.

### Decisions made during brainstorming

| Decision | Choice |
|---|---|
| What is cached | Each translated function (the metallib airconv emits) and each shader's reflection. Metal's side is already cached across launches by Metal's framework cache, which DXMT points at `dxmt/<exe>/com.apple.metal` |
| Where | DXMT's existing sqlite cache (`ShaderCache`, `dxmt/<exe>/shaders_<metal version>.db`), shared with D3D11 |
| Key | Hash of every shader bytecode involved + hash of every compile argument, walked generically; unknown argument types are not cached |
| Version | Hash of `AIRCONV_VERSION` and the build's `git describe`, for D3D11 and D3D12 alike; tables of other versions are dropped |
| Entry validation | A domain tag in each key (D3D12 function / D3D12 reflection) instead of a header in each value; a reflection must be exactly the struct's size; a function must load in Metal and contain its entry point |
| State cache (Fossilize-like) | Not in this slice: Unreal replays its own pipeline list; measure first |
| SM6 capabilities | `DXMT_D3D12_SM6=1` reports them without dumping; capture mode keeps reporting them too. Default capabilities unchanged for other games |

## 2. Evidence (2026-09-30; fork `d048cfa`, M5 Pro)

**Where pipeline creation time goes.** A timed copy of `dxil-translate` over 200 SMITE 2 shaders:

| Step | First run | Second run |
|---|---|---|
| Translation, DXIL → metallib | 828 ms: 85 ms parsing (`SM50Initialize`), 743 ms compiling (`SM50Compile`) | 828 ms: nothing is cached |
| Metal, `newLibrary` | 2304 ms | 37 ms |

Translation costs about 4.1 ms per shader on every launch. Metal's compile is already cached across launches: SMITE 2's `com.apple.metal` folder holds 505 MB, and no `shaders_*.db` exists for it, because only D3D11 uses `ShaderCache`.

**What Unreal logs.** SMITE 2's `Hemingway.log` of the 2026-09-29 run (lobby, then a practice match):
- `LogPSOHitching: Encountered 150 PSO creation hitches so far (145 graphics, 5 compute). 53 of them were precached`: a pipeline Unreal precached still stalled a frame, because precaching hadn't finished it.
- 119 `PSO PRECACHING MISS:` blocks: pipelines Unreal didn't predict, created when first drawn.
- Unreal skips a draw whose pipeline is still being precached (`r.PSOPrecaching 1`): the black hedges of the pass dump.

**Capture mode costs every pipeline.** `DXMT_DXIL_DUMP` is today the only way through Unreal's SM6 check. For every pipeline it hashes each shader byte by byte, checks a file per shader, and appends a line to `pipelines.txt` under one process-wide lock, so Unreal's precaching threads wait on each other.

**Pipeline creation is otherwise parallel.** Nothing in the D3D12 device serializes `CreatePipelineState`; Unreal's precaching threads compile at the same time.

## 3. Design

### 3.1 Units

| Unit | Where (fork) | Does |
|---|---|---|
| `D3D12ShaderCache` | new `src/d3d12/d3d12_shader_cache.hpp/.cpp` | Looks up and stores functions and reflections; counts hits and misses |
| `CachedShader` | same file | One shader stage's bytecode: its SHA-1, its reflection (cached or parsed), the airconv shader parsed only when a function misses |
| `HashCompileArgs` | same file | The variant digest of an airconv argument chain; `nullopt` for an argument type it doesn't know |
| Graphics, geometry and compute pipelines | `d3d12_pipeline_graphics.cpp`, `d3d12_pipeline_compute.cpp` | Get their functions through `D3D12ShaderCache` instead of four copies of initialize → compile → `SM50GetCompiledBitcode` → `newLibrary` → `newFunction` |
| Cache version | `src/dxmt/dxmt_shader_cache.hpp/.cpp` | `kDXMTShaderCacheVersion` becomes the 64-bit FNV-1a of `AIRCONV_VERSION` and `DXMT_VERSION` (from the generated `version.h`, which `dxmt_lib` already depends on) |
| Stale tables | `src/winemetal/unix/cache.c`, `CacheWriter` open | Drops every `cache_%` table but the current version's, then `VACUUM`s if it dropped one |
| SM6 switch | `src/d3d12/d3d12_device.cpp`, `d3d12_dxil_dump.cpp` | `SM6Caps()` = capture mode or `DXMT_D3D12_SM6=1`; the capability answers that read `DXILCaptureMode()` read it instead |

### 3.2 Keys

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

### 3.3 Flow

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

`D3D12ShaderCache` counts function hits, function misses, reflection hits and reflection misses in process-wide atomics. It logs them at info level when a device is released, and every 1000 function lookups (a game may exit without releasing its device):

```
d3d12 shader cache: functions <hits> hit <misses> missed, reflections <hits> hit <misses> missed
```

A function that compiles uncached (`nullopt` key, or the cache disabled) counts as neither.

### 3.5 Performance rules

- One SHA-1 per shader bytecode per pipeline, reused by the reflection and function keys.
- No copy of a hit's metallib: the `DispatchData` from the store goes to `newLibrary` as is.
- A hit costs two sqlite reads per shader (reflection, function) plus Metal's cached library and pipeline builds; nothing in the path allocates in proportion to the shader count.
- Capture mode's per-pipeline costs stay as they are; `DXMT_D3D12_SM6` is how a game runs without them.

## 4. Error handling

- **No cache:** `DXMT_SHADER_CACHE=0`, a path that can't be opened or written, or a reader or writer that failed to open: pipelines compile exactly as today.
- **Bad reflection entry** (size ≠ `sizeof(MTL_SHADER_REFLECTION)`): a miss; the shader is parsed and the entry overwritten.
- **Bad function entry** (Metal refuses the library, or it has no function of that name): warn once per process (`d3d12 shader cache: rejected a cached function, recompiling`), count a miss, compile, overwrite.
- **Failed translation or failed Metal pipeline:** fails the pipeline as today; nothing is stored.
- **Write failure:** logged by `CacheWriter` as today; the pipeline is unaffected.
- **Stale versions:** never read; their tables are dropped when the writer opens.

## 5. Tests

All in `make dxmt-check`, test-first, compared with D3DMetal where D3DMetal has an answer.

**Harness:** `dxmt/tests/run.sh` and `dxmt/check.sh` point `DXMT_SHADER_CACHE_PATH` at a fresh folder for each run, so no test reads entries left by an earlier build, whose `git describe` a dirty tree shares. Runs that share a cache (below) share a folder on purpose.

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

`check.sh` also prints, informational only, the time runs 1 and 2 spent creating pipelines (`timing` lines the test prints, excluded from the D3DMetal comparison).

**Geometry path:** the existing geometry-shader run of `d3d12_triangle` (`triangle2` vertex, pixel and geometry shaders) runs a second time on the same folder: pixels = D3DMetal's, only hits.

**`HashCompileArgs`:** covered by run 3 for the argument types D3D12 uses today; an unknown type is covered by reading the code (§3.2's table is exhaustive for the fork's compile sites).

**SM6 switch:** `d3d12_api`'s caps line run with `DXMT_D3D12_SM6=1` and no dump folder prints FL 12_1 / SM 6.7 / binding tier 3 / wave ops / 64-bit atomics, and writes no `pipelines.txt`; without it, the caps line is unchanged.

**Existing tests:** every D3D12 and D3D11 test still passes, now through the cache (cold, fresh folder per run).

## 6. Delivery

- Fork commits on `macneutron`, pushed before `dxmt/pins` moves (LGPL).
- MacNeutron: tests, `check.sh`, `run.sh`, the pin, `docs/testing/acceptance-dxmt-pipeline-cache.md`, and the README's troubleshooting note that `DXMT_SHADER_CACHE=0` disables the cache and deleting `$(getconf DARWIN_USER_CACHE_DIR)dxmt/<exe>/shaders_*.db` clears it.
- SMITE 2's launch options become `/usr/bin/env DXMT_D3D12_SM6=1 %command%`: the user changes them.

## 7. Acceptance

Manual, recorded in `docs/testing/acceptance-dxmt-pipeline-cache.md`:

1. `make dxmt-check` passes.
2. Install: `.build/release/macneutron install-dxmt build/dxmt`.
3. SMITE 2 with `DXMT_D3D12_SM6=1` (no capture mode), first launch after install: lobby, then a practice match of about five minutes. Keep `Hemingway.log`.
4. Second launch, the same route and length. From `Hemingway.log`: the last `LogPSOHitching: Encountered N PSO creation hitches` line and the count of `PSO PRECACHING MISS:` blocks; from `steam-2437170.log`: the `d3d12 shader cache` line.
5. **Pass:** the second launch's hitch count is well under the first's and under 150; the shader cache line shows function hits outnumbering misses; the lobby and match render as before, the hedges included. Precaching misses count pipelines Unreal didn't predict and may stay near 119; they are recorded, not judged.
