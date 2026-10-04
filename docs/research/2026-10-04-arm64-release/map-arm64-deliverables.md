# MAP: what sub-projects 1-3 hand the launcher (sub-project 5 grounding)

Reader area: the arm64 deliverables (`wine.app`, the bridge's arm64 outputs, the check scripts that show how to drive
them). Read-only. All paths repo-relative to `/Users/chad/Documents/MacProton`. "spec-N" = native-arm64
(`docs/superpowers/specs/2026-10-02-macneutron-native-arm64-design.md`), "spec-D" = arm64 DXMT (`2026-10-03-...`),
"spec-S" = ship-base (`2026-10-04-...`).

---

## 1. What the build hands over

`make wine-arm64` (`Makefile:109-110` -> `wine-arm64/build.sh`, which ends in `wine-arm64/bundle.sh`,
`build.sh:352`) stages **one** signed bundle and a few files beside it:

| Output | Path | Source |
|---|---|---|
| The runtime | `build/wine-arm64/wine.app` | `bundle.sh:221-224` (built as `wine.app.tmp`, moved only after every assert) |
| Build stamp (input hash, NOT a runtime version) | `build/wine-arm64/version` (written only for non-development builds) | `build.sh:109-116`, `build.sh:355-357` |
| arm64 DXIL host tools (outside the bundle) | `build/wine-arm64/dxil-probe`, `build/wine-arm64/dxil-translate` | `build.sh:326-329` |
| aarch64 `steam.exe` + test helper (outside the bundle, from `make bridge`) | `build/bridge/arm64/steam.exe`, `build/bridge/arm64/tests/helper.exe` | `Makefile:25-31` |

Not built by `make wine-arm64`: the bridge, test programs, presenter (`wine-arm64/README.md:59-63`).

---

## 2. `wine.app` layout

From `bundle.sh:31-108` and spec-N §4 (`:191-214`), spec-D §6 (`:111-124`), spec-S §3 (`:79-94`).

```
wine.app/Contents/
  Info.plist                     CFBundleIdentifier net.authspot.macneutron.wine, CFBundleExecutable wine,
                                 LSMinimumSystemVersion 27.0, NO CFBundleVersion            (wine-arm64/Info.plist:5-16)
  embedded.provisionprofile      copy of $MACNEUTRON_PROVISIONING_PROFILE                    (bundle.sh:108)
  MacOS/wine                     THE loader; the only entitled binary                         (bundle.sh:40)
  MacOS/ntdll.so -> ../Resources/lib/wine/aarch64-unix/ntdll.so                               (bundle.sh:44)
  Resources/bin/                 make install's bindir: wineserver, wine -> ../../MacOS/wine, program links
                                                                                              (bundle.sh:37-42)
  Resources/lib/wine/aarch64-unix/
      ntdll.so (msync + strict x18), winemac.so (patch 13), win32u.so, ...  all unix modules
      wine -> ../../../../MacOS/wine           (replaces make install's unentitled copy)     (bundle.sh:43)
      libarm64ecfex.so                         FEX unixlib                                   (bundle.sh:47)
      winemetal.so                             DXMT unix side, arm64, LLVM 15 static          (bundle.sh:54)
      libfreetype.6.dylib, libgnutls.30.dylib  @rpath ids, beside their dlopen callers        (bundle.sh:62-63)
      lsteamclient.so                          arm64, loads Mac Steam's steamclient.dylib     (bundle.sh:204-215)
  Resources/lib/wine/aarch64-windows/
      Wine's PE builtins (ARM64X/ARM64EC), libarm64ecfex.dll (FEX, x64 emulator)             (bundle.sh:46)
      winemetal.dll                            ARM64X, Wine builtin marker (asserted)         (bundle.sh:53, 193)
      lsteamclient.dll                         ARM64X (CHPE asserted), builtin, 57 MB unstripped (bundle.sh:204-208;
                                                                                              acceptance-arm64-ship-base.md:101)
  Resources/share/wine/          wine.inf, nls                                                (bundle.sh:190)
  Resources/DXMT/aarch64-windows/  d3d11.dll d3d10core.dll dxgi.dll d3d12.dll dxmt-replay.exe (ARM64X, NO builtin marker)
                                                                                              (bundle.sh:52-57, 194-196)
  Resources/DXMT/                COPYING.LIB LICENSE LICENSE.OLD version                      (bundle.sh:58-59)
  Resources/licenses/            README NOTICES.md SOURCE; wine/ fex/ llvm/ llvm-mingw/ freetype/ gnutls/ nettle/
                                 gmp/ lsteamclient/(LICENSE, NOTE)                            (bundle.sh:64-106)
```

- No `aarch64-windows` for i386: no syswow64 / 32-bit until sub-project 8 (spec-D:124; spec-N:68).
- `DXMT/version` token: `<DXMT_COMMIT>+<12 chars of series hash>` or `<DXMT_COMMIT>+dev` (spec-D:122; build.sh:320-324;
  asserted bundle.sh:197-200).
- `licenses/SOURCE` keys: `MACNEUTRON_COMMIT` (`+dirty` suffix when `wine-arm64 dxmt bridge Makefile` differ from HEAD,
  build.sh:143-145), `WINE_COMMIT`/`WINE_SERIES`, `FEX_COMMIT`/`FEX_SERIES`, `FEX_SUBMODULE_*`, `DXMT_COMMIT`/`DXMT_SERIES`,
  `LLVM_TAG`, `LLVM_MINGW_SHA256`, `LSTEAMCLIENT_COMMIT`/`LSTEAMCLIENT_SERIES`, tarball URL/SHA256; any `*_SERIES=dev`
  marks a development tree (build.sh:333-350).
- A bundle is a "development build" when any of the four trees (wine, fex, dxmt, lsteamclient) has local work
  (`lib.sh:23-34`, `build.sh:146-152`); it still signs and stages, but gets no stamp.
- How Wine finds itself (spec-N:206-209): loader loads `<real dir of exe>/ntdll.so` (= `MacOS/ntdll.so` symlink);
  `init_paths` derives `dll_dir`, `bin_dir`, `data_dir` and `wineloader = <ntdll dir>/wine` (the symlink back to
  `MacOS/wine`); so **every** new Windows process and the 4K re-exec run the entitled loader. Kernel honours the
  entitlement through the symlink (verified in trial).
- bundle.sh asserts the symlink targets (`bundle.sh:185-188`), `bin/wineserver`, `share/wine/wine.inf` (189-190), and
  that no other Mach-O is named `wine` (218-219). check.sh re-asserts the symlink on the installed clone
  (`check.sh:151-153`).
- Every bundled Mach-O depends only on `/usr/lib`, `/System`, `@rpath`, `@loader_path`, `@executable_path`, and has no
  absolute rpath (bundle.sh:130-145); `minos 27.0` and a secure timestamp on every one (bundle.sh:131-133).
- 40 Mach-O files in the bundle (acceptance-arm64-ship-base.md:107).

---

## 3. Signing

| Item | Value | Evidence |
|---|---|---|
| Identity | `$MACNEUTRON_SIGN_IDENTITY` ("Developer ID Application: ... (49QMZXLR8S)") | README:38-41; lib.sh:75-83; spec-N §7.1:366 |
| Profile | `$MACNEUTRON_PROVISIONING_PROFILE` (never committed); checked: App ID `49QMZXLR8S.net.authspot.macneutron.wine`, has cross-arch entitlement, not expired | lib.sh:56-71 |
| Embedded profile | `Contents/embedded.provisionprofile` | bundle.sh:108 |
| Order | every Mach-O but the loader: `codesign -f -s ID --options runtime`; then the bundle with `--entitlements wine-arm64/wine.entitlements` (lands on `MacOS/wine` only) | bundle.sh:114-119 |
| Entitlements (loader only) | `com.apple.application-identifier`, `com.apple.developer.team-identifier` 49QMZXLR8S, **`com.apple.developer.cross-architecture-support`**, `cs.allow-jit`, `cs.allow-unsigned-executable-memory`, `cs.disable-library-validation` | wine.entitlements:5-16 |
| NOT entitled | **no `com.apple.security.cs.allow-dyld-environment-variables`**; `get-task-allow` explicitly refused | wine.entitlements; bundle.sh:125-127 |
| Asserts | `codesign --verify --strict --deep`; loader shows cross-arch; `disable-library-validation` present (Valve-signed `steamclient.dylib`) | bundle.sh:122-124, 216-217 |
| No ad-hoc mode | an unentitled loader can't map low 4 GB / KUSER or get 4K pages | README:34-36; spec-N:368 |
| Hardened runtime everywhere | `--options runtime` on every Mach-O, incl. wineserver | bundle.sh:116-118 |
| PE files | not signed individually ("PE DLLs need no signature") but they are inside the sealed bundle | bundle.sh:110 |
| Immutable after signing | "nothing can be added to a signed bundle later" — DXMT went inside for that reason | spec-D:42 |

Runtime refusal: Wine patch 0007 (`ntdll-Refuse-to-exec-a-loader-without-the-cross-arch`) checks `wineloader`'s
entitlement before any fork; missing -> `fatal_error` naming the path and "re-sign"; message contains
"lacks the com.apple.developer.cross-architecture-support entitlement" (check.sh:175-185; spec-N:236, :453).

---

## 4. How check.sh launches a program (the reference command line)

`wine-arm64/check.sh`:

- **Install location used by the check:** `cp -cR build/wine-arm64/wine.app "build/wine-arm64 check/Application Support/wine.app"`
  — a clone at a path with a space, "as Sub-project 5 will install it" (check.sh:9-10, 18-19, 613-615).
- **Global env:** `export WINEMSYNC=1` for every run and every server it starts (check.sh:30-32).
- **The binary:** `"$TOOL/Contents/MacOS/wine"` directly — `wine_run() { WINEPREFIX="$PFX" "$TOOL/Contents/MacOS/wine" "$@"; }`
  (check.sh:134). wineserver: `"$TOOL/Contents/Resources/bin/wineserver"` (`-k`, `-w`, `-p`) (check.sh:62-66, 282-300, 479).
- **No `WINEARCH`** anywhere (grep of wine-arm64/check.sh, bridge/, dxmt/check.sh, Sources: none).
- **No FEX env for normal runs.** FEX runs with its defaults; `unfex()` strips any caller `FEX_*` for measured runs
  (check.sh:138-139, 231, 414, 446). Only `FEX_TSOENABLED=0` in G2's control (check.sh:240); `FEX_SILENTLOG=0` is a
  diagnosis knob (spec-N:335, :431).
- **4K-page spawn: nothing for the caller to do.** Wine patch 0003 execs the arm64 loader with 4K pages; patch 0008
  re-execs the first process when `getpagesize() != 4096`, so every entry point (game, wineboot, winepath, reg) runs
  4K (spec-N:237-238). Patch 0005 keeps the env strings across that re-exec. wineserver stays 16K (spec-N:188, 216).
  The launcher process itself needs no entitlement (check.sh runs the loader from plain `sh`).
- **x64 vs ARM64EC/ARM64 programs:** identical command line (`wine_run <exe>`); the PE machine decides. x64 runs under
  FEX **only if the prefix has FEX registered** (else Wine's stub `xtajit64` runs it: check.sh:35). ARM64/ARM64EC run
  natively. `IsWow64Process2` native machine reports 0xaa64 (acceptance-arm64-wine.md:97).
- **Paths for programs:** Unix paths passed as-is or as `Z:\...` Windows paths (bridge/check.sh:31; probe.sh:73-75).
- **DXMT run:** `WINEDLLOVERRIDES="dxgi,d3d10core,d3d11,d3d12=n,b;d3d9,d3d10=b" wine_run ...` — "the launcher's DXMT
  overrides (GraphicsBackend.swift)" (check.sh:135-136; dxmt/check.sh:56-58 also sets `WINEDEBUG=${WINEDEBUG:--all}`
  and `DXMT_SHADER_CACHE_PATH`).
- **Process accounting:** Wine rewrites argv, so `pkill -f` finds nothing; processes are found by executable with
  `lsof -t <MacOS/wine> <Resources/bin/wineserver>` (check.sh:46-58); stop = `wineserver -k` per prefix then kill -9
  (check.sh:61-71).

---

## 5. Prefix creation and boot

- **Boot:** `WINEDLLOVERRIDES="mscoree,mshtml=" WINEPREFIX=<pfx> wine.app/Contents/MacOS/wine wineboot -i`
  (check.sh:156), cap 3 min (check.sh:560). `pages` then runs `wineboot -u` (check.sh:172).
  Contrast: bridge/check.sh:26 and probe.sh:66 use `wine wineboot -u` on a missing prefix; the Rosetta launcher uses
  `wineboot -u` (PrefixManager.swift:48).
- **FEX registration (the launcher's job per spec-N §6.3:360, "Sub-project 5 makes this part of prefix creation"):**
  `wine reg add 'HKLM\Software\Microsoft\Wow64\amd64' /ve /d libarm64ecfex.dll /f`, verified with `reg query ... /ve`
  expecting `REG_SZ libarm64ecfex.dll` (check.sh:206-213). `wine.inf` writes `xtajit64.dll` there with "don't overwrite",
  so the value survives `wineboot -u` (spec-N:360).
- **Crash dialog off:** `wine reg add 'HKCU\Software\Wine\WineDbg' /v ShowCrashDialog /t REG_DWORD /d 0 /f`
  (check.sh:325, 381, 469) — same as the Rosetta launcher (PrefixManager.swift:52).
- **Saved registry before cloning:** `wineserver -w` on the prefix (check.sh:478-479; dxmt/check.sh:82-84 clones with
  `cp -cR` after it).
- **msync during boot:** every boot/reg run sees `WINEMSYNC=1` (check.sh:32); the server a run starts inherits it.

---

## 6. DXMT into a prefix

- **Copy:** `cp wine.app/Contents/Resources/DXMT/aarch64-windows/* <pfx>/drive_c/windows/system32/` — all five files,
  including `dxmt-replay.exe` (check.sh:465-468). Then asserts each system32 copy `cmp`-equals the bundle's and has no
  builtin marker (check.sh:472-475); `winemetal.dll` is not copied (it's a builtin in `aarch64-windows`, check.sh:470).
- **Overrides:** `dxgi,d3d10core,d3d11,d3d12=n,b;d3d9,d3d10=b` (spec-D:124; check.sh:136) = `GraphicsBackend.swift:35`
  (the `dxmtHasD3D12` branch).
- **Rosetta launcher comparison:** `GraphicsBackend.prefixDLLs` copies `x64/{d3d11,d3d10core,dxgi}.dll` to system32,
  `x32/*` to syswow64, and `layout.dxmtD3D12` to system32 (GraphicsBackend.swift:44-59). arm64 has no x32/syswow64 and a different source folder (`DXMT/aarch64-windows`) —
  `ToolLayout.dxmt`/`dxmtReplay` (`ToolLayout.swift:57-58`: `x64/dxmt-replay.exe`) and `dxmtVersionFile`
  (`ToolLayout.swift:50`: tool-root `dxmt-version`) don't map onto `wine.app`.
- **Replayer for pre-caching:** `wine.app/Contents/Resources/DXMT/aarch64-windows/dxmt-replay.exe` (dxmt/check.sh:125);
  version for the precache stamp: `Resources/DXMT/version` (ShaderPrecache.swift:13 reads `layout.dxmtVersion`).
- **Launcher-only checks skipped in arm64 mode (owed by sub-project 5):** `MACNEUTRON_LOG=1` naming the unsupported op
  (dxmt/check.sh:481-487) and section 10, launcher recording/replay/stamp (dxmt/check.sh:791-813); spec-D:139.
- Winshot needs Screen Recording and nothing in native full screen on the main display (README:97-100;
  acceptance-arm64-ship-base.md "Found on the way") — a check-only concern, but the full-screen Space behaviour is
  real for games too.

---

## 7. Steam bridge into a prefix (arm64)

From `bridge/check.sh` and `bridge/probe.sh` in arm64 mode (`MACNEUTRON_ARM64_APP`, `MACNEUTRON_ARM64_PREFIX`):

- **Files into `<pfx>/drive_c/Program Files (x86)/Steam/`:**
  - `steam.exe` <- `build/bridge/arm64/steam.exe` (aarch64) (bridge/check.sh:11, 27-29; probe.sh:42, 67-69).
  - `steamclient64.dll` <- `wine.app/Contents/Resources/lib/wine/aarch64-windows/lsteamclient.dll` (probe.sh:44, 70).
  - **No** `steamclient.dll` (32-bit) in arm64 mode (probe.sh:71-72).
  - `tests/helper.exe` is a *test program* copied to a scratch "game dir" (`$WORK/game dir/hélper.exe`), never the
    prefix (bridge/check.sh:28-30; helper.c:1 "Test program for bridge/check.sh").
- **Launch line:** `wine 'C:\Program Files (x86)\Steam\steam.exe' <Z:\...\game.exe> [args...]`
  (bridge/check.sh:35; probe.sh:74-75). steam.exe writes `HKCU\Software\Valve\Steam\ActiveProcess` (pid, user,
  `SteamClientDll64`), runs the program in a job, waits for the whole job, clears pid, passes the exit code through
  (steam.c:1-11; bridge/check.sh:41-61: exit code, args, `user=<MACNEUTRON_STEAM_ACCOUNT>`, child-sees-Steam,
  pid cleared, missing program exits 1, breakaway, second steam.exe leaves the first's Steam running).
- **Env:** `WINEDEBUG=-all WINEMSYNC=1` (bridge/check.sh:22; probe.sh:59-60); `SteamAppId`/`SteamGameId`
  (probe uses 480) (probe.sh:61); `STEAM_COMPAT_CLIENT_INSTALL_PATH` = Mac Steam's
  `~/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS` (where `steamclient.dylib` is)
  (probe.sh:62-63; check.sh:374, 378-379); `MACNEUTRON_STEAM_ACCOUNT` optional, read by steam.exe for the registry
  user (probe.sh:64; bridge/check.sh:44-45). The Rosetta launcher already sets the last two
  (Launcher.swift:169-184; `SteamBridge.clientDirectory`, SteamBridge.swift:29-34) and redacts the account in logs
  (Launcher.swift:186-191).
- **lsteamclient.so** builds the dylib path from `STEAM_COMPAT_CLIENT_INSTALL_PATH`; being arm64, it loads the arm64
  slice of Steam's universal `steamclient.dylib` (spec-S:75; README:123-127). Needs `disable-library-validation`
  (Valve's team signature) — present (bundle.sh:216-217).
- **Proven by S7:** `init: ok`, `steamid ok`, `persona ok`, auth ticket > 0 bytes with callback, and `fault: caught`
  (SEH still works after `SteamAPI_Init`) — x64 `steamprobe.exe` under FEX with SMITE 2's `steam_api64.dll`
  (check.sh:375-405; README:129-135). x64 lane only (spec-S:58).
- Rosetta launcher copies via `SteamBridge.prefixFiles` (`steamHelper` -> steam.exe, `lsteamclient64`, optional
  `lsteamclient32`) every launch (SteamBridge.swift:18-25; PrefixManager.swift:76-83), and removes them when the bridge
  is off (PrefixManager.swift:85-94). The x64 `steam.exe` ships as `MacNeutron.app/Contents/Resources/steam.exe`
  (Makefile:93); there is no shipped location for the aarch64 one yet.

---

## 8. msync contract

- Patch 0015 is on **only** with `WINEMSYNC=1` (CrossOver semantics); "whatever starts the runtime sets it: check.sh
  here, the launcher in sub-project 5. `WINEMSYNC=0` per game stays the off switch" (spec-S:43).
- Client and wineserver must agree: a `WINEMSYNC=0` client on an msync server prints "Server is running with WINEMSYNC
  but this process is not" and exits; a `WINEMSYNC=1` client on a plain server prints "Failed bootstrap_look_up" and
  exits; both are ERR lines **hidden under `WINEDEBUG=-all`** (spec-S:72, :229; check.sh:294-299). Switching modes
  needs `wineserver -k` (spec-N:472).
- `msync: up and running.` and msync errors are written by wineserver to the stderr of the client that started it
  (spec-S:72; check.sh:291-293) — the launcher's game log would catch them if it captures that stderr.
- Rosetta launcher: sets `WINEMSYNC=1` unless `MACNEUTRON_NO_MSYNC=1` or already set (LaunchEnvironment.swift:17-19).
- Protocol bump 962 -> 963 (acceptance-arm64-ship-base.md:100): old servers and new clients refuse each other (spec-S:241).

---

## 9. Presenter / MetalFX / DYLD_INSERT_LIBRARIES

- Rosetta launcher injects the presenter with `DYLD_INSERT_LIBRARIES` (Launcher.swift:158-167; opt-out
  `MACNEUTRON_NO_METALFX=1`); `ToolLayout.presenterLibrary` = `<tool root>/lib/libmacneutron-present.dylib`
  (ToolLayout.swift:46-47).
- The presenter is already universal x86_64+arm64 (`Makefile:41-43`), hooks via a constructor that swizzles
  `CAMetalLayer -nextDrawable` and, lazily, the command buffer's present methods (present.m:27-31, 285-297).
- `wine.app`'s loader is hardened and lacks `allow-dyld-environment-variables` (wine.entitlements), so dyld ignores
  `DYLD_*`; spec-S:66 verified a hardened main ignores `DYLD_LIBRARY_PATH`/`DYLD_FALLBACK_LIBRARY_PATH`. Roadmap row 5
  owns "the presenter loaded without `DYLD_INSERT_LIBRARIES`" (spec-N:65). spec-D:17 put the MetalFX presenter out of
  sub-project 2.
- Interaction to check: Wine patch 13's `WineMetalLayer` overrides `nextDrawable` to post `CLIENT_SURFACE_PRESENTED`
  (spec-D:106); the presenter swizzles the base `CAMetalLayer` implementation. Whether the subclass calls `super`
  (reaching the swizzle) is not established in what I read.
- `disable-library-validation` is on, so a non-team-signed dylib could be `dlopen`ed by in-bundle code; but anything
  placed inside `wine.app` must be there before signing (spec-D:42).
- dxmt/check.sh's Rosetta runs set `MACNEUTRON_NO_METALFX=1` (dxmt/check.sh:61-62); no arm64 run has ever loaded the
  presenter.

---

## 10. Every place the docs assign work to "sub-project 5" / "the launcher"

| # | Item | Evidence |
|---|---|---|
| 1 | Per-game runtime choice, separate prefixes, preflight split | spec-N:65 |
| 2 | Install `wine.app` at a path with spaces | spec-N:65; check.sh:9-10 |
| 3 | `WINEMSYNC=1` for every arm64 run; `WINEMSYNC=0` per game as off switch | spec-N:65; spec-S:43; acceptance-arm64-ship-base.md:75-77 |
| 4 | Arm64 Steam bridge wiring: copy `lsteamclient.dll` and `build/bridge/arm64/steam.exe` (+ roadmap says `tests/helper.exe`) into prefixes; arm64 paths | spec-N:65; spec-S:18, :94, :175; README:126-127; acceptance-arm64-ship-base.md:107-108 |
| 5 | DXMT into arm64 prefixes: `DXMT/aarch64-windows/*` -> system32 + DXMT overrides | spec-N:65; spec-D:124; check.sh:460 comment "as the launcher will" |
| 6 | FEX registration as part of prefix creation | spec-N:360 |
| 7 | Decide whether releases may include lsteamclient (Steamworks SDK licence); not redistributed until decided | spec-N:65; spec-S:40, :244; README:224-225 |
| 8 | Notarization of the entitled bundle (unverified) | spec-N:65, :476; spec-S:23, :248; spec-D:20 |
| 9 | Release source archives | spec-N:65; spec-S:23 |
| 10 | Refuse development inputs in release bundles | spec-N:65; spec-S:23 |
| 11 | Strip builtin PE files (`lsteamclient.dll` 57 MB) | spec-N:65; acceptance-arm64-ship-base.md:101, "Found on the way" |
| 12 | Presenter without `DYLD_INSERT_LIBRARIES` | spec-N:65; spec-D:17 |
| 13 | Shader pre-caching from the launcher in arm64 mode | spec-N:65; spec-D:17 |
| 14 | `dxmt/check.sh`'s launcher checks (section 10, `MACNEUTRON_LOG`) in arm64 mode | spec-N:65; spec-D:139; dxmt/check.sh:481-483, 795-796 |
| 15 | macOS < 27 becomes a launcher preflight error | spec-N:456 |
| 16 | MacNeutron's own licence line in `licenses/README` "before sub-project 5's first release" | spec-S:105 |
| 17 | Parked: the Rosetta app's missing LLVM and mingw-w64 notices | spec-N:65; spec-S:24 |
| 18 | Deferred bundle: spec-D scope+§6, spec-S scope+§13, acceptance-ship-base "Found on the way" | spec-N:65 |

Not sub-project 5 (for scoping): SMITE 2 parity, x18 classification of Steam's dylib (row 6, spec-N:66); D3D9 (7);
32-bit and FEX WoW64 (8); cutover/deleting GPTK, DXVK, AVX switch, Rosetta preflight (9); media (10); Steam overlay (6);
32-bit Steam client (8) (spec-S:19).

---

## 11. Implied launcher TODO list

Runtime install and identity
1. Install `wine.app` (signed, with internal symlinks intact) under Application Support at a path with spaces; copy
   with something that keeps symlinks and the signature (`cp -cR` in check.sh:615). Verify after install:
   `codesign --verify --strict --deep`, cross-arch entitlement on `MacOS/wine`, `realpath(Resources/lib/wine/aarch64-unix/wine) == Contents/MacOS/wine` (check.sh:146-154).
2. Never write into `wine.app` (immutable after signing, spec-D:42).
3. Pick a runtime-identity token for prefix "needs preparation" checks — `wine.app` has no `runtime-version`; candidates
   are `licenses/SOURCE`, `DXMT/version`, or a new token written at bundle time (see Q5).
4. Preflight: Apple Silicon, macOS >= 27 (spec-N:456; Info.plist `LSMinimumSystemVersion` 27.0); surface patch 0007's
   "lacks the com.apple.developer.cross-architecture-support entitlement" as an error (check.sh:183).

ToolLayout split (arm64 side)
5. `wine` = `Contents/MacOS/wine`; `wineserver` = `Contents/Resources/bin/wineserver`; DXMT dir =
   `Contents/Resources/DXMT/aarch64-windows`; DXMT version = `Contents/Resources/DXMT/version`; replayer =
   `.../DXMT/aarch64-windows/dxmt-replay.exe`; bridge DLL = `Contents/Resources/lib/wine/aarch64-windows/lsteamclient.dll`;
   no `lsteamclient32`; d3d12 always present.

Prefix creation (arm64 prefixes, separate from Rosetta's)
6. `wineboot` (`-i` with `mscoree,mshtml=` as in check.sh:156, or `-u` as the Rosetta launcher does — Q2) with `WINEMSYNC` set.
7. `reg add HKLM\Software\Microsoft\Wow64\amd64 /ve /d libarm64ecfex.dll /f` (check.sh:208). Without it x64 games run
   on the stub.
8. `ShowCrashDialog=0` (already done by PrefixManager.swift:52).
9. Copy `DXMT/aarch64-windows/{d3d11,d3d10core,dxgi,d3d12}.dll` (and whether `dxmt-replay.exe`, Q6) into system32; no syswow64.
10. Steam bridge: `steam.exe` (aarch64) + `steamclient64.dll` (from `lsteamclient.dll`) into
    `drive_c/Program Files (x86)/Steam/`, every launch; remove when the bridge is off.

Launch
11. Exec `wine.app/Contents/MacOS/wine` (via steam.exe when the bridge is on) with `WINEPREFIX`,
    `WINEDLLOVERRIDES` (DXMT string), `WINEDEBUG` default `-all`, `WINEMSYNC=1` (unless the per-game off switch),
    `STEAM_COMPAT_CLIENT_INSTALL_PATH`, `SteamAppId`/`SteamGameId`, `MACNEUTRON_STEAM_ACCOUNT`; no `WINEARCH`; don't
    set `ROSETTA_ADVERTISE_AVX` (Rosetta-only) — no FEX env by default.
12. Keep `WINEMSYNC` identical across every process started in a prefix (wineboot, reg, replay, steam.exe, game,
    `wineserver -k/-w`); `wineserver -k` before flipping it.
13. Wait/stop by `wineserver -w`/`-k` and by executable path (argv is rewritten: check.sh:46-58).
14. Presenter: a non-DYLD load path (Q1).
15. Shader pre-caching: record with `DXMT_PIPELINE_RECORD`, replay with the arm64 `dxmt-replay.exe`, stamp with
    `DXMT/version` (ShaderPrecache.swift:13; dxmt/check.sh:791-813).
16. `MACNEUTRON_LOG=1` routing arm64 runs' output into the game log (dxmt/check.sh:481-487).

Release packaging (bundle.sh / release scripts, not launcher runtime)
17. Strip builtin PE files (before signing; they are sealed).
18. Refuse development inputs: fail when `licenses/SOURCE` has `MACNEUTRON_COMMIT=...+dirty` or any `*_SERIES=dev`, or
    `DXMT/version` ends `+dev`, or there is no stamp (`build/wine-arm64/version`) (build.sh:143-152, 320-324, 333-357).
19. Notarize the entitled bundle (unverified with a restricted entitlement + embedded Developer ID profile).
20. Release source archives (SOURCE lists the inputs: pins, patch series hashes, tarballs).
21. lsteamclient redistribution decision; if "no", a release bundle without it and Steam-API games stay on Rosetta
    (spec-S:40) — which means bundle.sh's lsteamclient asserts (bundle.sh:201-217) and licences_test need a release mode.
22. Ship the aarch64 `steam.exe` somewhere the launcher finds it (Q3).
23. MacNeutron's own licence line in `licenses/README` (spec-S:105); the Rosetta app's LLVM/mingw-w64 notices (parked).

---

## 12. Open design questions (with the evidence that makes each one a question)

1. **Presenter injection on arm64.** Launcher.swift:165-166 uses `DYLD_INSERT_LIBRARIES`; wine.entitlements has no
   `allow-dyld-environment-variables`; every Mach-O is `--options runtime` (bundle.sh:116-118); roadmap says hardened
   runtime ignores `DYLD_*` (spec-N:65). Options: add the (non-restricted) dyld entitlement in bundle.sh; ship the
   presenter inside `wine.app` and have Wine `dlopen` it (a Wine patch); or fold its hook into winemac/DXMT. Also
   unknown: whether `WineMetalLayer`'s `nextDrawable` override reaches the swizzled base method (spec-D:106 vs
   present.m:290-297).
2. **`wineboot -i` + `mscoree,mshtml=` vs `wineboot -u`.** check.sh:156 boots with `-i` and Mono/Gecko disabled;
   PrefixManager.swift:48, bridge/check.sh:26 and probe.sh:66 use `-u`. Which one the arm64 prefix uses decides
   whether Mono/Gecko prompts can appear.
3. **Where the aarch64 `steam.exe` ships.** Only the x64 one goes into `MacNeutron.app/Contents/Resources/steam.exe`
   (Makefile:93); `ToolLayout.steamHelper` is single; spec-S:94/168 say two builds are needed and neither runs on the
   other runtime. It is outside `wine.app` (spec-S:94), so it is MacNeutron.app content, not runtime content — unless
   moved into the bundle before signing.
4. **`tests/helper.exe` in the roadmap.** spec-N:65 says to copy `build/bridge/arm64/`'s `steam.exe` "and
   `tests/helper.exe`" into prefixes, but helper.c:1 says it is a test program for bridge/check.sh, which copies it to a
   scratch game dir (bridge/check.sh:30), and the Rosetta launcher never copies its helper (SteamBridge.swift:18-25).
   Probably a roadmap slip; confirm.
5. **Runtime identity / prefix re-preparation.** Rosetta prefixes compare `runtime-version` at the tool root
   (ToolLayout.swift:30, PrefixManager.swift:35-38). `wine.app` has no version token: Info.plist has no
   `CFBundleVersion`; the stamp `build/wine-arm64/version` lives outside the bundle and is an input hash
   (build.sh:355-357); only `licenses/SOURCE` and `DXMT/version` travel with it.
6. **DXMT/replay layout in ToolLayout.** `ToolLayout.dxmtReplay` = `x64/dxmt-replay.exe`, `dxmtVersionFile` = tool-root
   `dxmt-version` (ToolLayout.swift:50-58); arm64 has `Resources/DXMT/aarch64-windows/dxmt-replay.exe` and
   `Resources/DXMT/version`. check.sh copies `dxmt-replay.exe` into system32 too (check.sh:468) while the Rosetta
   launcher runs it from the tool folder — which does the arm64 launcher do?
7. **msync agreement as a launcher invariant.** Mismatch kills the client silently under `-all` (spec-S:72, :229).
   Every process the launcher starts in an arm64 prefix must carry the same value; a per-game `WINEMSYNC=0` (or
   `MACNEUTRON_NO_MSYNC=1`, LaunchEnvironment.swift:17-19, which leaves it *unset*, i.e. off) while a mode-1 server
   lingers (e.g. after pre-caching) breaks the launch. Needs `wineserver -k` on a mode change, or a recorded mode.
8. **Install path, archive format, notarization.** check.sh only proves a `cp -cR` clone at a spaced path works
   (check.sh:9-10, 615). Release packaging must preserve in-bundle symlinks and the seal; notarization with the
   cross-arch entitlement + embedded profile is explicitly unverified (spec-N:476; spec-S:248). Quarantine/Gatekeeper
   behaviour of a downloaded `wine.app` launched by another binary is untested.
9. **Stripping lsteamclient.dll / builtin PEs.** 57 MB unstripped (acceptance-arm64-ship-base.md:101). PE files are
   sealed by the bundle signature (bundle.sh:110-119), so stripping must be a bundle.sh step before signing — and it
   changes bytes that bundle.sh asserts on (builtin marker at offset 64, CHPE metadata: bundle.sh:192-208).
10. **Release without lsteamclient?** spec-S:40 offers "ship it, ask Valve, or release without it and leave Steam-API
    games on Rosetta". bundle.sh hard-requires lsteamclient (bundle.sh:204-217) and licences_test checks
    `licenses/lsteamclient/` (spec-S:107), so a no-lsteamclient release needs a build variant and the launcher must
    route Steam-API games to Rosetta.
11. **Preflight split.** Which preflight checks apply to the arm64 runtime (macOS >= 27 per spec-N:456 and
    Info.plist; Rosetta not needed; GPTK not applicable — D3DMetal is x86_64-only, spec-N:27) versus the Rosetta one;
    spec-N:69 says the Rosetta preflight is only deleted at cutover (row 9).
12. **Development-input refusal location.** The markers exist (`+dirty`, `*_SERIES=dev`, `+dev`, missing stamp), but
    nothing reads them yet; release script vs launcher-at-install check is undecided.
