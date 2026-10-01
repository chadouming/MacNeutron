# DXMT Fork, Sub-project 4 (first slice: D3D12 Shader Pre-Caching) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A D3D12 game on our DXMT never translates a shader twice, and after a DXMT or macOS update MacNeutron rebuilds every pipeline the game ever created before it starts, as Steam does for Vulkan games.

**Architecture:**
- **Milestone 1 (Tasks 1–3):** the translation cache.
  - Translated functions and their reflection go into DXMT's existing sqlite store (`ShaderCache`).
  - The keys are the shader's SHA-1 plus a hash of every airconv compile argument.
  - A cache hit never enters airconv.
- **Milestone 2 (Tasks 4–6):** record and replay.
  - `d3d12.dll` appends each new pipeline description to a `.pipelines` file per game executable.
  - `dxmt-replay.exe` rebuilds a recording on every core.
  - MacNeutron's launcher runs the replayer before `waitforexitandrun` when the DXMT build or the macOS build changed.
- **Task 7:** the docs, and the acceptance run.

**Tech Stack:**
- Fork: C++20, and Objective-C for `winemetal`'s unix side and its sqlite store.
- Every Windows binary is built with llvm-mingw Clang; DXC under Wine compiles the test shaders.
- MacNeutron: Swift (swift-testing), and POSIX sh for `check.sh`.

**Spec:** `docs/superpowers/specs/2026-09-30-macneutron-pipeline-cache-design.md`

## Global Constraints

- **Fork:** `github.com/chadouming/dxmt`, branch `macneutron`.
  - Never send anything upstream (DXMT refuses AI-authored contributions).
  - Before editing, run `git -C build/dxmt-src/dxmt switch macneutron`: `build.sh` leaves the clone detached at the pin, and so does every `make dxmt-check`.
  - To land fork work: commit it, `git -C build/dxmt-src/dxmt push origin macneutron`, then write the new head into `dxmt/pins` (`DXMT_COMMIT=`). `make dxmt-check` builds the pinned commit only; uncommitted fork changes make `build.sh` stop.
- **Commit trailer:** every fork and MacNeutron commit message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **New fork files** carry the LGPL-2.1+ notice of the existing files, with `Copyright 2026 MacNeutron contributors`.
- **Reference:** D3DMetal on the same Mac, GPTK imported. `d3d12_cache`'s `cache` lines must equal D3DMetal's. The counter, `timing` and `replay:` lines are ours only.
- **Dev loop:** `sh dxmt/tests/run.sh <test> [args]`. It rebuilds the fork's working tree, installs it into `check.sh`'s "ours" clone, and runs the test on our DXMT and on D3DMetal. Extra variables go in `RUN_ENV="A=1 B=2"`. After a Swift change, run `make build` first: `run.sh` installs with `.build/release/macneutron`.
- **Full check:** `make dxmt-check > "$W/check-tN.log" 2>&1`, where `W=.superpowers/sdd/2026-09-30-macneutron-pipeline-cache` is the plan's git-ignored workspace. Read its `FAIL` lines and its last line. Swift: `swift test 2>&1 | tail -5`.
- **Performance rules (spec §3.8):**
  - one SHA-1 per shader bytecode per pipeline, reused by the reflection key, the function key and the recorder;
  - a hit's metallib goes from the store to `newLibrary` without a copy;
  - after the first session, recording costs a set lookup per pipeline creation;
  - the replayer uses every core.
- **Deliberate ceilings:** mark them with `// ponytail:` comments naming the upgrade path. There are two: the store's single reader connection behind one lock, and the recorder's one lock with one write per new pipeline.
- **Privacy and licensing:**
  - SMITE 2's captured files (`~/dxil-smite2`) never enter git;
  - never commit SteamIDs or persona names;
  - never edit Steam's config: the user changes launch options themselves.
- **Choices:** pick the default option when a question comes up.
- **Out of scope (spec):**
  - sharing recordings between Macs;
  - recording D3D11 games;
  - an in-process pipeline cache;
  - `MTLBinaryArchive`;
  - an in-memory function cache;
  - a skip button;
  - `GetCachedBlob` contents.

## Review Focus

- **Pipelines created on many threads at once**, as Unreal's precaching does. The recording is whole: no torn or duplicated record, and every pipeline replays. Test: `d3d12_dxil_exec threads` is recorded, then replayed with `0 failed, 0 bad records` (Task 5).
- **A pipeline with no `pRootSignature`**, whose root signature is embedded in its shader. The cache keys it by that shader's root signature, the recorder writes no root id, and the replayer passes a null root signature. Test: `d3d12_cache`'s compute pipeline is always created this way (Tasks 3 and 5).
- **An unwritable recording folder.** The game draws the same, and one log line says recording is off. Test: `rec-unwritable` (Task 4).
- **A recorded pipeline the current DXMT can't rebuild**, as after an update that drops support. The replayer counts it failed, goes on, and exits 0. Test: a hand-built recording with a junk shader (Task 5).
- **A foreign file where a recording should be:**
  - the recorder starts it over (Task 4);
  - the replayer refuses it with `replay: not a recording` and exit 1 (Task 5);
  - the launcher still writes the stamp and starts the game (Task 6, `aFailedReplayStillStartsTheGame`).

---

## File Structure

**Fork (`build/dxmt-src/dxmt/src`):**
- `dxmt/dxmt_shader_cache.hpp/.cpp`:
  - `ShaderCacheVersion()` replaces `kDXMTShaderCacheVersion` (Task 1);
  - the path uses `env::getCacheExeName()` (Task 4).
- `winemetal/unix/cache.c`: `CacheWriter` drops other versions' tables (Task 1).
- `d3d12/d3d12_dxil_dump.hpp/.cpp`: `SM6Caps()` (Task 2).
- `d3d12/d3d12_device.cpp`: capability answers read `SM6Caps()` (Task 2).
- `winemetal/winemetal.h`, `winemetal_thunks.h`, `winemetal_thunks.c`, `unix/winemetal_unix.c`, `Metal.hpp`: unix call 149, `DispatchData_copyBytes` (Task 3).
- `d3d12/d3d12_shader_cache.hpp/.cpp` (new, Task 3): `CachedShader`, `HashCompileArgs`, `CompileFunction`, `LogShaderCacheCounters`.
- `d3d12/d3d12_pipeline_graphics.cpp`, `d3d12_pipeline_compute.cpp`:
  - functions through `CompileFunction` (Task 3);
  - `Record` hooks (Task 4).
- `d3d12/d3d12_device.hpp`:
  - `InitializeShader` removed (Task 3);
  - `MTLD3D12RootSignature::BlobDigest` (Task 4).
- `d3d12/d3d12.cpp`: counters at `DLL_PROCESS_DETACH` (Task 3).
- `d3d12/d3d12_pipeline_record.hpp/.cpp` (new, Task 4): the `.pipelines` format, the recorder and the reader.
- `d3d12/d3d12_root_signature.cpp`: `BlobDigest` set at creation (Task 4).
- `d3d12/d3d12_pipeline.hpp`: `RootBlob` (Task 4).
- `util/util_env.hpp/.cpp`: `getCacheExeName()` (Task 4).
- `dxgi/dxgi.cpp`: Metal cache path uses `getCacheExeName()` (Task 4).
- `replay/dxmt_replay.cpp`, `replay/meson.build` (new, Task 5); `meson.build` gains `subdir('replay')` (Task 5).
- `d3d12/meson.build`: new sources (Tasks 3, 4).

**MacNeutron:**
- `dxmt/check.sh`: a fresh cache per run (Task 1); new sections in Tasks 1–6.
- `dxmt/tests/run.sh`: a fresh cache, the counter and `replay:` lines, and copying the replayer (Tasks 1, 3, 5).
- `dxmt/tests/shaders/cache.hlsl`, `compile.sh` and three `.dxil` files (Task 3).
- `dxmt/tests/d3d12_cache.cpp` (new, Task 3); `Makefile` (Task 3).
- `dxmt/build.sh`: stages `dxmt-replay.exe` (Task 5).
- `Sources/MacNeutronCore/DXMTInstaller.swift`, `ToolLayout.swift` (Task 5).
- `Sources/MacNeutronCore/ShaderPrecache.swift` (new), `LaunchEnvironment.swift`, `Launcher.swift` (Task 6).
- `Tests/MacNeutronCoreTests/Support.swift`, `DXMTInstallerTests.swift` (Task 5); `ShaderPrecacheTests.swift` (new), `LaunchEnvironmentTests.swift` (Task 6).
- `README.md`, `docs/testing/acceptance-dxmt-pipeline-cache.md` (Task 7).

---

## Milestone 1: the translation cache

### Task 1: A fresh cache per test run; the cache version follows the build

**Files:**
- Modify: `dxmt/check.sh` (the `run` function; a new check after check 1)
- Modify: `dxmt/tests/run.sh`
- Modify: `build/dxmt-src/dxmt/src/dxmt/dxmt_shader_cache.hpp:8`, `dxmt_shader_cache.cpp`
- Modify: `build/dxmt-src/dxmt/src/winemetal/unix/cache.c` (`CacheWriter`'s `initWithPath:version:`)

**Interfaces:**
- Produces:
  - `uint64_t dxmt::ShaderCacheVersion()`;
  - `check.sh`'s `run` reads `CACHE`: when set, runs share that folder, and when unset each run gets `$WORK/cache/<name>`.

- [ ] **Step 1: Give every run its own cache folder, and write the failing version check**

In `dxmt/check.sh`, replace the first line of `run`'s `env` command and its continuation:

```sh
  env STEAM_COMPAT_DATA_PATH="$WORK/compat/$tool" SteamAppId=0 MACNEUTRON_GRAPHICS="$backend" \
      MACNEUTRON_NO_STEAM_BRIDGE=1 MACNEUTRON_NO_METALFX=1 \
```

with:

```sh
  # A fresh translation cache folder per run unless CACHE names a shared one: a dirty build shares its
  # `git describe`, so no run may read entries an earlier build left.
  env STEAM_COMPAT_DATA_PATH="$WORK/compat/$tool" SteamAppId=0 MACNEUTRON_GRAPHICS="$backend" \
      MACNEUTRON_NO_STEAM_BRIDGE=1 MACNEUTRON_NO_METALFX=1 DXMT_SHADER_CACHE_PATH="${CACHE:-$WORK/cache/$name}" \
```

After the line `expect "the D3D11 game ran our d3d11.dll" \` and its continuation line, add:

```sh
# 1b. The translation cache's table is named by the build (shader pre-caching spec §3.1): no table of
#     AIRCONV_VERSION alone (26), and a table another build left is dropped when the cache opens.
CACHE="$WORK/cache/version"
run ours version1 dxmt "$LOOP" 320 240 0 0 10 0
db=$(ls "$CACHE"/shaders_*.db 2> /dev/null | head -1)
expect "D3D11 opens the translation cache" "$([ -n "$db" ] && echo yes || echo no)" yes
expect "its table is named by the build, not AIRCONV_VERSION alone" \
  "$(sqlite3 "$db" "SELECT count(*) FROM sqlite_master WHERE name = 'cache_26'" 2> /dev/null)" 0
sqlite3 "$db" "CREATE TABLE cache_1 (key BLOB PRIMARY KEY, value BLOB NOT NULL);"
run ours version2 dxmt "$LOOP" 320 240 0 0 10 0
expect "another build's table is dropped when the cache opens" \
  "$(sqlite3 "$db" "SELECT count(*) FROM sqlite_master WHERE name = 'cache_1'" 2> /dev/null)" 0
unset CACHE
```

In `dxmt/tests/run.sh`, after the `make -C "$ROOT" -s dxmt-tests > /dev/null` line, add:

```sh
CACHE_DIR="$WORK/run-cache"; rm -rf "$CACHE_DIR"  # a fresh translation cache per invocation (RUN_ENV may override)
```

and in its `env` line, put `DXMT_SHADER_CACHE_PATH="$CACHE_DIR"` before `${RUN_ENV:-}`:

```sh
      MACNEUTRON_NO_STEAM_BRIDGE=1 MACNEUTRON_NO_METALFX=1 DXMT_SHADER_CACHE_PATH="$CACHE_DIR" ${RUN_ENV:-} \
```

- [ ] **Step 2: Run the check to see the version checks fail**

Run: `make dxmt-check > "$W/check-t1-red.log" 2>&1; grep -E '^(FAIL|dxmt-check)' "$W/check-t1-red.log"`

Expected: `FAIL its table is named by the build, not AIRCONV_VERSION alone: got [1], want [0]` and `FAIL another build's table is dropped when the cache opens: got [1], want [0]`, and no other `FAIL`.

- [ ] **Step 3: Version the table by the build**

Run `git -C build/dxmt-src/dxmt switch macneutron`. In `src/dxmt/dxmt_shader_cache.hpp`, replace `constexpr int kDXMTShaderCacheVersion = AIRCONV_VERSION;` with:

```cpp
// The cache table's version: airconv's and the fork build's (`git describe`), so a DXMT update never reads another
// build's translations. (MacNeutron)
uint64_t ShaderCacheVersion();
```

In `src/dxmt/dxmt_shader_cache.cpp`, add `#include <version.h>` after the existing includes. Add this before `ShaderCache &ShaderCache::getInstance`:

```cpp
uint64_t
ShaderCacheVersion() {
  uint64_t hash = 0xcbf29ce484222325ull; // FNV-1a
  for (const char *p = DXMT_VERSION; *p; p++)
    hash = (hash ^ (uint8_t)*p) * 0x100000001b3ull;
  for (int i = 0; i < 4; i++)
    hash = (hash ^ (uint8_t)((uint32_t)AIRCONV_VERSION >> (8 * i))) * 0x100000001b3ull;
  return hash;
}
```

Then replace both `kDXMTShaderCacheVersion` arguments with `ShaderCacheVersion()`.

In `src/winemetal/unix/cache.c`, in `CacheWriter`'s `initWithPath:version:`, insert between the `CREATE TABLE` block (ending `sqlite3_free(errMsg);\n    }`) and `flock(fd, LOCK_UN);`:

```objc
    // MacNeutron: drop the tables other builds left (ShaderCacheVersion), then give their space back.
    @autoreleasepool {
      NSMutableArray<NSString *> *stale = [NSMutableArray array];
      sqlite3_stmt *list = NULL;
      if (sqlite3_prepare_v2(_db, "SELECT name FROM sqlite_master WHERE type = 'table' AND name GLOB 'cache_*';", -1,
                             &list, NULL) == SQLITE_OK) {
        while (sqlite3_step(list) == SQLITE_ROW) {
          NSString *name = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(list, 0)];
          if (![name isEqualToString:tableName])
            [stale addObject:name];
        }
        sqlite3_finalize(list);
      }
      for (NSString *name in stale)
        sqlite3_exec(_db, [NSString stringWithFormat:@"DROP TABLE \"%@\";", name].UTF8String, NULL, NULL, NULL);
      if (stale.count)
        sqlite3_exec(_db, "VACUUM;", NULL, NULL, NULL);
    }
```

- [ ] **Step 4: Land the fork change and run the full check**

```bash
git -C build/dxmt-src/dxmt add src/dxmt/dxmt_shader_cache.hpp src/dxmt/dxmt_shader_cache.cpp src/winemetal/unix/cache.c
git -C build/dxmt-src/dxmt commit -m "dxmt: version the shader cache by the build; drop other builds' tables

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git -C build/dxmt-src/dxmt push origin macneutron
sed -i '' "s/^DXMT_COMMIT=.*/DXMT_COMMIT=$(git -C build/dxmt-src/dxmt rev-parse HEAD)/" dxmt/pins
make dxmt-check > "$W/check-t1.log" 2>&1; grep -E '^(FAIL|dxmt-check)' "$W/check-t1.log"
```

Expected: `dxmt-check: all passed`, no `FAIL`.

- [ ] **Step 5: Commit**

```bash
git add dxmt/check.sh dxmt/tests/run.sh dxmt/pins
git commit -m "test(dxmt): a fresh translation cache per run; the cache version follows the build

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `DXMT_D3D12_SM6=1` reports the SM6 capabilities without capture mode

**Files:**
- Modify: `build/dxmt-src/dxmt/src/d3d12/d3d12_dxil_dump.hpp`, `d3d12_dxil_dump.cpp`
- Modify: `build/dxmt-src/dxmt/src/d3d12/d3d12_device.cpp` (the nine `DXILCaptureMode()` calls in `CheckFeatureSupport`)
- Modify: `dxmt/check.sh` (section 3)

**Interfaces:**
- Produces: `bool dxmt::SM6Caps()`, true in capture mode or with `DXMT_D3D12_SM6=1`.

- [ ] **Step 1: Write the failing check**

In `dxmt/check.sh`, after the two `expect "capture mode reports ..."` checks (the `clear-capture` run), add:

```sh
# DXMT_D3D12_SM6=1 reports the same without capture mode (shader pre-caching spec §3.1): Unreal 5 games play with it.
export DXMT_D3D12_SM6=1
run ours clear-sm6 dxmt "$TESTS/d3d12_clear.exe" 10
unset DXMT_D3D12_SM6
expect "DXMT_D3D12_SM6 reports shader model 6.6 and binding tier 3" \
  "$(grep -cE '^(shader model 0x66 |resource binding tier 3$)' "$WORK/clear-sm6.txt" || true)" 2
expect "DXMT_D3D12_SM6 reports feature level 12_1, wave ops and 64-bit atomics" \
  "$(grep -c '^feature level 0xc100, wave ops 1, atomic64 1$' "$WORK/clear-sm6.txt" || true)" 1
```

- [ ] **Step 2: Run it to see it fail**

Run: `sh dxmt/tests/run.sh d3d12_clear 10` with `RUN_ENV=DXMT_D3D12_SM6=1` (that is, `RUN_ENV=DXMT_D3D12_SM6=1 sh dxmt/tests/run.sh d3d12_clear 10`).

Expected: the `dxmt:` lines show `shader model 0x51` and `feature level 0xb100, wave ops 0, atomic64 0`, not 6.6 and 12_1.

- [ ] **Step 3: Implement**

In `src/d3d12/d3d12_dxil_dump.hpp`, after `bool DXILCaptureMode();`, add:

```cpp
// Report what Shader Model 6 games check for (feature level 12_1, SM 6.7, binding tier 3, wave ops, 64-bit atomics):
// in capture mode, or with DXMT_D3D12_SM6=1. (MacNeutron)
bool SM6Caps();
```

In `src/d3d12/d3d12_dxil_dump.cpp`, after `DXILCaptureMode()`'s definition, add:

```cpp
bool SM6Caps() {
  static const bool on = DXILCaptureMode() || env::getEnvVar("DXMT_D3D12_SM6") == "1";
  return on;
}
```

Then:

```bash
sed -i '' 's/DXILCaptureMode()/SM6Caps()/g' build/dxmt-src/dxmt/src/d3d12/d3d12_device.cpp
grep -c 'SM6Caps()' build/dxmt-src/dxmt/src/d3d12/d3d12_device.cpp
```

Expected: `9`. Every `DXILCaptureMode()` call in `d3d12_device.cpp` is a capability answer (lines 473, 505, 516, 560–562, 574, 575).

- [ ] **Step 4: Run it to see it pass**

Run: `RUN_ENV=DXMT_D3D12_SM6=1 sh dxmt/tests/run.sh d3d12_clear 10`

Expected: `dxmt: shader model 0x66 …`, `dxmt: resource binding tier 3` and `dxmt: feature level 0xc100, wave ops 1, atomic64 1`.

- [ ] **Step 5: Land, run the full check, commit**

```bash
git -C build/dxmt-src/dxmt add src/d3d12/d3d12_dxil_dump.hpp src/d3d12/d3d12_dxil_dump.cpp src/d3d12/d3d12_device.cpp
git -C build/dxmt-src/dxmt commit -m "d3d12: DXMT_D3D12_SM6=1 reports the SM6 capabilities without capture mode

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git -C build/dxmt-src/dxmt push origin macneutron
sed -i '' "s/^DXMT_COMMIT=.*/DXMT_COMMIT=$(git -C build/dxmt-src/dxmt rev-parse HEAD)/" dxmt/pins
make dxmt-check > "$W/check-t2.log" 2>&1; grep -E '^(FAIL|dxmt-check)' "$W/check-t2.log"
git add dxmt/check.sh dxmt/pins
git commit -m "test(dxmt): DXMT_D3D12_SM6 reports the SM6 capabilities without capture mode

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Expected from the check: `dxmt-check: all passed`, no `FAIL`.

---

### Task 3: The D3D12 translation cache

**Files:**
- Create: `dxmt/tests/shaders/cache.hlsl`, and `cache.vs.dxil`, `cache.ps.dxil`, `cache.cs.dxil` (compiled)
- Modify: `dxmt/tests/shaders/compile.sh`
- Create: `dxmt/tests/d3d12_cache.cpp`
- Modify: `Makefile` (`dxmt-tests`), `dxmt/check.sh` (a new section 7; check 6's shader count), `dxmt/tests/run.sh` (its output filter)
- Modify: `build/dxmt-src/dxmt/src/winemetal/winemetal.h`, `winemetal_thunks.h`, `winemetal_thunks.c`, `unix/winemetal_unix.c`, `Metal.hpp`
- Create: `build/dxmt-src/dxmt/src/d3d12/d3d12_shader_cache.hpp`, `d3d12_shader_cache.cpp`
- Modify: `build/dxmt-src/dxmt/src/d3d12/meson.build`, `d3d12_pipeline_graphics.cpp`, `d3d12_pipeline_compute.cpp`, `d3d12_device.hpp:157-158`, `d3d12.cpp` (`DllMain`)

**Interfaces:**
- Consumes: `ShaderCache::getInstance(WMTMetalVersion)` with `getReader()`/`getWriter()` (existing); `check.sh`'s `CACHE` (Task 1).
- Produces:
  - `uint64_t WMT::DispatchData::copyBytes(void *buffer, uint64_t capacity)`, which returns the data's full size;
  - `class dxmt::CachedShader` with `Initialize(const D3D12_SHADER_BYTECODE &)`, `Keep()`, `Reflection(MTL_SHADER_REFLECTION *)`, `Parse(sm50_shader_t *)` and `const Sha1Digest &digest() const`;
  - `std::optional<Sha1Digest> HashCompileArgs(const SM50_SHADER_COMPILATION_ARGUMENT_DATA *)`;
  - `enum class FunctionKind { Shader, GeometryVertex, GeometryMesh }`;
  - `HRESULT CompileFunction(WMT::Device, FunctionKind, CachedShader &first, CachedShader *second, SM50_SHADER_COMPILATION_ARGUMENT_DATA *args, const char *name, const char *stage, WMT::Reference<WMT::Function> &)`;
  - `void LogShaderCacheCounters()`;
  - the log line `d3d12 shader cache: functions <h> hit <m> missed, reflections <h> hit <m> missed`;
  - `d3d12_cache.exe <vs> <ps> <cs> <a|rt|layout|root>` and its `cache …` / `timing …` lines;
  - in `check.sh`: `cachetest <name> <mode>`, `counters <name>` and `drawn <name>`.

- [ ] **Step 1: Write the test shader and compile it**

Create `dxmt/tests/shaders/cache.hlsl`:

```hlsl
// The translation cache test (d3d12_cache): a quad from a vertex buffer, coloured from a root CBV, and a compute shader
// that carries its own root signature. A different render target format, input layout or root signature changes the
// translated functions.
cbuffer Draw : register(b0) { float4 color; };
float4 vsmain(float2 pos : POSITION) : SV_Position { return float4(pos, 0.5, 1); }
float4 psmain(float4 pos : SV_Position) : SV_Target { return color; }
RWStructuredBuffer<float> data : register(u0);
[RootSignature("UAV(u0)")]
[numthreads(64, 1, 1)]
void csmain(uint3 id : SV_DispatchThreadID) { data[id.x] = data[id.x] * 2 + 1; }
```

In `dxmt/tests/shaders/compile.sh`, after `dxc -T cs_6_0 -E main -Fo null.cs.dxil null.hlsl`, add:

```sh
dxc -T vs_6_6 -E vsmain -Fo cache.vs.dxil cache.hlsl
dxc -T ps_6_6 -E psmain -Fo cache.ps.dxil cache.hlsl
dxc -T cs_6_6 -E csmain -Fo cache.cs.dxil cache.hlsl
```

Then compile, and restore the already-committed shaders (only the three new ones should change):

```bash
sh dxmt/tests/shaders/compile.sh > /dev/null
git checkout -- 'dxmt/tests/shaders/*.dxil' 'dxmt/tests/dxil/*.dxil'
ls dxmt/tests/shaders/cache.*.dxil
```

Expected: `cache.cs.dxil cache.ps.dxil cache.vs.dxil`.

- [ ] **Step 2: Write the test program**

Create `dxmt/tests/d3d12_cache.cpp`:

```cpp
// The D3D12 translation cache (shader pre-caching spec §5.1), drawn offscreen through D3D12:
//   d3d12_cache.exe <vs.dxil> <ps.dxil> <cs.dxil> <a|rt|layout|root>   (shaders/cache.hlsl)
// Mode a: a quad over the left half of a 32x32 R32G32B32A32_FLOAT target, from a vertex buffer (POSITION at offset
// 0), coloured from a root CBV (root parameter 0); and csmain over 64 floats, with the root signature embedded in it.
// Each other mode changes one thing that a reused translated function would get wrong:
//   rt      an R16G16B16A16_FLOAT target;
//   layout  POSITION at offset 8 of 16-byte vertices, whose first 8 bytes would put the quad on the right half;
//   root    a root constant first, so the CBV is root parameter 1.
// Prints "cache <mode> ok <texel (8,16)> <texel (24,16)> <data[0]> <data[1]> <data[63]>", texels as the target's bytes
// in hex, then "timing <ms creating the two pipelines>". check.sh compares the cache line with D3DMetal's.
#include "d3d12_common.hpp"
#include <string>

int main(int argc, char **argv) {
    if (argc != 5) { printf("usage: d3d12_cache.exe <vs.dxil> <ps.dxil> <cs.dxil> <a|rt|layout|root>\n"); return 2; }
    std::vector<char> vs = Load(argv[1]), ps = Load(argv[2]), cs = Load(argv[3]);
    if (vs.empty() || ps.empty() || cs.empty()) { printf("can't read the shaders\n"); return 1; }
    const std::string mode = argv[4];
    const bool rt = mode == "rt", layout = mode == "layout", rootmode = mode == "root";
    if (mode != "a" && !rt && !layout && !rootmode) { printf("unknown mode %s\n", argv[4]); return 2; }
    const UINT size = 32, texel = rt ? 8 : 16, pitch = size * texel;  // 256 or 512: both 256-aligned
    const DXGI_FORMAT format = rt ? DXGI_FORMAT_R16G16B16A16_FLOAT : DXGI_FORMAT_R32G32B32A32_FLOAT;
    Gpu gpu;

    D3D12_ROOT_PARAMETER params[2] = {};
    params[0].ParameterType = D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS;
    params[0].Constants = {1, 0, 1};  // b1, one value; no shader reads it
    params[1].ParameterType = D3D12_ROOT_PARAMETER_TYPE_CBV;  // b0
    D3D12_ROOT_SIGNATURE_DESC rd = {};
    rd.NumParameters = rootmode ? 2 : 1;
    rd.pParameters = rootmode ? params : &params[1];
    rd.Flags = D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT;
    ID3D12RootSignature *root = gpu.RootSignature(rd), *croot;
    CHECK(gpu.device->CreateRootSignature(0, cs.data(), cs.size(), __uuidof(ID3D12RootSignature), (void **)&croot));

    D3D12_INPUT_ELEMENT_DESC element = {"POSITION", 0, DXGI_FORMAT_R32G32_FLOAT, 0, layout ? 8u : 0u,
                                        D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0};
    D3D12_GRAPHICS_PIPELINE_STATE_DESC gd = {};
    gd.pRootSignature = root;
    gd.VS = {vs.data(), vs.size()};
    gd.PS = {ps.data(), ps.size()};
    gd.InputLayout = {&element, 1};
    gd.BlendState.RenderTarget[0].RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
    gd.SampleMask = UINT_MAX;
    gd.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID;
    gd.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
    gd.RasterizerState.DepthClipEnable = TRUE;
    gd.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    gd.NumRenderTargets = 1;
    gd.RTVFormats[0] = format;
    gd.SampleDesc.Count = 1;
    D3D12_COMPUTE_PIPELINE_STATE_DESC cd = {};
    cd.CS = {cs.data(), cs.size()};  // no pRootSignature: the one embedded in cs.dxil
    LARGE_INTEGER frequency, start, end;
    QueryPerformanceFrequency(&frequency);
    QueryPerformanceCounter(&start);
    ID3D12PipelineState *pso, *cpso;
    CHECK(gpu.device->CreateGraphicsPipelineState(&gd, __uuidof(ID3D12PipelineState), (void **)&pso));
    CHECK(gpu.device->CreateComputePipelineState(&cd, __uuidof(ID3D12PipelineState), (void **)&cpso));
    QueryPerformanceCounter(&end);

    // The left half of the target; layout mode also stores the right half where offset 0 would read.
    const float left[6][2] = {{-1, -1}, {0, -1}, {-1, 1}, {-1, 1}, {0, -1}, {0, 1}};
    float wide[6][4];
    for (int i = 0; i < 6; i++) {
        wide[i][0] = left[i][0] + 1; wide[i][1] = left[i][1];
        wide[i][2] = left[i][0]; wide[i][3] = left[i][1];
    }
    const void *vdata = layout ? (const void *)wide : (const void *)left;
    const UINT vsize = layout ? sizeof wide : sizeof left;
    const float color[64] = {0.25f, 0.5f, 0.75f, 1};  // 256 bytes, a CBV's unit
    float values[64];
    for (int i = 0; i < 64; i++) values[i] = (float)i;
    ID3D12Resource *vbuf = gpu.Buffer(D3D12_HEAP_TYPE_UPLOAD, vsize, D3D12_RESOURCE_STATE_GENERIC_READ);
    ID3D12Resource *cbuf = gpu.Buffer(D3D12_HEAP_TYPE_UPLOAD, sizeof color, D3D12_RESOURCE_STATE_GENERIC_READ);
    ID3D12Resource *upload = gpu.Buffer(D3D12_HEAP_TYPE_UPLOAD, sizeof values, D3D12_RESOURCE_STATE_GENERIC_READ);
    void *p; D3D12_RANGE none = {0, 0};
    CHECK(vbuf->Map(0, &none, &p)); memcpy(p, vdata, vsize); vbuf->Unmap(0, nullptr);
    CHECK(cbuf->Map(0, &none, &p)); memcpy(p, color, sizeof color); cbuf->Unmap(0, nullptr);
    CHECK(upload->Map(0, &none, &p)); memcpy(p, values, sizeof values); upload->Unmap(0, nullptr);
    ID3D12Resource *data = gpu.Buffer(D3D12_HEAP_TYPE_DEFAULT, sizeof values, D3D12_RESOURCE_STATE_COPY_DEST,
                                      D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    ID3D12Resource *target = gpu.Texture(Tex2D(size, size, format, 1, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET),
                                         D3D12_RESOURCE_STATE_RENDER_TARGET);
    ID3D12Resource *pixels = gpu.Buffer(D3D12_HEAP_TYPE_READBACK, pitch * size, D3D12_RESOURCE_STATE_COPY_DEST);
    ID3D12Resource *result = gpu.Buffer(D3D12_HEAP_TYPE_READBACK, sizeof values, D3D12_RESOURCE_STATE_COPY_DEST);
    ID3D12DescriptorHeap *rtv_heap;
    D3D12_DESCRIPTOR_HEAP_DESC hd = {D3D12_DESCRIPTOR_HEAP_TYPE_RTV, 1};
    CHECK(gpu.device->CreateDescriptorHeap(&hd, __uuidof(ID3D12DescriptorHeap), (void **)&rtv_heap));
    D3D12_CPU_DESCRIPTOR_HANDLE rtv = rtv_heap->GetCPUDescriptorHandleForHeapStart();
    gpu.device->CreateRenderTargetView(target, nullptr, rtv);

    ID3D12GraphicsCommandList *list = gpu.list;
    const float clear[4] = {0, 0, 0, 0};
    D3D12_VIEWPORT viewport = {0, 0, (float)size, (float)size, 0, 1};
    D3D12_RECT scissor = {0, 0, (LONG)size, (LONG)size};
    D3D12_VERTEX_BUFFER_VIEW vbv = {vbuf->GetGPUVirtualAddress(), vsize, layout ? 16u : 8u};
    list->ClearRenderTargetView(rtv, clear, 0, nullptr);
    list->OMSetRenderTargets(1, &rtv, FALSE, nullptr);
    list->RSSetViewports(1, &viewport);
    list->RSSetScissorRects(1, &scissor);
    list->SetGraphicsRootSignature(root);
    if (rootmode) list->SetGraphicsRoot32BitConstant(0, 0x3f800000, 0);  // 1.0f
    list->SetGraphicsRootConstantBufferView(rootmode ? 1 : 0, cbuf->GetGPUVirtualAddress());
    list->SetPipelineState(pso);
    list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    list->IASetVertexBuffers(0, 1, &vbv);
    list->DrawInstanced(6, 1, 0, 0);
    gpu.Barrier(target, D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_COPY_SOURCE);
    D3D12_TEXTURE_COPY_LOCATION from = {target, D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX}; from.SubresourceIndex = 0;
    D3D12_TEXTURE_COPY_LOCATION to = {pixels, D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT};
    to.PlacedFootprint.Footprint = {format, size, size, 1, pitch};
    list->CopyTextureRegion(&to, 0, 0, 0, &from, nullptr);
    list->CopyBufferRegion(data, 0, upload, 0, sizeof values);
    gpu.Barrier(data, D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    list->SetComputeRootSignature(croot);
    list->SetComputeRootUnorderedAccessView(0, data->GetGPUVirtualAddress());
    list->SetPipelineState(cpso);
    list->Dispatch(1, 1, 1);
    gpu.Barrier(data, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_COPY_SOURCE);
    list->CopyBufferRegion(result, 0, data, 0, sizeof values);
    gpu.Submit();

    uint8_t *px; float *out;
    D3D12_RANGE whole = {0, pitch * size}, all = {0, sizeof values};
    CHECK(pixels->Map(0, &whole, (void **)&px));
    CHECK(result->Map(0, &all, (void **)&out));
    auto hex = [&](UINT x, UINT y) {
        std::string s; char b[3];
        for (UINT i = 0; i < texel; i++) { snprintf(b, sizeof b, "%02x", px[y * pitch + x * texel + i]); s += b; }
        return s;
    };
    printf("cache %s ok %s %s %g %g %g\n", argv[4], hex(8, 16).c_str(), hex(24, 16).c_str(), out[0], out[1], out[63]);
    printf("timing %.1f\n", (end.QuadPart - start.QuadPart) * 1000.0 / frequency.QuadPart);
    fflush(stdout);
    pixels->Unmap(0, &none);
    result->Unmap(0, &none);
    return 0;
}
```

In `Makefile`, after the `d3d12_timestamp.exe` line of `dxmt-tests`, add:

```make
	$(MINGWXX) -std=c++17 -o build/dxmt-tests/d3d12_cache.exe dxmt/tests/d3d12_cache.cpp -ld3d12 -ldxgi
```

In `dxmt/tests/run.sh`, change the output filter `grep -E '^[a-z][a-z0-9-]* '` to `grep -E '^([a-z][a-z0-9-]* |info:  d3d12 shader cache)'`, so the counter line shows.

- [ ] **Step 3: See the test draw as D3DMetal, with no counter line yet**

Run: `S=$PWD/dxmt/tests/shaders; sh dxmt/tests/run.sh d3d12_cache "Z:$S/cache.vs.dxil" "Z:$S/cache.ps.dxil" "Z:$S/cache.cs.dxil" a`

Expected:
- `dxmt: cache a ok 0000803e0000003f0000403f0000803f 00000000000000000000000000000000 1 3 127` and the same line with `d3dmetal:`;
- a `dxmt: timing …` line;
- no `d3d12 shader cache:` line (RED for the counters).

If the two `cache` lines differ, stop and debug the test before going on (superpowers:systematic-debugging).

- [ ] **Step 4: Write the cache checks**

In `dxmt/check.sh`, before the comment `# AMD's FSR 3 swapchain proxy`, add:

```sh
# 7. The D3D12 translation cache (shader pre-caching spec §5.1). Runs 1-5 share one folder; the counter line is ours
#    only. Each mode changes one thing a reused translated function would get wrong, so that function must miss.
cachetest() { run ours "$1" dxmt "$TESTS/d3d12_cache.exe" "Z:$S/cache.vs.dxil" "Z:$S/cache.ps.dxil" "Z:$S/cache.cs.dxil" "$2"; }
counters() { grep -o 'd3d12 shader cache: .*' "$WORK/$1.txt" | tail -1; }
drawn() { grep '^cache ' "$WORK/$1.txt" || echo "no cache line in $1"; }
for m in a rt layout root; do
  run ours "cache-ref-$m" d3dmetal "$TESTS/d3d12_cache.exe" "Z:$S/cache.vs.dxil" "Z:$S/cache.ps.dxil" "Z:$S/cache.cs.dxil" $m
done
CACHE="$WORK/cache/shared"
cachetest cache1 a
expect "cache run 1 (cold) draws as D3DMetal" "$(drawn cache1)" "$(drawn cache-ref-a)"
expect "cache run 1 misses every lookup" "$(counters cache1)" \
  "d3d12 shader cache: functions 0 hit 3 missed, reflections 0 hit 3 missed"
cachetest cache2 a
expect "cache run 2 (warm) draws as D3DMetal" "$(drawn cache2)" "$(drawn cache-ref-a)"
expect "cache run 2 only hits" "$(counters cache2)" "d3d12 shader cache: functions 3 hit 0 missed, reflections 3 hit 0 missed"
echo "info pipeline creation: $(grep '^timing' "$WORK/cache1.txt") ms cold, $(grep '^timing' "$WORK/cache2.txt") ms warm"
cachetest cache3rt rt
expect "another render target format draws as D3DMetal" "$(drawn cache3rt)" "$(drawn cache-ref-rt)"
expect "and misses the pixel shader only" "$(counters cache3rt)" \
  "d3d12 shader cache: functions 2 hit 1 missed, reflections 3 hit 0 missed"
cachetest cache3layout layout
expect "another input layout draws as D3DMetal" "$(drawn cache3layout)" "$(drawn cache-ref-layout)"
expect "and misses the vertex shader only" "$(counters cache3layout)" \
  "d3d12 shader cache: functions 2 hit 1 missed, reflections 3 hit 0 missed"
cachetest cache3root root
expect "another root signature draws as D3DMetal" "$(drawn cache3root)" "$(drawn cache-ref-root)"
expect "and misses both graphics shaders" "$(counters cache3root)" \
  "d3d12 shader cache: functions 1 hit 2 missed, reflections 3 hit 0 missed"
db="$CACHE/shaders_310.db"
sqlite3 "$db" "UPDATE \"$(sqlite3 "$db" "SELECT name FROM sqlite_master WHERE name GLOB 'cache_*'")\" SET value = x'00';"
cachetest cache4 a
expect "corrupt entries: still draws as D3DMetal" "$(drawn cache4)" "$(drawn cache-ref-a)"
expect "corrupt entries are misses" "$(counters cache4)" \
  "d3d12 shader cache: functions 0 hit 3 missed, reflections 0 hit 3 missed"
expect "a rejected cached function is logged once" \
  "$(grep -c 'd3d12 shader cache: rejected a cached function, recompiling' "$WORK/cache4.txt" || true)" 1
sqlite3 "$db" "CREATE TABLE cache_1 (key BLOB PRIMARY KEY, value BLOB NOT NULL);"
cachetest cache5 a
expect "D3D12 drops another build's table too" "$(sqlite3 "$db" "SELECT count(*) FROM sqlite_master WHERE name = 'cache_1'")" 0
expect "and still draws as D3DMetal" "$(drawn cache5)" "$(drawn cache-ref-a)"
CACHE="$WORK/cache/gs"
run ours trigs-cold dxmt "$TESTS/d3d12_triangle.exe" "Z:$S/triangle2.vs.dxil" "Z:$S/triangle2.ps.dxil" "Z:$S/triangle2.gs.dxil"
run ours trigs-warm dxmt "$TESTS/d3d12_triangle.exe" "Z:$S/triangle2.vs.dxil" "Z:$S/triangle2.ps.dxil" "Z:$S/triangle2.gs.dxil"
expect "a warm geometry-shader pipeline only hits" \
  "$(counters trigs-warm | grep -cE 'functions [1-9][0-9]* hit 0 missed, reflections [1-9][0-9]* hit 0 missed$' || true)" 1
expect "and draws as D3DMetal" "$(same_pixels "$WORK/trigs-warm.txt" "$WORK/trigs-ref.txt")" yes
unset CACHE
```

In check 6, change the expected `10/10` of `dxil-translate accepts the test shaders` to `13/13`.

- [ ] **Step 5: Add unix call 149, `DispatchData_copyBytes`**

Run `git -C build/dxmt-src/dxmt switch macneutron`. All paths below are under `build/dxmt-src/dxmt/src/winemetal/`.

`winemetal.h`, after the `MTLDevice_sampleTimestamps` declaration:

```c
/* MacNeutron: copies up to `capacity` bytes of `data` into `buffer`; returns the data's full size. */
WINEMETAL_API uint64_t DispatchData_copyBytes(obj_handle_t data, void *buffer, uint64_t capacity);
```

`winemetal_thunks.h`, after `struct unixcall_mtldevice_sampletimestamps { … };`:

```c
struct unixcall_dispatchdata_copybytes {
  obj_handle_t data;
  struct WMTMemoryPointer buffer;
  uint64_t capacity;
  uint64_t ret_size;
};
```

`winemetal_thunks.c`, after `MTLDevice_sampleTimestamps`:

```c
WINEMETAL_API uint64_t
DispatchData_copyBytes(obj_handle_t data, void *buffer, uint64_t capacity) {
  struct unixcall_dispatchdata_copybytes params;
  params.data = data;
  WMT_MEMPTR_SET(params.buffer, buffer);
  params.capacity = capacity;
  params.ret_size = 0;
  UNIX_CALL(149, &params);
  return params.ret_size;
}
```

`unix/winemetal_unix.c`, after `_MTLDevice_sampleTimestamps`:

```objc
static NTSTATUS
_DispatchData_copyBytes(void *obj) {
  struct unixcall_dispatchdata_copybytes *params = obj;
  dispatch_data_t data = (dispatch_data_t)params->data;
  char *out = params->buffer.ptr;
  uint64_t capacity = params->capacity;
  dispatch_data_apply(data, ^bool(dispatch_data_t region, size_t offset, const void *bytes, size_t length) {
    if (offset >= capacity)
      return false;
    memcpy(out + offset, bytes, MIN(length, capacity - offset));
    return true;
  });
  params->ret_size = dispatch_data_get_size(data);
  return STATUS_SUCCESS;
}
```

Also in `unix/winemetal_unix.c`, add `&_DispatchData_copyBytes,` after `&_MTLDevice_sampleTimestamps,` in both `__wine_unix_call_funcs` and `__wine_unix_call_wow64_funcs`. That makes it call 149 in each.

`Metal.hpp`, replace `class DispatchData : public Object {\npublic:\n};` with:

```cpp
class DispatchData : public Object {
public:
  // Copies up to `capacity` bytes into `buffer`; returns the data's full size. (MacNeutron)
  uint64_t
  copyBytes(void *buffer, uint64_t capacity) {
    return DispatchData_copyBytes(handle, buffer, capacity);
  }
};
```

- [ ] **Step 6: Write the translation cache**

Create `build/dxmt-src/dxmt/src/d3d12/d3d12_shader_cache.hpp`. Start it with the LGPL notice, copied from `d3d12_pipeline_compute.cpp`'s first 17 lines with `Copyright 2026 MacNeutron contributors`:

```cpp
#pragma once
#include "Metal.hpp"
#include "airconv_public.h"
#include "d3d12_pipeline.hpp"
#include "sha1/sha1_util.hpp"
#include <optional>
#include <vector>

namespace dxmt {

// One shader stage's bytecode during pipeline creation (shader pre-caching spec §3.3): its SHA-1, its reflection from
// the translation cache or airconv, and the airconv shader, parsed only when a function misses.
class CachedShader {
public:
  // Checks the container and hashes it; fails as the container check always has.
  HRESULT Initialize(const D3D12_SHADER_BYTECODE &bytecode);
  // Copies the bytecode, for a shader compiled after creation returns (the geometry pipeline's variants).
  void Keep();
  HRESULT Reflection(MTL_SHADER_REFLECTION *out);
  // The airconv shader, parsed on first use.
  HRESULT Parse(sm50_shader_t *out);
  const Sha1Digest &digest() const { return digest_; }

private:
  D3D12_SHADER_BYTECODE bytecode_ = {};
  std::vector<char> kept_;
  Sha1Digest digest_ = {};
  SM50Shader shader_;
  bool parsed_ = false;
  bool reflected_ = false;
  MTL_SHADER_REFLECTION reflection_ = {};
};

// The variant digest of an airconv argument chain (spec §3.2); nullopt for an argument type it doesn't know.
std::optional<Sha1Digest> HashCompileArgs(const SM50_SHADER_COMPILATION_ARGUMENT_DATA *args);

enum class FunctionKind { Shader, GeometryVertex, GeometryMesh };

// A translated function, from the translation cache or compiled by airconv and stored (spec §3.3). `second` is the
// geometry shader for the geometry pipeline's two compiles, else null; `stage` names the shader in error messages.
HRESULT CompileFunction(WMT::Device device, FunctionKind kind, CachedShader &first, CachedShader *second,
                        SM50_SHADER_COMPILATION_ARGUMENT_DATA *args, const char *name, const char *stage,
                        WMT::Reference<WMT::Function> &function);

// "d3d12 shader cache: functions <h> hit <m> missed, reflections <h> hit <m> missed" (spec §3.4); nothing when this
// process made no lookup.
void LogShaderCacheCounters();

} // namespace dxmt
```

Create `build/dxmt-src/dxmt/src/d3d12/d3d12_shader_cache.cpp` with the same LGPL notice:

```cpp
#include "d3d12_shader_cache.hpp"
#include "dxmt_shader_cache.hpp"
#include "log/log.hpp"
#include "util_string.hpp"
#include "DXBCParser/BlobContainer.h"
#include <atomic>
#include <cstring>

namespace dxmt {

namespace {

std::atomic<uint64_t> function_hits, function_misses, reflection_hits, reflection_misses, function_lookups;

// D3D12 compiles for Metal 3.1 (SM50_SHADER_METAL_310), so its entries live in that store.
ShaderCache &
Store() {
  return ShaderCache::getInstance(WMTMetal310);
}

using Key = std::pair<Sha1Digest, Sha1Digest>; // the store's key, as D3D11's

Sha1Digest
Tag(const char *tag) {
  return Sha1HashState::compute(tag, strlen(tag));
}

void
CountFunctionLookup() {
  if (++function_lookups % 1000 == 0)
    LogShaderCacheCounters();
}

} // namespace

HRESULT
CachedShader::Initialize(const D3D12_SHADER_BYTECODE &bytecode) {
  microsoft::CDXBCParser parser;
  if (HRESULT hr = parser.ReadDXBC(bytecode.pShaderBytecode, bytecode.BytecodeLength); FAILED(hr))
    return hr;
  bytecode_ = bytecode;
  digest_ = Sha1HashState::compute(bytecode.pShaderBytecode, bytecode.BytecodeLength);
  return S_OK;
}

void
CachedShader::Keep() {
  auto bytes = static_cast<const char *>(bytecode_.pShaderBytecode);
  kept_.assign(bytes, bytes + bytecode_.BytecodeLength);
  bytecode_.pShaderBytecode = kept_.data();
}

HRESULT
CachedShader::Parse(sm50_shader_t *out) {
  if (!parsed_) {
    SM50Error error;
    if (SM50Initialize(bytecode_.pShaderBytecode, bytecode_.BytecodeLength, &shader_, &reflection_, &error)) {
      ERR("Failed to initialize shader: ", SM50GetErrorMessageString(error));
      return E_FAIL;
    }
    parsed_ = reflected_ = true;
  }
  *out = shader_;
  return S_OK;
}

HRESULT
CachedShader::Reflection(MTL_SHADER_REFLECTION *out) {
  if (!reflected_) {
    Key key{digest_, Tag("d3d12-reflection")};
    bool enabled = false, cached = false;
    if (auto reader = Store().getReader()) {
      enabled = true;
      auto data = reader->get(key);
      cached = data && data.copyBytes(&reflection_, sizeof(reflection_)) == sizeof(reflection_);
    }
    if (cached) {
      reflection_hits++;
      reflected_ = true;
    } else {
      if (enabled)
        reflection_misses++;
      sm50_shader_t shader;
      if (HRESULT hr = Parse(&shader); FAILED(hr))
        return hr;
      if (auto writer = Store().getWriter())
        writer->set(key, WMT::MakeDispatchData(&reflection_, sizeof(reflection_)));
    }
  }
  *out = reflection_;
  return S_OK;
}

std::optional<Sha1Digest>
HashCompileArgs(const SM50_SHADER_COMPILATION_ARGUMENT_DATA *args) {
  // Fields one by one, never whole structs, so padding never enters a key.
  Sha1HashState h;
  for (auto *arg = args; arg; arg = static_cast<const SM50_SHADER_COMPILATION_ARGUMENT_DATA *>(arg->next)) {
    uint32_t type = arg->type;
    h.update(type);
    switch (arg->type) {
    case SM50_SHADER_COMMON: {
      auto *d = reinterpret_cast<const SM50_SHADER_COMMON_DATA *>(arg);
      uint32_t flags = d->flags, version = d->metal_version;
      h.update(flags).update(version);
      break;
    }
    case SM50_SHADER_ROOT_SIGNATURE: {
      auto *d = reinterpret_cast<const SM50_SHADER_ROOT_SIGNATURE_DATA *>(arg);
      uint64_t length = d->bytecode_length;
      h.update(length).update(d->bytecode, d->bytecode_length);
      break;
    }
    case SM50_SHADER_IA_INPUT_LAYOUT: {
      auto *d = reinterpret_cast<const SM50_SHADER_IA_INPUT_LAYOUT_DATA *>(arg);
      uint32_t index_format = d->index_buffer_format;
      h.update(index_format).update(d->slot_mask).update(d->num_elements);
      for (uint32_t i = 0; i < d->num_elements; i++) {
        auto &e = d->elements[i];
        uint32_t step_function = e.step_function, step_rate = e.step_rate;
        h.update(e.reg).update(e.slot).update(e.aligned_byte_offset).update(e.format).update(step_function)
            .update(step_rate);
      }
      break;
    }
    case SM50_SHADER_PSO_PIXEL_SHADER: {
      auto *d = reinterpret_cast<const SM50_SHADER_PSO_PIXEL_SHADER_DATA *>(arg);
      uint8_t dual_source = d->dual_source_blending, no_depth = d->disable_depth_output;
      h.update(d->sample_mask).update(dual_source).update(no_depth).update(d->unorm_output_reg_mask);
      for (uint32_t format : d->pixel_formats)
        h.update(format);
      break;
    }
    case SM50_SHADER_PSO_GEOMETRY_SHADER: {
      uint8_t strip = reinterpret_cast<const SM50_SHADER_PSO_GEOMETRY_SHADER_DATA *>(arg)->strip_topology;
      h.update(strip);
      break;
    }
    default:
      return std::nullopt;
    }
  }
  return h.final();
}

HRESULT
CompileFunction(WMT::Device device, FunctionKind kind, CachedShader &first, CachedShader *second,
                SM50_SHADER_COMPILATION_ARGUMENT_DATA *args, const char *name, const char *stage,
                WMT::Reference<WMT::Function> &function) {
  WMT::Reference<WMT::Error> err;
  std::optional<Key> key;
  if (auto variant = HashCompileArgs(args)) {
    Sha1HashState shaders, v;
    shaders.update(first.digest());
    if (second)
      shaders.update(second->digest());
    v.update(Tag("d3d12-function")).update(name, strlen(name)).update(*variant);
    key = Key{shaders.final(), v.final()};
  }
  if (key) {
    // ponytail: one reader connection behind one lock; a connection per thread if the lock shows up in profiles.
    WMT::Reference<WMT::DispatchData> data;
    bool enabled = false;
    if (auto reader = Store().getReader()) {
      enabled = true;
      data = reader->get(*key);
    }
    if (data) {
      function = device.newLibrary(data, err).newFunction(name);
      if (function) {
        function_hits++;
        CountFunctionLookup();
        return S_OK;
      }
      static std::atomic_flag warned = ATOMIC_FLAG_INIT;
      if (!warned.test_and_set())
        WARN("d3d12 shader cache: rejected a cached function, recompiling");
    }
    if (enabled) {
      function_misses++;
      CountFunctionLookup();
    }
  }

  sm50_shader_t a = {}, b = {};
  HRESULT hr;
  if (FAILED(hr = first.Parse(&a)) || (second && FAILED(hr = second->Parse(&b))))
    return hr;
  SM50ShaderBitcode bitcode;
  SM50Error error;
  int failed = 1;
  switch (kind) {
  case FunctionKind::Shader:
    failed = SM50Compile(a, args, name, &bitcode, &error);
    break;
  case FunctionKind::GeometryVertex:
    failed = SM50CompileGeometryPipelineVertex(a, b, args, name, &bitcode, &error);
    break;
  case FunctionKind::GeometryMesh:
    failed = SM50CompileGeometryPipelineGeometry(a, b, args, name, &bitcode, &error);
    break;
  }
  if (failed)
    return ShaderCompileFailed(stage, error);
  SM50_COMPILED_BITCODE compiled;
  SM50GetCompiledBitcode(bitcode, &compiled);
  auto data = WMT::MakeDispatchData(compiled.Data, compiled.Size);
  function = device.newLibrary(data, err).newFunction(name);
  if (function && key)
    if (auto writer = Store().getWriter())
      writer->set(*key, data);
  return S_OK;
}

void
LogShaderCacheCounters() {
  uint64_t fh = function_hits, fm = function_misses, rh = reflection_hits, rm = reflection_misses;
  if (fh + fm + rh + rm == 0)
    return;
  Logger::info(str::format("d3d12 shader cache: functions ", fh, " hit ", fm, " missed, reflections ", rh, " hit ", rm,
                           " missed"));
}

} // namespace dxmt
```

In `src/d3d12/meson.build`, add `'d3d12_shader_cache.cpp',` after `'d3d12_sampler.cpp',`.

In `src/d3d12/d3d12.cpp`, add `#include "d3d12_shader_cache.hpp"` to its includes. In `DllMain`, replace:

```cpp
  if (reason != DLL_PROCESS_ATTACH)
    return TRUE;
```

with:

```cpp
  if (reason == DLL_PROCESS_DETACH)
    LogShaderCacheCounters(); // games and test programs often exit without releasing their device (spec §3.4)
  if (reason != DLL_PROCESS_ATTACH)
    return TRUE;
```

- [ ] **Step 7: Route the compute pipeline through the cache**

In `src/d3d12/d3d12_pipeline_compute.cpp`, add `#include "d3d12_shader_cache.hpp"` after `#include "d3d12_pipeline.hpp"`.

In `Initialize`, replace everything from `    SM50Shader shader_cs;` through `    auto cs_func = cs_lib.newFunction("cs_main");` with:

```cpp
    CachedShader shader_cs;

    SM50_SHADER_ROOT_SIGNATURE_DATA rootsig;
    rootsig.type = SM50_SHADER_ROOT_SIGNATURE;
    if (pDesc->pRootSignature) {
      rootsig.bytecode_length = static_cast<MTLD3D12RootSignature *>(pDesc->pRootSignature)->GetBlob(&rootsig.bytecode);
    } else {
      rootsig.bytecode = pDesc->CS.pShaderBytecode;
      rootsig.bytecode_length = pDesc->CS.BytecodeLength;
    }
    rootsig.next = nullptr;

    SM50_SHADER_COMMON_DATA common;
    common.flags = {};
    common.type = SM50_SHADER_COMMON;
    common.metal_version = SM50_SHADER_METAL_310;
    common.next = &rootsig;

    HRESULT hr;
    if (FAILED(hr = shader_cs.Initialize(pDesc->CS)) || FAILED(hr = shader_cs.Reflection(&ref_cs)))
      return hr;

    threadgroup_size = {ref_cs.ThreadgroupSize[0], ref_cs.ThreadgroupSize[1], ref_cs.ThreadgroupSize[2]};

    auto metal = device_->GetMTLDevice();

    WMT::Reference<WMT::Error> err;

    WMT::Reference<WMT::Function> cs_func;
    if (FAILED(hr = CompileFunction(metal, FunctionKind::Shader, shader_cs, nullptr,
                                    (SM50_SHADER_COMPILATION_ARGUMENT_DATA *)&common, "cs_main", "cs", cs_func)))
      return hr;
```

The `// PSO` block that follows stays as it is.

- [ ] **Step 8: Route the graphics and geometry pipelines through the cache**

In `src/d3d12/d3d12_pipeline_graphics.cpp`:

1. Add `#include "d3d12_shader_cache.hpp"` after `#include "d3d12_pipeline.hpp"`.
2. Delete the definition `HRESULT\nMTLD3D12PipelineState::InitializeShader(…) { … }` (from `HRESULT\nMTLD3D12PipelineState::InitializeShader(` to its closing `}`). In `src/d3d12/d3d12_device.hpp`, delete its declaration (the two lines `  static HRESULT\n  InitializeShader(D3D12_SHADER_BYTECODE Bytecode, sm50_shader_t *ppShader, struct MTL_SHADER_REFLECTION *pRefl);`).
3. In the members, replace `  SM50Shader geometry_vs_, geometry_gs_;` with `  CachedShader geometry_vs_, geometry_gs_;`.
4. Replace the whole `CompilePixelShader` function (from its comment `// The pixel shader, for either pipeline kind` to its closing `}`) with:

```cpp
  // The pixel shader, for either pipeline kind: `colors` are the render target formats InitializePSO filled.
  HRESULT
  CompilePixelShader(const D3D12_GRAPHICS_PIPELINE_STATE_DESC *pDesc, CachedShader &shader_ps,
                     const WMTColorAttachmentBlendInfo *colors, bool dual_source_blending,
                     WMT::Reference<WMT::Function> &ps_func) {
    if (!pDesc->PS.pShaderBytecode)
      return S_OK;
    SM50_SHADER_COMMON_DATA common;
    common.flags = {};
    common.type = SM50_SHADER_COMMON;
    common.metal_version = SM50_SHADER_METAL_310;
    common.next = nullptr;
    SM50_SHADER_PSO_PIXEL_SHADER_DATA data_ps;
    data_ps.dual_source_blending = dual_source_blending;
    data_ps.disable_depth_output = false;
    data_ps.unorm_output_reg_mask = 0;
    data_ps.sample_mask = pDesc->SampleMask;
    data_ps.type = SM50_SHADER_PSO_PIXEL_SHADER;
    data_ps.next = &common;
    memset(data_ps.pixel_formats, 0, sizeof(data_ps.pixel_formats));
    for (unsigned i = 0; i < pDesc->NumRenderTargets; i++) {
      data_ps.pixel_formats[i] = ORIGINAL_FORMAT(colors[i].pixel_format);
    }
    SM50_SHADER_ROOT_SIGNATURE_DATA rootsig;
    rootsig.type = SM50_SHADER_ROOT_SIGNATURE;
    if (pDesc->pRootSignature) {
      rootsig.bytecode_length =
          static_cast<MTLD3D12RootSignature *>(pDesc->pRootSignature)->GetBlob(&rootsig.bytecode);
    } else {
      rootsig.bytecode = pDesc->PS.pShaderBytecode;
      rootsig.bytecode_length = pDesc->PS.BytecodeLength;
    }
    rootsig.next = &data_ps;
    std::string ps_name = "ps_main" + shader_ps.digest().string().substr(0, 8);
    return CompileFunction(device_->GetMTLDevice(), FunctionKind::Shader, shader_ps, nullptr,
                           (SM50_SHADER_COMPILATION_ARGUMENT_DATA *)&rootsig, ps_name.c_str(), "ps", ps_func);
  }
```

5. In `InitializeGeometry`, replace:

```cpp
    if (FAILED(hr = InitializeShader(pDesc->VS, &geometry_vs_, &ref_vs)) ||
        FAILED(hr = InitializeShader(pDesc->GS, &geometry_gs_, &ref_gs)))
      return hr;
```

with:

```cpp
    if (FAILED(hr = geometry_vs_.Initialize(pDesc->VS)) || FAILED(hr = geometry_vs_.Reflection(&ref_vs)) ||
        FAILED(hr = geometry_gs_.Initialize(pDesc->GS)) || FAILED(hr = geometry_gs_.Reflection(&ref_gs)))
      return hr;
    // The strip and indexed variants compile at draw time, when the app may have freed its bytecode.
    geometry_vs_.Keep();
    geometry_gs_.Keep();
```

Still in `InitializeGeometry`, replace:

```cpp
    SM50Shader shader_ps;
    ref_ps = {};
    if (pDesc->PS.pShaderBytecode && FAILED(hr = InitializeShader(pDesc->PS, &shader_ps, &ref_ps)))
      return hr;
```

with:

```cpp
    CachedShader shader_ps;
    ref_ps = {};
    if (pDesc->PS.pShaderBytecode &&
        (FAILED(hr = shader_ps.Initialize(pDesc->PS)) || FAILED(hr = shader_ps.Reflection(&ref_ps))))
      return hr;
```

6. In `CompileGeometryVariant`, replace everything from `    SM50ShaderBitcode object_bitcode, mesh_bitcode;` through `    auto mesh_function = function(mesh_bitcode, "gs_main");` with:

```cpp
    WMT::Reference<WMT::Function> object_function, mesh_function;
    HRESULT hr;
    if (FAILED(hr = CompileFunction(metal, FunctionKind::GeometryVertex, geometry_vs_, &geometry_gs_,
                                    (SM50_SHADER_COMPILATION_ARGUMENT_DATA *)&object_args, "vsgs_main",
                                    "vs (geometry pipeline)", object_function)) ||
        FAILED(hr = CompileFunction(metal, FunctionKind::GeometryMesh, geometry_vs_, &geometry_gs_,
                                    (SM50_SHADER_COMPILATION_ARGUMENT_DATA *)&mesh_args, "gs_main", "gs",
                                    mesh_function)))
      return hr;
    WMT::Reference<WMT::Error> err;
```

The rest of the function, from `auto info = geometry_info_;` on, stays as it is.

7. In `Initialize`, replace everything from `    SM50Shader shader_vs, shader_ps;` through the `if (FAILED(hr = CompilePixelShader(pDesc, shader_ps, info.colors, dual_source_blending, ps_func)))\n      return hr;` line with:

```cpp
    CachedShader shader_vs, shader_ps;
    auto metal = device_->GetMTLDevice();
    WMT::Reference<WMT::Error> err;
    WMT::Reference<WMT::Function> vs_func, ps_func;

    SM50_SHADER_COMMON_DATA common;
    common.flags = {};
    common.type = SM50_SHADER_COMMON;
    common.metal_version = SM50_SHADER_METAL_310;
    common.next = nullptr;

    if (!pDesc->VS.pShaderBytecode) {
      ERR("no vertex shader");
      return E_INVALIDARG;
    }
    if (FAILED(hr = shader_vs.Initialize(pDesc->VS)) || FAILED(hr = shader_vs.Reflection(&ref_vs)))
      return hr;
    SM50_SHADER_IA_INPUT_LAYOUT_DATA data_ia_layout;
    data_ia_layout.type = SM50_SHADER_IA_INPUT_LAYOUT;
    data_ia_layout.index_buffer_format = SM50_INDEX_BUFFER_FORMAT_NONE;
    std::vector<SM50_IA_INPUT_ELEMENT> elements(pDesc->InputLayout.NumElements);
    hr = ExtractMTLInputLayoutElements(
        device_, pDesc->VS.pShaderBytecode, pDesc->InputLayout.pInputElementDescs, pDesc->InputLayout.NumElements,
        elements.data(), &data_ia_layout.num_elements
    );
    elements.resize(data_ia_layout.num_elements);
    data_ia_layout.elements = elements.data();
    if (FAILED(hr)) {
      return hr;
    }
    slot_mask = 0;
    for (auto &element : elements) {
      slot_mask |= (1 << element.slot);
    }
    data_ia_layout.slot_mask = slot_mask;
    data_ia_layout.next = &common;

    SM50_SHADER_ROOT_SIGNATURE_DATA rootsig;
    rootsig.type = SM50_SHADER_ROOT_SIGNATURE;
    if (pDesc->pRootSignature) {
      rootsig.bytecode_length =
          static_cast<MTLD3D12RootSignature *>(pDesc->pRootSignature)->GetBlob(&rootsig.bytecode);
    } else {
      rootsig.bytecode = pDesc->VS.pShaderBytecode;
      rootsig.bytecode_length = pDesc->VS.BytecodeLength;
    }
    rootsig.next = &data_ia_layout;

    if (FAILED(hr = CompileFunction(metal, FunctionKind::Shader, shader_vs, nullptr,
                                    (SM50_SHADER_COMPILATION_ARGUMENT_DATA *)&rootsig, "vs_main", "vs", vs_func)))
      return hr;

    WMTRenderPipelineInfo info;
    WMT::InitializeRenderPipelineInfo(info);

    bool dual_source_blending = false;

    // MacNeutron: reflect the pixel shader first; InitializePSO reads ref_ps.PixelShader.HasCoverageOutput.
    ref_ps = {};
    if (pDesc->PS.pShaderBytecode &&
        (FAILED(hr = shader_ps.Initialize(pDesc->PS)) || FAILED(hr = shader_ps.Reflection(&ref_ps))))
      return hr;

    if (FAILED(hr = InitializePSO(pDesc, info, dual_source_blending)))
      return hr;

    if (FAILED(hr = CompilePixelShader(pDesc, shader_ps, info.colors, dual_source_blending, ps_func)))
      return hr;
```

The `// PSO` block that follows stays as it is. The now-unused `SM50Error sm50_err;` goes away with the replaced lines; if the compiler reports another unused local, delete it.

- [ ] **Step 9: Run the dev loop cold and warm**

```bash
S=$PWD/dxmt/tests/shaders; C="${TMPDIR:-/tmp}/cache-dev"; rm -rf "$C"
for m in a a rt layout root; do RUN_ENV="DXMT_SHADER_CACHE_PATH=$C" sh dxmt/tests/run.sh d3d12_cache "Z:$S/cache.vs.dxil" "Z:$S/cache.ps.dxil" "Z:$S/cache.cs.dxil" $m | grep -E 'cache |shader cache'; done
```

Expected, in order:
- `functions 0 hit 3 missed, reflections 0 hit 3 missed`, then `functions 3 hit 0 missed, reflections 3 hit 0 missed`;
- then `2 hit 1 missed`, `2 hit 1 missed` and `1 hit 2 missed` for the functions, with reflections `3 hit 0 missed`;
- every `dxmt: cache …` line equal to its `d3dmetal: cache …` line.

- [ ] **Step 10: Land, run the full check, commit**

```bash
git -C build/dxmt-src/dxmt add src/winemetal src/d3d12
git -C build/dxmt-src/dxmt commit -m "d3d12: translation cache for DXIL/DXBC functions and reflection (shader pre-caching)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git -C build/dxmt-src/dxmt push origin macneutron
sed -i '' "s/^DXMT_COMMIT=.*/DXMT_COMMIT=$(git -C build/dxmt-src/dxmt rev-parse HEAD)/" dxmt/pins
make dxmt-check > "$W/check-t3.log" 2>&1; grep -E '^(FAIL|dxmt-check|info pipeline)' "$W/check-t3.log"
git add dxmt/tests/shaders/cache.hlsl dxmt/tests/shaders/cache.*.dxil dxmt/tests/shaders/compile.sh \
  dxmt/tests/d3d12_cache.cpp dxmt/tests/run.sh dxmt/check.sh Makefile dxmt/pins
git commit -m "test(dxmt): d3d12_cache: cold, warm, per-argument misses, corrupt entries, stale tables

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Expected from the check: `dxmt-check: all passed`, no `FAIL`, and an `info pipeline creation:` line with the cold and warm times.

---

## Milestone 2: record and replay

### Task 4: The recorder

**Files:**
- Create: `build/dxmt-src/dxmt/src/d3d12/d3d12_pipeline_record.hpp`, `d3d12_pipeline_record.cpp`
- Modify: `build/dxmt-src/dxmt/src/d3d12/meson.build`, `d3d12_device.hpp` (`MTLD3D12RootSignature`), `d3d12_root_signature.cpp` (`CreateRootSignature`), `d3d12_pipeline.hpp`, `d3d12_pipeline_graphics.cpp`, `d3d12_pipeline_compute.cpp`
- Modify: `build/dxmt-src/dxmt/src/util/util_env.hpp`, `util_env.cpp`, `dxmt/dxmt_shader_cache.cpp`, `dxgi/dxgi.cpp`
- Modify: `dxmt/check.sh` (a new section 8)

**Interfaces:**
- Consumes: `CachedShader::digest()` (Task 3); `check.sh`'s `cachetest`, `drawn` and `CACHE` (Tasks 1, 3).
- Produces:
  - `std::string dxmt::env::getCacheExeName()`, which is `DXMT_CACHE_EXE` or `getExeName()`;
  - `Sha1Digest MTLD3D12RootSignature::BlobDigest`;
  - in `namespace dxmt::record`:
    - `kMagic`, `kHeaderSize` (36), `enum Kind : uint32_t { kBlob = 1, kGraphics = 2, kCompute = 3 }`;
    - `struct Blob { Sha1Digest id; const void *data; size_t size; }`;
    - `Checksum`, `SerializeGraphics`, `SerializeCompute`, `ParseGraphics`, `ParseCompute`;
    - `struct GraphicsRecord`, `struct ComputeRecord`, `struct Recording` and `Recording Read(const std::wstring &)`;
    - `bool RecordingOn()`, `RecordGraphics(...)`, `RecordCompute(...)`;
  - `inline record::Blob dxmt::RootBlob(ID3D12RootSignature *)`;
  - the log line `d3d12 pipeline recording off: <reason>`.

- [ ] **Step 1: Write the failing recording checks**

In `dxmt/check.sh`, after section 7 (its `unset CACHE`), add:

```sh
# 8. Recording (spec §3.5, §5.2 runs 6-7): each pipeline once, a torn tail cut and re-recorded, a foreign file
#    started over, and an unwritable folder that changes nothing drawn.
REC="$WORK/rec"; f="$REC/d3d12_cache.exe.pipelines"
export DXMT_PIPELINE_RECORD="$REC"
CACHE="$WORK/cache/rec"
cachetest rec6 a
expect "run 6: the pipelines are recorded" "$(head -c 8 "$f" 2> /dev/null)" DXMTPRC1
full=$(wc -c < "$f" | tr -d ' ')
cachetest rec7 a
expect "run 7: a second run records nothing new" "$(wc -c < "$f" | tr -d ' ')" "$full"
python3 -c "import os, sys; os.truncate(sys.argv[1], os.path.getsize(sys.argv[1]) - 10)" "$f"
cachetest rec-torn a
expect "a torn tail is cut and its pipeline recorded again" "$(wc -c < "$f" | tr -d ' ')" "$full"
expect "recording changes nothing drawn" "$(drawn rec-torn)" "$(drawn cache-ref-a)"
printf 'not a recording' > "$f"
cachetest rec-foreign a
expect "a foreign file is started over" "$(head -c 8 "$f"):$(wc -c < "$f" | tr -d ' ')" "DXMTPRC1:$full"
export DXMT_PIPELINE_RECORD="/nonexistent/macneutron rec"
cachetest rec-unwritable a
expect "an unwritable recording folder changes nothing drawn" "$(drawn rec-unwritable)" "$(drawn cache-ref-a)"
expect "and says once that recording is off" "$(grep -c 'd3d12 pipeline recording off' "$WORK/rec-unwritable.txt" || true)" 1
unset DXMT_PIPELINE_RECORD CACHE
```

- [ ] **Step 2: See the dev loop record nothing**

Run: `S=$PWD/dxmt/tests/shaders; R="${TMPDIR:-/tmp}/rec-dev"; rm -rf "$R"; RUN_ENV="DXMT_PIPELINE_RECORD=$R" sh dxmt/tests/run.sh d3d12_cache "Z:$S/cache.vs.dxil" "Z:$S/cache.ps.dxil" "Z:$S/cache.cs.dxil" a > /dev/null; ls "$R" 2>&1`

Expected: `No such file or directory` (RED).

- [ ] **Step 3: The cache identity**

Run `git -C build/dxmt-src/dxmt switch macneutron`. In `src/util/util_env.hpp`, after `std::string getExeName();`, add:

```cpp
/**
 * \brief The executable name DXMT's caches are kept under
 *
 * DXMT_CACHE_EXE when set (dxmt-replay.exe fills a game's caches), else \ref getExeName. (MacNeutron)
 */
std::string getCacheExeName();
```

In `src/util/util_env.cpp`, after `getExeName()`'s definition:

```cpp
std::string getCacheExeName() {
  std::string name = getEnvVar("DXMT_CACHE_EXE");
  return name.empty() ? getExeName() : name;
}
```

In `src/dxmt/dxmt_shader_cache.cpp`, replace `str::format("dxmt/", env::getExeName(), "/")` with `str::format("dxmt/", env::getCacheExeName(), "/")`. In `src/dxgi/dxgi.cpp`'s `InitializeMetalCachePath`, replace `env::getExeName()` with `env::getCacheExeName()`.

- [ ] **Step 4: The format and the recorder**

Create `src/d3d12/d3d12_pipeline_record.hpp`, with the LGPL notice:

```cpp
#pragma once
#include "d3d12.h"
#include "sha1/sha1_util.hpp"
#include <cstdint>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

// A `.pipelines` recording (shader pre-caching spec §3.5), what Fossilize's .foz files are to Steam's Vulkan
// pre-caching: "DXMTPRC1", then records of a 36-byte header (uint32 kind, uint32 payload size, uint64 FNV-1a of the
// payload, 20-byte SHA-1 id) and the payload. Blobs (shaders, root signatures) are stored once; pipeline payloads name
// them by id, all zeros for none.
namespace dxmt::record {

constexpr char kMagic[8] = {'D', 'X', 'M', 'T', 'P', 'R', 'C', '1'};
constexpr size_t kHeaderSize = 36;
enum Kind : uint32_t { kBlob = 1, kGraphics = 2, kCompute = 3 };

// A blob a pipeline refers to. Null data: none.
struct Blob {
  Sha1Digest id = {};
  const void *data = nullptr;
  size_t size = 0;
};

uint64_t Checksum(const void *data, size_t size);

std::vector<uint8_t> SerializeGraphics(const D3D12_GRAPHICS_PIPELINE_STATE_DESC &desc, const Sha1Digest &root,
                                       const Sha1Digest &vs, const Sha1Digest &ps, const Sha1Digest &gs);
std::vector<uint8_t> SerializeCompute(const D3D12_COMPUTE_PIPELINE_STATE_DESC &desc, const Sha1Digest &root,
                                      const Sha1Digest &cs);

// A pipeline read back. Its pointers are null: the replayer points them at blobs, and the input layout at `elements`
// (whose SemanticName point into `names`) just before creating it.
struct GraphicsRecord {
  Sha1Digest root, vs, ps, gs;
  D3D12_GRAPHICS_PIPELINE_STATE_DESC desc;
  std::vector<std::string> names;
  std::vector<D3D12_INPUT_ELEMENT_DESC> elements;
};
struct ComputeRecord {
  Sha1Digest root, cs;
  D3D12_COMPUTE_PIPELINE_STATE_DESC desc;
};
bool ParseGraphics(const std::vector<uint8_t> &payload, GraphicsRecord &record);
bool ParseCompute(const std::vector<uint8_t> &payload, ComputeRecord &record);

// A whole recording as the replayer reads it: every record's size and checksum verified.
struct Recording {
  bool opened = false; // false: missing, unreadable, or not a recording
  std::unordered_map<Sha1Digest, std::vector<uint8_t>> blobs;
  std::vector<std::pair<Kind, std::vector<uint8_t>>> pipelines;
  uint64_t bad = 0; // records skipped: cut short, unknown kind or wrong checksum
};
Recording Read(const std::wstring &path);

// The recorder: after a pipeline's creation succeeded, appends what `<DXMT_PIPELINE_RECORD>/<exe>.pipelines` lacks.
bool RecordingOn();
void RecordGraphics(const D3D12_GRAPHICS_PIPELINE_STATE_DESC &desc, const Blob &root, const Blob &vs, const Blob &ps,
                    const Blob &gs);
void RecordCompute(const D3D12_COMPUTE_PIPELINE_STATE_DESC &desc, const Blob &root, const Blob &cs);

} // namespace dxmt::record
```

Create `src/d3d12/d3d12_pipeline_record.cpp`, with the LGPL notice:

```cpp
#include "d3d12_pipeline_record.hpp"
#include "log/log.hpp"
#include "util_env.hpp"
#include "util_string.hpp"
#include <windows.h>
#include <cstring>
#include <mutex>
#include <type_traits>
#include <unordered_set>

namespace dxmt::record {

namespace {

const Sha1Digest kNone = {};

// Fields go one by one, never as whole structs, so padding never reaches a file or an id. Out writes a description,
// In reads one back; GraphicsFields and ComputeFields list the fields once for both.
struct Out {
  std::vector<uint8_t> bytes;
  void raw(const void *data, size_t size) {
    auto *p = static_cast<const uint8_t *>(data);
    bytes.insert(bytes.end(), p, p + size);
  }
  template <typename T> void field(T &value) {
    static_assert(std::is_arithmetic_v<T> || std::is_enum_v<T>);
    raw(&value, sizeof(T));
  }
  void field(Sha1Digest &digest) { raw(digest.data, sizeof(digest.data)); }
  void layout(D3D12_INPUT_LAYOUT_DESC &layout, std::vector<std::string> &, std::vector<D3D12_INPUT_ELEMENT_DESC> &);
};

struct In {
  const uint8_t *p, *end;
  bool ok = true;
  void raw(void *data, size_t size) {
    if (!ok || size_t(end - p) < size) {
      ok = false;
      memset(data, 0, size);
      return;
    }
    memcpy(data, p, size);
    p += size;
  }
  template <typename T> void field(T &value) {
    static_assert(std::is_arithmetic_v<T> || std::is_enum_v<T>);
    raw(&value, sizeof(T));
  }
  void field(Sha1Digest &digest) { raw(digest.data, sizeof(digest.data)); }
  void layout(D3D12_INPUT_LAYOUT_DESC &layout, std::vector<std::string> &names,
              std::vector<D3D12_INPUT_ELEMENT_DESC> &elements);
};

template <typename IO>
void
ElementFields(IO &io, D3D12_INPUT_ELEMENT_DESC &e) {
  io.field(e.SemanticIndex);
  io.field(e.Format);
  io.field(e.InputSlot);
  io.field(e.AlignedByteOffset);
  io.field(e.InputSlotClass);
  io.field(e.InstanceDataStepRate);
}

void
Out::layout(D3D12_INPUT_LAYOUT_DESC &layout, std::vector<std::string> &, std::vector<D3D12_INPUT_ELEMENT_DESC> &) {
  field(layout.NumElements);
  for (UINT i = 0; i < layout.NumElements; i++) {
    D3D12_INPUT_ELEMENT_DESC e = layout.pInputElementDescs[i];
    uint32_t length = e.SemanticName ? (uint32_t)strlen(e.SemanticName) : 0;
    field(length);
    raw(e.SemanticName, length);
    ElementFields(*this, e);
  }
}

void
In::layout(D3D12_INPUT_LAYOUT_DESC &layout, std::vector<std::string> &names,
           std::vector<D3D12_INPUT_ELEMENT_DESC> &elements) {
  field(layout.NumElements);
  if (layout.NumElements > D3D12_IA_VERTEX_INPUT_STRUCTURE_ELEMENT_COUNT)
    ok = false;
  for (UINT i = 0; ok && i < layout.NumElements; i++) {
    uint32_t length = 0;
    field(length);
    if (!ok || length > 256 || size_t(end - p) < length) {
      ok = false;
      break;
    }
    names.emplace_back(reinterpret_cast<const char *>(p), length);
    p += length;
    D3D12_INPUT_ELEMENT_DESC e = {};
    ElementFields(*this, e);
    elements.push_back(e);
  }
  layout.pInputElementDescs = nullptr;
}

template <typename IO>
void
GraphicsFields(IO &io, D3D12_GRAPHICS_PIPELINE_STATE_DESC &d, Sha1Digest (&ids)[4], std::vector<std::string> &names,
               std::vector<D3D12_INPUT_ELEMENT_DESC> &elements) {
  for (auto &id : ids) // root signature, VS, PS, GS
    io.field(id);
  auto &blend = d.BlendState;
  io.field(blend.AlphaToCoverageEnable);
  io.field(blend.IndependentBlendEnable);
  for (auto &rt : blend.RenderTarget) {
    io.field(rt.BlendEnable);
    io.field(rt.LogicOpEnable);
    io.field(rt.SrcBlend);
    io.field(rt.DestBlend);
    io.field(rt.BlendOp);
    io.field(rt.SrcBlendAlpha);
    io.field(rt.DestBlendAlpha);
    io.field(rt.BlendOpAlpha);
    io.field(rt.LogicOp);
    io.field(rt.RenderTargetWriteMask);
  }
  io.field(d.SampleMask);
  auto &r = d.RasterizerState;
  io.field(r.FillMode);
  io.field(r.CullMode);
  io.field(r.FrontCounterClockwise);
  io.field(r.DepthBias);
  io.field(r.DepthBiasClamp);
  io.field(r.SlopeScaledDepthBias);
  io.field(r.DepthClipEnable);
  io.field(r.MultisampleEnable);
  io.field(r.AntialiasedLineEnable);
  io.field(r.ForcedSampleCount);
  io.field(r.ConservativeRaster);
  auto &z = d.DepthStencilState;
  io.field(z.DepthEnable);
  io.field(z.DepthWriteMask);
  io.field(z.DepthFunc);
  io.field(z.StencilEnable);
  io.field(z.StencilReadMask);
  io.field(z.StencilWriteMask);
  for (auto *face : {&z.FrontFace, &z.BackFace}) {
    io.field(face->StencilFailOp);
    io.field(face->StencilDepthFailOp);
    io.field(face->StencilPassOp);
    io.field(face->StencilFunc);
  }
  io.layout(d.InputLayout, names, elements);
  io.field(d.IBStripCutValue);
  io.field(d.PrimitiveTopologyType);
  io.field(d.NumRenderTargets);
  for (auto &format : d.RTVFormats)
    io.field(format);
  io.field(d.DSVFormat);
  io.field(d.SampleDesc.Count);
  io.field(d.SampleDesc.Quality);
  io.field(d.NodeMask);
  io.field(d.Flags);
}

template <typename IO>
void
ComputeFields(IO &io, D3D12_COMPUTE_PIPELINE_STATE_DESC &d, Sha1Digest (&ids)[2]) {
  for (auto &id : ids) // root signature, CS
    io.field(id);
  io.field(d.NodeMask);
  io.field(d.Flags);
}

void
AppendRecord(std::vector<uint8_t> &out, Kind kind, const Sha1Digest &id, const void *payload, size_t size) {
  uint32_t k = kind, n = (uint32_t)size;
  uint64_t sum = Checksum(payload, size);
  auto put = [&](const void *data, size_t length) {
    auto *b = static_cast<const uint8_t *>(data);
    out.insert(out.end(), b, b + length);
  };
  put(&k, 4);
  put(&n, 4);
  put(&sum, 8);
  put(id.data, 20);
  put(payload, size);
}

bool
ReadAll(HANDLE file, std::vector<uint8_t> &bytes) {
  LARGE_INTEGER size;
  if (!GetFileSizeEx(file, &size) || size.QuadPart > 0x7fffffff)
    return false;
  bytes.resize((size_t)size.QuadPart);
  DWORD got = 0;
  return bytes.empty() || (ReadFile(file, bytes.data(), (DWORD)bytes.size(), &got, nullptr) && got == bytes.size());
}

bool
WriteAll(HANDLE file, const std::vector<uint8_t> &bytes) {
  DWORD written = 0;
  return WriteFile(file, bytes.data(), (DWORD)bytes.size(), &written, nullptr) && written == bytes.size();
}

struct Recorder {
  // ponytail: one lock and one write per new pipeline; a writer thread if recording shows in first-session profiles.
  std::mutex mutex;
  HANDLE file = INVALID_HANDLE_VALUE;
  bool opened = false, off = false;
  std::unordered_set<Sha1Digest> ids;
};

Recorder &
State() {
  static Recorder recorder;
  return recorder;
}

// `<DXMT_PIPELINE_RECORD>\<exe>.pipelines`, or empty when recording is off.
const std::wstring &
RecordingPath() {
  static const std::wstring path = [] {
    std::string folder = env::getEnvVar("DXMT_PIPELINE_RECORD");
    if (folder.empty() || folder == "0")
      return std::wstring();
    while (folder.size() > 1 && (folder.back() == '/' || folder.back() == '\\'))
      folder.pop_back();
    if (folder[0] == '/')
      folder = "Z:" + folder; // the launcher passes a Mac path; Wine's Z: drive is the Mac's root
    std::wstring wide = str::tows(folder.c_str());
    CreateDirectoryW(wide.c_str(), nullptr); // may exist; any other failure shows when the file doesn't open
    return wide + L"\\" + str::tows(env::getCacheExeName().c_str()) + L".pipelines";
  }();
  return path;
}

void
TurnOff(Recorder &r, const char *reason) {
  WARN("d3d12 pipeline recording off: ", reason);
  r.off = true;
  if (r.file != INVALID_HANDLE_VALUE) {
    CloseHandle(r.file);
    r.file = INVALID_HANDLE_VALUE;
  }
}

// Opens the recording once: reads its record ids and cuts a torn tail. Sizes only, no checksums: a game doesn't hash
// a large file while it loads.
bool
Ready(Recorder &r) {
  if (r.off)
    return false;
  if (r.opened)
    return true;
  r.opened = true;
  r.file = CreateFileW(RecordingPath().c_str(), GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ, nullptr, OPEN_ALWAYS,
                       FILE_ATTRIBUTE_NORMAL, nullptr);
  if (r.file == INVALID_HANDLE_VALUE) {
    TurnOff(r, "can't open the recording");
    return false;
  }
  std::vector<uint8_t> bytes;
  if (!ReadAll(r.file, bytes)) {
    TurnOff(r, "can't read the recording");
    return false;
  }
  size_t end = 0;
  if (bytes.size() >= sizeof(kMagic) && !memcmp(bytes.data(), kMagic, sizeof(kMagic))) {
    end = sizeof(kMagic);
    while (bytes.size() - end >= kHeaderSize) {
      uint32_t kind, size;
      Sha1Digest id;
      memcpy(&kind, bytes.data() + end, 4);
      memcpy(&size, bytes.data() + end + 4, 4);
      memcpy(id.data, bytes.data() + end + 16, 20);
      if (kind < kBlob || kind > kCompute || size > bytes.size() - end - kHeaderSize)
        break;
      r.ids.insert(id);
      end += kHeaderSize + size;
    }
  }
  // A foreign file starts over; anything after the last complete record is cut.
  LARGE_INTEGER at;
  at.QuadPart = (LONGLONG)end;
  if (!SetFilePointerEx(r.file, at, nullptr, FILE_BEGIN) || !SetEndOfFile(r.file)) {
    TurnOff(r, "can't cut the recording's torn tail");
    return false;
  }
  if (!end && !WriteAll(r.file, std::vector<uint8_t>(kMagic, kMagic + sizeof(kMagic)))) {
    TurnOff(r, "can't write the recording");
    return false;
  }
  return true;
}

void
Append(const std::vector<uint8_t> &payload, Kind kind, std::initializer_list<const Blob *> blobs) {
  Sha1Digest id = Sha1HashState::compute(payload.data(), payload.size());
  auto &r = State();
  std::lock_guard<std::mutex> lock(r.mutex);
  if (!Ready(r) || r.ids.count(id))
    return;
  std::vector<uint8_t> out;
  for (auto *blob : blobs)
    if (blob->data && r.ids.insert(blob->id).second)
      AppendRecord(out, kBlob, blob->id, blob->data, blob->size);
  AppendRecord(out, kind, id, payload.data(), payload.size());
  if (!WriteAll(r.file, out)) {
    TurnOff(r, "can't write the recording");
    return;
  }
  r.ids.insert(id);
}

Sha1Digest
IdOf(const Blob &blob) {
  return blob.data ? blob.id : kNone;
}

} // namespace

uint64_t
Checksum(const void *data, size_t size) {
  auto *p = static_cast<const uint8_t *>(data);
  uint64_t hash = 0xcbf29ce484222325ull; // FNV-1a
  for (size_t i = 0; i < size; i++)
    hash = (hash ^ p[i]) * 0x100000001b3ull;
  return hash;
}

std::vector<uint8_t>
SerializeGraphics(const D3D12_GRAPHICS_PIPELINE_STATE_DESC &desc, const Sha1Digest &root, const Sha1Digest &vs,
                  const Sha1Digest &ps, const Sha1Digest &gs) {
  Out out;
  auto d = desc;
  Sha1Digest ids[4] = {root, vs, ps, gs};
  std::vector<std::string> names;
  std::vector<D3D12_INPUT_ELEMENT_DESC> elements;
  GraphicsFields(out, d, ids, names, elements);
  return std::move(out.bytes);
}

std::vector<uint8_t>
SerializeCompute(const D3D12_COMPUTE_PIPELINE_STATE_DESC &desc, const Sha1Digest &root, const Sha1Digest &cs) {
  Out out;
  auto d = desc;
  Sha1Digest ids[2] = {root, cs};
  ComputeFields(out, d, ids);
  return std::move(out.bytes);
}

bool
ParseGraphics(const std::vector<uint8_t> &payload, GraphicsRecord &record) {
  In in{payload.data(), payload.data() + payload.size()};
  record.desc = {};
  Sha1Digest ids[4];
  GraphicsFields(in, record.desc, ids, record.names, record.elements);
  record.root = ids[0];
  record.vs = ids[1];
  record.ps = ids[2];
  record.gs = ids[3];
  return in.ok && in.p == in.end;
}

bool
ParseCompute(const std::vector<uint8_t> &payload, ComputeRecord &record) {
  In in{payload.data(), payload.data() + payload.size()};
  record.desc = {};
  Sha1Digest ids[2];
  ComputeFields(in, record.desc, ids);
  record.root = ids[0];
  record.cs = ids[1];
  return in.ok && in.p == in.end;
}

Recording
Read(const std::wstring &path) {
  Recording recording;
  HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
                            FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE)
    return recording;
  std::vector<uint8_t> bytes;
  bool read = ReadAll(file, bytes);
  CloseHandle(file);
  if (!read || bytes.size() < sizeof(kMagic) || memcmp(bytes.data(), kMagic, sizeof(kMagic)))
    return recording;
  recording.opened = true;
  for (size_t at = sizeof(kMagic); at < bytes.size();) {
    if (bytes.size() - at < kHeaderSize) {
      recording.bad++;
      break;
    }
    uint32_t kind, size;
    uint64_t sum;
    Sha1Digest id;
    memcpy(&kind, bytes.data() + at, 4);
    memcpy(&size, bytes.data() + at + 4, 4);
    memcpy(&sum, bytes.data() + at + 8, 8);
    memcpy(id.data, bytes.data() + at + 16, 20);
    if (size > bytes.size() - at - kHeaderSize) { // cut short
      recording.bad++;
      break;
    }
    const uint8_t *payload = bytes.data() + at + kHeaderSize;
    at += kHeaderSize + size;
    if (kind < kBlob || kind > kCompute || Checksum(payload, size) != sum) {
      recording.bad++;
      continue;
    }
    std::vector<uint8_t> copy(payload, payload + size);
    if (kind == kBlob)
      recording.blobs.emplace(id, std::move(copy));
    else
      recording.pipelines.emplace_back(Kind(kind), std::move(copy));
  }
  return recording;
}

bool
RecordingOn() {
  return !RecordingPath().empty();
}

void
RecordGraphics(const D3D12_GRAPHICS_PIPELINE_STATE_DESC &desc, const Blob &root, const Blob &vs, const Blob &ps,
               const Blob &gs) {
  if (RecordingOn())
    Append(SerializeGraphics(desc, IdOf(root), IdOf(vs), IdOf(ps), IdOf(gs)), kGraphics, {&root, &vs, &ps, &gs});
}

void
RecordCompute(const D3D12_COMPUTE_PIPELINE_STATE_DESC &desc, const Blob &root, const Blob &cs) {
  if (RecordingOn())
    Append(SerializeCompute(desc, IdOf(root), IdOf(cs)), kCompute, {&root, &cs});
}

} // namespace dxmt::record
```

In `src/d3d12/meson.build`, add `'d3d12_pipeline_record.cpp',` after `'d3d12_pipeline_library.cpp',`.

- [ ] **Step 5: Hook the recorder into pipeline creation**

`src/d3d12/d3d12_device.hpp`:
- add `#include "sha1/sha1_util.hpp"` to its includes;
- in `class MTLD3D12RootSignature`, after `uint64_t const *EncodedStaticSamplers;`, add:

```cpp
  Sha1Digest BlobDigest = {}; // SHA-1 of the blob it was created from, for pipeline recordings (MacNeutron)
```

`src/d3d12/d3d12_root_signature.cpp`:
- add `#include "sha1/sha1_util.hpp"`;
- in `CreateRootSignature`, after `if (FAILED(hr))\n    return hr;` (the one after `root_sig->Initialize()`), add:

```cpp
  root_sig->BlobDigest = Sha1HashState::compute(pBytecode, BytecodeLength);
```

`src/d3d12/d3d12_pipeline.hpp`: add `#include "d3d12_pipeline_record.hpp"` to its includes. Before `} // namespace dxmt`, add:

```cpp
// A root signature as the pipeline recorder names it; none for a pipeline without one (the shader's own).
inline record::Blob
RootBlob(ID3D12RootSignature *rs) {
  if (!rs)
    return {};
  auto *root = static_cast<MTLD3D12RootSignature *>(rs);
  const void *blob;
  size_t size = root->GetBlob(&blob);
  return {root->BlobDigest, blob, size};
}
```

`src/d3d12/d3d12_pipeline_graphics.cpp`:

1. In `MTLD3D12GraphicsPipelineStateImpl`'s members, after `MTL_SHADER_REFLECTION ref_ps;`, add:

```cpp
  Sha1Digest digest_vs_ = {}, digest_ps_ = {}, digest_gs_ = {}; // the shaders' SHA-1s, for the recording
```

2. In `InitializeGeometry`, after `if (FAILED(hr = CompilePixelShader(pDesc, shader_ps, geometry_info_.colors, dual_source_blending, geometry_ps_)))\n      return hr;`, add:

```cpp
    digest_vs_ = geometry_vs_.digest();
    digest_ps_ = shader_ps.digest();
    digest_gs_ = geometry_gs_.digest();
```

3. In `Initialize`, after `if (FAILED(hr = CompilePixelShader(pDesc, shader_ps, info.colors, dual_source_blending, ps_func)))\n      return hr;`, add:

```cpp
    digest_vs_ = shader_vs.digest();
    digest_ps_ = shader_ps.digest();
```

4. After `Initialize`'s closing brace, add:

```cpp
  // Shader pre-caching: appends this pipeline to the recording (spec §3.5), once its creation succeeded.
  void
  Record(const D3D12_GRAPHICS_PIPELINE_STATE_DESC &desc) {
    if (!record::RecordingOn())
      return;
    record::RecordGraphics(desc, RootBlob(desc.pRootSignature),
                           {digest_vs_, desc.VS.pShaderBytecode, desc.VS.BytecodeLength},
                           {digest_ps_, desc.PS.pShaderBytecode, desc.PS.BytecodeLength},
                           {digest_gs_, desc.GS.pShaderBytecode, desc.GS.BytecodeLength});
  }
```

5. In `CreateGraphicsPipelineState`, after `pso->desc_hash = HashGraphicsDesc(*pDesc);`, add `pso->Record(*pDesc);`.

`src/d3d12/d3d12_pipeline_compute.cpp`:

1. After `MTL_SHADER_REFLECTION ref_cs;`, add `Sha1Digest digest_cs_ = {}; // for the recording`.
2. After the new `CompileFunction(...)` call and its `return hr;` (Task 3 Step 7), add `digest_cs_ = shader_cs.digest();`.
3. After `Initialize`'s closing brace, add:

```cpp
  // Shader pre-caching: appends this pipeline to the recording (spec §3.5), once its creation succeeded.
  void
  Record(const D3D12_COMPUTE_PIPELINE_STATE_DESC &desc) {
    if (record::RecordingOn())
      record::RecordCompute(desc, RootBlob(desc.pRootSignature),
                            {digest_cs_, desc.CS.pShaderBytecode, desc.CS.BytecodeLength});
  }
```

4. In `CreateComputePipelineState`, after `pso->desc_hash = HashComputeDesc(*pDesc);`, add `pso->Record(*pDesc);`.

- [ ] **Step 6: See the dev loop record**

Run the Step 2 command again, then `head -c 8 "$R/d3d12_cache.exe.pipelines"`.

Expected: `ls` lists `d3d12_cache.exe.pipelines`, which starts with `DXMTPRC1`. The `dxmt: cache a ok …` line equals D3DMetal's.

- [ ] **Step 7: Land, run the full check, commit**

```bash
git -C build/dxmt-src/dxmt add src/util src/dxmt src/dxgi src/d3d12
git -C build/dxmt-src/dxmt commit -m "d3d12: record each new pipeline description (shader pre-caching); DXMT_CACHE_EXE

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git -C build/dxmt-src/dxmt push origin macneutron
sed -i '' "s/^DXMT_COMMIT=.*/DXMT_COMMIT=$(git -C build/dxmt-src/dxmt rev-parse HEAD)/" dxmt/pins
make dxmt-check > "$W/check-t4.log" 2>&1; grep -E '^(FAIL|dxmt-check)' "$W/check-t4.log"
git add dxmt/check.sh dxmt/pins
git commit -m "test(dxmt): pipeline recording: once per pipeline, torn tail, foreign file, unwritable folder

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Expected from the check: `dxmt-check: all passed`, no `FAIL`.

---

### Task 5: The replayer, staged and installed

**Files:**
- Create: `build/dxmt-src/dxmt/src/replay/dxmt_replay.cpp`, `build/dxmt-src/dxmt/src/replay/meson.build`
- Modify: `build/dxmt-src/dxmt/src/meson.build` (`subdir('replay')`)
- Modify: `dxmt/build.sh` (stage and verify `dxmt-replay.exe`), `dxmt/tests/run.sh` (copy it; show `replay: ` lines)
- Modify: `Sources/MacNeutronCore/DXMTInstaller.swift:55-58`, `Sources/MacNeutronCore/ToolLayout.swift`
- Modify: `Tests/MacNeutronCoreTests/Support.swift` (`makeDXMTBuild`), `Tests/MacNeutronCoreTests/DXMTInstallerTests.swift`
- Modify: `dxmt/check.sh` (a new section 9)

**Interfaces:**
- Consumes: `record::Read`, `ParseGraphics`, `ParseCompute`, `GraphicsRecord`, `ComputeRecord`, `kGraphics`, `kCompute` (Task 4); `DXMT_CACHE_EXE` (Task 4).
- Produces:
  - `dxmt-replay.exe <recording>`, which prints `replay progress <n>/<total>` lines and one final line, `replay: <n> pipelines (<g> graphics, <c> compute), <ok> created, <failed> failed, <bad> bad records, <ms> ms`, then exits 0. It prints `replay: not a recording` or `replay: no D3D12 device` and exits 1 on those failures;
  - `ToolLayout.dxmtReplay: URL` (`Libraries/DXMT/x64/dxmt-replay.exe`);
  - `build/dxmt/x86_64-windows/dxmt-replay.exe`.

- [ ] **Step 1: Write the failing Swift test**

In `Tests/MacNeutronCoreTests/Support.swift`'s `makeDXMTBuild`, change the `x86_64-windows` list to `["winemetal.dll", "d3d11.dll", "d3d10core.dll", "dxgi.dll", "d3d12.dll", "dxmt-replay.exe"]`.

In `Tests/MacNeutronCoreTests/DXMTInstallerTests.swift`, add:

```swift
@Test func installsTheReplayerBesideD3D12() throws {
    let layout = try makeToolLayout()
    let build = try makeDXMTBuild(in: try makeTempDir())
    try DXMTInstaller.install(layout: layout, from: build)
    #expect(try String(contentsOf: layout.dxmtReplay, encoding: .utf8) == "ours x86_64-windows dxmt-replay.exe")
    #expect(layout.dxmtReplay.path(percentEncoded: false).hasSuffix("/Libraries/DXMT/x64/dxmt-replay.exe"))
}

@Test func aBuildWithoutTheReplayerIsRefused() throws {
    let folder = try makeTempDir()
    try makeDXMTBuild(in: folder)
    try FileManager.default.removeItem(at: folder.appending(path: "x86_64-windows/dxmt-replay.exe"))
    #expect(DXMTBuild(folder: folder) == nil)
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `swift test --filter DXMTInstallerTests 2>&1 | tail -5`

Expected: a compile error, `value of type 'ToolLayout' has no member 'dxmtReplay'`.

- [ ] **Step 3: Install the replayer**

In `Sources/MacNeutronCore/ToolLayout.swift`, after `dxmtHasD3D12`, add:

```swift
    /// Our DXMT's pipeline replayer (shader pre-caching), run by the launcher under Wine.
    public var dxmtReplay: URL { dxmt.appending(path: "x64/dxmt-replay.exe") }
```

In `Sources/MacNeutronCore/DXMTInstaller.swift`, change the `frontEnds` comment and x64 entry to:

```swift
    /// Front ends that go into `Libraries/DXMT/<dir>`, where prefixes get them, and the 64-bit pipeline replayer, which
    /// stays there. Direct3D 12 is 64-bit only.
    static let frontEnds: [(arch: String, dir: String, dlls: [String])] = [
        ("x86_64-windows", "x64", ["d3d11.dll", "d3d10core.dll", "dxgi.dll", "d3d12.dll", "dxmt-replay.exe"]),
        ("i386-windows", "x32", ["d3d11.dll", "d3d10core.dll", "dxgi.dll"]),
    ]
```

Run: `swift test 2>&1 | tail -3`

Expected: every test passes, including the two new ones.

- [ ] **Step 4: Write the failing replay checks**

In `dxmt/check.sh`, after section 8, add:

```sh
# 9. Replay (spec §3.6, §5.2 runs 8-12): dxmt-replay.exe rebuilds a recording into that game's caches.
RP="$WORK/ours/Libraries/DXMT/x64/dxmt-replay.exe"
replay() { run ours "$1" dxmt "$RP" "Z:$2"; grep '^replay: ' "$WORK/$1.txt" | tail -1 | sed 's/, [0-9]* ms$//'; }
UC="$(getconf DARWIN_USER_CACHE_DIR)dxmt"; rm -rf "$UC/d3d12_cache.exe" "$UC/dxmt-replay.exe"
CACHE="$WORK/cache/replay"
expect "run 8: the replay rebuilds every recorded pipeline" "$(replay rep8 "$f")" \
  "replay: 2 pipelines (1 graphics, 1 compute), 2 created, 0 failed, 0 bad records"
expect "into the game's Metal cache, not the replayer's" \
  "$([ -d "$UC/d3d12_cache.exe/com.apple.metal" ] && echo game):$([ -d "$UC/dxmt-replay.exe" ] && echo replayer)" "game:"
cachetest rep9 a
expect "run 9: after a replay the game only hits" "$(counters rep9)" \
  "d3d12 shader cache: functions 3 hit 0 missed, reflections 3 hit 0 missed"
expect "and draws as D3DMetal" "$(drawn rep9)" "$(drawn cache-ref-a)"
cp "$f" "$WORK/torn.pipelines"
python3 -c "import os, sys; os.truncate(sys.argv[1], os.path.getsize(sys.argv[1]) - 10)" "$WORK/torn.pipelines"
CACHE="$WORK/cache/replay-torn"
expect "run 10: a torn record is skipped and counted" "$(replay rep10 "$WORK/torn.pipelines")" \
  "replay: 1 pipelines (1 graphics, 0 compute), 1 created, 0 failed, 1 bad records"
export DXMT_PIPELINE_RECORD="$WORK/rec-gs"
CACHE="$WORK/cache/gs-rec"
run ours gs-rec dxmt "$TESTS/d3d12_triangle.exe" "Z:$S/triangle2.vs.dxil" "Z:$S/triangle2.ps.dxil" "Z:$S/triangle2.gs.dxil"
export DXMT_PIPELINE_RECORD="$WORK/rec-threads"
run ours threads-rec dxmt "$TESTS/d3d12_dxil_exec.exe" "Z:$X" threads
unset DXMT_PIPELINE_RECORD
CACHE="$WORK/cache/gs-replay"
expect "run 12: a geometry-shader pipeline replays" \
  "$(replay gs-replay "$WORK/rec-gs/d3d12_triangle.exe.pipelines" | grep -cE '^replay: [1-9][0-9]* pipelines .*, 0 failed, 0 bad records$' || true)" 1
run ours gs-after dxmt "$TESTS/d3d12_triangle.exe" "Z:$S/triangle2.vs.dxil" "Z:$S/triangle2.ps.dxil" "Z:$S/triangle2.gs.dxil"
expect "and then only hits" \
  "$(counters gs-after | grep -cE 'functions [1-9][0-9]* hit 0 missed, reflections [1-9][0-9]* hit 0 missed$' || true)" 1
expect "and draws as D3DMetal" "$(same_pixels "$WORK/gs-after.txt" "$WORK/trigs-ref.txt")" yes
CACHE="$WORK/cache/threads"
expect "pipelines created on 8 threads at once replay whole" \
  "$(replay threads-replay "$WORK/rec-threads/d3d12_dxil_exec.exe.pipelines" | grep -cE '^replay: [1-9][0-9]* pipelines .*, 0 failed, 0 bad records$' || true)" 1
# A recorded pipeline this DXMT can't build (a junk shader), and a file that isn't a recording.
python3 - "$WORK/junk.pipelines" <<'PY'
import hashlib, struct, sys
def fnv(b):
    h = 0xcbf29ce484222325
    for x in b: h = ((h ^ x) * 0x100000001b3) & 0xffffffffffffffff
    return h
def record(kind, payload, id):
    return struct.pack("<IIQ", kind, len(payload), fnv(payload)) + id + payload
junk = b"DXBC" + bytes(60)
compute = bytes(20) + hashlib.sha1(junk).digest() + struct.pack("<II", 0, 0)  # no root signature, the junk CS
open(sys.argv[1], "wb").write(b"DXMTPRC1" + record(1, junk, hashlib.sha1(junk).digest())
                              + record(3, compute, hashlib.sha1(compute).digest()))
PY
CACHE="$WORK/cache/junk"
expect "a recorded pipeline that no longer builds is counted, not fatal" "$(replay junk "$WORK/junk.pipelines")" \
  "replay: 1 pipelines (0 graphics, 1 compute), 0 created, 1 failed, 0 bad records"
printf 'nope' > "$WORK/foreign.pipelines"
expect "a file that isn't a recording is refused" "$(replay foreign "$WORK/foreign.pipelines")" "replay: not a recording"
unset CACHE
```

- [ ] **Step 5: Write the replayer**

Run `git -C build/dxmt-src/dxmt switch macneutron`. Create `src/replay/dxmt_replay.cpp`, with the LGPL notice:

```cpp
// dxmt-replay.exe <recording>: rebuilds every pipeline a game recorded (d3d12_pipeline_record) through our d3d12.dll,
// on every core, into that game's translation and Metal caches (shader pre-caching spec §3.6). MacNeutron's launcher
// runs it before a game after a DXMT or macOS update, as Steam runs fossilize_replay for Vulkan games.
#include "d3d12_pipeline_record.hpp"
#include "log/log.hpp"
#include <windows.h>
#include <d3d12.h>
#include <algorithm>
#include <atomic>
#include <cstdio>
#include <thread>
#include <unordered_map>
#include <vector>

namespace dxmt {
Logger Logger::s_instance("dxmt-replay.log");
} // namespace dxmt

using namespace dxmt;

namespace {

const Sha1Digest kNone = {};

struct Job {
  record::Kind kind;
  record::GraphicsRecord graphics;
  record::ComputeRecord compute;
  ID3D12RootSignature *root = nullptr;
  bool root_failed = false;
};

} // namespace

int
wmain(int argc, wchar_t **argv) {
  if (argc != 2) {
    printf("usage: dxmt-replay.exe <recording>\n");
    return 1;
  }
  // A recording is named after the game's executable: DXMT then resolves that game's cache folders.
  std::wstring path = argv[1], name = path.substr(path.find_last_of(L"\\/") + 1);
  const std::wstring extension = L".pipelines";
  if (name.size() <= extension.size() || name.compare(name.size() - extension.size(), extension.size(), extension)) {
    printf("replay: not a recording\n");
    return 1;
  }
  name.resize(name.size() - extension.size());
  SetEnvironmentVariableW(L"DXMT_CACHE_EXE", name.c_str());
  SetEnvironmentVariableW(L"DXMT_PIPELINE_RECORD", nullptr);

  ULONGLONG start = GetTickCount64();
  record::Recording recording = record::Read(path);
  if (!recording.opened) {
    printf("replay: not a recording\n");
    return 1;
  }
  // DXMT loads only now, after DXMT_CACHE_EXE is set: dxgi.dll picks the Metal cache folder as it loads.
  using CreateDevice = HRESULT(WINAPI *)(IUnknown *, D3D_FEATURE_LEVEL, REFIID, void **);
  HMODULE d3d12 = LoadLibraryW(L"d3d12.dll");
  auto create = d3d12 ? reinterpret_cast<CreateDevice>(GetProcAddress(d3d12, "D3D12CreateDevice")) : nullptr;
  ID3D12Device *device = nullptr;
  if (!create || FAILED(create(nullptr, D3D_FEATURE_LEVEL_11_0, __uuidof(ID3D12Device), (void **)&device))) {
    printf("replay: no D3D12 device\n");
    return 1;
  }

  // Parse every pipeline and create its root signature, one thread; a pipeline missing a blob counts as bad.
  uint64_t bad = recording.bad;
  size_t graphics = 0, compute = 0;
  std::unordered_map<Sha1Digest, ID3D12RootSignature *> roots;
  auto has = [&](const Sha1Digest &id) { return id == kNone || recording.blobs.count(id); };
  auto code = [&](const Sha1Digest &id) -> D3D12_SHADER_BYTECODE {
    if (id == kNone)
      return {};
    auto &bytes = recording.blobs.at(id);
    return {bytes.data(), bytes.size()};
  };
  std::vector<Job> jobs;
  for (auto &[kind, payload] : recording.pipelines) {
    Job job = {kind};
    bool ok;
    Sha1Digest root_id;
    if (kind == record::kGraphics) {
      auto &g = job.graphics;
      ok = record::ParseGraphics(payload, g) && has(g.root) && has(g.vs) && has(g.ps) && has(g.gs);
      if (ok) {
        g.desc.VS = code(g.vs);
        g.desc.PS = code(g.ps);
        g.desc.GS = code(g.gs);
      }
      root_id = g.root;
    } else {
      auto &c = job.compute;
      ok = record::ParseCompute(payload, c) && has(c.root) && has(c.cs);
      if (ok)
        c.desc.CS = code(c.cs);
      root_id = c.root;
    }
    if (!ok) {
      bad++;
      continue;
    }
    if (root_id != kNone) {
      auto [slot, created] = roots.try_emplace(root_id, nullptr);
      if (created) {
        auto blob = code(root_id);
        if (FAILED(device->CreateRootSignature(0, blob.pShaderBytecode, blob.BytecodeLength,
                                               __uuidof(ID3D12RootSignature), (void **)&slot->second)))
          slot->second = nullptr;
      }
      job.root = slot->second;
      job.root_failed = !job.root;
    }
    (kind == record::kGraphics ? graphics : compute)++;
    jobs.push_back(std::move(job));
  }

  std::atomic<size_t> next{0}, done{0}, created{0}, failed{0};
  auto run = [&](Job &job) {
    HRESULT hr = E_FAIL;
    ID3D12PipelineState *pso = nullptr;
    if (job.root_failed) {
      // counted below as failed
    } else if (job.kind == record::kGraphics) {
      auto &g = job.graphics;
      for (size_t i = 0; i < g.elements.size(); i++)
        g.elements[i].SemanticName = g.names[i].c_str();
      g.desc.InputLayout = {g.elements.data(), (UINT)g.elements.size()};
      g.desc.pRootSignature = job.root;
      hr = device->CreateGraphicsPipelineState(&g.desc, __uuidof(ID3D12PipelineState), (void **)&pso);
    } else {
      job.compute.desc.pRootSignature = job.root;
      hr = device->CreateComputePipelineState(&job.compute.desc, __uuidof(ID3D12PipelineState), (void **)&pso);
    }
    if (SUCCEEDED(hr)) {
      pso->Release();
      created++;
    } else {
      failed++;
    }
  };
  auto work = [&] {
    for (size_t i; (i = next++) < jobs.size();) {
      run(jobs[i]);
      size_t n = ++done;
      if (n * 10 / jobs.size() != (n - 1) * 10 / jobs.size()) {
        printf("replay progress %zu/%zu\n", n, jobs.size());
        fflush(stdout);
      }
    }
  };
  std::vector<std::thread> threads(std::max(1u, std::thread::hardware_concurrency()));
  for (auto &thread : threads)
    thread = std::thread(work);
  for (auto &thread : threads)
    thread.join();
  printf("replay: %zu pipelines (%zu graphics, %zu compute), %zu created, %zu failed, %llu bad records, %llu ms\n",
         jobs.size(), graphics, compute, created.load(), failed.load(), (unsigned long long)bad,
         (unsigned long long)(GetTickCount64() - start));
  fflush(stdout);
  return 0;
}
```

Create `src/replay/meson.build`:

```meson
# dxmt-replay.exe (MacNeutron): rebuilds a game's recorded D3D12 pipelines; see dxmt_replay.cpp.
executable('dxmt-replay', [ 'dxmt_replay.cpp', '../d3d12/d3d12_pipeline_record.cpp' ],
  dependencies        : [ util_dep ],
  include_directories : [ dxmt_include_path, include_directories('../d3d12') ],
  link_args           : [ '-municode' ],
  install             : true,
  install_dir         : windows_native_install_dir,
)
```

In `src/meson.build`, change:

```meson
if get_option('enable_d3d12')
subdir('d3d12')
endif
```

to:

```meson
if get_option('enable_d3d12')
subdir('d3d12')
subdir('replay')
endif
```

- [ ] **Step 6: Stage it**

In `dxmt/build.sh`, change `cp "$I64"/x86_64-windows/*.dll "$I64"/system32/*.dll "$T/x86_64-windows/"` to:

```sh
cp "$I64"/x86_64-windows/*.dll "$I64"/system32/*.dll "$I64"/system32/dxmt-replay.exe "$T/x86_64-windows/"
```

and add `x86_64-windows/dxmt-replay.exe` to the list the second `for f in …` loop checks (after `x86_64-windows/d3d12.dll`).

In `dxmt/tests/run.sh`:
- change its first `cp` line to also copy `"$SRC"/win64-install/system32/dxmt-replay.exe`;
- change the filter to `grep -E '^([a-z][a-z0-9-]* |info:  d3d12 shader cache|replay: )'`.

- [ ] **Step 7: See it replay in the dev loop**

```bash
make build > /dev/null
S=$PWD/dxmt/tests/shaders; R="${TMPDIR:-/tmp}/rec-dev"; C="${TMPDIR:-/tmp}/cache-replay-dev"; rm -rf "$R" "$C"
RUN_ENV="DXMT_PIPELINE_RECORD=$R" sh dxmt/tests/run.sh d3d12_cache "Z:$S/cache.vs.dxil" "Z:$S/cache.ps.dxil" "Z:$S/cache.cs.dxil" a > /dev/null
WORK="${TMPDIR:-/tmp}/macneutron dxmt"; env STEAM_COMPAT_DATA_PATH="$WORK/compat/ours" SteamAppId=0 MACNEUTRON_GRAPHICS=dxmt \
  MACNEUTRON_NO_STEAM_BRIDGE=1 MACNEUTRON_NO_METALFX=1 DXMT_SHADER_CACHE_PATH="$C" \
  "$WORK/ours/bin/macneutron" launch waitforexitandrun "$WORK/ours/Libraries/DXMT/x64/dxmt-replay.exe" "Z:$R/d3d12_cache.exe.pipelines" 2>&1 | tr -d '\r' | grep '^replay'
RUN_ENV="DXMT_SHADER_CACHE_PATH=$C" sh dxmt/tests/run.sh d3d12_cache "Z:$S/cache.vs.dxil" "Z:$S/cache.ps.dxil" "Z:$S/cache.cs.dxil" a | grep 'shader cache'
```

Expected:
- `replay progress 1/2`, `replay progress 2/2`, then `replay: 2 pipelines (1 graphics, 1 compute), 2 created, 0 failed, 0 bad records, <n> ms`;
- then `dxmt: info:  d3d12 shader cache: functions 3 hit 0 missed, reflections 3 hit 0 missed`.

Note: `run.sh`'s last command uses its own `RUN_ENV` cache folder.

- [ ] **Step 8: Land, run the full check, commit**

```bash
git -C build/dxmt-src/dxmt add src/replay src/meson.build
git -C build/dxmt-src/dxmt commit -m "replay: dxmt-replay.exe rebuilds a game's recorded pipelines on every core

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git -C build/dxmt-src/dxmt push origin macneutron
sed -i '' "s/^DXMT_COMMIT=.*/DXMT_COMMIT=$(git -C build/dxmt-src/dxmt rev-parse HEAD)/" dxmt/pins
make dxmt-check > "$W/check-t5.log" 2>&1; grep -E '^(FAIL|dxmt-check)' "$W/check-t5.log"
swift test 2>&1 | tail -3
git add Sources/MacNeutronCore/DXMTInstaller.swift Sources/MacNeutronCore/ToolLayout.swift \
  Tests/MacNeutronCoreTests/Support.swift Tests/MacNeutronCoreTests/DXMTInstallerTests.swift \
  dxmt/build.sh dxmt/tests/run.sh dxmt/check.sh dxmt/pins
git commit -m "feat(dxmt): ship and install dxmt-replay.exe; replay checks

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Expected: `dxmt-check: all passed` with no `FAIL`, and every Swift test passing.

---

### Task 6: The launcher replays before the game

**Files:**
- Create: `Sources/MacNeutronCore/ShaderPrecache.swift`, `Tests/MacNeutronCoreTests/ShaderPrecacheTests.swift`
- Modify: `Sources/MacNeutronCore/LaunchEnvironment.swift` (`build`), `Sources/MacNeutronCore/Launcher.swift` (`.waitforexitandrun`)
- Modify: `Tests/MacNeutronCoreTests/LaunchEnvironmentTests.swift`, `dxmt/check.sh` (a new section 10)

**Interfaces:**
- Consumes:
  - `ToolLayout.dxmtReplay` (Task 5), `ToolLayout.dxmtVersion` and `dxmtHasD3D12`;
  - `dxmt-replay.exe`'s final `replay: …` line (Task 5);
  - `DXMT_PIPELINE_RECORD` (Task 4);
  - `FakeRunner`, `RecordingNotifier`, `makeToolLayout`, `makeTempDir`, `write`, `steamEnvironment` and `makeSteamLocation` (existing test support).
- Produces:
  - `public struct ShaderPrecache` with:
    - `init(context:layout:osBuild:)`, `static func folder(for: CompatContext) -> URL` and `static func enabled(backend:layout:environment:) -> Bool`;
    - `stampFile`, `recordings`, `needsReplay`, `writeStamp()` and `writeStampIfMissing()`;
    - `replay(layout:runner:environment:) -> [String]` and `static func macOSBuild() -> String`;
  - launcher log lines `precache: <file> exit=<status> <replay line or "no result">`;
  - the notification `Preparing shaders for this game (DXMT or macOS changed)`.

- [ ] **Step 1: Write the failing Swift tests**

Create `Tests/MacNeutronCoreTests/ShaderPrecacheTests.swift`:

```swift
import Foundation
import Testing
@testable import MacNeutronCore

private struct PrecacheFixture {
    let launcher: Launcher
    let runner: FakeRunner
    let notifier: RecordingNotifier
    let env: [String: String]
    let folder: URL
    let builds: String
    var stamp: String? { try? String(contentsOf: folder.appending(path: "replayed"), encoding: .utf8) }
    var replays: [FakeRunner.Call] { runner.calls.filter { $0.arguments.first?.hasSuffix("dxmt-replay.exe") == true } }
    var launcherLog: String { (try? String(contentsOf: launcher.log.launcherLog, encoding: .utf8)) ?? "" }
}

/// A launcher whose tool folder has our DXMT with Direct3D 12 and the replayer. The fake dxmt-replay.exe writes a
/// result line to its output and returns `replayStatus`.
private func makePrecacheFixture(replayStatus: Int32 = 0) throws -> PrecacheFixture {
    let layout = try makeToolLayout()
    try write("ours d3d12", to: layout.dxmtD3D12)
    try write("ours replay", to: layout.dxmtReplay)
    try write("fork123\n", to: layout.dxmtVersionFile)
    let runner = FakeRunner { call in
        if call.arguments.first == "wineboot", let prefix = call.environment["WINEPREFIX"] {
            try? FileManager.default.createDirectory(atPath: prefix, withIntermediateDirectories: true)
        }
        if call.arguments.first?.hasSuffix("dxmt-replay.exe") == true, let output = call.output {
            try? "replay progress 2/2\r\nreplay: 2 pipelines (1 graphics, 1 compute), 2 created, 0 failed, 0 bad records, 5 ms\r\n"
                .write(to: output, atomically: true, encoding: .utf8)
            return replayStatus
        }
        return 0
    }
    let notifier = RecordingNotifier()
    let data = try makeTempDir().appending(path: "compatdata/42", directoryHint: .isDirectory)
    let launcher = Launcher(layout: layout, runner: runner,
                            log: LauncherLog(directory: try makeTempDir().appending(path: "Logs")),
                            notifier: notifier, preflight: Preflight(rosettaAvailable: { true }),
                            settings: GameSettingsStore(directory: try makeTempDir().appending(path: "games")),
                            steam: try makeSteamLocation())
    let env = steamEnvironment(dataPath: data, appID: "42")
    let context = try CompatContext(environment: env)
    return PrecacheFixture(launcher: launcher, runner: runner, notifier: notifier, env: env,
                           folder: ShaderPrecache.folder(for: context),
                           builds: "fork123 \(ShaderPrecache.macOSBuild())")
}

private let game = ["waitforexitandrun", "/g/Game.exe"]

@Test func theGameRecordsIntoItsCompatFolder() throws {
    let f = try makePrecacheFixture()
    _ = f.launcher.launch(game, environment: f.env)
    let run = f.runner.calls.first { $0.arguments == ["/g/Game.exe"] }
    #expect(run?.environment["DXMT_PIPELINE_RECORD"] == f.folder.path(percentEncoded: false))
    #expect(f.folder.path(percentEncoded: false).hasSuffix("compatdata/42/dxmt-pipelines"))
}

@Test func theFirstSessionStampsWithoutReplaying() throws {
    let f = try makePrecacheFixture()
    #expect(f.launcher.launch(game, environment: f.env) == 0)
    #expect(f.replays.isEmpty)
    #expect(f.stamp == f.builds + "\n")
}

@Test func recordingsWithoutAStampAreNotReplayed() throws {
    let f = try makePrecacheFixture()
    try write("rec", to: f.folder.appending(path: "Game.exe.pipelines"))
    _ = f.launcher.launch(game, environment: f.env)
    #expect(f.replays.isEmpty)
    #expect(f.stamp == f.builds + "\n")
}

@Test func theSameBuildsDoNotReplay() throws {
    let f = try makePrecacheFixture()
    try write("rec", to: f.folder.appending(path: "Game.exe.pipelines"))
    try write(f.builds + "\n", to: f.folder.appending(path: "replayed"))
    _ = f.launcher.launch(game, environment: f.env)
    #expect(f.replays.isEmpty)
}

@Test func changedBuildsReplayEveryRecordingBeforeTheGame() throws {
    let f = try makePrecacheFixture()
    let a = f.folder.appending(path: "A.exe.pipelines"), b = f.folder.appending(path: "B.exe.pipelines")
    try write("rec", to: a)
    try write("rec", to: b)
    try write("old 1A2\n", to: f.folder.appending(path: "replayed"))
    #expect(f.launcher.launch(game, environment: f.env) == 0)
    #expect(f.replays.map { $0.arguments } == [
        [f.launcher.layout.dxmtReplay.path(percentEncoded: false), "Z:" + a.path(percentEncoded: false)],
        [f.launcher.layout.dxmtReplay.path(percentEncoded: false), "Z:" + b.path(percentEncoded: false)],
    ])
    #expect(f.replays.allSatisfy { $0.environment["DXMT_PIPELINE_RECORD"] == nil })
    let calls = f.runner.calls
    let lastReplay = try #require(calls.lastIndex { $0.arguments.first?.hasSuffix("dxmt-replay.exe") == true })
    let gameRun = try #require(calls.firstIndex { $0.arguments == ["/g/Game.exe"] })
    #expect(lastReplay < gameRun)
    #expect(f.stamp == f.builds + "\n")
    #expect(f.notifier.posted == ["Preparing shaders for this game (DXMT or macOS changed)"])
    #expect(f.launcherLog.contains(
        "precache: A.exe.pipelines exit=0 replay: 2 pipelines (1 graphics, 1 compute), 2 created, 0 failed, 0 bad records, 5 ms"))
}

@Test func aFailedReplayStillStartsTheGame() throws {
    let f = try makePrecacheFixture(replayStatus: 1)
    try write("rec", to: f.folder.appending(path: "Game.exe.pipelines"))
    try write("old 1A2\n", to: f.folder.appending(path: "replayed"))
    #expect(f.launcher.launch(game, environment: f.env) == 0)
    #expect(f.runner.calls.contains { $0.arguments == ["/g/Game.exe"] })
    #expect(f.stamp == f.builds + "\n")
    #expect(f.launcherLog.contains("precache: Game.exe.pipelines exit=1 "))
}

@Test func theRunVerbNeitherReplaysNorStamps() throws {
    let f = try makePrecacheFixture()
    try write("rec", to: f.folder.appending(path: "Game.exe.pipelines"))
    try write("old 1A2\n", to: f.folder.appending(path: "replayed"))
    _ = f.launcher.launch(["run", "/g/Game.exe"], environment: f.env)
    #expect(f.replays.isEmpty)
    #expect(f.stamp == "old 1A2\n")
}

@Test func precacheCanBeTurnedOff() throws {
    let f = try makePrecacheFixture()
    try write("rec", to: f.folder.appending(path: "Game.exe.pipelines"))
    try write("old 1A2\n", to: f.folder.appending(path: "replayed"))
    var env = f.env
    env["MACNEUTRON_PRECACHE"] = "0"
    _ = f.launcher.launch(game, environment: env)
    #expect(f.replays.isEmpty)
    #expect(f.runner.calls.first { $0.arguments == ["/g/Game.exe"] }?.environment["DXMT_PIPELINE_RECORD"] == nil)
    #expect(f.stamp == "old 1A2\n")
}
```

In `Tests/MacNeutronCoreTests/LaunchEnvironmentTests.swift`, add:

```swift
@Test func recordsPipelinesOnlyForOurD3D12() throws {
    let ours = try makeToolLayout()
    try write("ours d3d12", to: ours.dxmtD3D12)
    func record(_ base: [String: String], _ backend: GraphicsBackend, _ layout: ToolLayout) -> String? {
        LaunchEnvironment.build(base: base, context: context, backend: backend, layout: layout, logging: false)["DXMT_PIPELINE_RECORD"]
    }
    #expect(record([:], .dxmt, ours) == "/c/42/dxmt-pipelines")
    #expect(record(["MACNEUTRON_PRECACHE": "0"], .dxmt, ours) == nil)
    #expect(record([:], .d3dmetal, ours) == nil)
    #expect(record([:], .dxmt, layout) == nil)  // the runtime's DXMT 0.80: no d3d12.dll
    #expect(record(["DXMT_PIPELINE_RECORD": "/mine"], .dxmt, ours) == "/mine")
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test 2>&1 | tail -5`

Expected: a compile error, `cannot find 'ShaderPrecache' in scope`.

- [ ] **Step 3: Implement `ShaderPrecache`**

Create `Sources/MacNeutronCore/ShaderPrecache.swift`:

```swift
import Foundation

/// Shader pre-caching as Steam does it for Vulkan games (docs/superpowers/specs/2026-09-30-macneutron-pipeline-cache-design.md
/// §3.7): our d3d12.dll records each game's pipelines in `<compatdata>/dxmt-pipelines`, and after a DXMT or macOS
/// update the launcher rebuilds them with `dxmt-replay.exe` before the game starts.
public struct ShaderPrecache: Sendable {
    public let folder: URL
    /// The builds the recordings are compiled for: `<dxmt-version> <macOS build>`.
    public let builds: String

    public init(context: CompatContext, layout: ToolLayout, osBuild: String = ShaderPrecache.macOSBuild()) {
        folder = Self.folder(for: context)
        builds = "\(layout.dxmtVersion ?? "none") \(osBuild)"
    }

    public static func folder(for context: CompatContext) -> URL { context.dataPath.appending(path: "dxmt-pipelines") }

    /// Recording and replay need our DXMT's Direct3D 12; `MACNEUTRON_PRECACHE=0` turns both off.
    public static func enabled(backend: GraphicsBackend, layout: ToolLayout, environment: [String: String]) -> Bool {
        backend == .dxmt && layout.dxmtHasD3D12 && environment["MACNEUTRON_PRECACHE"] != "0"
    }

    public var stampFile: URL { folder.appending(path: "replayed") }

    var stamp: String? {
        (try? String(contentsOf: stampFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var recordings: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "pipelines" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Recordings compiled for other builds. No stamp means the recordings came from sessions of these builds.
    public var needsReplay: Bool {
        guard let stamp, stamp != builds else { return false }
        return !recordings.isEmpty
    }

    public func writeStamp() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? (builds + "\n").write(to: stampFile, atomically: true, encoding: .utf8)
    }

    public func writeStampIfMissing() {
        if stamp == nil { writeStamp() }
    }

    /// Runs `dxmt-replay.exe` on every recording in the game's environment, minus recording; one log line each.
    public func replay(layout: ToolLayout, runner: any ProcessRunner, environment: [String: String]) -> [String] {
        var env = environment
        env.removeValue(forKey: "DXMT_PIPELINE_RECORD")
        let output = folder.appending(path: "replay.log")
        return recordings.map { recording in
            try? FileManager.default.removeItem(at: output)
            let status = (try? runner.run(layout.wine, [layout.dxmtReplay.path(percentEncoded: false),
                                                        "Z:" + recording.path(percentEncoded: false)],
                                          environment: env, output: output)) ?? -1
            let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
            let result = text.split(whereSeparator: \.isNewline).last { $0.hasPrefix("replay: ") }
            return "precache: \(recording.lastPathComponent) exit=\(status) \(result.map(String.init) ?? "no result")"
        }
    }

    /// `kern.osversion`, the macOS build (e.g. 25A354): Metal's compiler changes with it.
    public static func macOSBuild() -> String {
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("kern.osversion", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
}
```

In `Sources/MacNeutronCore/LaunchEnvironment.swift`'s `build`, before `return env`, add:

```swift
        if ShaderPrecache.enabled(backend: backend, layout: layout, environment: base), base["DXMT_PIPELINE_RECORD"] == nil {
            env["DXMT_PIPELINE_RECORD"] = ShaderPrecache.folder(for: context).path(percentEncoded: false)
        }
```

In `Sources/MacNeutronCore/Launcher.swift`, replace the `.waitforexitandrun` case's body:

```swift
                try prefix.prepare(backend: backend, environment: env, steamBridge: steamBridge)
                if !steamBridge { try prefix.removeSteamBridge() }
                _ = try runner.run(layout.wineserver, ["-w"], environment: env, output: nil)
                status = try runGame(request, env, gameLog, throughSteam: steamBridge)
                // Keep Steam's "running" state until every process in the prefix is gone
                // (covers launchers that start the real game and exit).
                _ = try runner.run(layout.wineserver, ["-w"], environment: env, output: nil)
```

with:

```swift
                try prefix.prepare(backend: backend, environment: env, steamBridge: steamBridge)
                if !steamBridge { try prefix.removeSteamBridge() }
                _ = try runner.run(layout.wineserver, ["-w"], environment: env, output: nil)
                // Shader pre-caching: after a DXMT or macOS update, rebuild the recorded pipelines before the game.
                let precache = ShaderPrecache.enabled(backend: backend, layout: layout, environment: env)
                    ? ShaderPrecache(context: context, layout: layout) : nil
                if let precache, precache.needsReplay {
                    notifier.post(title: "MacNeutron", message: "Preparing shaders for this game (DXMT or macOS changed)")
                    for line in precache.replay(layout: layout, runner: runner, environment: env) { log.append(line) }
                    precache.writeStamp()
                }
                status = try runGame(request, env, gameLog, throughSteam: steamBridge)
                // Keep Steam's "running" state until every process in the prefix is gone
                // (covers launchers that start the real game and exit).
                _ = try runner.run(layout.wineserver, ["-w"], environment: env, output: nil)
                precache?.writeStampIfMissing()
```

- [ ] **Step 4: Run the Swift tests**

Run: `swift test 2>&1 | tail -5`

Expected: every test passes (the existing ones plus the 9 new).

- [ ] **Step 5: Write the end-to-end check**

In `dxmt/check.sh`, after section 9, add:

```sh
# 10. The launcher (spec §3.7): recordings land in the compat folder and the first session stamps the builds; with
#     another build in the stamp, the next launch replays every recording before the game, which then only hits.
#     (d3d12_cache's recording there holds every mode section 7 ran: a, rt, layout and root.)
P="$WORK/compat/ours/dxmt-pipelines"
expect "the launcher records into the game's compat folder" "$([ -s "$P/d3d12_cache.exe.pipelines" ] && echo yes || echo no)" yes
expect "and stamps the builds after the first session" "$(cut -d ' ' -f 1 "$P/replayed" 2> /dev/null)" "$(cat "$WORK/ours/dxmt-version")"
echo "old build" > "$P/replayed"
LLOG="$HOME/Library/Logs/MacNeutron/launcher.log"; before=$(cat "$LLOG" 2> /dev/null | wc -l)
CACHE="$WORK/cache/e2e"
cachetest e2e a
unset CACHE
expect "a changed build replays d3d12_cache's recording before the game" \
  "$(tail -n +$((before + 1)) "$LLOG" | grep -cE 'precache: d3d12_cache\.exe\.pipelines exit=0 replay: [1-9][0-9]* pipelines .*, 0 failed, 0 bad records' || true)" 1
expect "then the game only hits" "$(counters e2e)" "d3d12 shader cache: functions 3 hit 0 missed, reflections 3 hit 0 missed"
expect "and draws as D3DMetal" "$(drawn e2e)" "$(drawn cache-ref-a)"
expect "and the stamp holds the current builds" "$(cut -d ' ' -f 1 "$P/replayed")" "$(cat "$WORK/ours/dxmt-version")"
```

- [ ] **Step 6: Run the full check, commit**

```bash
make dxmt-check > "$W/check-t6.log" 2>&1; grep -E '^(FAIL|dxmt-check)' "$W/check-t6.log"
git add Sources/MacNeutronCore/ShaderPrecache.swift Sources/MacNeutronCore/LaunchEnvironment.swift \
  Sources/MacNeutronCore/Launcher.swift Tests/MacNeutronCoreTests/ShaderPrecacheTests.swift \
  Tests/MacNeutronCoreTests/LaunchEnvironmentTests.swift dxmt/check.sh
git commit -m "feat: shader pre-caching: record into the compat folder, replay after DXMT or macOS updates

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Expected: `dxmt-check: all passed`, no `FAIL`. No fork change in this task, so the pin stays.

---

### Task 7: Docs and the acceptance run

**Files:**
- Modify: `README.md` (Per-game options, Graphics)
- Create: `docs/testing/acceptance-dxmt-pipeline-cache.md`

**Interfaces:**
- Consumes: the variables `DXMT_D3D12_SM6`, `MACNEUTRON_PRECACHE`, `DXMT_SHADER_CACHE` and `DXMT_PIPELINE_RECORD`, and the log lines of Tasks 3, 5 and 6.

- [ ] **Step 1: Update the README**

In `README.md`'s Per-game options table, after the `MACNEUTRON_NO_METALFX` row, add:

```markdown
| `/usr/bin/env DXMT_D3D12_SM6=1 %command%` | On DXMT, report the Direct3D 12 features Shader Model 6 games check for (Unreal Engine 5 games need it) |
| `/usr/bin/env MACNEUTRON_PRECACHE=0 %command%` | Don't record the game's pipelines or rebuild them after updates (shader pre-caching) |
```

In the Graphics section, replace the paragraph that starts `DXMT's Direct3D 12 is early.` with:

```markdown
DXMT's Direct3D 12 is early, but it translates Shader Model 6 (DXIL) shaders: SMITE 2 (Unreal Engine 5) plays on it.
Unreal Engine 5 games check for Shader Model 6 features before they start; launch them with
`/usr/bin/env DXMT_D3D12_SM6=1 %command%`. For a game that doesn't run on DXMT yet, import GPTK and set
**Graphics: D3DMetal** for it in the Games window (or use `/usr/bin/env MACNEUTRON_GRAPHICS=d3dmetal %command%`).

**Shader pre-caching**, as Steam does for Vulkan games. DXMT keeps every shader it translates in a cache, so a
Direct3D 12 game translates each shader once. MacNeutron also records every pipeline the game creates, in
`dxmt-pipelines` in the game's Steam compat folder (`~/Library/Application Support/Steam/steamapps/compatdata/<appid>`).
After an update of MacNeutron's DXMT or of macOS, the launcher rebuilds them before the game starts, and a
notification says so. Troubleshooting:

- `DXMT_SHADER_CACHE=0` turns the translation cache off, and `MACNEUTRON_PRECACHE=0` turns recording and rebuilding
  off.
- Deleting `$(getconf DARWIN_USER_CACHE_DIR)dxmt/<game exe>/shaders_*.db` clears the cache.
- Deleting the `dxmt-pipelines` folder clears the recordings.
```

In the paragraph after it (`For DXMT development, …`), replace its last two sentences (from `While it's set, DXMT reports` to the end) with:

```markdown
While it's set, DXMT also reports the Shader Model 6 features, as `DXMT_D3D12_SM6=1` does.
```

- [ ] **Step 2: Write the acceptance doc**

Create `docs/testing/acceptance-dxmt-pipeline-cache.md`:

```markdown
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
```

- [ ] **Step 3: Verify everything and commit**

```bash
swift test 2>&1 | tail -3
make dxmt-check > "$W/check-t7.log" 2>&1; grep -E '^(FAIL|dxmt-check)' "$W/check-t7.log"
git add README.md docs/testing/acceptance-dxmt-pipeline-cache.md
git commit -m "docs: shader pre-caching (README, acceptance test)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Expected: every Swift test passes, and `dxmt-check: all passed` with no `FAIL`.

- [ ] **Step 4: Hand the acceptance run to the user**

The acceptance run needs the user at the keyboard. They change SMITE 2's launch options (never edit Steam's config yourself) and play the routes. Ask them to:
- set launch options to `/usr/bin/env DXMT_D3D12_SM6=1 MACNEUTRON_LOG=1 %command%`;
- play steps 3–5 of `docs/testing/acceptance-dxmt-pipeline-cache.md`, and say when each is done.

Then read the logs, fill in the Results row, and commit it:

```bash
git add docs/testing/acceptance-dxmt-pipeline-cache.md
git commit -m "docs: shader pre-caching acceptance results

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
