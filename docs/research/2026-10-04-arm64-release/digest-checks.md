# Interface digest: the dev check scripts (sub-project 5, §8.1, §8.2, §9 L1-L6)

Code at `69f0e4f` (main). All paths relative to `/Users/chad/Documents/MacProton`. Read-only survey; nothing built or run.

## 0. Cross-cutting facts the plan writer needs

- **CLI today** (`Sources/MacNeutronCore/CommandLineTool.swift`): `public enum CommandLineTool`,
  `public static func run(_ args: [String], environment: [String: String], executable: URL) async -> Int32`.
  Verbs: `launch` (:17-20), `import-gptk` (:21-30), `install-runtime` (:31-43), `install-dxmt` (:44-56); usage text
  :6-11; `static func option(_ name: String, in args: inout [String]) -> String?` (:63-68);
  `static func toolLayout(_ dir: String?) -> ToolLayout` (:70-72). Exit codes: usage 2, failure 1.
- **Who calls the deleted verbs (scripts only):**
  - `install-dxmt`: `dxmt/check.sh:44`, `dxmt/tests/run.sh:17`.
  - `install-runtime`: `Tests/Smoke/smoke.sh:16,18`.
  - `import-gptk`: `Tests/Smoke/smoke.sh:21`.
  - Swift tests on them (`Tests/MacNeutronCoreTests/CommandLineToolTests.swift`): `importGPTKRejectsANonGPTKFolder`
    (:17), `installRuntimeRejectsAWrongTarball` (:24), `installDXMTRejectsAFolderThatIsNotABuild` (:34),
    `installDXMTInstallsABuild` (:41). Kept: `unknownCommandPrintsUsage` (:5), `optionParsingRemovesTheFlagAndValue` (:10).
- **Who copies the new CLI into a Rosetta clone:** `dxmt/check.sh:42` (into `$WORK/stock/bin/macneutron`; `ours` is
  cloned from `stock` at :43, so it gets it too), `wine-arm64/check.sh:439` (into `$RTOOL/bin/macneutron`).
- **What the tool-file writer does today** (`RuntimeInstaller.writeToolFiles(layout:launcherBinary:)`,
  `RuntimeInstaller.swift:110-134`): copies the CLI to `bin/macneutron`; looks for `steam.exe` next to the CLI or in
  `../Resources/steam.exe` (:121-125); looks for the presenter next to the CLI or in `../Frameworks` (:128-131).
  For `.build/release/macneutron` neither `steam.exe` nor `Resources/` exists, so **an install run from
  `.build/release/macneutron` writes no `bin/steam.exe`** and the bridge counts as not installed
  (`ToolLayout.steamBridgeInstalled`, `ToolLayout.swift:40-43`). See flag F3.
- **Launcher behaviour the checks rely on** (`Launcher.swift`):
  - `CompatContext` needs `STEAM_COMPAT_DATA_PATH`; `SteamAppId` defaults to `"0"` (`CompatContext.swift:19-23`);
    prefix `<data>/pfx`, stamp `<data>/version`, lock `<data>/macneutron.lock` (:26-28).
  - Lock held only during `prepare` (`PrefixManager.swift:44-59`), never while the game runs.
  - `waitforexitandrun`: prepare → `wineserver -w` **before** the game (:86) → optional precache replay (:88-100) →
    game → `wineserver -w` (:108) → `writeStampIfMissing` (:109). A second `waitforexitandrun` in the same prefix
    therefore waits for every process of the first (matters for bridge/check.sh's concurrency row, §4).
  - `runinprefix` (:74-75): no prepare, no bridge, no wait; runs the target directly.
  - `getcompatpath` (:111-114): prepare, then `wine winepath.exe -w <target>`.
  - Game stdout/stderr are inherited unless `MACNEUTRON_LOG=1`, then they go to `~/Library/Logs/MacNeutron/steam-<appid>.log`
    (`LauncherLog.swift:17-20`) with a header that redacts `MACNEUTRON_STEAM_ACCOUNT` (:186-199).
  - `launcher.log` line (:116-119): `verb=… appid=… backend=… runtime=… gptk=… exit=…`; precache lines
    `precache: <file> exit=<n> <replay: …>` (`ShaderPrecache.swift:85`).
  - Env the launcher sets (`LaunchEnvironment.swift:7-23`): `WINEPREFIX`; `WINEDLLOVERRIDES` (merged, user wins);
    `WINEDEBUG` = `-all` or `+err,+warn,+loaddll,+steamclient` with logging, only if unset; `ROSETTA_ADVERTISE_AVX=1`
    (goes, §3.7); `WINEMSYNC=1` unless `MACNEUTRON_NO_MSYNC=1` or set; `DXMT_PIPELINE_RECORD=<data>/dxmt-pipelines`
    when precache is enabled and the variable is unset. `addPresenter` (`Launcher.swift:159-167`) sets
    `DYLD_INSERT_LIBRARIES` for `run`/`waitforexitandrun` only (to be replaced by `MACNEUTRON_PRESENT=1`, §3.7/§5.3).
  - `terminate` (`Launcher.swift:127-133`) runs `wineserver -k` with `WINEPREFIX` only (no `WINEMSYNC`; §3.7 adds it).
  - `MACNEUTRON_STEAM_ACCOUNT` is filled from `loginusers.vdf` only when unset (:178-183).
- **Env vars the scripts read today:** `MACNEUTRON_TOOL` (dxmt/check.sh:15, wine-arm64/check.sh:26, bridge/check.sh:18,
  bridge/probe.sh:50, presenter/check.sh:10, dxmt/tests/shaders/compile.sh:7), `DXMT_CHECK_WORK`,
  `MACNEUTRON_ARM64_APP`, `MACNEUTRON_ARM64_PREFIX`, `MACNEUTRON_ARM64_TESTS`, `MACNEUTRON_ARM64_LOOP`,
  `MACNEUTRON_ARM64_TOOLS`, `BRIDGE_CHECK_WORK`, `PROBE_REDACT`, `ACCOUNT`, `APPID`, `STEAM_COMPAT_CLIENT_INSTALL_PATH`,
  `MACNEUTRON_TARBALL`, `GPTK`, `RUN_ENV`, `BUILD_DIR`. New per §8.1: `MACNEUTRON_REFERENCE`
  (default `~/Library/Application Support/MacNeutron Reference/rosetta-tool`).
- **The frozen reference** (what it must contain, as read by the scripts today): `bin/macneutron` (old CLI),
  `runtime-version` (`runtime-v4.7.3`), `gptk.json`, `gptk/`, `Libraries/Wine/bin/{wine,wineserver}`,
  `Libraries/Wine/lib/wine/x86_64-unix/wine`, `Libraries/DXMT/…`, `dxmt-version`, `lib/libmacneutron-present.dylib`,
  `bin/steam.exe`. The old CLI's `ToolLayout(executable:)` resolves to its own folder, so running its `bin/macneutron`
  is self-contained; its launch path writes only the prefix, `~/Library/Logs/MacNeutron/*` and (d3dmetal: none)
  compat precache files.

## 1. `dxmt/check.sh` (813 lines)

### 1.1 Blocks (current)

| Lines | Block |
|---|---|
| 1-8 | header comment (prereqs: `make build dxmt presenter dxmt-tests`, installed runtime + GPTK + cached tarball; arm64 mode vars) |
| 9-21 | `ROOT`, `DXMT=$ROOT/build/dxmt` (:11), `TESTS=$ROOT/build/dxmt-tests` (:12), `S=dxmt/tests/shaders` (:13), `LOOP=build/presenter/present_loop.exe` (:14), `TOOL` (:15), `WORK=${DXMT_CHECK_WORK:-$TMPDIR/macneutron dxmt}` (:16), `ARM64=${MACNEUTRON_ARM64_APP:-}` (:17), `TOOLS="$DXMT"` (:18), `expect name got want` (:20), `die` (:21) |
| 23-30 | arm64 mode: `APFX`, `ATESTS`, `ALOOP`, `TOOLS` from `MACNEUTRON_ARM64_*`; existence checks; prints `info arm64 mode: $ARM64` (:24) |
| 31-33 | Rosetta prereqs: `$TOOL/gptk.json`, `TARBALL=~/Library/Caches/MacNeutron/$(cat $TOOL/runtime-version).tar.gz` |
| 35-44 | **WORK clones:** `rm -rf $WORK; mkdir $WORK/compat`; `cp -cR $TOOL $WORK/stock`; strip `Libraries/DXMT`, `dxmt-version`; untar DXMT 0.80 + `winemetal.{so,dll}` (x86_64-unix, x86_64-windows, i386-windows) from the tarball; `cp .build/release/macneutron $WORK/stock/bin/` (:42); `cp -cR stock ours` (:43); `macneutron install-dxmt --tool-dir $WORK/ours $DXMT` (:44) |
| 46-71 | `run <stock\|ours\|x86> <name> <backend> <exe> [args…]` → `$WORK/<name>.out`/`.txt`. ARM64 branch (:53-58): only `tool=ours && backend=dxmt`: maps `$LOOP`→`$ALOOP`, `$TESTS/*`→`$ATESTS/*`; raw `env WINEPREFIX=$WORK/arm64/ours${LANE:+-$LANE} WINEDLLOVERRIDES="dxgi,d3d10core,d3d11,d3d12=n,b;d3d9,d3d10=b" WINEDEBUG=${WINEDEBUG:--all} DXMT_SHADER_CACHE_PATH=${CACHE:-$WORK/cache/$name} $ARM64/Contents/MacOS/wine`. Else branch (:60-63): `x86`→`ours`; `env STEAM_COMPAT_DATA_PATH=$WORK/compat/$tool${LANE:+-$LANE} SteamAppId=0 MACNEUTRON_GRAPHICS=$backend MACNEUTRON_NO_STEAM_BRIDGE=1 MACNEUTRON_NO_METALFX=1 DXMT_SHADER_CACHE_PATH=… $WORK/$tool/bin/macneutron launch waitforexitandrun "$@"`. 120 s watchdog (:67-69); `tr -d '\r'` to `.txt` (:70) |
| 72-79 | prefixes, in parallel: for `stock ours ours-A … ours-E`: `$WORK/${p%%-*}/bin/macneutron launch getcompatpath $WORK` |
| 80-85 | arm64: `wineserver -w` on `$APFX`; `cp -cR $APFX $WORK/arm64/{ours,ours-A..E}` |
| 86-102 | `pA..pE`; `stop_lanes()` kills lane subshells + children, then arm64 `wineserver -k` per `$WORK/arm64/*` (:96-98); `trap stop_lanes EXIT`, `TERM`→143, `INT`→130 |
| 103-126 | helpers: `invalid <run>` (:106-109), `same_pixels <ours> <ref> [prefix]` (:110-120), `cachetest <name> <mode>` (:121, `run ours … dxmt d3d12_cache.exe Z:cache.{vs,ps,cs}.dxil <mode>`), `counters <run>` (:122, last `d3d12 shader cache: .*`), `drawn <run>` (:123, `^cache ` lines), `RP` = `$WORK/ours/Libraries/DXMT/x64/dxmt-replay.exe` or arm64 `$ARM64/Contents/Resources/DXMT/aarch64-windows/dxmt-replay.exe` (:124-125), `replay <name> <file>` (:126) |
| 128-147 | **section 1** (D3D11 frame time): `ref=stock`, `dll=$DXMT/x86_64-windows/d3d11.dll`, `sys=$WORK/compat/ours/pfx/drive_c/windows/system32`; arm64: `ref=x86`, `dll=$ARM64/…/DXMT/aarch64-windows/d3d11.dll`, `sys=$WORK/arm64/ours/drive_c/windows/system32` (:133-135); 3× `run $ref` + 3× `run ours` present_loop 1280 720 0 0 600 0 (:136-139); `best()` (:140); arm64 prints `info D3D11 frame time: arm64 … ms, rosetta … ms` (:142) else `expect "D3D11 frame time within 10% of DXMT 0.80"` (:144-145); `expect "the D3D11 game ran our d3d11.dll"` (:147) |
| 148-161 | section 9 / E1 (compression): `compress`, `compress-off`, `compress-ref` (d3dmetal) |
| 163-182 | section 5 (dxil-probe, `$TOOLS/dxil-probe`); **:167 uses `$DXMT/version` as the non-container file** |
| 184-276 | lane A (sections 7-9: cache, recording, replay) |
| 278-414 | lane B (hazards, overlap stats M2-M4, E4, E7, E10) |
| 416-528 | lane C (present, DXIL capture, SM6, MACNEUTRON_LOG check :481-487, DXIL exec, triangles, GS record/replay) |
| 530-627 | lane D (depth, pass dump, pixel history, queries, d3d12_api, copy, null, layered, volume) |
| 629-767 | lane E (D3D11 cache table, vsread, ExecuteIndirect, stats, timestamps, junk replay, FSR 3 :731-739, section 4 D3DMetal :740-742, dxil-translate :743-755, bounds) |
| 769 | wait and print lanes A-E |
| 771-791 | alone-last: `queues-stats`, `deferred-stats` |
| 792-810 | **section 10** (launcher precache), guarded `if [ -z "$ARM64" ]` (:796); reads `$WORK/compat/ours-A/dxmt-pipelines`; stamp vs `$(cat "$WORK/ours/dxmt-version")` (:799, :809); `launcher.log` grep (:801, :805-806) |
| 812-813 | `dxmt-check: all passed` / `exit $fail` |

**Runs on the D3DMetal reference (backend `d3dmetal`)** — lines 156, 193, 297, 439, 491, 498, 501, 535, 579, 583, 593,
604, 611, 623, 646, 653, 741, 761. Names: `compress-ref` (alone); `cache-ref-{a,rt,layout,root}` (A); `hazards-ref`
(B); `dxil-ref`, `exec-ref`, `tri-ref`, `trigs-ref` (C); `depth-ref`, `query-ref`, `api-ref`, `copy-ref`, `null-ref`,
`layered-ref`, `volume-ref` (D); `vsread-ref`, `indirect-ref`, `d3dmetal`, `bounds-ref` (E). Every one is `run ours …
d3dmetal …`, i.e. today it shares the **ours** prefix of its lane (`compat/ours-<LANE>`) with our DXMT's Rosetta runs.

**Section 10 / L1 expects (:798-809):** `the launcher records into the game's compat folder`; `and stamps the builds
after the first session`; `a changed build replays d3d12_cache's recording before the game` (grep
`precache: d3d12_cache\.exe\.pipelines exit=0 replay: [1-9][0-9]* pipelines .*, 0 failed, 0 bad records`); `then the
game only hits` (`d3d12 shader cache: functions 3 hit 0 missed, reflections 3 hit 0 missed`); `and draws as
D3DMetal` (vs `cache-ref-a`); `and the stamp holds the current builds`.

**L2 expect (:484-486):** `LOG=$HOME/Library/Logs/MacNeutron/steam-0.log`; `export MACNEUTRON_LOG=1; dxil dxil-logged`;
`expect "the unsupported op is named in the log"` counting
`Failed to compile cs shader: DXIL: dx.op.createHandleFromHeap` = 1 in the new tail.

### 1.2 What it needs from the installed Rosetta tool today
`$TOOL/gptk.json`, `$TOOL/runtime-version` → `~/Library/Caches/MacNeutron/<v>.tar.gz` (DXMT 0.80 and winemetal for
`stock`), the whole folder cloned (`Libraries/`, `gptk/`, `bin/`), `Libraries/DXMT/x64/dxmt-replay.exe` (via
`install-dxmt`), `dxmt-version` (written by `install-dxmt`, read by section 10). Our DXMT from `build/dxmt` (x86_64).

### 1.3 Changes (§8.1, §8.2, L1, L2)

1. **Header :1-8**: prereqs become `make build wine-arm64 dxmt-tests presenter` (+ `dxmt-tests-arm64ec` for the
   ARM64EC lane) and the frozen reference; describe the two tool folders.
2. **Variables :11-18, :23-30**: delete `DXMT` (:11) and the arm64-mode switch. Proposed (keeps today's names, so
   `wine-arm64/check.sh:546-547` changes least):
   ```sh
   REF="${MACNEUTRON_REFERENCE:-$HOME/Library/Application Support/MacNeutron Reference/rosetta-tool}"
   WINEAPP="${MACNEUTRON_ARM64_APP:-$ROOT/build/wine-arm64/wine.app}"
   ATESTS="${MACNEUTRON_ARM64_TESTS:-$TESTS}" ALOOP="${MACNEUTRON_ARM64_LOOP:-$LOOP}"
   TOOLS="${MACNEUTRON_ARM64_TOOLS:-$ROOT/build/wine-arm64}"
   ```
   Drop `MACNEUTRON_ARM64_PREFIX`/`APFX` (the launcher prepares prefixes) and `TOOL`/`MACNEUTRON_TOOL`.
   Drop `info arm64 mode:` (:24) or keep it as the line `wine-arm64/check.sh:549` greps (see §2.3).
3. **:31-33** → `[ -f "$REF/gptk.json" ] || die "no frozen Rosetta reference at $REF (run tools/freeze-rosetta-reference.sh)"`;
   delete the tarball.
4. **:35-44 (WORK clones)** → two tool folders, no CLI copied into the reference:
   ```sh
   rm -rf "$WORK"; mkdir -p "$WORK/compat"
   cp -cR "$(cd "$REF" && pwd -P)" "$WORK/ref"          # frozen tool, its own bin/macneutron
   "$ROOT/.build/release/macneutron" install --tool-dir "$WORK/ours" --wine-app "$WINEAPP" > /dev/null \
     || die "assembling the tool folder failed"
   ```
   Cloning the reference (APFS, instant) keeps the frozen copy pristine and gives `wine-arm64/check.sh`'s
   `runtime_pids` a per-run path; running it in place also works (the old launcher writes nothing in its folder).
5. **`run()` :46-71**: one branch per backend, no arm64 special case:
   - `backend=d3dmetal` → `tool=ref`, `exe` **unmapped** (x64 `$TESTS`/`$LOOP`; Rosetta can't run ARM64EC);
     `env STEAM_COMPAT_DATA_PATH=$WORK/compat/ref${LANE:+-$LANE} … MACNEUTRON_GRAPHICS=d3dmetal … $WORK/ref/bin/macneutron launch waitforexitandrun`.
   - `backend=dxmt` → `tool=ours`, map `$LOOP`→`$ALOOP`, `$TESTS/*`→`$ATESTS/*` (today's :55);
     `env STEAM_COMPAT_DATA_PATH=$WORK/compat/ours${LANE:+-$LANE} … MACNEUTRON_GRAPHICS=dxmt MACNEUTRON_NO_STEAM_BRIDGE=1 MACNEUTRON_NO_METALFX=1 DXMT_SHADER_CACHE_PATH=… $WORK/ours/bin/macneutron launch waitforexitandrun`.
   - The first argument (`stock|ours|x86`) becomes redundant; either drop it (touches ~120 call sites
     mechanically) or keep and ignore it. Lazy: keep the signature, derive the tool from the backend.
   - **Ours and ref must never share a compat folder** (F1).
6. **Prefixes :72-85**: `for p in ours ours-A … ours-E` with `$WORK/ours/bin/macneutron`, and
   `for p in ref ref-A … ref-E` with `$WORK/ref/bin/macneutron`, all `launch getcompatpath "$WORK"` in parallel
   (12 at once). Delete :80-85 (template prefix clones).
7. **`stop_lanes` :96-98**: replace the `$WORK/arm64/*` loop with `wineserver -k` per `$WORK/compat/ours*/pfx` using
   `$WORK/ours/wine.app/Contents/Resources/bin/wineserver` with `WINEMSYNC=1`, and per `$WORK/compat/ref*/pfx` using
   `$WORK/ref/Libraries/Wine/bin/wineserver` (also `WINEMSYNC=1`, as the old launcher sets it). The killed
   `macneutron launch` processes already run `wineserver -k` from their TERM handler, so this is the backstop.
8. **`RP` :124-125** → `RP="$WORK/ours/wine.app/Contents/Resources/DXMT/aarch64-windows/dxmt-replay.exe"`.
9. **Section 1 :128-147**: delete `stock`/`x86`, `best()`, the 10% expect and the frame-time `info` comparison
   (D6 historical). Keep one ours run and `expect "the D3D11 game ran our d3d11.dll"` with
   `dll=$WORK/ours/wine.app/Contents/Resources/DXMT/aarch64-windows/d3d11.dll`,
   `sys=$WORK/compat/ours/pfx/drive_c/windows/system32` (now checks §3.4 step 6). Optional `info` line with the one
   run's `avg frame`.
10. **Section 5 :167**: `"$TOOLS/dxil-probe" "$DXMT/version"` reads a file of the deleted x86_64 build → use any
    non-DXBC file, e.g. `"$ROOT/dxmt/pins"` (F6).
11. **L2 :481-487**: delete the `if [ -z "$ARM64" ]` guard and the "not in arm64 mode" comment; body unchanged.
12. **Section 10 :792-810 (L1)**: delete the guard (:796, :810) and the comment (:795); `$(cat "$WORK/ours/dxmt-version")`
    (:799, :809) → `$(cat "$WORK/ours/wine.app/Contents/Resources/DXMT/version")`.
13. **Section 4 :740-742** stays: it now proves the frozen reference itself works (rename the expect to say so).
14. Lane comments mentioning DXMT 0.80 / Rosetta (:128-132) go.

## 2. `wine-arm64/check.sh` (618 lines)

### 2.1 Structure
- Vars :13-32: `B=${BUILD_DIR:-$ROOT/build}`, `STAGED=$B/wine-arm64/wine.app`, `TESTS=$B/wine-arm64-tests`,
  `WORK="$B/wine-arm64 check"`, `TOOL="$WORK/Application Support/wine.app"`, `PFX="$WORK/prefix arm64"`,
  `UNENT`, `UPFX`; **G4:** `RSRC=${MACNEUTRON_TOOL:-…/compatibilitytools.d/macneutron}` (:26), `RTOOL="$WORK/rosetta tool"`
  (:27), `RPFX="$WORK/prefix rosetta"` (:28), `RWINE=$RTOOL/Libraries/Wine/bin` (:29); `export WINEMSYNC=1` (:32).
- Step lists :37-44: `STEPS="macos signature boot pages unentitled arm64 isec g3-cpu fex $G1 g2-litmus viewec wxflip
  wxflip-x64 msync x18 g5-jit fonts-tls steam-bridge dxmt dxmt-present dxmt-arm64ec dxmt-x64 g4-bench"`;
  `NEEDS_DXMT="dxmt-present dxmt-arm64ec dxmt-x64"`; `NEEDS_PREFIX` (all but macos/signature/unentitled);
  `NEEDS_FEX="$G1 g2-litmus wxflip-x64 msync x18 g5-jit steam-bridge $NEEDS_DXMT g4-bench"`.
- Functions: `runtime_pids` :49-58 (lsof -t on executables; Rosetta paths of `$RTOOL`, `$WORK/dxmt-*/stock`,
  `$WORK/dxmt-*/ours`: `bin/macneutron`, `Libraries/Wine/lib/wine/x86_64-unix/wine`, `Libraries/Wine/bin/wineserver`),
  `cleanup` :61-71 (`wineserver -k` for `$TOOL|$PFX`, `$UNENT|$UPFX`, `$RWINE|$RPFX/pfx`), `orphans` :74-82,
  `stop_step` :87-94, `finish` :97-104 + traps :105-107, `step <name> <cap> <cmd…>` :111-132,
  `wine_run` :134, `dxmt_run` :136, `unfex` :139, `macos_cmd` :141, `signature_cmd` :146, `boot_cmd` :156
  (`WINEDLLOVERRIDES="mscoree,mshtml=" wine_run wineboot -i`), `pages_run`/`pages_cmd` :160-173, `unentitled_cmd` :176,
  `exe_cmd <test> [args]` :190-198 (passes on a `PASS <test>` line; stderr to `$WORK/<test>.err`), `g3_cpu_cmd` :201,
  `fex_cmd` :207-213 (`reg add 'HKLM\Software\Microsoft\Wow64\amd64' /ve /d libarm64ecfex.dll /f`), `g1_hello_cmd` :216,
  `g1_seh_cmd` :222, `g2_litmus_cmd` :227, `wxflip_cmd` :250, `wxflip_x64_cmd` :268, `msync_cmd` :281-304,
  `x18_run`/`x18_cmd` :314-347, `bench_rows` :350-354 (`BENCH_ROWS=36`), `fonts_tls_cmd` :358,
  `steam_bridge_cmd` :372-405, `g5_jit_cmd` :411, **G4** `rosetta()` :429-432 and `g4_bench_cmd` :433-458,
  `builtin` :464, `dxmt_cmd` :465-480, `LOOP_GREEN=56 LOOP_WHITE=12 CLEAR_GREEN=80` :485, `onscreen` :491-512,
  `dxmt_present_cmd` :516-534, `dxmt_lane_cmd <lane> <machine> <tests> <loop> [line]` :541-554, `run_step` :556-592,
  main :594-618 (`rm -rf $WORK`; `cp -cR $STAGED $TOOL` :615).
- Invoked from `Makefile:148-153` (`wine-arm64-check: build bridge wine-arm64 wine-arm64-tests dxmt dxmt-tests
  presenter dxmt-tests-arm64ec`; first runs `mode_test.sh`, `profile_test.sh`, `licences_test.sh` ×2).

### 2.2 What it needs from the installed Rosetta tool today
Only G4 and the dxmt-* steps (through dxmt/check.sh). G4: `$RSRC/runtime-version` = `runtime-v4.7.3` (:434-435),
clone of the whole folder (:438), `bin/macneutron` overwritten with the new CLI (:439), `Libraries/Wine/bin/wineserver`
(cleanup :63). **M1 and M2 use no Rosetta tool at all** (F5).

### 2.3 Changes
1. **Header :3-11**: G4 needs the frozen reference (`MACNEUTRON_REFERENCE`), not an installed runtime; dxmt-* steps
   need it too (D3DMetal), no tarball, no `make dxmt`.
2. **G4 :24-29, :424-458**: `RSRC` → `REF="${MACNEUTRON_REFERENCE:-$HOME/Library/Application Support/MacNeutron Reference/rosetta-tool}"`;
   keep the `runtime-v4.7.3` check against `$REF/runtime-version` and the `pwd -P` clone (:438); **delete :439**
   (`cp .build/release/macneutron …`). Comment :424-428: "the frozen tool's own launcher" instead of "the launcher just
   built". `rosetta()` :429-432 unchanged.
3. **`runtime_pids` :49-52**: replace `"$WORK"/dxmt-*/stock "$WORK"/dxmt-*/ours` with
   `"$WORK"/dxmt-*/ref` (Rosetta paths as today) and add the assembled folders' arm64 paths:
   `"$WORK"/dxmt-*/ours/{bin/macneutron,wine.app/Contents/MacOS/wine,wine.app/Contents/Resources/bin/wineserver}` and
   the same for the steam-bridge step's assembled folder (item 5).
4. **`dxmt_lane_cmd` :541-554**: drop `MACNEUTRON_ARM64_PREFIX="$PFX"` (:546); keep `MACNEUTRON_ARM64_APP="$TOOL"` (the
   source `install` clones) or pass `"$STAGED"`; keep TESTS/LOOP/TOOLS. `grep -q '^info arm64 mode: '` (:549) goes
   unless dxmt/check.sh keeps printing that line. The FSR 3 expected line (:588)
   `ok   the FSR 3 swapchain proxy presents on our DXMT` is unchanged. Since the lanes no longer use `$PFX`, the
   dxmt-arm64ec / dxmt-x64 steps can leave `NEEDS_DXMT`/`NEEDS_FEX`/`NEEDS_PREFIX` (optional; harmless to keep).
5. **`steam_bridge_cmd` :372-405 (L3)**: after today's direct runs, assemble a tool folder and run both scripts through
   the launcher:
   ```sh
   T="$WORK/steam-bridge tool"
   "$ROOT/.build/release/macneutron" install --tool-dir "$T" --wine-app "$TOOL" || return 1
   # + bin/steam.exe, see F3
   BRIDGE_CHECK_WORK="$WORK/steam-bridge launcher ü" MACNEUTRON_TOOL_DIR="$T" sh "$ROOT/bridge/check.sh"
   PROBE_REDACT=1 STEAM_COMPAT_CLIENT_INSTALL_PATH="$client" MACNEUTRON_TOOL_DIR="$T" sh "$ROOT/bridge/probe.sh" "$SMITE2_API"
   ```
   with the same `has` rows (:394) and ticket-size row (:397-398). `cleanup` gets `$T/wine.app/…/wineserver` with
   that run's prefix(es).
6. **`dxmt_cmd` :465-480, `dxmt_present_cmd`, `onscreen`**: unchanged (raw `wine.app` in `$PFX`, not the launcher).
   `x18`, `msync`, `fex`, `boot`, `exe_cmd` unchanged.
7. **Makefile `wine-arm64-check` :148**: drop `dxmt`; comment :144-147 → frozen reference.

## 3. `bridge/check.sh` (63 lines) — L3

- Modes :10-21: arm64 (`MACNEUTRON_ARM64_APP` → `B=build/bridge/arm64`, `WINE=$APP/Contents/MacOS/wine`,
  `WINEPREFIX=${MACNEUTRON_ARM64_PREFIX:?}`), else Rosetta (`B=build/bridge`, `WINE=$TOOL/Libraries/Wine/bin/wine`,
  `WINEPREFIX=$WORK/pfx`, `wineboot -u` :26). `WORK=${BRIDGE_CHECK_WORK:-$TMPDIR/macneutron bridge ü}` (:9).
  `export WINEDEBUG=-all WINEMSYNC=1` (:22). Copies `steam.exe` into the prefix's Steam folder (:29) and
  `tests/helper.exe` to `$WORK/game dir/hélper.exe` (:30). `steam()` :35; `expect` :37-39.
- Rows (names = L3's reuse list): `exit code passes through` (7, :41-42); `arguments arrive unchanged`
  (`[a b][--name="Player One"][]`, :43); `registry names a live Steam`
  (`alive=1 user=12345 client64=C:\Program Files (x86)\Steam\steamclient64.dll`, :44-45, `MACNEUTRON_STEAM_ACCOUNT=12345`);
  `launcher-style child still sees Steam` (`alive=1`, :46-48); `pid cleared afterwards` (0, :49, helper run without
  steam.exe); `missing program exits 1` (:50-51, `C:\missing.exe`); `launchers may start children outside the job`
  (`breakaway ok`, :52); `a second steam.exe leaves the first one's Steam running` (:54-61).
- Invoked from `Makefile:34-36` (`bridge-check: bridge` → `probe.sh --redact-self-test`, `check.sh` in Rosetta mode)
  and `wine-arm64/check.sh:382-383` (arm64 mode).

**Changes:**
1. Delete the Rosetta branch :16-21 and `MACNEUTRON_TOOL`; header :2-6.
2. Standalone (`make bridge-check`): with no `MACNEUTRON_ARM64_APP`, assemble `$WORK/tool` with
   `macneutron install --tool-dir … --wine-app $ROOT/build/wine-arm64/wine.app`, create the prefix with
   `launch getcompatpath` (`STEAM_COMPAT_DATA_PATH=$WORK/compat`), then run the direct rows with
   `WINE=$WORK/tool/wine.app/Contents/MacOS/wine`, `WINEPREFIX=$WORK/compat/pfx`. Makefile `bridge-check` deps:
   `build bridge wine-arm64`.
3. Launcher pass (new mode, e.g. `MACNEUTRON_TOOL_DIR=<assembled>`; `L` = `env STEAM_COMPAT_DATA_PATH=… SteamAppId=0 "$MACNEUTRON_TOOL_DIR/bin/macneutron" launch`):
   - `exit code passes through`: `L waitforexitandrun "$WORK/game dir/hélper.exe" exit 7` → 7.
   - `arguments arrive unchanged`: `L waitforexitandrun <helper> args 'a b' '--name="Player One"' ''`.
   - `registry names a live Steam`: `MACNEUTRON_STEAM_ACCOUNT=12345 L waitforexitandrun <helper> steam` (the launcher
     keeps a set value, `Launcher.swift:178`).
   - `launcher-style child still sees Steam`: `L waitforexitandrun <helper> spawn <late.txt>` (the launcher's
     `wineserver -w` now waits for the child, so no race).
   - `pid cleared afterwards`: `L runinprefix <helper> pid` (no steam.exe, no prepare).
   - `missing program exits 1`: `L waitforexitandrun 'C:\missing.exe'` (`windowsPath` leaves it as is,
     `SteamBridge.swift:10-12`); needs §3.3 preflight to pass a missing / non-PE target (F8).
   - `launchers may start children outside the job`: `L waitforexitandrun <helper> breakaway`.
   - The concurrency row **cannot** use two `waitforexitandrun`s (second blocks in `wineserver -w`,
     `Launcher.swift:86`); use `L runinprefix 'C:\Program Files (x86)\Steam\steam.exe' …` or keep it direct-only.
   - Needs `bin/steam.exe` in the tool folder and `steamBridgeInstalled` true (F3).

## 4. `bridge/probe.sh` (80 lines) — L3

- `probe_redact()` :14-20: keeps lines matching
  `^(load|init|SteamUser|SteamFriends|auth ticket|callback|fault|missing export|steamid|persona)`, byte-wise
  (`LC_ALL=C`); rewrites `persona: (null)`→`persona FAIL`, `steamid: [1-9]…`→`steamid ok`, `steamid: 0`→`steamid FAIL`,
  `persona: .+`→`persona ok`, `7656119[0-9]{10}`→`<steamid>`.
- `--redact-self-test` :21-37 (prints `PASS probe redaction`), 7 fake rows.
- Usage :38 `bridge/probe.sh <steam_api64.dll>`; modes :41-58 (arm64: `B=build/bridge/arm64`,
  `CLIENT64=$APP/Contents/Resources/lib/wine/aarch64-windows/lsteamclient.dll`, prefix required, `FAULT=fault`;
  Rosetta: `Libraries/Wine/bin/wine`, `x86_64-windows/lsteamclient.dll`, `i386-windows/…` as `steamclient.dll` :71-72,
  `$TMPDIR/macneutron probe/pfx`). Env :59-64 (`WINEDEBUG`, `WINEMSYNC=1`, `SteamAppId`/`SteamGameId=${APPID:-480}`,
  `STEAM_COMPAT_CLIENT_INSTALL_PATH` default Mac Steam's `Contents/MacOS`, `ACCOUNT`→`MACNEUTRON_STEAM_ACCOUNT` else
  unset). Copies `steam.exe` and `steamclient64.dll` (:69-70). Runs
  `wine 'C:\Program Files (x86)\Steam\steam.exe' Z:…\build\bridge\steamprobe.exe Z:<dll> [fault]` (:74-75); unredacted
  `exec` (:76) or redacted into a variable (:78-80, never a file).
- **L3 rows reused** (as `wine-arm64/check.sh:393-398` checks them): `init: ok`, `steamid ok`, `persona ok`,
  `auth ticket: callback, result 1`, `fault: caught`, `auth ticket: handle <n>, <bytes> bytes` with bytes > 0;
  failure hint row `init: FAIL` + `init message: `.

**Changes:** delete the Rosetta branch :48-58 and :71-72 (no 32-bit half); `FAULT=fault` always; header :2-10.
Add the launcher mode (`MACNEUTRON_TOOL_DIR` set): `env STEAM_COMPAT_DATA_PATH="$WORK/compat" SteamAppId=480
"$MACNEUTRON_TOOL_DIR/bin/macneutron" launch waitforexitandrun "$ROOT/build/bridge/steamprobe.exe" "$(winpath "$DLL")" fault`
— the launcher prepares the prefix (FEX key needed: steamprobe.exe is x64), copies the bridge, sets
`STEAM_COMPAT_CLIENT_INSTALL_PATH` (passed value kept when it holds `steamclient.dylib`) and fills
`MACNEUTRON_STEAM_ACCOUNT` from `loginusers.vdf` if `ACCOUNT` is unset. Redaction path unchanged (`out=$(…)` then
`probe_redact`). `make bridge`: drop `$(BRIDGE)/steam.exe` and `$(BRIDGE)/tests/helper.exe` (:27, :29), keep
`steamprobe.exe` (x64) and the arm64 pair.

## 5. `presenter/check.sh` (81 lines) — L4

- Today: `LIB=build/presenter/libmacneutron-present.dylib` (:9), Rosetta `TOOL` (:10), `WORK=$TMPDIR/macneutron presenter`.
  `run_loop <name> <inject 0|1> <scale> <present_loop args…>` (:17-29): `env STEAM_COMPAT_DATA_PATH=$WORK/compat/0
  SteamAppId=0 MACNEUTRON_GRAPHICS=d3dmetal MACNEUTRON_NO_STEAM_BRIDGE=1 MACNEUTRON_NO_METALFX=1
  DYLD_INSERT_LIBRARIES=<lib or ''> MACNEUTRON_PRESENT_SCALE=<scale> MACNEUTRON_PRESENT_DUMP=$WORK/frame.ppm
  $TOOL/bin/macneutron launch waitforexitandrun $B/present_loop.exe …`; 120 s watchdog. `frame_ms` :30. Prefix :33-34.
- **Check names and expect strings (L4 reuses):**

| Run (args) | Expect name | Got / want |
|---|---|---|
| `pass` 1 1 `1280 720 0 0 200 0` | `full-size game passes through` | count `macneutron-present: MetalFX` = 0 |
| `up` 1 1 `1280 720 640 360 300 0` | `small swap chain is upscaled` | count `macneutron-present: MetalFX 640x360 -> 1280x720` = 1 |
| (same, frame.ppm) | `upscaled frame shows the whole checkerboard` | `python3 presenter/tests/pixels.py $WORK/frame.ppm` = `WNWNWNWN` (else `none`) |
| `retina` 1 2 `1280 720 0 0 200 0` | `Retina density is upscaled` | `macneutron-present: MetalFX 1280x720 -> 2560x1440` = 1 |
| getcompatpath with lib | `prefix setup works with the library loaded` | `0:yes` (`compat/fresh/pfx/drive_c`) |
| `resize` … `resize=150:960x540` | `overlay follows a window resize` | `macneutron-present: MetalFX 640x360 -> 960x540` = 1 |
| `grow` … `grow=150` | `overlay goes away at full size` | `macneutron-present: pass-through (full size)` = 1 |
| `hdr` … `fp16` | `HDR layers are left alone` | `left alone (HDR/extended-range layer)`:`macneutron-present: MetalFX` = `1:0` |
| `vsync` … `200 1` | `vsync-on game is upscaled` | `…MetalFX 640x360 -> 1280x720` = 1 |
| `vswitch` … `vsync_at=60:1` | `switching vsync on keeps upscaling` | pixels.py = `WNWNWNWN` |
| `format` … `format_at=100` | `a pixel-format switch rebuilds the overlay` | MetalFX line count : `avg frame` count = `2:1` |
| `base` 0 1 / `pace` 1 1 (600 frames) | `pacing within 1 ms of no library` | `yes` |

  The presenter's lines come from `fprintf(stderr, "macneutron-present: %s\n", …)` (`presenter/present.m:40`); its
  constructor (:290-297) reads `MACNEUTRON_PRESENT_SCALE` and `MACNEUTRON_PRESENT_DUMP` and swizzles
  `CAMetalLayer -nextDrawable`.

**Changes (L4):** run through an assembled tool folder (`macneutron install`), `MACNEUTRON_GRAPHICS=dxmt`, no
`DYLD_INSERT_LIBRARIES`, no `LIB`. `inject=1` → no `MACNEUTRON_NO_METALFX` (launcher sets `MACNEUTRON_PRESENT=1`);
`inject=0` → `MACNEUTRON_NO_METALFX=1`. Add L4's negative row on `base`:
`expect "MACNEUTRON_NO_METALFX=1 loads no presenter" "$(grep -c 'macneutron-present' "$WORK/base.txt" || true)" 0`.
The `prefix setup works with the library loaded` row (:48-52) becomes meaningless (getcompatpath adds no presenter
today and wineboot loads no `winemetal.so`) → delete or turn into "a launch with the presenter prepares a fresh
prefix" via `waitforexitandrun` on `compat/fresh` (F9). Program: x64 `build/presenter/present_loop.exe` (FEX) or the
ARM64EC one; `MACNEUTRON_NO_STEAM_BRIDGE=1` stays. Makefile: `presenter` builds `present_loop.exe` only (drop :41-43);
`presenter-check: build wine-arm64 presenter`.

## 6. `Tests/Smoke/smoke.sh` (42 lines) — L5

- Today: `WORK=$TMPDIR/macneutron smoke`, `TOOL=$WORK/tool`; builds `exitcode.exe` with pinned llvm-mingw
  `x86_64-w64-mingw32-clang` (:12) and **`d3d11probe.exe` with Homebrew's `x86_64-w64-mingw32-gcc`** (:13);
  `install-runtime [--tarball]` (:15-19); `import-gptk` if `GPTK` (:20-22); `check <backend> <exe> <want> [args]`
  (:25-33) runs **`$TOOL/proton waitforexitandrun`** with `STEAM_COMPAT_DATA_PATH=$WORK/compatdata/shared SteamAppId=0
  MACNEUTRON_GRAPHICS=$backend`, prints `PASS|FAIL <backend> <exe>`; backends `dxmt dxvk` (+`d3dmetal`) (:35-40);
  `exitcode.exe` 2 with `"a b" "c"`, `d3d11probe.exe` 0; tails `launcher.log` (:41). Make: `smoke: build` (:19-20).
- `exitcode.c` exits with argc-1; **`d3d11probe.c` only creates a device and swap chain** and exits 0/1 — it draws
  nothing (F7).

**Changes (L5):**
1. Tool folder: `"$ROOT/.build/release/macneutron" install --tool-dir "$TOOL" --wine-app "$ROOT/build/wine-arm64/wine.app"`;
   delete `MACNEUTRON_TARBALL`, `GPTK`, header :3-4.
2. Entry point: `"$TOOL/bin/macneutron" launch waitforexitandrun` (R0b manifest), or `$TOOL/proton` only if R0b falls
   back.
3. Compilers (all pinned llvm-mingw, `$(sh dxmt/toolchain.sh)`): `x86_64-w64-mingw32-clang` for `exitcode.exe` and
   `d3d11probe.exe` (`-ld3d11 -luser32`); `arm64ec-w64-mingw32-clang` for an ARM64EC `exitcode`; `i686-w64-mingw32-clang`
   for a 32-bit `exitcode` (the refused one).
4. Rows: backends `dxmt wined3d` × (`exitcode.exe` 2, `d3d11probe.exe` 0); ARM64EC `exitcode` 2; i386 `exitcode`
   non-zero with §10's text `This game is 32-bit. MacNeutron 0.1 runs 64-bit games only; 32-bit support is planned.`
   (stderr/`launcher.log`); a Rosetta-era prefix: pre-create `compatdata/rosetta/pfx` (+ `version` holding
   `runtime-v4.7.3`, or none), launch, expect `pfx.rosetta` present and `version` starting `wine.app `.
5. Makefile `smoke: build wine-arm64`.

## 7. `dxmt/tests/run.sh` (32 lines) and `dxmt/tests/build_test.sh` (65 lines)

- `run.sh`: requires `$WORK/ours/bin/macneutron` from a dxmt-check run (:7); ninja + meson install of the **x86_64**
  tree `build/dxmt-src/win64` (:8-10); copies into `build/dxmt/x86_64-{windows,unix}` (:11-13); writes
  `build/dxmt/version` (:16); **`install-dxmt --tool-dir $WORK/ours build/dxmt`** (:17); `make dxmt-tests` (:18);
  runs `<test>.exe` for `dxmt` and `d3dmetal` through `$WORK/ours/bin/macneutron launch waitforexitandrun` in
  `compat/ours` (:21-32).
  **Change:** remove it (lazy; spec allows), or retarget: rebuild `build/wine-arm64-src/dxmt-build`
  (`meson compile` + `meson install` into `dxmt-install`), copy the ARM64X front ends straight into
  `$WORK/compat/ours/pfx/drive_c/windows/system32/` (the signed `wine.app` must not be edited: its `CodeResources`
  seals them, and a changed `winemetal.so` would fail library validation), run `dxmt` through `$WORK/ours` and
  `d3dmetal` through `$WORK/ref` in `compat/ref`. Only PE changes can be tried this way.
- `build_test.sh`: rows on `dxmt/build.sh` (:11-33, :47-50) go with the x86_64 DXMT build (`a missing tool stops the
  build`, `and is named with its formula`, `a bad checksum stops the build`, `and says so`, `and stages nothing`,
  `and moves the bad file aside…`, `a missing Metal Toolchain is named`, `an up-to-date build is kept`). Keep:
  `a pushed fork commit may ship` / `an unpushed fork commit may not` (:35-45, `dxmt/published.sh`, used by §6.3),
  `the Windows compiler is Clang` (:54), `a finished LLVM install is reused` (:57-63, `dxmt/llvm.sh` is sourced by
  `wine-arm64/build.sh:17`). **`make uses it` (:55) counts 3 x86_64-clang lines in `make -n bridge`; after the bridge
  change only `steamprobe.exe` is x86_64 → want `1`.** Called from `Makefile:82` (dxmt-check).

## 8. Makefile targets that run the checks

| Target (line) | Today | After |
|---|---|---|
| `smoke` (:19-20) | `build`; `sh Tests/Smoke/smoke.sh` | `build wine-arm64` |
| `bridge` (:25-31) | x64 `steam.exe`, `steamprobe.exe`, x64 `helper.exe`, arm64 `steam.exe`, arm64 `helper.exe` | drop :27, :29 |
| `bridge-check` (:34-36) | `bridge`; redaction self-test; `check.sh` (Rosetta) | `build bridge wine-arm64`; `check.sh` arm64 (+ launcher pass) |
| `presenter` (:39-44) | universal dylib + `present_loop.exe` | `present_loop.exe` only |
| `presenter-check` (:47-48) | `presenter`; Rosetta/D3DMetal | `build wine-arm64 presenter` |
| `dxmt` (:52-53) | `sh dxmt/build.sh` | deleted |
| `dxil-corpus` (:77-78) | `dxmt`; `build/dxmt/dxil-translate` | `wine-arm64`; `build/wine-arm64/dxil-translate` |
| `dxmt-check` (:81-83) | `build dxmt presenter dxmt-tests`; `build_test.sh`; `check.sh` | `build wine-arm64 dxmt-tests dxmt-tests-arm64ec presenter` |
| `app` (:86-104) | `build bridge presenter dxmt` … | per §8.2 (not this area) |
| `wine-arm64-check` (:148-153) | `… dxmt dxmt-tests presenter dxmt-tests-arm64ec` | drop `dxmt` |

`.PHONY` (:1) loses `dxmt`, gains `release`.

## 9. L6 (`macneutron install` with a real `wine.app`)

No script exists. Needs, from the plan: a script (or a `wine-arm64/check.sh` step) that runs
`.build/release/macneutron install --tool-dir <d> --wine-app build/wine-arm64/wine.app` twice (second a no-op), with a
real `wine.app/Contents/MacOS/wine` running from `<d>` (e.g. `wineserver -p` or `arm64-hello.exe` in background) to
get a deferral, `--force`, `<d>/runtime-damaged`, a leftover `wine.app.new`/`.old`, and `spctl`/`stapler` on an
installed notarized copy (that half only after §6.3 step 2). Must find out "deferred" from the verb (F2).

## 10. Flags: where the spec and the code disagree or leave a gap

- **F1 (prefix sharing).** Today every D3DMetal reference run shares its lane's `compat/ours-<LANE>` prefix with our
  DXMT. With two launchers that would break both ways: the new launcher renames a prefix whose stamp doesn't start with
  `wine.app ` to `pfx.rosetta` (§3.4), and the old launcher re-runs `wineboot -u` with Rosetta Wine over an arm64
  prefix whose stamp isn't `runtime-v4.7.3` (`PrefixManager.swift:35-39`). The plan must give the reference its own
  compat folders (`compat/ref`, `compat/ref-A..E`), 6 more prefixes created at start.
- **F2 (deferral exit code).** §3.9 step 1 "defer: log it and return" says nothing about the CLI verb's exit code or
  output. A check that assembles a tool folder must notice a deferral (it would otherwise run with no `wine.app`), and
  L6 must assert it: specify non-zero exit (or a fixed line) for `install` when deferred.
- **F3 (`bin/steam.exe` from the CLI verb).** `writeToolFiles` finds `steam.exe` only beside the CLI or in
  `../Resources/` (`RuntimeInstaller.swift:121-125`); `.build/release/` has neither, so `install` from the dev CLI
  writes no `bin/steam.exe` and the launcher skips the bridge ("note: Steam bridge not installed"). L3's launcher runs
  need it. Options: an `install --steam-exe <path>` option, or the scripts copy `build/bridge/arm64/steam.exe` into
  `<tool>/bin/` after `install` (step 5 rewrites tool files only on the next install).
- **F4 (`stock` lane needs nothing frozen).** With the `stock` and `x86` lanes dropped, the runtime tarball in
  `~/Library/Caches` is no longer needed; the spec-review's concern about freezing it is moot. The frozen tool's
  `dxmt-version` / `Libraries/DXMT` are unused by the checks (D3DMetal only).
- **F5 (§8.2's "G4, M1, M2").** Only G4 runs on Rosetta. M1 (msync timing rows, `msync_cmd` :281-304) and M2 (x18
  round-trip A/B, `arm64-x18path.exe time`, measured once by hand per `acceptance-arm64-ship-base.md:37`) run on
  `wine.app` only and need no frozen tool. The §8.2 row should say "G4".
- **F6 (`$DXMT/version`).** `dxmt/check.sh:167` feeds `build/dxmt/version` to `dxil-probe` as a non-container file in
  both modes; it disappears with `make dxmt`. Use another non-DXBC file (e.g. `dxmt/pins`).
- **F7 (L5 "draws").** `d3d11probe.c` creates a device and swap chain and exits; it never draws or reads back. Either
  L5 says "creates a D3D11 device and swap chain on wined3d", or d3d11probe gains a clear + readback.
- **F8 (preflight on non-files).** bridge/check.sh's `missing program exits 1` passes `C:\missing.exe` as the target;
  §3.3 must treat an unreadable / missing target as "not PE, not checked", or that row fails in preflight instead of
  in steam.exe.
- **F9 (presenter "library loaded" row).** `presenter/check.sh:48-52` tested `getcompatpath` with the dylib injected.
  With winemetal loading the presenter, wineboot never loads it, and `addPresenter` only runs for `run` /
  `waitforexitandrun`; §3.7 doesn't say whether `MACNEUTRON_PRESENT` is set for `getcompatpath`. Drop the row or move it
  to a `waitforexitandrun` on a fresh compat folder.
- **F10 (`make dxmt-check` lanes).** §8.2 adds `dxmt-tests-arm64ec` to `dxmt-check`'s deps, but standalone
  `dxmt/check.sh` runs one lane (x64 programs by default). Decide: run both lanes from the target (two invocations,
  `MACNEUTRON_ARM64_TESTS`/`LOOP`), or drop the dep. `wine-arm64-check` already runs both (dxmt-arm64ec, dxmt-x64).
- **F11 (bridge concurrency row).** `a second steam.exe leaves the first one's Steam running` can't run as two
  `waitforexitandrun`s through the launcher: the second blocks in the pre-game `wineserver -w` (`Launcher.swift:86`).
  "Through the launcher" for L3 covers the exit-code and argument rows; that row stays direct or uses `runinprefix`.
- **F12 (`dxmt/tests/shaders/compile.sh`, not in the spec).** It runs DXC under the installed tool's
  `Libraries/Wine/bin/wine` (:7, :13, :15) and needs `make dxmt` to fetch DXC (`dxmt/build.sh:32-42`,
  `DXC_URL`/`DXC_SHA256` in `dxmt/pins:10-11`). Both go. Point it at `$MACNEUTRON_REFERENCE/Libraries/Wine/bin/wine`
  (or run dxc.exe under FEX in `wine.app`) and move the DXC fetch into the script itself (`dxmt/fetch.sh`'s `fetch`).
- **F13 (install time per check run).** §3.9 step 4 runs `codesign --verify --strict` on the 1.3 GB clone. dxmt/check.sh
  assembles one folder per run (twice in `wine-arm64-check`, plus steam-bridge and presenter/smoke folders); expect
  that cost each time. Acceptable, but don't assemble per lane.
- **F14 (`WINEMSYNC` in stop paths).** `Launcher.terminate` (:127-133) doesn't set `WINEMSYNC`; the scripts' own
  `wineserver -k` backstops (`dxmt/check.sh` stop_lanes, `wine-arm64/check.sh` cleanup) should set `WINEMSYNC=1` to
  match the launcher-started servers (wine-arm64/check.sh exports it globally; standalone dxmt/check.sh doesn't).
- **F15 (old-CLI behaviour assumptions).** Reference lanes rely on the frozen CLI honouring `MACNEUTRON_GRAPHICS=d3dmetal`,
  `MACNEUTRON_NO_STEAM_BRIDGE=1`, `MACNEUTRON_NO_METALFX=1` and checking Rosetta in preflight; all true of today's
  binary. Its `launcher.log` lines interleave with the new launcher's in the shared
  `~/Library/Logs/MacNeutron/launcher.log` (section 10 counts only `precache: d3d12_cache…` lines, so unaffected).
