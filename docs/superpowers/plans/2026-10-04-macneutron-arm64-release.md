# Native arm64 sub-project 5: the arm64-only release — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** a notarized MacNeutron 0.1.0 that runs 64-bit Windows Steam games only on the native arm64 `wine.app`,
with the Rosetta runtime deleted from the launcher, the app and the build.

**Architecture:** the launcher keeps its shape and swaps its one runtime in place: `ToolLayout` reads every path from
the tool folder's `wine.app`, which the app installs from `MacNeutron.app/Contents/Helpers/wine.app`. `check.sh`'s
prefix recipe moves into `PrefixManager`. `release/release.sh` refuses development inputs, bundles a stripped
`wine.app`, notarizes it and the app, and builds the source archive. Dev checks run the new launcher through assembled
tool folders and keep D3DMetal as a reference through a frozen copy of today's Rosetta tool.

**Tech Stack:** Swift 6 (Swift Testing), Security.framework, Darwin (`proc_pidpath`, `realpath`, `renamex_np`,
`posix_spawnattr_setarchpref_np`), POSIX shell, Wine 11.19 + FEX + DXMT (`wine-arm64/`), `codesign`, `notarytool`,
`stapler`, `syspolicy_check`, `spctl`, `launchctl`, llvm-mingw.

**Spec:** `docs/superpowers/specs/2026-10-04-macneutron-arm64-release-design.md` (§14 amends §§1-13). Exact current
code: `docs/research/2026-10-04-arm64-release/digest-{core,install-app,wine-build,checks,release-docs}.md`, cited as
`core §…`, `install §…`, `build §…`, `checks §…`, `release §…`. Line numbers are at `92d8f83` and drift as tasks land:
re-find by content. The plan's own review: `docs/research/2026-10-04-arm64-release/plan-review.md`.

## Global Constraints

- macOS 27 or later, Apple Silicon only. `Package.swift` `.macOS("27.0")`; `App/Info.plist` and `wine.app`
  `LSMinimumSystemVersion` `27.0`; every Mach-O in `wine.app` has minos `27.0` (bundle.sh asserts it).
- **Never modify the installed tool folders** `~/Library/Application Support/MacNeutron/compatibilitytools.d/
  macneutron` and `…/macneutron-native`. Every launcher run in a test or check uses a folder assembled with
  `macneutron install --tool-dir <dir> …` (required flag) or a clone. Installing the release there is the maintainer's
  last step.
- **Never open or run a `MacNeutron.app` built by this plan on this Mac** (`build/MacNeutron.app`,
  `build/release/…/MacNeutron.app`): its start writes the real tool folder. A new app runs only in R6's fresh account.
- Signing env for anything that builds `wine.app` (including `make app`): `MACNEUTRON_SIGN_IDENTITY="Developer ID
  Application: Chad Cormier Roussel (49QMZXLR8S)"`, `MACNEUTRON_PROVISIONING_PROFILE` (today
  `$HOME/Downloads/Mac_Neutron.provisionprofile`). Never copy the profile into the repo. Notarization reads
  `MACNEUTRON_NOTARY_PROFILE` (default `macneutron`) and needs the network, as do `release.sh`'s `git fetch` and
  `dxmt/published.sh`.
- The Wine, FEX, DXMT and lsteamclient trees under `build/wine-arm64-src/`: changes are **new commits** on branch
  `macneutron`, exported with `make wine-arm64-export`; never amend, rebase or cherry-pick. After an export, check
  `git diff --stat wine-arm64/patches` touches only the intended files.
- Stamp format, exactly: `wine.app <identity> msync=<0|1>`; while preparing: `wine.app preparing`. Damage marker:
  `<tool folder>/runtime-damaged`. Identity: the loader's CDHash, 40 lowercase hex (`kSecCodeInfoUnique`).
- Player-facing texts, verbatim (spec §10):
  - `MacNeutron needs macOS 27 or later on an Apple Silicon Mac.`
  - `MacNeutron's runtime is missing or damaged. Open MacNeutron to repair it.`
  - `This game is 32-bit. MacNeutron 0.1 runs 64-bit games only; 32-bit support is planned.`
  - `This game is built for <machine>, which MacNeutron can't run.` — `<machine>` is `ARM (32-bit)` for 0x1c4,
    `Itanium` for 0x200, else `machine type 0x%04x`
  - launcher.log notes: `skipped 32-bit installer <name>`, `note: renamed a Rosetta-era prefix to <name>`,
    `note: msync changed, stopped the prefix's wineserver`, `install deferred: <path> is running`,
    `note: '<value>' was removed in 0.1, using dxmt`
- DXMT overrides `dxgi,d3d10core,d3d11,d3d12=n,b;d3d9,d3d10=b`; wined3d `dxgi,d3d9,d3d10,d3d10core,d3d11,d3d12=b`;
  wineboot adds `mscoree,mshtml=`.
- `macneutron install` output: `installed <label>` / `unchanged <label>` (exit 0), `deferred: <path> is running`
  (exit 3), errors exit 1, usage exit 2. `<label>` = `<CFBundleShortVersionString or unknown> (<identity[0..12] or
  unsigned>)`.
- `LC_ALL=C /usr/bin/grep` in every script and check (the interactive `grep` is a wrapper that can return 0 silently).
- Never print or commit SteamIDs, account IDs or persona names (`bridge/probe.sh`'s redaction stays on).
- Stop Wine with `wineserver -k` (with the run's `WINEMSYNC`) plus `lsof -t` on the executables; never `pkill -f`.
- No new downloads. Submissions to Apple's notary service happen only in Task 1 (R0) and Task 14 (the release).
- Commits end with the implementer's own `Co-Authored-By:` trailer. Nothing is pushed, except `main` in Task 14
  Step 2 on the maintainer's explicit yes.
- From Task 6a until Tasks 9-11 rewrite them, `make smoke`, `make app`, `make dxmt-check`, `make wine-arm64-check`,
  `make bridge-check` and `make presenter-check` are expected to fail: gate those tasks on `make test` only.

## Review Focus

1. **Paths with spaces and non-ASCII** → Task 7 `installWorksUnderASpacedNonASCIIPath`,
   `appBundleResolvesToItsExecutable` (`"Gamé Folder"/"My Game.app"`), Task 5 `machineReadsAPathWithSpaces`.
2. **A Rosetta-era prefix holding saves**, `pfx.rosetta` taken → Task 6c `renameNumbersPastTakenNamesAndKeepsTheSaves`.
3. **A multi-GB game exe** → Task 5 `machineReadsOnlyTheHeaderOfAHugeFile`.
4. **Settings changed between launches** → Task 6c `msyncOnlyChangeKillsTheServerUnderTheOldMode`,
   `switchingBackToDXMTFindsItsDLLs`.
5. **An install interrupted mid-copy, then a launch** → Task 7 `leftoversFromAnInterruptedInstallAreCleaned`,
   `aDeferredInstallLeavesTheOldRuntimeWorking`; **the kernel's real path under `/private`** →
   `deferralMatchesTheKernelsRealPath`.

---

### Task 1: R0 — notarize `wine.app` and launch its quarantined copy

**Needs the maintainer:** first `xcrun notarytool store-credentials macneutron` (only they can; it contacts Apple);
later, turning the network off and on when asked in chat.

**Files:**
- Create: `release/lib.sh`, `release/r0.sh`, `docs/testing/acceptance-arm64-release.md`

**Interfaces:**
- Produces (`release/lib.sh`, sourced, `set -eu`): `die <msg>` (prefix `release: `);
  `notarize_and_staple <bundle> <work-dir>`: `/usr/bin/syspolicy_check notary-submission <bundle>`; `ditto -c -k
  --keepParent` into `<work-dir>/<name>.zip`; `xcrun notarytool submit <zip> -p "${MACNEUTRON_NOTARY_PROFILE:-macneutron}"
  --wait --output-format json`; require `jq -r .status` = `Accepted`, else `xcrun notarytool log <id> -p …` and fail;
  `xcrun stapler staple`, `xcrun stapler validate`, `/usr/bin/syspolicy_check distribution`; prints `submission <id>`.
- Produces: `build/release/r0/wine.app` (stapled, unquarantined), reused by Task 9's L6 notarized row.

- [ ] **Step 1: Write `release/lib.sh`.**
- [ ] **Step 2: Write `release/r0.sh <notarize|online|offline|results>`.**
  - `notarize`: `cp -c -R build/wine-arm64/wine.app build/release/r0/wine.app`; record `codesign -dvvv` `CDHash=`;
    `notarize_and_staple`; record the CDHash again (must be equal); make `build/release/r0/quarantined/wine.app` (clone)
    and `xattr -r -w com.apple.quarantine "0081;$(printf %x $(date +%s));Safari;$(uuidgen)"` on it.
  - `online` / `offline`: clone the quarantined copy to `build/release/r0/<mode>/Application Support/wine.app` (fresh
    each time). Boot `build/release/r0/<mode>/pfx` with the **unquarantined** `build/wine-arm64/wine.app` from the
    shell (`WINEPREFIX=… WINEMSYNC=1 WINEDLLOVERRIDES=mscoree,mshtml= … wine wineboot -i`, then `wineserver -w`). Then run
    only `build/wine-arm64-tests/arm64-hello.exe` with the clone's loader through launchd: write
    `build/release/r0/<mode>/job.plist` (Label `net.authspot.macneutron.r0`, ProgramArguments `/bin/sh -c '[ -e <out>.done ]
    && exit 0; : > <out>.done; WINEPREFIX=<pfx> WINEMSYNC=1 <clone>/Contents/MacOS/wine <hello> > <out> 2>&1; echo
    "status=$?" >> <out>'`, RunAtLoad true, KeepAlive false, absolute paths only); `launchctl bootout
    gui/$(id -u)/net.authspot.macneutron.r0 2>/dev/null` first; `trap` the bootout plus `wineserver -k` on EXIT INT TERM;
    `launchctl bootstrap gui/$(id -u) <plist>`; poll ≤ 120 s for `status=`; bootout. Writes
    `build/release/r0/result-<mode>.txt`. `offline` refuses unless `/sbin/route -n get default` fails.
  - `results`: prints both result files and the CDHash lines.
- [ ] **Step 3: Run** `sh release/r0.sh notarize` and `sh release/r0.sh online`. Then ask the maintainer in chat to turn
  the network off; run `sh release/r0.sh offline`; ask them to turn it back on; `sh release/r0.sh results`.
  Expected: `Accepted`, staple/validate/distribution clean, equal CDHashes, both results contain the hello line and
  `status=0`.
- [ ] **Step 4: Record** the R0 section in `docs/testing/acceptance-arm64-release.md` (create it: title, spec link):
  submission ids, the results, the CDHash lines. **A rejection, a stapler/syspolicy failure or a blocked launch stops
  the plan for the maintainer's decision.** A bug in the script may be fixed and the trial rerun; record every
  submission id.
- [ ] **Step 5: Commit** `release/lib.sh release/r0.sh docs/testing/acceptance-arm64-release.md`.

### Task 2: R0b — can Steam launch a thin arm64 tool?

**Needs the maintainer:** Steam restarts and choosing a tool in Steam's UI.

**Files:**
- Create: `tools/r0b-probe.c`, `tools/r0b.sh` (`setup` / `results` / `remove`)
- Modify: `docs/testing/acceptance-arm64-release.md`

**Interfaces:**
- Produces: the verdict line `R0b: PASS` or `R0b: FAIL` in the acceptance doc; Task 7 and Task 9 read it.

- [ ] **Step 1: `tools/r0b-probe.c`** (thin arm64: `clang -arch arm64 -mmacosx-version-min=27.0`; check `lipo -archs` =
  `arm64`): appends `arch=<uname machine> translated=<sysctl.proc_translated> argv=<argv joined by |>` to
  `<dirname of its own realpath>/r0b.log` (create on demand), then exits 0; on an open failure exits 1.
- [ ] **Step 2: `tools/r0b.sh`.** `setup` refuses unless Steam is in Linux mode (`LC_ALL=C /usr/bin/grep -qx
  '@sSteamCmdForcePlatformType linux' "$HOME/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/
  steam_dev.cfg"`) and builds two tools under `build/r0b/` in the shape `RuntimeInstaller`/`SteamPlayMode` write today:
  `r0b-probe` with the probe at `bin/r0b-probe` and manifest `"/bin/r0b-probe launch %verb%"`, and `r0b-probe-native`
  (`from_oslist macos`, `to_oslist linux`) with the probe at `bin/r0b-probe-native` and manifest
  `"/bin/r0b-probe-native passthrough %verb%"`; it links both into Steam's bundle `compatibilitytools.d` (where
  `SteamPlayMode.link(_:)` links ours). The names deliberately don't start with `macneutron` (spec §14:
  `MappingPlanner.isOurs`), so MacNeutron's sync leaves the maintainer's choices alone. `results` prints both
  `r0b.log`s. `remove` refuses while Steam runs, keeps everything and prints a reminder while Steam's `config.vdf`
  still names `r0b-probe`, tolerates links that were never made, then deletes the links and `build/r0b`.
- [ ] **Step 3: Run with the maintainer:** quit Steam; `setup`; start Steam; the maintainer sets Spacewar (480) to
  `r0b-probe` and a Mac game to `r0b-probe-native` (Properties → Compatibility), presses Play on each, then sets both
  back to their previous tool; `results`; quit Steam; `remove`; start Steam.
- [ ] **Step 4: Record** `R0b: PASS` (both logs: `arch=arm64 translated=0`, argv[1] `launch`/`passthrough`, the verb
  present) or `R0b: FAIL` with the log lines. A FAIL counts only if Steam logged the launch attempt; otherwise rerun.
  A FAIL doesn't stop the plan: Task 7 keeps the shell entry points.
- [ ] **Step 5: Commit.**

### Task 3: Move the running app aside and freeze the Rosetta reference

**Needs the maintainer** for Step 1.

**Files:**
- Create: `tools/freeze-rosetta-reference.sh`

**Interfaces:**
- Produces: `~/Library/Application Support/MacNeutron Reference/rosetta-tool/` and `…/MacNeutron Reference/FROZEN`
  (`runtime=…`, `gptk=…`, `date=…`). Checks find the reference through `MACNEUTRON_REFERENCE` (default that
  `rosetta-tool` path) and treat it as missing unless `"$REF/../FROZEN"` exists.

- [ ] **Step 1 (maintainer): stop running the app from the build folder.** The maintainer quits MacNeutron, runs
  `ditto build/MacNeutron.app /Applications/MacNeutron.app`, opens the `/Applications` copy and turns Launch at login
  off and on in its Settings. Check: `ps -axo comm= | LC_ALL=C /usr/bin/grep -F "$PWD/build/MacNeutron.app/"` prints
  nothing. (`make app` rebuilds that folder from Task 9 on; a rebuilt app must never start here.)
- [ ] **Step 2: Write the script:** source `${MACNEUTRON_TOOL:-…/compatibilitytools.d/macneutron}`; refuse if
  `gptk.json`, `runtime-version` or `Libraries/Wine/bin/wineserver` is missing, or if `rosetta-tool` exists; delete any
  `rosetta-tool.partial`, `cp -c -R` into `rosetta-tool.partial`, `mv` to `rosetta-tool`, then write `FROZEN`.
  Read-only on the source.
- [ ] **Step 3: Run it.** Expected: `"$REF/bin/macneutron"` exists; `cat "$REF/runtime-version"` = `runtime-v4.7.3`;
  `FROZEN` written; a second run refuses with `already exists`.
- [ ] **Step 4: Commit** the script.

### Task 4: `wine.app` gains its version, the presenter, patch 0002 and its licence entries

**Files:**
- Modify: `wine-arm64/build.sh` (presenter build after DXMT's step 7; stamp adds `presenter/present.m` and `LICENSE`;
  `+dirty` pathspec adds `presenter LICENSE`; SOURCE's `DXMT_SUBMODULE_*` after `DXMT_SERIES`),
  `wine-arm64/bundle.sh` (presenter `put` into `$U`; `CFBundleShortVersionString`/`CFBundleVersion` = `dev` via
  `PlistBuddy` before signing; `licenses/macneutron/LICENSE`), `wine-arm64/licenses/README`,
  `wine-arm64/licenses/NOTICES.md` (folder list), `wine-arm64/tests/licences_test.sh`, `presenter/present.m:1` comment
- Create: `LICENSE` (MIT, `Copyright (c) 2026 Chad Cormier Roussel`); exported
  `wine-arm64/patches/dxmt/0002-winemetal-Load-the-MetalFX-presenter-when-asked.patch`
- Details: `build §13` (§5.1, §5.3, §7.1, §7.2), `build §8`. The Makefile's `presenter` target is Task 9's.

**Interfaces:**
- Produces: `wine.app/Contents/Resources/lib/wine/aarch64-unix/libmacneutron-present.dylib` (arm64, minos 27.0,
  install name `@rpath/libmacneutron-present.dylib`); `winemetal.so` loads it when `MACNEUTRON_PRESENT=1`; Info.plist
  `CFBundleShortVersionString` `dev`; SOURCE keys `DXMT_SUBMODULE_nvapi`, `DXMT_SUBMODULE_directx`;
  `licenses/macneutron/LICENSE`.

- [ ] **Step 1: Failing licence checks.** `licences_test.sh`: require `licenses/macneutron/LICENSE`, a README line with
  `macneutron/LICENSE`, the lsteamclient entry containing `maintainer's decision of 2026-10-04`, SOURCE keys
  `DXMT_SUBMODULE_nvapi DXMT_SUBMODULE_directx`; self-test red case deleting `licenses/macneutron/LICENSE`. Run
  `sh wine-arm64/tests/licences_test.sh build/wine-arm64/wine.app`. Expected: FAIL naming the four items.
- [ ] **Step 2: DXMT patch 0002.** In `build/wine-arm64-src/dxmt` on `macneutron`: in
  `src/winemetal/unix/winemetal_unix.c`, an `__attribute__((constructor)) static void load_presenter(void)` that, when
  `getenv("MACNEUTRON_PRESENT")` is `"1"`, calls `dlopen("@loader_path/libmacneutron-present.dylib", RTLD_NOW |
  RTLD_LOCAL)` and on failure prints `winemetal: can't load the MetalFX presenter: <dlerror()>` to stderr. Commit
  (subject `winemetal: Load the MetalFX presenter when asked.`; body: the hardened runtime ignores
  `DYLD_INSERT_LIBRARIES`), `make wine-arm64-export`, check only `patches/dxmt/0002-*` was added.
- [ ] **Step 3: build.sh and bundle.sh** as listed. Presenter build: `/usr/bin/clang -arch arm64
  -mmacosx-version-min=27.0 -fobjc-arc -O2 -dynamiclib -install_name @rpath/libmacneutron-present.dylib -framework
  Foundation -framework AppKit -framework QuartzCore -framework Metal -framework MetalFX -o
  "$SRC/presenter/libmacneutron-present.dylib" "$ROOT/presenter/present.m"`. Licences README: lsteamclient "ships by the
  maintainer's decision of 2026-10-04 under Valve's Steamworks SDK licence (`lsteamclient/`)"; new entry "MacNeutron
  (`libmacneutron-present.dylib`, the MetalFX presenter; the Wine, DXMT and FEX patch files): MIT,
  `macneutron/LICENSE`".
- [ ] **Step 4: Build and check.** `make wine-arm64` (DXMT rebuilds: its series changed). Expected: every bundle.sh
  assertion passes; `licences_test.sh` and `--self-test` PASS; `PlistBuddy -c 'Print :CFBundleShortVersionString'` =
  `dev`; `otool -D` on the presenter = `@rpath/libmacneutron-present.dylib`.
- [ ] **Step 5: Presenter smoke.** `make dxmt-tests-arm64ec`; run `build/dxmt-tests-arm64ec/present_loop.exe 1280 720
  640 360 120 0` in a scratch prefix prepared as `wine-arm64/check.sh` does (boot, FEX key, DXMT DLLs, DXMT overrides)
  with `MACNEUTRON_PRESENT=1 MACNEUTRON_PRESENT_SCALE=1`. Expected: stderr has `macneutron-present: MetalFX 640x360 ->
  1280x720`; the same run without `MACNEUTRON_PRESENT` has no `macneutron-present` line.
- [ ] **Step 6: Commit** (repo files + the exported patch).

### Task 5: Leaf pieces — PE machine, code identity, running processes

**Files:**
- Create: `Sources/MacNeutronCore/{PEImage,CodeIdentity,RunningProcesses}.swift`
- Test: `Tests/MacNeutronCoreTests/{PEImageTests,CodeIdentityTests,RunningProcessesTests}.swift`; add to
  `Tests/MacNeutronCoreTests/Support.swift`: `func makeSignedWineApp(at dir: URL, loader: URL =
  URL(filePath: "/usr/bin/true"), shortVersion: String = "test", bundleVersion: String = "1") throws -> URL`
  (writes `Contents/Info.plist` with `CFBundleExecutable` `wine`, `CFBundleIdentifier` `test.wine` and the versions,
  copies `loader` to `Contents/MacOS/wine`, runs `/usr/bin/codesign -s - -f <bundle>`; shared with Tasks 7-8)
- Details: `core §C.1`, `core §B §5.1`, `install §D`

**Interfaces:**
- Produces:
  - `public enum PEImage { public static let i386: UInt16 = 0x014c, amd64: UInt16 = 0x8664, arm64: UInt16 = 0xAA64;
    public static func machine(of url: URL) -> UInt16? }` — nil when not PE (missing, unreadable, script, truncated);
    reads only the DOS header and 6 bytes at `e_lfanew` through `FileHandle`.
  - `public enum CodeIdentity { public static func of(_ bundle: URL) -> String? }` — `SecStaticCodeCreateWithPath`,
    `SecCodeCopySigningInformation(…, SecCSFlags(rawValue: kSecCSSigningInformation), …)`, `kSecCodeInfoUnique` as 40
    lowercase hex; nil when unsigned or missing.
  - `public enum RunningProcesses { public static func executablePaths() -> [String] }` — `proc_listallpids` +
    `proc_pidpath` (buffer `4 * Int(MAXPATHLEN)`), skipping results ≤ 0. Paths are the kernel's (`/private/var/…`).

- [ ] **Step 1: Failing tests.**
  - `PEImageTests`: `amd64AndArm64AndI386MachinesAreRead` (synthetic 64-byte DOS header, `e_lfanew` 0x80, `PE\0\0`,
    machine), `aScriptIsNotPE`, `aTruncatedMZIsNotPE`, `aMissingFileIsNotPE`, `machineReadsAPathWithSpaces`
    (`makeTempDir()` + `"game é/Game.exe"`), `machineReadsOnlyTheHeaderOfAHugeFile` (header, then
    `FileHandle.truncate(atOffset: 4 << 30)`; under 1 s).
  - `CodeIdentityTests` (with `makeSignedWineApp`): `identityIs40HexAndMatchesCodesign` (vs `codesign -dvvv` stderr
    `CDHash=`), `bundlesDifferingOnlyInTheLoaderDiffer` (`/usr/bin/false`), `bundlesDifferingOnlyInInfoPlistDiffer`,
    `resigningIdenticalBitsKeepsTheIdentity`, `unsignedOrMissingBundleHasNoIdentity`.
  - `RunningProcessesTests`: `thisTestProcessIsListed` (contains `String(cString: realpath(Bundle.main.executablePath!,
    nil))`), `aSpawnedSleepIsListedByItsExecutable` (`/bin/sleep 5` through `Process`, terminated in `defer`).
- [ ] **Step 2: Run** `swift test --filter 'PEImageTests|CodeIdentityTests|RunningProcessesTests'`. Expected: compile
  failure (types missing).
- [ ] **Step 3: Implement** the three types (`import Security`, `import Darwin`).
- [ ] **Step 4: Run** the filter, then `make test`. Expected: PASS.
- [ ] **Step 5: Commit.**

### Task 6a: Delete the Rosetta install side

The launcher is untouched in this task.

**Files:**
- Delete: `Sources/MacNeutronCore/{GPTKDiskImage,GPTKImporter,DXMTInstaller}.swift` and
  `Tests/MacNeutronCoreTests/{GPTKDiskImageTests,GPTKImporterTests,DXMTInstallerTests}.swift`
- Modify: `Sources/MacNeutronCore/{RuntimeInstaller,CommandLineTool,SteamPlayMode,SteamLocation}.swift`,
  `Sources/MacNeutronApp/{AppModel,SetupView,SettingsView}.swift`
- Test: `Tests/MacNeutronCoreTests/{RuntimeInstallerTests,CommandLineToolTests,SteamPlayModeTests,AppModelTests}.swift`
- Details: `install §A.1-A.5, §A.9`, `core §B §3.3` (cross-area), `plan-review.md` R1.1, R1.2

**Interfaces:**
- Produces: `RuntimeInstaller` keeps only `writeToolFiles(layout:launcherBinary:)` and `installFile`; no `RuntimePin`,
  `install(tarball:)`, `cachedDownload`, `download`, `sha256(of:)`. `SteamPlayMode` has no `rosettaAvailable`;
  `SteamPlayError` no `rosettaMissing`. CLI verbs: `launch` only (Task 7 adds `install`, `passthrough`).

- [ ] **Step 1: Tests first.** Delete the three test files and: `RuntimeInstallerTests` `makeRuntimeTarball` and the
  tests at :28, :57, :67, :77, :132, :142, :153, :166, :175 (rewrite :45 and :86 to call `writeToolFiles` directly;
  keep :95, :105, :120); `CommandLineToolTests` `importGPTKRejectsANonGPTKFolder`, `installRuntimeRejectsAWrongTarball`,
  `installDXMTRejectsAFolderThatIsNotABuild`, `installDXMTInstallsABuild`; `SteamPlayModeTests` `enableRequiresRosetta`,
  `turningOnWithoutRosettaLeavesSteamRunning` and the `mode.rosettaAvailable = …` lines (:12, :237, :249) —
  `passthroughPrefersTheAppleSiliconBuild` stays until Task 6c; `AppModelTests` cases using `importGPTK` or
  `installRuntime`.
- [ ] **Step 2: Delete and trim the code** (`install §A.3`, `§A.4`, `§A.5`): the three files; RuntimeInstaller's tarball
  code and `import CryptoKit`; the CLI verbs and usage lines; `SteamPlayMode.rosettaAvailable` and the `enable` guard;
  `SteamPlayError.rosettaMissing`; in the app the GPTK step, `choosingDMG`, `.fileImporter`, `importGPTK`,
  `installRuntime`, its Setup button and Settings' "Repair runtime" (Task 8 restores Repair), and the
  `writeToolFiles`/`DXMTInstaller` refresh in `AppModel.init`.
- [ ] **Step 3: Run** `make test`. Expected: PASS.
- [ ] **Step 4: Commit.**

### Task 6b: Settings and graphics

**Files:**
- Modify: `Sources/MacNeutronCore/{GameSettings,GraphicsBackend,LaunchEnvironment,ShaderPrecache,Launcher}.swift`,
  `Sources/MacNeutronApp/GamesView.swift`
- Test: `Tests/MacNeutronCoreTests/{GameSettingsTests,GraphicsBackendTests,LaunchEnvironmentTests,LauncherTests}.swift`
- Details: `core §B §3.2, §3.6, §3.7`

**Interfaces:**
- Produces: `GameSettings(graphics:log:msync:runAs:metalFX:)` (no `avx`; an old `avx` key is ignored silently: §3.2
  wins over §10's "noted"); `GraphicsBackend: String, CaseIterable { case dxmt, wined3d }`, `static func
  select(requested: String?) -> (backend: GraphicsBackend, note: String?)` (`d3dmetal`/`dxvk` → `.dxmt` with note
  `'<value>' was removed in 0.1, using dxmt`; other unknowns as today), `var dllOverrides: String`;
  `LaunchEnvironment.build(base:context:backend:logging:)` (no `layout:`, no `ROSETTA_ADVERTISE_AVX`; `WINEMSYNC=1`
  unless `MACNEUTRON_NO_MSYNC=1`, then removed); `ShaderPrecache.enabled(backend:environment:) -> Bool` = `backend ==
  .dxmt && environment["MACNEUTRON_PRECACHE"] != "0"` (no `layout:`).

- [ ] **Step 1: Failing tests:** `oldSettingsFilesStillLoad` (`{"avx":false,"graphics":"d3dmetal"}` →
  `GameSettings(graphics: "d3dmetal")`), `settingsBecomeLaunchVariables` (no `MACNEUTRON_NO_AVX`), `defaultsToDXMT`,
  `removedBackendsReadAsDXMTWithANote`, `overrideStringsPerBackend`, `everyBackendOverridesTheSameDLLSet`,
  `honorsRequestCaseInsensitively` (`" WINED3D "`), `unknownRequestFallsBackWithNote`, `setsPrefixOverridesAndDefaults`
  (`dxgi=n,b;d3d10core=n,b;d3d11=n,b;d3d12=n,b;d3d9=b;d3d10=b`, no AVX), `wined3dOverridesUseBuiltins`,
  `optOutsDropDefaults`, `userOverridesWin`, `recordsPipelinesForDXMTOnly` (dxmt yes, wined3d no, `MACNEUTRON_PRECACHE=0`
  no, the user's path wins), `oldGraphicsValueRunsDXMTWithANote` (launcher line has `backend=dxmt` and
  the note). Delete the D3DMetal/DXVK/GPTK backend tests (`core §B §3.6`).
- [ ] **Step 2: Run** `make test`. Expected: FAIL.
- [ ] **Step 3: Implement**; GamesView: drop the AVX toggle, picker `Default (DXMT)` / `DXMT` / `wined3d (OpenGL)`.
- [ ] **Step 4: Run** `make test`. Expected: PASS.
- [ ] **Step 5: Commit.**

### Task 6c: The launch path on `wine.app`

**Files:**
- Modify: `Sources/MacNeutronCore/{ToolLayout,Preflight,PrefixManager,SteamBridge,ShaderPrecache,Launcher,
  RuntimeInstaller}.swift`, `Sources/MacNeutronApp/{AppModel,MenuContent,SetupView}.swift` (runtime version reads only)
- Test: `Tests/MacNeutronCoreTests/{Support,PathsTests,PreflightTests,PrefixManagerTests,LauncherTests,
  ShaderPrecacheTests,SteamBridgeTests,SteamPlayModeTests,AppModelTests}.swift`
- Details: `core §B §3.1, §3.3, §3.4, §3.5, §3.8, §3.10`, `core §D`

**Interfaces:**
- Consumes: Task 5 `PEImage`, `CodeIdentity`; Task 6b's backend and environment.
- Produces:
  - `ToolLayout`: `wineApp`, `wine`, `wineserver`, `dxmt`, `dxmtVersionFile`, `dxmtVersion`, `dxmtReplay`,
    `static let dxmtDLLs = ["d3d10core.dll", "d3d11.dll", "d3d12.dll", "dxgi.dll"]`, `lsteamclient`,
    `lsteamclientUnix`, `launcherBinary`, `steamHelper`, `steamBridgeInstalled` (steam.exe + both lsteamclient files),
    `runtimeDamagedMarker`, `runtimeVersion: String?` (`Contents/Info.plist` through `PropertyListSerialization`, read
    each time), `identity: String?` (`CodeIdentity.of(wineApp)`), `public static func runtimeLabel(version: String?,
    identity: String?) -> String` (= Global Constraints' `<label>`), `static let rosettaEraEntries = ["Libraries",
    "gptk", "gptk.json", "gptk.staging", "lib", "dxmt-version", "runtime-version", "runtime.staging"]`. Deleted:
    `core §B §3.1` list.
  - `PreflightError { unsupportedSystem, runtimeMissing, thirtyTwoBit, unsupportedMachine(UInt16) }` with the Global
    Constraints texts; `Preflight(systemSupported: @Sendable () -> Bool = …, identity: @Sendable (ToolLayout) ->
    String? = { $0.identity })`; `func check(_ layout: ToolLayout, request: LaunchRequest) throws(PreflightError) ->
    String` (returns the identity; writes `runtimeDamagedMarker` on `runtimeMissing`; PE check only for
    `waitforexitandrun`).
  - `PrefixError.emulatorSetupFailed(Int32)`; `PrefixManager(context:layout:identity:runner:log:)`,
    `static func stamp(identity: String, msync: Bool) -> String`, `prepare(environment:steamBridge:)` per spec §3.4
    (msync read from the built env's `WINEMSYNC` with atoi semantics).

- [ ] **Step 1: Fixtures and failing tests.** `Support.swift` `makeToolLayout()` builds a fake `wine.app` tree
  (`Contents/Info.plist` with `CFBundleShortVersionString` `test`, `MacOS/wine`, `Resources/bin/wineserver`,
  `Resources/DXMT/{version, aarch64-windows/{4 DLLs, dxmt-replay.exe}}`,
  `Resources/lib/wine/aarch64-{windows/lsteamclient.dll, unix/lsteamclient.so}`); launcher, prefix and precache tests
  inject `Preflight(systemSupported: { true }, identity: { _ in "0123456789abcdef0123456789abcdef01234567" })`.
  Tests (names and assertions):
  - Paths: `layoutPathsFollowWineApp`, `runtimeVersionComesFromWineAppInfoPlist` (nil when absent),
    `runtimeLabelFormats` (`test (0123456789ab)`, `unknown (unsigned)`).
  - Preflight: `unsupportedSystemIsRefusedFirst`, `unreadableIdentityIsDamagedAndMarked`, `x64AndArm64TargetsPass`,
    `i386TargetIsThirtyTwoBit`, `otherMachineIsNamed` (0x1c4 → `This game is built for ARM (32-bit), which MacNeutron
    can't run.`; 0x5032 → `machine type 0x5032`), `nonPETargetIsNotChecked` (a script, a missing file),
    `targetIsCheckedOnlyForWaitForExitAndRun`.
  - Launcher: `missingRuntimeNotifiesAndFails`, `thirtyTwoBitGameIsRefusedWithItsMessage`, `runSkipsA32BitInstaller`
    (exit 0, no runner calls, no notification, `skipped 32-bit installer Setup.exe`), `failureMessagesReachTheGameLog`
    (`MACNEUTRON_LOG=1` + i386 → `steam-42.log` has the 32-bit text), `presenterIsAskedForByDefault`
    (`MACNEUTRON_PRESENT == "1"`, no `DYLD_INSERT_LIBRARIES`), `optingOutLeavesThePresenterOff`,
    `toolCommandsGetNoPresenter`, `everyLaunchIsLoggedWithVersions` (ends `backend=dxmt runtime=test (0123456789ab)
    exit=0`), `terminateKillsThePrefixWineserverUnderTheGamesMsync` (`WINEMSYNC == "1"`; settings `msync: false` →
    unset), `waitForExitAndRunPreparesWaitsRunsThenWaits` (`wineboot -u`, FEX `reg add`, crash-dialog `reg add`,
    `wineserver -w`, `wineserver -w`, the game, `wineserver -w`). Delete the six DYLD presenter tests and
    `defaultBackendIsDXMTEvenWithGPTKImported`.
  - Prefix: `freshPrefixRunsWinebootAndRecordsVersion` (stamp `wine.app <id> msync=1`; wineboot overrides contain
    `mscoree=;mshtml=`), `failedWinebootSkipsTheRegistrySteps`, `upToDatePrefixSkipsWineboot`,
    `identityChangePreparesInPlace`, `rosettaEraPrefixIsRenamedNeverDeleted` (log `note: renamed a Rosetta-era prefix
    to pfx.rosetta`), `renameNumbersPastTakenNamesAndKeepsTheSaves`, `preparingStampIsRetriedInPlace`,
    `failedFEXRegistrationFailsThePreparation`, `msyncOnlyChangeKillsTheServerUnderTheOldMode` (`wineserver -k` with the
    old `WINEMSYNC`, no wineboot, the msync note), `copiesDXMTIntoSystem32Only`, `switchingBackToDXMTFindsItsDLLs`,
    `missingRuntimeDLLIsAnError`, `concurrentLaunchesRunWinebootOnce`, `steamBridgeIsCopiedIntoTheSteamFolder` (no
    `steamclient.dll`), `unchangedBridgeFilesAreNotRecopied`, `changedBridgeFileIsRecopied`. Delete
    `thirtyTwoBitClientIsSkippedWithoutAnI386Build`, `dxmtDeploysOurD3D12WhenInstalled`.
  - Other: `SteamBridgeTests.bridgeNeedsSteamExeAndBothHalvesOfTheClient`; `ShaderPrecacheTests` on the new paths; delete
    `SteamPlayModeTests.passthroughPrefersTheAppleSiliconBuild`; `AppModelTests.setupWindowStaysClosedOnceSetUp` relies
    on the fake `wine.app`'s version.
- [ ] **Step 2: Run** `make test`. Expected: compile failures on the old APIs.
- [ ] **Step 3: Implement** per Interfaces: `fail` also appends to the game log when one is open (open it before
  preflight); `run` + i386 skip right after preflight; `terminate` merges the game's settings and builds §3.7's
  environment; copy-when-different sets the target's mtime to the source's; `RuntimeInstaller.writeToolFiles` stops
  copying the presenter; the app reads `runtimeVersion` from the new layout and shows
  `ToolLayout.runtimeLabel(version:identity:)` in the menu.
- [ ] **Step 4: Run** `make test`. Expected: PASS.
- [ ] **Step 5: Commit.**

### Task 7: Installing `wine.app`, the CLI verbs and Steam's entry points

**Files:**
- Modify: `Sources/MacNeutronCore/{RuntimeInstaller,CommandLineTool,SteamPlayMode}.swift`
- Test: `Tests/MacNeutronCoreTests/{RuntimeInstallerTests,CommandLineToolTests,SteamPlayModeTests,FakeSteam}.swift`
- Details: `install §B.1, §B.2, §C`

**Interfaces:**
- Consumes: Task 5 `CodeIdentity`, `RunningProcesses`, `makeSignedWineApp`; Task 6c `ToolLayout`; Task 2's verdict.
- Produces:
  - `public enum RuntimeInstallOutcome: Equatable, Sendable { case installed, unchanged, deferred(String) }`;
    `public enum RuntimeInstallError: Error { case notAWineApp(String), signatureInvalid(Int32), swapFailed(Int32) }`.
  - `RuntimeInstaller.install(wineApp: URL, layout: ToolLayout, launcherBinary: URL, steamExe: URL? = nil, force: Bool
    = false, runner: any ProcessRunner = SystemProcessRunner(), runningExecutables: () -> [String] =
    RunningProcesses.executablePaths, identity: (URL) -> String? = CodeIdentity.of, log: LauncherLog = .standard)
    throws -> RuntimeInstallOutcome`, spec §3.9 steps 1-6:
    1. Defer when a running executable path starts with `realpath(layout.wineApp) + "/"` or `realpath(layout.root +
       "/Libraries") + "/"` (resolve with `realpath(3)`, free the buffer, skip a missing folder; never
       `URL.resolvingSymlinksInPath`, which strips `/private`); log `install deferred: <path> is running`.
    2-6. Clone with `runner.run(/bin/cp, ["-c", "-R", src, new])`, verify with `runner.run(/usr/bin/codesign,
       ["--verify", "--strict", new])` (both through `runner`), swap with `renamex_np(new, wineApp, UInt32(RENAME_SWAP))`
       (plain `rename` on a first install), delete the old copy and the marker, `writeToolFiles`, remove
       `rosettaEraEntries` (and `proton` after R0b PASS).
  - `RuntimeInstaller.writeToolFiles(layout:launcherBinary:steamExe: URL? = nil)`; manifest commandline
    `/bin/macneutron launch %verb%` after R0b PASS (else `/proton %verb%` and the stub stay).
  - CLI: `install --tool-dir <dir> --wine-app <path> [--steam-exe <path>] [--force]` (`--tool-dir` and `--wine-app`
    required; usage + exit 2 otherwise; never `ToolLayout.defaultRoot`), with `static func installExitCode(_:
    RuntimeInstallOutcome) -> Int32` and `static func installMessage(_: RuntimeInstallOutcome, label: String) -> String`;
    `passthrough <verb> <command> [args…]` (after R0b PASS) with `static func passthroughTarget(_ path: String) -> URL`,
    `static let passthroughArchitectures: [(cpu_type_t, cpu_subtype_t)]` = arm64e, arm64, x86_64, and `static func
    spawn(_ executable: URL, _ arguments: [String], environment: [String: String], replacingThisProcess: Bool,
    standardOutput: URL? = nil) throws -> pid_t` (`posix_spawnattr_setarchpref_np`; `POSIX_SPAWN_SETEXEC` when
    replacing; `posix_spawn_file_actions_addopen` for fd 1 when `standardOutput` is set). No test-only environment
    variables in the CLI.
  - `SteamPlayMode.installNativeTool()` after R0b PASS: manifest `/bin/macneutron passthrough %verb%`, copies
    `<runtime tool>/bin/macneutron` to `macneutron-native/bin/macneutron`, deletes a stale `passthrough.sh`.

- [ ] **Step 1: Read R0b's verdict.** FAIL → skip every "after R0b PASS" item; say so in the commit message.
- [ ] **Step 2: Failing tests.** Fake-source tests use `FakeRunner { call in if call.tool == "cp" { try?
  FileManager.default.copyItem(atPath: call.arguments[2], toPath: call.arguments[3]) }; return call.tool == "codesign" ?
  codesignStatus : 0 }` plus the identity and process seams:
  `equalIdentitySkipsTheCopyButWritesToolFiles`, `differentIdentityReplacesTheRuntime`,
  `forceReinstallsOverAnEqualIdentity`, `damagedMarkerReinstallsAndIsCleared`, `aRunningRuntimeProcessDefers` (outcome
  `.deferred`, nothing moved, the log line), `deferralMatchesTheKernelsRealPath` (layout from `makeTempDir()`;
  `runningExecutables` returns the `realpath` of `layout.wine`), `aRunningRosettaProcessDefersTheInstall`
  (`Libraries/` intact), `aDeferredInstallLeavesTheOldRuntimeWorking`, `leftoversFromAnInterruptedInstallAreCleaned`,
  `aBadSignatureLeavesTheOldRuntime`, `rosettaEraEntriesAreRemoved`, `installWorksUnderASpacedNonASCIIPath`
  (`"Application Support/é"`), `steamExeOptionIsUsedWhenGiven`, `manifestPointsAtTheCLI` (after PASS). Real-file test:
  `firstInstallClonesVerifiesAndSwapsIn` (`makeSignedWineApp` source, `SystemProcessRunner`). CLI:
  `installRequiresToolDir` (exit 2, nothing written), `installRequiresWineApp`, `installExitCodes` (0, 0, 3),
  `installMessages`, `unknownCommandPrintsUsage` (lists `install` and `passthrough`). Passthrough:
  `appBundleResolvesToItsExecutable` (`makeTempDir()/"Gamé Folder"/"My Game.app"`), `appWithoutPlistFallsBackToItsName`,
  `plainPathIsKept`, `preferenceIsArm64eArm64ThenX86`, `spawnRunsTheTargetAndReturnsItsPid` (spawn `/usr/bin/arch` with
  `standardOutput` a temp file, `waitpid`, file = `arm64\n`). Steam Play: `nativeToolRunsTheCLIPassthrough`,
  `staleScriptIsRemoved`; after PASS delete `passthroughRunsTheMacGameItself` and `passthroughLaunchesAppBundles`;
  `FakeSteam.makeFakeSteam` writes a fake `macneutron/bin/macneutron`.
- [ ] **Step 3: Run** `make test`. Expected: compile failures.
- [ ] **Step 4: Implement** per Interfaces.
- [ ] **Step 5: Run** `make test`. Expected: PASS.
- [ ] **Step 6: Hand checks:** `swift build -c release`, then
  `.build/release/macneutron install --tool-dir "$TMPDIR/l6 tool" --wine-app build/wine-arm64/wine.app --steam-exe
  build/bridge/arm64/steam.exe` → `installed dev (<12 hex>)`, exit 0; again → `unchanged …`. After PASS:
  `.build/release/macneutron passthrough waitforexitandrun /usr/bin/arch` prints `arm64`.
- [ ] **Step 7: Commit.**

### Task 8: The app — background install, setup, repair, macOS 27

**Files:**
- Modify: `Sources/MacNeutronApp/{AppModel,SetupView,SettingsView,MenuContent}.swift`, `Package.swift`, `App/Info.plist`
- Test: `Tests/MacNeutronCoreTests/AppModelTests.swift`
- Details: `install §B.3, §C.4-C.6, C.13`

**Interfaces:**
- Consumes: Task 7 `RuntimeInstaller.install`, `RuntimeInstallOutcome`.
- Produces: `AppModel(…, wineAppSource: URL? = AppModel.bundledWineApp, launcherBinary: URL? = nil, installer:
  @escaping @Sendable (URL, ToolLayout, URL, Bool) throws -> RuntimeInstallOutcome = { try
  RuntimeInstaller.install(wineApp: $0, layout: $1, launcherBinary: $2, force: $3) }, identity: @escaping @Sendable
  (URL) -> String? = CodeIdentity.of)` (`launcherBinary` nil → `helper`); `static var bundledWineApp: URL?`
  (`Bundle.main.bundleURL/Contents/Helpers/wine.app` when present); `private(set) var runtime: InstalledRuntime?`
  (`struct InstalledRuntime: Equatable, Sendable { let version: String; let identity: String }`, read from the layout
  with the injected identity); `private(set) var runtimeNotice: String?`; `private(set) var installTask: Task<Void,
  Never>?` (init's install); `func installRuntime(force: Bool = false) async`; `func pollRuntime() async` (called each
  poll tick: retries while deferred, reinstalls when `runtimeDamagedMarker` exists); `setupComplete == (runtime != nil
  && mode.isWanted)`.

- [ ] **Step 1: Failing tests** (scripted `installer`, fixed `identity`, `wineAppSource` a temp folder):
  `startupInstallsTheBundledRuntime` (`await model.installTask?.value`; `runtime` set, notice cleared),
  `noBundledRuntimeInstallsNothing`, `aDeferredInstallIsRetriedByThePoll` (installer `.deferred("/x")` then
  `.installed`; call `pollRuntime()`; `busy` never set), `repairForcesAReinstall` (installer sees `force == true`),
  `damagedMarkerTriggersAReinstall`, `setupCompletesWithRuntimeAndSteamPlay`, `installRefreshesTheNativeTool`.
- [ ] **Step 2: Run** `make test`. Expected: FAIL.
- [ ] **Step 3: Implement:** the install runs in a detached task guarded by a private `installing` flag, never through
  `run()`/`busy`; notices `Installing the runtime…`, `The runtime updates after the game exits.`, or the error; Setup
  steps "Steam" (done: `steamInstalled`), "Runtime" (done: `runtime != nil`; detail = notice or `Runtime <label>
  installed`), "Steam Play" (disabled until both); Settings "Repair runtime" → `installRuntime(force: true)`, disabled
  while installing; menu `Runtime <label>` or `Runtime not installed`. `Package.swift` `.macOS("27.0")`;
  `App/Info.plist` `LSMinimumSystemVersion` `27.0`.
- [ ] **Step 4: Run** `make test` and `swift build -c release`. Expected: PASS; `lipo -archs .build/release/macneutron
  .build/release/MacNeutronApp` → `arm64` each; `vtool -show-build .build/release/macneutron` shows `minos 27.0`.
- [ ] **Step 5: Commit.**

### Task 9: Makefile, smoke test (L5) and the install gate (L6)

**Files:**
- Modify: `Makefile`, `Tests/Smoke/smoke.sh`, `dxmt/tests/shaders/compile.sh`, `dxmt/tests/build_test.sh`,
  `dxmt/published.sh` (comment)
- Create: an i386 build of `Tests/Smoke/exitcode.c` (`i686-w64-mingw32-clang`, at test time)
- Delete: `dxmt/build.sh`, `dxmt/tests/run.sh`
- Details: `checks §6, §7, §8, §9`, `build §13 (§8.2)`, `install §B.4`. `dxmt/pins` stays as it is (a DXMT series
  input: any edit forces a DXMT rebuild).

**Interfaces:**
- Consumes: Task 7's `install` verb, Task 6c's messages, Task 1's `build/release/r0/wine.app`, Task 2's verdict.
- Produces: `make app` (dev `build/MacNeutron.app` with `Contents/Helpers/wine.app` cloned from
  `build/wine-arm64/wine.app` and `Contents/Resources/steam.exe` from `build/bridge/arm64/steam.exe`; outer ad-hoc sign
  without `--deep`); `smoke.sh` reading `MACNEUTRON_ARM64_APP` (default `build/wine-arm64/wine.app`).

- [ ] **Step 1: Makefile:**
  - `.PHONY` drops `dxmt`, adds `release`; `dxmt` target deleted; `dxil-corpus: wine-arm64` using
    `build/wine-arm64/dxil-translate`.
  - `bridge`: no x64 `steam.exe`/`helper.exe` (keeps `steamprobe.exe` and the arm64 pair). `presenter`:
    `present_loop.exe` only.
  - `app: build bridge wine-arm64`; its recipe starts with `@! ps -axo comm= | LC_ALL=C /usr/bin/grep -qF
    "$(abspath $(APP))/" || { echo 'app: quit the MacNeutron running from $(APP) first' >&2; exit 1; }`; clone
    `wine.app` into `Contents/Helpers/` with `cp -c -R`; `steam.exe` from `build/bridge/arm64/`; no Frameworks,
    `Resources/DXMT` or `published.sh` lines; outer ad-hoc sign without `--deep`.
  - `smoke: build bridge wine-arm64`; `bridge-check: build bridge wine-arm64`; `presenter-check: build wine-arm64
    presenter`; `wine-arm64-check` drops `dxmt`.
  - `dxmt-check: build wine-arm64 dxmt-tests dxmt-tests-arm64ec presenter`, recipe: `sh dxmt/tests/build_test.sh`,
    `sh dxmt/check.sh`, `MACNEUTRON_ARM64_TESTS=build/dxmt-tests-arm64ec MACNEUTRON_ARM64_LOOP=build/dxmt-tests-arm64ec/
    present_loop.exe DXMT_CHECK_WORK="$$TMPDIR/macneutron dxmt arm64ec" sh dxmt/check.sh`.
  - `release: build bridge wine-arm64` → `sh release/release.sh "$(VERSION)"`.
  - Every target comment updated. `build_test.sh`: drop the `dxmt/build.sh` rows, keep `published.sh`, Clang and LLVM;
    "make uses it" now wants `1`.
- [ ] **Step 2: smoke.sh (L5, L6).** `WINEAPP="${MACNEUTRON_ARM64_APP:-$ROOT/build/wine-arm64/wine.app}"`; first line
  `info wine.app: $WINEAPP (<CFBundleShortVersionString>)`; tool folder from `install --tool-dir "$TOOL" --wine-app
  "$WINEAPP" --steam-exe build/bridge/arm64/steam.exe`; entry point `$TOOL/bin/macneutron launch waitforexitandrun` (or
  `$TOOL/proton` after an R0b FAIL); compilers from `dxmt/toolchain.sh`. Rows print `PASS|FAIL <name>`:
  - `dxmt exitcode`, `wined3d exitcode` → exit 2 with `"a b" c`; `dxmt d3d11probe`, `wined3d d3d11probe` → exit 0 (a
    device and a swap chain; no draw);
  - `arm64ec exitcode` → exit 2;
  - `32-bit game refused` → non-zero, and the lines of `~/Library/Logs/MacNeutron/launcher.log` added since the launch
    (`before=$(wc -l < …)`) contain the 32-bit text once;
  - `rosetta-era prefix renamed` (pre-create `compatdata/rosetta/pfx/drive_c/save.txt` and `version` =
    `runtime-v4.7.3`) → `pfx.rosetta/drive_c/save.txt` intact, `version` starts `wine.app `;
  - L6 `install twice is a no-op` (`unchanged`); `install defers while the server runs` (`trap '… wineserver -k' EXIT`,
    then `"$TOOL/wine.app/Contents/Resources/bin/wineserver" -p30` in a prefix → install exit 3 `deferred: …wineserver
    is running`; `wineserver -k`); `install defers while the loader runs` (`"$TOOL/wine.app/Contents/MacOS/wine"
    cmd /c pause` fed from a held FIFO in the background → exit 3 naming `…/Contents/MacOS/wine`; close the FIFO,
    `wineserver -k`); `--force reinstalls`; `damaged marker reinstalls` (marker gone after); `leftovers are cleaned`
    (`mkdir "$TOOL/wine.app.new"` → gone);
  - L6 `notarized copy installs and stays accepted`: when `build/release/r0/wine.app` exists, install it into
    `"$WORK/notarized tool"`, then `xcrun stapler validate` exits 0 and `spctl -a -vvv -t exec` stderr has `accepted`;
    otherwise `SKIP`.
- [ ] **Step 3: compile.sh:** source `dxmt/pins` and `dxmt/lib.sh`; `REF=${MACNEUTRON_REFERENCE:-…}`; `[ -f
  "$REF/../FROZEN" ] || die "no frozen Rosetta reference at $REF (run tools/freeze-rosetta-reference.sh)"`; DXC from
  `build/dxmt-src/dxc.zip` (already cached; `fetch` it with the existing pin only if missing), unzipped only when
  `build/dxmt-src/dxc/bin/x64/dxc.exe` is missing, with `dxmt/build.sh`'s exit-1 tolerance moved over; run under
  `"$REF/Libraries/Wine/bin/wine"`. Then delete `dxmt/build.sh` and `dxmt/tests/run.sh`.
- [ ] **Step 4: Run** `make smoke` (every row PASS; the notarized row PASS, not SKIP, when Task 1 ran),
  `sh dxmt/tests/build_test.sh` (PASS), `sh dxmt/tests/shaders/compile.sh` (finishes; leave any `.dxil` diff
  uncommitted and report it), `make app` and `codesign --verify --strict build/MacNeutron.app/Contents/Helpers/wine.app`
  (PASS). **Do not open `build/MacNeutron.app`.**
- [ ] **Step 5: Commit.**

### Task 10: `dxmt/check.sh` and `wine-arm64/check.sh` on the new launcher (L1, L2, G4)

**Files:**
- Modify: `dxmt/check.sh`, `wine-arm64/check.sh`
- Details: `checks §1.3` (items 1-14), `checks §2.3` (items 1-4), flags F1, F6, F13-F15

**Interfaces:**
- Consumes: Task 3's reference, Task 7's `install` verb, Task 9's `dxmt-check` recipe.

- [ ] **Step 1: dxmt/check.sh** per `checks §1.3`: arm64 only (keep printing `info arm64 mode: <wine.app>`, which
  `wine-arm64/check.sh` greps); missing reference → `die` unless `"$REF/../FROZEN"` exists; `$WORK/ref` = clone of the
  frozen tool (its own CLI, never overwritten); `$WORK/ours` = `install --tool-dir … --wine-app
  "${MACNEUTRON_ARM64_APP:-build/wine-arm64/wine.app}"` (exit 0 required); `run()` picks the tool from the backend
  (`d3dmetal` → ref, x64 programs, `compat/ref*`; `dxmt` → ours, `compat/ours*`); prefixes `ours ours-A…E` and
  `ref ref-A…E` by `getcompatpath` in parallel; `stop_lanes` stops each family with its own `wineserver` and
  `WINEMSYNC=1`; section 1 keeps only "the D3D11 game ran our d3d11.dll"; section 5 feeds `dxmt/pins`; L2 and
  section 10 (L1) unguarded, reading `$WORK/ours/wine.app/Contents/Resources/DXMT/version`; section 4 renamed "the
  frozen D3DMetal reference still runs".
- [ ] **Step 2: wine-arm64/check.sh** per `checks §2.3`: G4 reads `REF`, no CLI copy; `runtime_pids` covers
  `dxmt-*/ref` and `dxmt-*/ours`; `dxmt_lane_cmd` drops `MACNEUTRON_ARM64_PREFIX`; headers updated.
- [ ] **Step 3: Run** `make dxmt-check`. Expected: `dxmt-check: all passed` twice (x64 and ARM64EC), including `the
  launcher records into the game's compat folder`, `a changed build replays d3d12_cache's recording before the game`,
  `then the game only hits`, `the unsupported op is named in the log`.
- [ ] **Step 4: Run** `make build bridge wine-arm64 wine-arm64-tests dxmt-tests dxmt-tests-arm64ec presenter && sh
  wine-arm64/check.sh dxmt-x64 g4-bench`. Expected: both steps PASS, `PASS orphans`. (The full check runs in Task 14.)
- [ ] **Step 5: Commit.**

### Task 11: Steam bridge and presenter through the launcher (L3, L4)

**Files:**
- Modify: `bridge/check.sh`, `bridge/probe.sh`, `presenter/check.sh`, `wine-arm64/check.sh` (`steam_bridge_cmd`,
  `cleanup`, `runtime_pids`)
- Details: `checks §3, §4, §5`, `checks §2.3` item 5, flags F3, F8, F9, F11

- [ ] **Step 1: bridge/check.sh:** no Rosetta branch; standalone mode assembles `$WORK/tool` (`install … --steam-exe
  build/bridge/arm64/steam.exe`) and a prefix by `getcompatpath`; a launcher pass (`MACNEUTRON_TOOL_DIR`) runs `exit code
  passes through`, `arguments arrive unchanged`, `registry names a live Steam`, `launcher-style child still sees Steam`,
  `pid cleared afterwards` (`runinprefix`), `missing program exits 1`, `launchers may start children outside the job`
  through `launch waitforexitandrun`; the second-steam.exe row stays direct.
- [ ] **Step 2: bridge/probe.sh:** no Rosetta branch (no `steamclient.dll`), `FAULT=fault` always; launcher mode
  (`MACNEUTRON_TOOL_DIR`) runs `steamprobe.exe` through `launch waitforexitandrun` with `SteamAppId=480`; redaction
  unchanged.
- [ ] **Step 3: wine-arm64/check.sh steam-bridge step:** after the direct runs, `"$ROOT/.build/release/macneutron"
  install --tool-dir "$WORK/steam-bridge tool" --wine-app "$TOOL" --steam-exe "$ROOT/build/bridge/arm64/steam.exe" ||
  return 1`, then both scripts with `MACNEUTRON_TOOL_DIR`; expect `init: ok`, `steamid ok`, `auth ticket: callback,
  result 1`, ticket bytes > 0. Add that folder's `wineserver` to `cleanup` and `runtime_pids`.
- [ ] **Step 4: presenter/check.sh (L4):** assembled tool folder, `MACNEUTRON_GRAPHICS=dxmt`, no
  `DYLD_INSERT_LIBRARIES`; inject=1 → no `MACNEUTRON_NO_METALFX`; inject=0 → `MACNEUTRON_NO_METALFX=1`; keep `checks
  §5`'s rows except "prefix setup works with the library loaded"; add `MACNEUTRON_NO_METALFX=1 loads no presenter` (0
  `macneutron-present` lines on `base`).
- [ ] **Step 5: Run** `make bridge-check`, `make presenter-check`, `sh wine-arm64/check.sh steam-bridge`. Expected: all
  PASS. Privacy: `LC_ALL=C /usr/bin/grep -rE '7656119[0-9]{10}'` over the work folders and logs finds nothing, and the
  active account ID (read as `SteamLocation.activeAccountID` does, never printed) appears in none of them; print only
  `PASS no steam ids` / `FAIL no steam ids`.
- [ ] **Step 6: Commit.**

### Task 12: `release/release.sh` (R1-R5) and its rehearsal

**Files:**
- Modify: `wine-arm64/bundle.sh` (`--release --version <V> --out <dir>`; strip; deletions), `wine-arm64/build.sh`
  (SOURCE through `write_source`), `wine-arm64/lib.sh` (`write_source <out> <mac>`), `wine-arm64/tests/licences_test.sh`
  (`--app <MacNeutron.app>`), `release/lib.sh`, `dxmt/published.sh` (comment)
- Create: `release/release.sh`, `release/source-archive.sh`, `release/verify-sources.sh`
- Details: `build §13 (§5.2, §6.3)`, `build §14` 1-3 and 11, `release §A-C`, spec §6.3 and §14

**Interfaces:**
- Consumes: Task 1 `notarize_and_staple`; Task 4 licences; Task 9 smoke; Task 11 probe launcher mode.
- Produces: `release.sh <V>` (normal), `release.sh --self-test`, `release.sh --rehearse <V>`; outputs in
  `build/release/<V>/` (`MacNeutron.app`, `wine.app`, `MacNeutron-<V>.zip`, `MacNeutron-<V>-source.tar.gz`,
  `SHA256SUMS`, `SOURCES.txt`); `source-archive.sh <V> <out-dir>`; `verify-sources.sh <archive> <SOURCE>`.

- [ ] **Step 1: R1 first.** Each refusal is its own shell function. `--self-test` runs each on its own input in `T=$(mktemp
  -d)` (`git clone -q "$ROOT" "$T/repo"`, `origin` = a second local bare clone; the unpublished-commit case uses a local
  bare repo as the fork, as `build_test.sh` does; never `build.sh`, real trees or GitHub; deletes `$T`): bad version
  `0.0.1-rc`, existing tag (`v0.0.0` in the clone, VERSION `0.0.0` → `release: v0.0.0 is already a tag`), dirty tree,
  HEAD not in `origin/main`, a README with `import-gptk`, `check_source` on fixture SOURCE files (`WINE_SERIES=dev` →
  `release: SOURCE has WINE_SERIES=dev`; `+dirty` → `release: SOURCE MACNEUTRON_COMMIT is +dirty`; another commit →
  `release: SOURCE MACNEUTRON_COMMIT <c> is not HEAD <h>`), an unpublished DXMT commit. Run it. Expected: FAIL.
- [ ] **Step 2: Refusals.** release.sh checks VERSION first (format, then tag; exit 2 on a bad one, before any fetch or
  build), then reports every one of these before exiting 1: README strings (`Rosetta 2`, `import-gptk`, `doesn't
  redistribute`), clean tree, `git fetch origin` and HEAD in `origin/main`, `build_mode` of each tree (`applied`),
  `dxmt/published.sh build/wine-arm64-src/dxmt "$DXMT_COMMIT"`; and only when all passed, `sh wine-arm64/build.sh 2>&1`
  must print `wine-arm64: up to date`. Run `--self-test`. Expected: PASS.
- [ ] **Step 3: Release bundle (R3).** `bundle.sh --release --version "$V" --out "build/release/$V"`: strip between the
  layout and the signing (`"$(sh dxmt/toolchain.sh)/llvm-strip" --strip-debug` on PE files, `strip -S` on Mach-Os;
  delete `.a` files and `winegcc wineg++ winecpp winebuild winedump widl wrc wmc winemaker function_grep.pl`),
  `write_source` with `MACNEUTRON_COMMIT=$(git rev-parse HEAD)`, version keys `$V`, then every existing assertion; record
  `du -sk` before and after. release.sh then runs `check_source` on the bundle's SOURCE and R3:
  `MACNEUTRON_ARM64_APP="build/release/$V/wine.app" sh Tests/Smoke/smoke.sh` (expects `info wine.app:
  …/build/release/<V>/wine.app (<V>)`), then assembles `build/release/$V/r3 tool` (`install … --steam-exe …`) and runs
  `PROBE_REDACT=1 MACNEUTRON_TOOL_DIR=… sh bridge/probe.sh <steam_api64.dll>` (`init: ok`, `steamid ok`, ticket > 0)
  and `present_loop.exe 1280 720 0 0 120 0` through it with `MACNEUTRON_GRAPHICS=dxmt` (an `avg frame` line).
- [ ] **Step 4: Notarization and the app (R2, R4, L6).** `notarize_and_staple` the release `wine.app`; L6's notarized
  row: install it into `build/release/$V/l6 tool`, `stapler validate` and `spctl -a -vvv -t exec` (stderr `accepted`).
  Build `build/release/$V/MacNeutron.app` (never `$(APP)`): `.build/release/MacNeutronApp` → `Contents/MacOS/MacNeutron`,
  CLI → `Contents/Helpers/macneutron`, `ditto` the stapled `wine.app` → `Contents/Helpers/wine.app`, `steam.exe` →
  `Contents/Resources/`, `Contents/Resources/licenses/` (`LICENSE`, the llvm-mingw texts, a README pointing at
  `Contents/Helpers/wine.app/Contents/Resources/licenses/`); Info.plist version `$V`, minimum `27.0`; `lipo -archs` =
  `arm64` for both Swift binaries; sign the CLI then the app with `--options runtime --timestamp`, never `--deep`,
  never re-signing `wine.app`; `licences_test.sh --app`; `notarize_and_staple MacNeutron.app`; `spctl -a -vvv -t exec`
  stderr `accepted`; `ditto -c -k --keepParent` → `MacNeutron-<V>.zip`.
- [ ] **Step 5: Source archive (R5).** `release/source-archive.sh <V> <out>` (called by release.sh): nested tars per spec
  §7.2 and §14 — the repo (`git archive --prefix=MacNeutron/ HEAD`); Wine, FEX with its six SOURCE submodules (each
  archived from the submodule), DXMT with its two submodules, by `git archive` of the applied trees; lsteamclient as a
  `tar` of its clean sparse worktree; the four tarballs — plus `SOURCES.txt` (tree, pin, applied commit, patch count).
  `verify-sources.sh` checks: each tar's `git get-tar-commit-id` = the tree's `.applied`; in the build tree
  `git rev-parse <applied>~<patch count>` = `*_COMMIT`; each `*_SERIES` recomputed from the archived pins and patches;
  submodule commits; tarball SHA-256s; `LLVM_TAG` and `LLVM_MINGW_SHA256` cited only. Prints `PASS sources`.
- [ ] **Step 6: Finish:** `SHA256SUMS` for the zip and the archive; print `git tag v$V <MACNEUTRON_COMMIT>` and `gh
  release create v$V --target <MACNEUTRON_COMMIT> …` (commit from `SOURCES.txt`); never run them.
- [ ] **Step 7: Rehearsal mode.** `--rehearse <V>` skips the clean-tree and `origin/main` refusals and both
  `notarize_and_staple` calls (and the L6 notarized row), writes `build/release/rehearse-<V>/` with a `REHEARSAL` file, and
  prints no tag commands.
- [ ] **Step 8: Commit**, then verify: `make release VERSION=0.0.1-rc` exits 2 with only the version message;
  `sh release/release.sh --self-test` PASS; `sh release/release.sh --rehearse 0.0.0` gives every stage except
  notarization PASS (R3 rows, `licences_test.sh --app`, `PASS sources`); record the sizes in the acceptance doc and
  commit that.

### Task 13: Documentation and status lines

**Files:**
- Modify: `README.md`, `wine-arm64/README.md`, `docs/superpowers/specs/2026-10-02-macneutron-native-arm64-design.md`,
  every spec in `release §F`, the ten Rosetta-era `docs/testing/acceptance-*.md`, the three `acceptance-arm64-*.md`
- Details: `release §E, §F`, spec §7.3, §13, §14

- [ ] **Step 1: README.md** per `release §E` (download, move to Applications, requirements, setup, options, licences,
  the `install` verb, 32-bit and Direct3D 9 not supported in 0.1, `runtime-v*.tar.gz` can be deleted, building needs the
  Developer ID setup, `make release`, a Licence section). Never `Rosetta 2`, `import-gptk` or `doesn't redistribute`.
- [ ] **Step 2: wine-arm64/README.md** lines in `release §E`; "Next Wine rebase" mentions DXMT patch 0002.
- [ ] **Step 3: Native spec** (spec §13, §14): lines 22, 39, 47, rows 5-9, §11's notarization line.
- [ ] **Step 4: Status lines:** "Superseded in part by `2026-10-04-macneutron-arm64-release-design.md` (the Rosetta
  runtime, GPTK, DXVK and the x86_64 DXMT build were removed in 0.1.0)." on every spec in `release §F` dated before
  2026-10-04, and on `2026-10-04-macneutron-ship-base-wine-design.md` (its §1 lsteamclient decision is superseded; say so
  in the commit message); "Historical: the Rosetta runtime was removed in 0.1.0; reproduce with the frozen reference
  (`tools/freeze-rosetta-reference.sh`)." under each Rosetta-era acceptance title; "Rosetta baselines now come from the
  frozen reference (`MACNEUTRON_REFERENCE`)." on the three arm64 records.
- [ ] **Step 5: Check:** `LC_ALL=C /usr/bin/grep -nF -e 'Rosetta 2' -e 'import-gptk' -e "doesn't redistribute"
  README.md wine-arm64/README.md` prints nothing.
- [ ] **Step 6: Commit.**

### Task 14: Acceptance and the release candidate

**Needs the maintainer:** the push, the notary submission's account, R6 and S.

**Files:**
- Modify: `docs/testing/acceptance-arm64-release.md`, the spec's Status line

- [ ] **Step 1: Full runs**, recorded: `make test`, `make smoke` (the notarized row PASS), `make bridge-check`, `make
  presenter-check`, `make wine-arm64-check` (once; it includes both DXMT lanes and G4), `release.sh --self-test`.
- [ ] **Step 1b: Commit** the acceptance doc.
- [ ] **Step 2: Push gate:** ask the maintainer to approve `git push origin main`; push only on a yes.
- [ ] **Step 3: `make release VERSION=0.1.0`** with the signing and notary variables. Record both submission ids, R3's
  rows, L6's notarized row, R4, R2's `spctl` verdict, `PASS sources`, sizes (wine.app before/after stripping, zip,
  archive), `SHA256SUMS`.
- [ ] **Step 4: Maintainer gates.** Copy the zip to `/Users/Shared/MacNeutron-0.1.0.zip`. In a fresh macOS account the
  maintainer runs `xattr -w com.apple.quarantine "0081;$(printf %x $(date +%s));Safari;$(uuidgen)"
  /Users/Shared/MacNeutron-0.1.0.zip`, unzips with Archive Utility, moves the app to Applications, opens it, completes
  setup, turns on Steam Play mode, launches Spacewar (480) from Steam (R6), checks `spctl -a -vvv -t exec` on the
  installed `wine.app`, and reads Activity Monitor's Kind column (`Apple`, not `Intel`) for MacNeutron, `wine`,
  `wineserver` and the game; then SMITE 2 reaches gameplay in that account (S; installed there, or in a Steam library
  folder both accounts share). Record their notes verbatim.
- [ ] **Step 5: Spec status** "Implemented <date>: `docs/testing/acceptance-arm64-release.md`" only if R6 and S both
  pass; otherwise record the notes, leave the Status line, and stop for the maintainer's decision.
- [ ] **Step 6: Commit**, and give the maintainer the printed `git tag` / `gh release create` commands. Publishing and
  installing the release over their Rosetta setup are theirs.
