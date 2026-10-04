# Native arm64 sub-project 5: the arm64-only release — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** a notarized MacNeutron 0.1.0 that runs 64-bit Windows Steam games only on the native arm64 `wine.app`,
with the Rosetta runtime deleted from the launcher, the app and the build.

**Architecture:** the launcher keeps its shape and swaps its one runtime in place: `ToolLayout` reads every path from
the tool folder's `wine.app`, which the app installs from `MacNeutron.app/Contents/Helpers/wine.app`. `check.sh`'s
prefix recipe moves into `PrefixManager`. A new `release/release.sh` refuses development inputs, bundles a stripped
`wine.app`, notarizes it and the app, and builds the source archive. Dev checks run the new launcher through assembled
tool folders and keep D3DMetal as a reference through a frozen copy of today's Rosetta tool.

**Tech Stack:** Swift 6 (Swift Testing), Security.framework, Darwin (`proc_pidpath`, `renamex_np`,
`posix_spawnattr_setarchpref_np`), POSIX shell, Wine 11.19 + FEX + DXMT (`wine-arm64/`), `codesign`, `notarytool`,
`stapler`, `syspolicy_check`, `spctl`, llvm-mingw.

**Spec:** `docs/superpowers/specs/2026-10-04-macneutron-arm64-release-design.md` (§14 amends §§1-13). Evidence and
exact current line numbers: `docs/research/2026-10-04-arm64-release/` — the digests `digest-core.md`,
`digest-install-app.md`, `digest-wine-build.md`, `digest-checks.md`, `digest-release-docs.md` (cited below as
`core §B…`, `install §B…`, `build §13`, `checks §1.3`, `release §B`). Line numbers are at `92d8f83` and drift as tasks
land: re-find by content.

## Global Constraints

- macOS 27 or later, Apple Silicon only. `Package.swift` `.macOS("27.0")`; `App/Info.plist` and `wine.app`
  `LSMinimumSystemVersion` `27.0`; every Mach-O in `wine.app` has minos `27.0` (bundle.sh asserts it).
- **Never modify the installed tool folder** `~/Library/Application Support/MacNeutron/compatibilitytools.d/macneutron`
  (or `macneutron-native`). Every launcher run in a test or check uses a tool folder assembled with
  `macneutron install --tool-dir <dir> …` or a clone. Installing the release there is the maintainer's last step.
- Signing env for anything that builds `wine.app`: `MACNEUTRON_SIGN_IDENTITY="Developer ID Application: Chad Cormier
  Roussel (49QMZXLR8S)"`, `MACNEUTRON_PROVISIONING_PROFILE` (today `$HOME/Downloads/Mac_Neutron.provisionprofile`).
  Never copy the profile into the repo. Notarization reads `MACNEUTRON_NOTARY_PROFILE` (default `macneutron`).
- The Wine, FEX, DXMT and lsteamclient trees under `build/wine-arm64-src/`: changes are **new commits** on branch
  `macneutron`, exported with `make wine-arm64-export`; never amend, rebase or cherry-pick. After an export, check
  `git diff --stat wine-arm64/patches` touches only the intended files.
- Stamp format, exactly: `wine.app <identity> msync=<0|1>`; while preparing: `wine.app preparing`. Damage marker:
  `<tool folder>/runtime-damaged`. Identity: the loader's CDHash, 40 lowercase hex digits (`kSecCodeInfoUnique`).
- Player-facing messages, verbatim (spec §10):
  - `MacNeutron needs macOS 27 or later on an Apple Silicon Mac.`
  - `MacNeutron's runtime is missing or damaged. Open MacNeutron to repair it.`
  - `This game is 32-bit. MacNeutron 0.1 runs 64-bit games only; 32-bit support is planned.`
  - `This game is built for <machine>, which MacNeutron can't run.`
  - `skipped 32-bit installer <name>` (launcher.log only)
- DXMT overrides: `dxgi,d3d10core,d3d11,d3d12=n,b;d3d9,d3d10=b`; wined3d: `dxgi,d3d9,d3d10,d3d10core,d3d11,d3d12=b`;
  wineboot adds `mscoree,mshtml=`.
- Interactive `grep` here is a ugrep wrapper that can silently return 0: scripts and checks use `LC_ALL=C /usr/bin/grep`.
- Never print or commit SteamIDs, account IDs or persona names (`bridge/probe.sh`'s redaction stays on).
- Stop Wine with `wineserver -k` (with the run's `WINEMSYNC`) plus `lsof -t` on the executables; never `pkill -f`.
- No new downloads. Submissions to Apple's notary service happen only in Task 1 (R0) and Task 14 (the release).
- Commits end with the implementer's own `Co-Authored-By:` trailer. Nothing is pushed.

## Review Focus

1. **Paths with spaces and non-ASCII** (`Application Support`, a user folder `é`): install, preflight's PE read and the
   passthrough must work on them → Task 7 `installWorksUnderASpacedNonASCIIPath`, Task 5 `machineReadsAPathWithSpaces`.
2. **A Rosetta-era prefix holding saves** must never lose data, even when `pfx.rosetta` is taken → Task 6
   `renameNumbersPastTakenNamesAndKeepsTheSaves`.
3. **A multi-GB game exe**: the PE check must read only the header → Task 5 `machineReadsOnlyTheHeaderOfAHugeFile`
   (sparse 4 GB file).
4. **Settings changed between launches** (msync toggled while a server lives; graphics dxmt → wined3d → dxmt) → Task 6
   `msyncOnlyChangeKillsTheServerUnderTheOldMode`, `switchingBackToDXMTFindsItsDLLs`.
5. **An install interrupted mid-copy, then a launch** → Task 7 `leftoversFromAnInterruptedInstallAreCleaned` and
   `aDeferredInstallLeavesTheOldRuntimeWorking`.

---

### Task 1: R0 — notarize `wine.app` and launch its quarantined copy

**Needs the maintainer first:** `xcrun notarytool store-credentials macneutron` (only they can; it contacts Apple).

**Files:**
- Create: `release/lib.sh` (shell functions shared by Task 12), `release/r0.sh` (the trial)
- Create: `docs/testing/acceptance-arm64-release.md` (R0 section)

**Interfaces:**
- Produces (`release/lib.sh`, sourced, `set -eu`):
  - `notarize_and_staple <bundle.app> <work-dir>`: `syspolicy_check notary-submission <bundle>`; `ditto -c -k
    --keepParent` into `<work-dir>/<name>.zip`; `xcrun notarytool submit … -p "${MACNEUTRON_NOTARY_PROFILE:-macneutron}"
    --wait --output-format json`; require `.status == "Accepted"` (read with `/usr/bin/jq`), otherwise run
    `notarytool log <id>` and fail; `stapler staple`, `stapler validate`, `syspolicy_check distribution`. Prints the
    submission id. Exit non-zero on any failure.
  - `die <msg>` (prefix `release: `).

- [ ] **Step 1: Write `release/lib.sh` with `notarize_and_staple` and `die`.**
- [ ] **Step 2: Write `release/r0.sh`:** copy `build/wine-arm64/wine.app` (cp -c -R) into `build/release/r0/`,
  `notarize_and_staple` it, record `codesign -dvvv` CDHash before and after stapling (they must match: §3.9 compares
  identities of stapled and installed copies), then:
  `xattr -r -w com.apple.quarantine "0081;$(printf %x $(date +%s));Safari;" <copy>`, clone with `cp -c -R` to
  `build/release/r0/Application Support/wine.app` (a space), boot a fresh prefix and run
  `build/wine-arm64-tests/arm64-hello.exe` with the clone's loader **through launchd** (`launchctl submit -l
  net.authspot.macneutron.r0 -- /bin/sh -c '…'`, output to a file, poll for it, then `launchctl remove`), once online and
  once with the network off (the maintainer turns Wi-Fi off when the script asks). Pass = the hello line both times.
- [ ] **Step 3: Run it.** Expected: `Accepted`, `stapler validate` OK, `syspolicy_check distribution` clean, hello line
  online and offline, CDHash unchanged by stapling.
- [ ] **Step 4: Record** in `docs/testing/acceptance-arm64-release.md` (create it: title, spec link, an "R0" section with
  the submission id, the four results, the CDHash line). **If anything fails, stop the plan and ask the maintainer.**
- [ ] **Step 5: Commit** `release/lib.sh release/r0.sh docs/testing/acceptance-arm64-release.md`.

### Task 2: R0b — can Steam launch a thin arm64 tool?

**Needs the maintainer:** Steam restarts and choosing a tool in Steam's UI.

**Files:**
- Create: `tools/r0b-probe.c` (thin arm64), `tools/r0b.sh` (`setup` / `results` / `remove`)
- Modify: `docs/testing/acceptance-arm64-release.md` (R0b section)

**Interfaces:**
- Produces: R0b's verdict line in the acceptance doc, `R0b: PASS` or `R0b: FAIL`, which Task 7 reads.

- [ ] **Step 1: Write `tools/r0b-probe.c`:** appends one line to `$TMPDIR/r0b/<argv0 basename>.log`:
  `arch=<uname machine> translated=<sysctl.proc_translated> argv=<argv joined by |>`, then exits 0. Build with
  `clang -arch arm64 -mmacosx-version-min=27.0`; check `lipo -archs` is `arm64`.
- [ ] **Step 2: Write `tools/r0b.sh setup`:** two tool folders under `build/r0b/`, `r0b-probe` (manifest `"commandline"
  "/r0b-probe %verb%"`, `to_oslist linux`) and `r0b-probe-native` (`from_oslist macos`, `to_oslist linux`), the same
  `compatibilitytool.vdf`/`toolmanifest.vdf` shape `RuntimeInstaller`/`SteamPlayMode` write today, each holding the
  probe binary; symlinks to them in Steam's bundle `compatibilitytools.d` (same place `SteamPlayMode.link(_:)` uses).
  `results` prints the two logs; `remove` deletes the links and `build/r0b`. Never touch the `macneutron*` tools.
- [ ] **Step 3: Run with the maintainer:** quit Steam; `tools/r0b.sh setup`; start Steam; the maintainer sets Spacewar
  (480) to `r0b-probe` and a Mac game to `r0b-probe-native` in Properties → Compatibility, presses Play on each, then
  restores the previous tool choices; `tools/r0b.sh results`; quit Steam; `tools/r0b.sh remove`; start Steam.
  PASS = both logs have a line with `arch=arm64 translated=0` and the verb in argv.
- [ ] **Step 4: Record** `R0b: PASS` or `R0b: FAIL` with the two log lines in the acceptance doc. A FAIL doesn't stop the
  plan: Task 7 keeps the shell entry points.
- [ ] **Step 5: Commit** `tools/r0b-probe.c tools/r0b.sh docs/testing/acceptance-arm64-release.md`.

### Task 3: Freeze the Rosetta reference

**Files:**
- Create: `tools/freeze-rosetta-reference.sh`

**Interfaces:**
- Produces: `~/Library/Application Support/MacNeutron Reference/rosetta-tool/` (clone of the installed tool folder) and
  `…/MacNeutron Reference/FROZEN` (lines `runtime=<runtime-version>`, `gptk=<gptk.json version>`, `date=<ISO>`).
  Later tasks read `MACNEUTRON_REFERENCE` (default that `rosetta-tool` path).

- [ ] **Step 1: Write the script:** source = `${MACNEUTRON_TOOL:-$HOME/Library/Application Support/MacNeutron/
  compatibilitytools.d/macneutron}`; refuse (`die`) if `gptk.json` or `runtime-version` or
  `Libraries/Wine/bin/wineserver` is missing, or if the destination exists; `cp -c -R` the folder; write `FROZEN`.
  Read-only on the source.
- [ ] **Step 2: Run it** and check: `"$REF/bin/macneutron"` exists, `cat "$REF/runtime-version"` = `runtime-v4.7.3`,
  `FROZEN` written; a second run refuses with "already exists".
- [ ] **Step 3: Commit** the script.

### Task 4: `wine.app` gains its version, the presenter, patch 0002 and its licence entries

**Files:**
- Modify: `wine-arm64/build.sh` (presenter build block after DXMT's step 7; stamp list; `+dirty` pathspec; SOURCE's
  `DXMT_SUBMODULE_*`), `wine-arm64/bundle.sh` (presenter `put`; `CFBundleShortVersionString`/`CFBundleVersion` = `dev`;
  `licenses/macneutron/LICENSE`), `wine-arm64/licenses/README`, `wine-arm64/licenses/NOTICES.md` (folder list),
  `wine-arm64/tests/licences_test.sh`, `presenter/present.m:1` (comment), `Makefile` (`presenter` builds only
  `present_loop.exe`)
- Create: `LICENSE` (MIT, `Copyright (c) 2026 Chad Cormier Roussel`)
- Create (exported): `wine-arm64/patches/dxmt/0002-winemetal-Load-the-MetalFX-presenter-when-asked.patch`
- Details: `build §13 (§5.1, §5.3, §7.1, §7.2)`, `build §8` (where the constructor goes)

**Interfaces:**
- Produces: `wine.app/Contents/Resources/lib/wine/aarch64-unix/libmacneutron-present.dylib` (install name
  `@rpath/libmacneutron-present.dylib`, arm64, minos 27.0); `winemetal.so` loads it when `MACNEUTRON_PRESENT=1`;
  Info.plist `CFBundleShortVersionString`; SOURCE keys `DXMT_SUBMODULE_nvapi`, `DXMT_SUBMODULE_directx`;
  `licenses/macneutron/LICENSE`.

- [ ] **Step 1: Failing licence checks first.** In `licences_test.sh`: require `licenses/macneutron/LICENSE`, a README
  line containing `macneutron/LICENSE`, the lsteamclient entry containing `maintainer's decision of 2026-10-04`, and
  SOURCE keys `DXMT_SUBMODULE_nvapi DXMT_SUBMODULE_directx`; add a self-test red case that deletes
  `licenses/macneutron/LICENSE`. Run `sh wine-arm64/tests/licences_test.sh build/wine-arm64/wine.app`. Expected: FAIL
  naming the four missing items.
- [ ] **Step 2: DXMT patch 0002.** In `build/wine-arm64-src/dxmt` on `macneutron`, add to
  `src/winemetal/unix/winemetal_unix.c` an `__attribute__((constructor)) static void load_presenter(void)` that, when
  `getenv("MACNEUTRON_PRESENT")` is `"1"`, calls `dlopen("@loader_path/libmacneutron-present.dylib", RTLD_NOW |
  RTLD_LOCAL)` and on failure prints one stderr line `winemetal: can't load the MetalFX presenter: <dlerror()>`. Commit
  (subject `winemetal: Load the MetalFX presenter when asked.`, body explaining the hardened runtime ignores
  `DYLD_INSERT_LIBRARIES`), then `make wine-arm64-export` and check only `patches/dxmt/0002-*` was added.
- [ ] **Step 3: build.sh and bundle.sh changes** as listed in Files (presenter: `/usr/bin/clang -arch arm64
  -mmacosx-version-min=27.0 -fobjc-arc -O2 -dynamiclib -install_name @rpath/libmacneutron-present.dylib` + the five
  frameworks, into `$SRC/presenter/`; stamp adds `presenter/present.m` and `LICENSE`; pathspec adds `presenter LICENSE`).
  Licences README: the lsteamclient entry says it ships by the maintainer's decision of 2026-10-04 under Valve's
  Steamworks SDK licence (`lsteamclient/`); new entry "MacNeutron (`libmacneutron-present.dylib`, the MetalFX
  presenter; the Wine, DXMT and FEX patch files): MIT, `macneutron/LICENSE`".
- [ ] **Step 4: Build and check.** `make wine-arm64` (DXMT rebuilds: its series changed). Expected: build passes every
  bundle.sh assertion; `licences_test.sh` and `--self-test` PASS; `PlistBuddy -c 'Print :CFBundleShortVersionString'`
  = `dev`; `otool -D` on the presenter = `@rpath/libmacneutron-present.dylib`.
- [ ] **Step 5: Presenter smoke.** Run `build/dxmt-tests-arm64ec/present_loop.exe 1280 720 640 360 120 0` in a scratch
  prefix with `MACNEUTRON_PRESENT=1` (DXMT overrides, prefix prepared as `wine-arm64/check.sh` does). Expected: stderr
  has `macneutron-present: MetalFX 640x360 -> 1280x720`; without the variable, no `macneutron-present` line.
- [ ] **Step 6: Commit** (repo files + the exported patch).

### Task 5: Leaf pieces — PE machine, code identity, running processes

**Files:**
- Create: `Sources/MacNeutronCore/PEImage.swift`, `Sources/MacNeutronCore/CodeIdentity.swift`,
  `Sources/MacNeutronCore/RunningProcesses.swift`
- Test: `Tests/MacNeutronCoreTests/PEImageTests.swift`, `Tests/MacNeutronCoreTests/CodeIdentityTests.swift`,
  `Tests/MacNeutronCoreTests/RunningProcessesTests.swift`
- Details: `core §C.1`, `core §B §5.1`, `install §D`

**Interfaces:**
- Produces:
  - `public enum PEImage { public static let i386: UInt16 = 0x014c, amd64: UInt16 = 0x8664, arm64: UInt16 = 0xAA64;
    public static func machine(of url: URL) -> UInt16? }` — nil when not a PE file (missing, script, truncated);
    reads only the DOS header and the 6 bytes at `e_lfanew` (`FileHandle`, never `Data(contentsOf:)`).
  - `public enum CodeIdentity { public static func of(_ bundle: URL) -> String? }` — `SecStaticCodeCreateWithPath` +
    `SecCodeCopySigningInformation(kSecCSSigningInformation)`, `kSecCodeInfoUnique` as 40 lowercase hex; nil when
    unsigned or missing.
  - `public enum RunningProcesses { public static func executablePaths() -> [String] }` — `proc_listallpids` +
    `proc_pidpath` (buffer `4 * Int(MAXPATHLEN)`), skipping pids that return ≤ 0.

- [ ] **Step 1: Write the failing tests.**
  - `PEImageTests`: `amd64AndArm64AndI386MachinesAreRead` (synthetic 64-byte DOS header, `e_lfanew = 0x80`, `PE\0\0`,
    machine), `aScriptIsNotPE`, `aTruncatedMZIsNotPE`, `aMissingFileIsNotPE`, `machineReadsAPathWithSpaces`
    (`makeTempDir()` path + `"game é/Game.exe"`), `machineReadsOnlyTheHeaderOfAHugeFile` (header written, then
    `FileHandle.truncate(atOffset: 4 << 30)` to make a sparse 4 GB file; `#expect` the result in under 1 s).
  - `CodeIdentityTests` (each signs a temp bundle: `Contents/Info.plist` with `CFBundleExecutable=wine`, a copy of
    `/usr/bin/true` as `Contents/MacOS/wine`, then `/usr/bin/codesign -s - -f <bundle>`):
    `identityIs40HexAndMatchesCodesign` (compare with `codesign -dvvv` stderr `CDHash=`),
    `bundlesDifferingOnlyInTheLoaderDiffer` (`/usr/bin/false`), `bundlesDifferingOnlyInInfoPlistDiffer`,
    `resigningIdenticalBitsKeepsTheIdentity`, `unsignedOrMissingBundleHasNoIdentity`.
  - `RunningProcessesTests`: `thisTestProcessIsListed` (contains `ProcessInfo` executable path),
    `aSpawnedSleepIsListedByItsExecutable` (`/bin/sleep 5` through `Process`, then terminate).
- [ ] **Step 2: Run** `swift test --filter 'PEImageTests|CodeIdentityTests|RunningProcessesTests'`. Expected: fail to
  compile (types missing).
- [ ] **Step 3: Implement** the three types as specified in Interfaces (`import Security`, `import Darwin`).
- [ ] **Step 4: Run** the same filter, then `make test`. Expected: PASS; total count = previous + new.
- [ ] **Step 5: Commit.**

### Task 6: The launch path on `wine.app` (the swap)

This task deletes the Rosetta code and must leave the module compiling and `make test` green. The app's runtime
install comes back in Tasks 7-8; until then the app shows the installed runtime only.

**Files:**
- Modify: `Sources/MacNeutronCore/{ToolLayout,Preflight,GraphicsBackend,GameSettings,LaunchEnvironment,PrefixManager,
  SteamBridge,ShaderPrecache,Launcher,CommandLineTool,RuntimeInstaller,SteamPlayMode,SteamLocation}.swift`,
  `Sources/MacNeutronApp/{AppModel,SetupView,SettingsView,MenuContent,GamesView}.swift` (remove GPTK/AVX/tarball use
  only)
- Delete: `Sources/MacNeutronCore/{GPTKDiskImage,GPTKImporter,DXMTInstaller}.swift`, their tests, the
  `import-gptk`/`install-runtime`/`install-dxmt` verbs and their tests, `RuntimePin` and the tarball install
- Test: `Tests/MacNeutronCoreTests/{Support,PathsTests,PreflightTests,GraphicsBackendTests,GameSettingsTests,
  LaunchEnvironmentTests,PrefixManagerTests,LauncherTests,ShaderPrecacheTests,SteamBridgeTests,SteamPlayModeTests,
  AppModelTests,CommandLineToolTests,RuntimeInstallerTests}.swift`
- Details: `core §B` (every subsection), `core §D`, `install §A.9` (test fates)

**Interfaces:**
- Consumes: Task 5's `PEImage`, `CodeIdentity`.
- Produces:
  - `ToolLayout` (`core §B §3.1`): `wineApp`, `wine`, `wineserver`, `dxmt`, `dxmtVersionFile`, `dxmtVersion`,
    `dxmtReplay`, `static let dxmtDLLs = ["d3d10core.dll", "d3d11.dll", "d3d12.dll", "dxgi.dll"]`, `lsteamclient`,
    `lsteamclientUnix`, `launcherBinary`, `steamHelper`, `steamBridgeInstalled`, `runtimeDamagedMarker`,
    `runtimeVersion: String?` (read `Contents/Info.plist` with `PropertyListSerialization` each time, never
    `Bundle(url:)`), `identity: String?` (`CodeIdentity.of(wineApp)`), `runtimeLabel: String`
    (`"<version or unknown> (<identity prefix 12>)"`), `static let rosettaEraEntries = ["Libraries", "gptk",
    "gptk.json", "gptk.staging", "lib", "dxmt-version", "runtime-version", "runtime.staging"]`.
  - `PreflightError` cases `unsupportedSystem`, `runtimeMissing`, `thirtyTwoBit`, `unsupportedMachine(UInt16)` with
    the Global Constraints texts; `Preflight(systemSupported:identity:)` (both injectable closures) and
    `func check(_ layout: ToolLayout, request: LaunchRequest) throws(PreflightError) -> String` (returns the identity;
    writes `runtimeDamagedMarker` on `runtimeMissing`).
  - `GraphicsBackend: String { case dxmt, wined3d }`, `static func select(requested: String?) -> (backend:, note:)`,
    `var dllOverrides: String`.
  - `GameSettings(graphics:log:msync:runAs:metalFX:)` (no `avx`; old files still decode).
  - `LaunchEnvironment.build(base:context:backend:logging:)` (no `layout:`).
  - `PrefixError.emulatorSetupFailed(Int32)` (new); `PrefixManager(context:layout:identity:runner:log:)`,
    `static func stamp(identity: String, msync: Bool) -> String`, `prepare(environment:steamBridge:)`.
  - `ShaderPrecache.enabled(backend:environment:) -> Bool`.

- [ ] **Step 1: Rewrite the fixtures and tests first** per `core §B` and `install §A.9`: `Support.swift`'s
  `makeToolLayout()` builds a fake `wine.app` tree (`Contents/Info.plist` with `CFBundleShortVersionString` `test`,
  `MacOS/wine`, `Resources/bin/wineserver`, `Resources/DXMT/{version,aarch64-windows/{4 DLLs,dxmt-replay.exe}}`,
  `Resources/lib/wine/aarch64-{windows/lsteamclient.dll,unix/lsteamclient.so}`); launcher and prefix tests inject
  `Preflight(systemSupported: { true }, identity: { _ in "0123456789abcdef0123456789abcdef01234567" })`. Delete the
  deleted code's tests. New and rewritten tests, with these names and assertions:
  - Paths: `layoutPathsFollowWineApp`, `runtimeVersionComesFromWineAppInfoPlist` (and nil when the key is missing).
  - Preflight: `unsupportedSystemIsRefusedFirst`, `unreadableIdentityIsDamagedAndMarked` (marker file exists),
    `x64AndArm64TargetsPass`, `i386TargetIsThirtyTwoBit`, `otherMachineIsNamed` (0x1c4 → message contains `0x01c4` or
    `ARM`), `nonPETargetIsNotChecked` (script and missing file), `targetIsCheckedOnlyForWaitForExitAndRun`.
  - Launcher: `missingRuntimeNotifiesAndFails`, `thirtyTwoBitGameIsRefusedWithItsMessage` (notification text exact),
    `runSkipsA32BitInstaller` (exit 0, no runner calls, no notification, launcher.log has `skipped 32-bit installer
    Setup.exe`), `presenterIsAskedForByDefault` (`MACNEUTRON_PRESENT == "1"`, no `DYLD_INSERT_LIBRARIES`),
    `optingOutLeavesThePresenterOff`, `toolCommandsGetNoPresenter`, `everyLaunchIsLoggedWithVersions` (line ends
    `backend=dxmt runtime=test (0123456789ab) exit=0`), `oldGraphicsValueRunsDXMTWithANote`,
    `terminateKillsThePrefixWineserverUnderTheGamesMsync` (`WINEMSYNC == "1"`; with settings `msync: false`, unset),
    `waitForExitAndRunPreparesWaitsRunsThenWaits` (calls: `wineboot -u`, FEX `reg add`, crash-dialog `reg add`,
    `wineserver -w`, `wineserver -w`, the game, `wineserver -w`).
  - Prefix: `freshPrefixRunsWinebootAndRecordsVersion` (stamp `wine.app <id> msync=1`; wineboot's overrides contain
    `mscoree=;mshtml=`), `failedWinebootSkipsTheRegistrySteps`, `upToDatePrefixSkipsWineboot`,
    `identityChangePreparesInPlace`, `rosettaEraPrefixIsRenamedNeverDeleted`,
    `renameNumbersPastTakenNamesAndKeepsTheSaves` (`pfx.rosetta` exists → `pfx.rosetta-2`; a save file inside is
    intact), `preparingStampIsRetriedInPlace` (failed wineboot leaves `wine.app preparing`; next prepare retries
    without renaming), `failedFEXRegistrationFailsThePreparation` (`PrefixError.emulatorSetupFailed`),
    `msyncOnlyChangeKillsTheServerUnderTheOldMode` (`wineserver -k` with old `WINEMSYNC`, no wineboot),
    `copiesDXMTIntoSystem32Only`, `switchingBackToDXMTFindsItsDLLs` (prepared under wined3d, DLLs present),
    `unchangedBridgeFilesAreNotRecopied` (same mtime on the second prepare), `changedBridgeFileIsRecopied`.
  - Graphics/settings/env: `defaultsToDXMT`, `removedBackendsReadAsDXMTWithANote`, `overrideStringsPerBackend`,
    `everyBackendOverridesTheSameDLLSet`, `oldSettingsFilesStillLoad` (`{"avx":false,"graphics":"d3dmetal"}`),
    `setsPrefixOverridesAndDefaults` (`dxgi=n,b;d3d10core=n,b;d3d11=n,b;d3d12=n,b;d3d9=b;d3d10=b`, no
    `ROSETTA_ADVERTISE_AVX`), `wined3dOverridesUseBuiltins`, `recordsPipelinesForDXMTOnly`.
  - Steam Play: `enable` no longer checks Rosetta (delete `enableRequiresRosetta`,
    `turningOnWithoutRosettaLeavesSteamRunning`).
- [ ] **Step 2: Run** `make test`. Expected: compile failures pointing at the old APIs.
- [ ] **Step 3: Implement** per Interfaces and `core §B`, in this order: ToolLayout, GameSettings, GraphicsBackend,
  LaunchEnvironment (`WINEMSYNC=1` unless `MACNEUTRON_NO_MSYNC=1`, then removed; `MACNEUTRON_PRESENT=1` added by the
  launcher for `run`/`waitforexitandrun` unless `MACNEUTRON_NO_METALFX=1`), Preflight (+ `fail` also appends to the
  game log when one is open: move `logging`/`gameLog` above preflight), PrefixManager (`core §B §3.4`; copy-when-
  different sets the target's mtime to the source's), SteamBridge (no `steamclient.dll`), ShaderPrecache, Launcher
  (`run` + i386 skip right after preflight; `terminate` merges the game's settings and builds §3.7's environment).
  Delete the GPTK/DXMTInstaller/tarball code and the three CLI verbs; trim the app files to compile (GPTK step,
  `importGPTK`, `gptkVersion`, AVX toggle, graphics picker to Default/DXMT/wined3d, menu line to
  `Runtime <runtimeLabel>`; `installRuntime` and its Setup button removed for now).
- [ ] **Step 4: Run** `make test`. Expected: PASS.
- [ ] **Step 5: Commit.**

### Task 7: Installing `wine.app`, the CLI verbs and Steam's entry points

**Files:**
- Modify: `Sources/MacNeutronCore/{RuntimeInstaller,CommandLineTool,SteamPlayMode}.swift`
- Test: `Tests/MacNeutronCoreTests/{RuntimeInstallerTests,CommandLineToolTests,SteamPlayModeTests,FakeSteam}.swift`
- Details: `install §B.1, §B.2, §C`

**Interfaces:**
- Consumes: Task 5 `CodeIdentity`, `RunningProcesses`; Task 6 `ToolLayout`; Task 2's R0b verdict.
- Produces:
  - `public enum RuntimeInstallOutcome: Equatable, Sendable { case installed, unchanged, deferred(String) }`
  - `public enum RuntimeInstallError: Error { case notAWineApp(String), signatureInvalid(Int32), swapFailed(Int32) }`
  - `RuntimeInstaller.install(wineApp: URL, layout: ToolLayout, launcherBinary: URL, steamExe: URL? = nil,
    force: Bool = false, runner: any ProcessRunner = SystemProcessRunner(), runningExecutables: () -> [String] =
    RunningProcesses.executablePaths, identity: (URL) -> String? = CodeIdentity.of) throws -> RuntimeInstallOutcome`
    following spec §3.9 steps 1-6 (deferral on any executable under `layout.wineApp` or `layout.root/Libraries/`;
    clone `cp -c -R` to `wine.app.new`; `codesign --verify --strict`; `renamex_np(RENAME_SWAP)` or `rename` on a first
    install; delete the old copy and the marker; `writeToolFiles`; remove `ToolLayout.rosettaEraEntries` and, after
    R0b PASS, `proton`).
  - `RuntimeInstaller.writeToolFiles(layout:launcherBinary:steamExe:)`; manifest commandline
    `/bin/macneutron launch %verb%` after R0b PASS (else keep `/proton %verb%` and the stub).
  - CLI: `macneutron install --tool-dir <dir> --wine-app <path> [--steam-exe <path>] [--force]` — prints
    `installed <runtimeLabel>`, `unchanged <runtimeLabel>`, or `deferred: <path> is running`; exits 0, 0, 3; 1 on error.
    `macneutron passthrough <verb> <command> [args…]` (after R0b PASS): `static func passthroughTarget(_ path: String)
    -> URL` (`.app` → `Contents/MacOS/<CFBundleExecutable>` via `PropertyListSerialization`, falling back to the
    bundle's base name); `static let passthroughArchitectures` = arm64e, arm64, x86_64 (cpu type + subtype);
    `static func spawn(_ executable: URL, _ arguments: [String], environment: [String: String],
    replacingThisProcess: Bool) throws -> pid_t` with `posix_spawnattr_setarchpref_np` and, when replacing,
    `POSIX_SPAWN_SETEXEC`.
  - `SteamPlayMode.installNativeTool()`: manifest `/bin/macneutron passthrough %verb%`, copies
    `<runtime tool>/bin/macneutron` to `macneutron-native/bin/macneutron`, deletes a stale `passthrough.sh` (after R0b
    PASS; else unchanged).

- [ ] **Step 1: Read R0b's verdict** in `docs/testing/acceptance-arm64-release.md`. FAIL → skip every "after R0b PASS"
  item and say so in the commit message.
- [ ] **Step 2: Write the failing tests.** Install tests use a fake source tree and the `identity`/`runningExecutables`
  seams, except where named: `firstInstallClonesVerifiesAndSwapsIn` (real ad-hoc-signed source, `SystemProcessRunner`),
  `equalIdentitySkipsTheCopyButWritesToolFiles`, `differentIdentityReplacesTheRuntime`, `forceReinstallsOverAnEqual
  Identity`, `damagedMarkerReinstallsAndIsCleared`, `aRunningRuntimeProcessDefers` (outcome `.deferred(path)`, nothing
  moved), `aRunningRosettaProcessDefersTheCleanup`, `aDeferredInstallLeavesTheOldRuntimeWorking`,
  `leftoversFromAnInterruptedInstallAreCleaned` (`wine.app.new` and `.old` removed),
  `aBadSignatureLeavesTheOldRuntime` (codesign status 1 → `signatureInvalid`, `.new` deleted),
  `rosettaEraEntriesAreRemoved`, `installWorksUnderASpacedNonASCIIPath` (tool dir under `"Application Support/é"`),
  `steamExeOptionIsUsedWhenGiven`, `manifestPointsAtTheCLI` (after R0b PASS). CLI: `installRequiresWineApp` (exit 2),
  `installPrintsTheOutcomeAndExitsThreeWhenDeferred`, `unknownCommandPrintsUsage` (usage lists `install` and
  `passthrough`, not the removed verbs). Passthrough: `appBundleResolvesToItsExecutable`,
  `appWithoutPlistFallsBackToItsName`, `plainPathIsKept`, `preferenceIsArm64eArm64ThenX86`,
  `spawnWithoutReplacingRunsTheNativeSlice` (spawn `/usr/bin/arch` with no args, capture stdout, expect `arm64`).
  Steam Play: `nativeToolRunsTheCLIPassthrough`, `staleScriptIsRemoved`; `FakeSteam.makeFakeSteam` writes a fake
  `macneutron/bin/macneutron`.
- [ ] **Step 3: Run** `make test`. Expected: compile failures.
- [ ] **Step 4: Implement** per Interfaces (`import Darwin`; `RENAME_SWAP` as `UInt32(RENAME_SWAP)`).
- [ ] **Step 5: Run** `make test`. Expected: PASS.
- [ ] **Step 6: Real install, by hand:** `swift build -c release` then
  `.build/release/macneutron install --tool-dir "$TMPDIR/l6 tool" --wine-app build/wine-arm64/wine.app --steam-exe
  build/bridge/arm64/steam.exe`. Expected: `installed dev (<12 hex>)`, exit 0; a second run: `unchanged …`.
- [ ] **Step 7: Commit.**

### Task 8: The app — background install, setup, repair, macOS 27

**Files:**
- Modify: `Sources/MacNeutronApp/{AppModel,SetupView,SettingsView,MenuContent}.swift`, `Package.swift`,
  `App/Info.plist`
- Test: `Tests/MacNeutronCoreTests/AppModelTests.swift`
- Details: `install §B.3, §C.4-C.6, C.13`

**Interfaces:**
- Consumes: Task 7 `RuntimeInstaller.install`.
- Produces: `AppModel(…, wineAppSource: URL? = AppModel.bundledWineApp)` (`static var bundledWineApp: URL?` =
  `Bundle.main.bundleURL/Contents/Helpers/wine.app` when it exists); `private(set) var runtime: InstalledRuntime?`
  (`struct InstalledRuntime: Equatable, Sendable { let version: String; let identity: String }`);
  `private(set) var runtimeNotice: String?`; `func installRuntime(force: Bool = false) async`;
  `setupComplete == (runtime != nil && mode.isWanted)`.

- [ ] **Step 1: Failing tests:** `startupInstallsTheBundledRuntime` (source given → `runtime` set, notice cleared),
  `noBundledRuntimeInstallsNothing` (nil source, nothing written), `aDeferredInstallIsRetriedByThePoll` (deferred once,
  then installed on the next tick, `busy` never set), `repairForcesAReinstall`, `damagedMarkerTriggersAReinstall`,
  `setupCompletesWithRuntimeAndSteamPlay`, `setupWindowStaysClosedOnceSetUp` (rewritten),
  `installRefreshesTheNativeTool` (after an install with Steam Play wanted, `macneutron-native/bin/macneutron` exists).
- [ ] **Step 2: Run** `make test`. Expected: FAIL.
- [ ] **Step 3: Implement:** install in `Task.detached`, guarded by a private `installing` flag, notice `Installing the
  runtime…` / `The runtime updates after the game exits.` / the error text; never through `run()`/`busy`; the poll
  retries while deferred and reinstalls when `runtimeDamagedMarker` exists; Setup steps "Steam" (done:
  `steamInstalled`), "Runtime" (done: `runtime != nil`, detail = notice or `Runtime <label> installed`), "Steam Play"
  (disabled until both); Settings "Repair runtime" → `installRuntime(force: true)`, disabled while installing; menu
  line `Runtime <label>` or `Runtime not installed`. `Package.swift` `.macOS("27.0")`; `App/Info.plist`
  `LSMinimumSystemVersion` `27.0`.
- [ ] **Step 4: Run** `make test`. Expected: PASS; `lipo -archs .build/release/macneutron` = `arm64`.
- [ ] **Step 5: Commit.**

### Task 9: Makefile, smoke test (L5) and the install gate (L6)

**Files:**
- Modify: `Makefile`, `Tests/Smoke/smoke.sh`, `dxmt/tests/shaders/compile.sh`, `dxmt/tests/build_test.sh`,
  `dxmt/published.sh` (comment). `dxmt/pins` stays as it is: it is a DXMT series input, so any edit forces a DXMT
  rebuild (its unused `WINE_URL`/`WINE_SHA256` lines are harmless).
- Create: `Tests/Smoke/i386.c` (or reuse `exitcode.c` compiled with `i686-w64-mingw32-clang`)
- Delete: `dxmt/build.sh`, `dxmt/tests/run.sh`
- Details: `checks §6, §7, §8, §9`, `build §13 (§8.2)`, `install §B.4`

**Interfaces:**
- Consumes: Task 7's `install` verb (exit codes), Task 6's messages.
- Produces: `make app` (dev `MacNeutron.app` with `Contents/Helpers/wine.app` cloned from `build/wine-arm64/wine.app`
  and `Contents/Resources/steam.exe` from `build/bridge/arm64/steam.exe`, outer app ad-hoc signed without `--deep`);
  `make smoke` running L5 and L6.

- [ ] **Step 1: Makefile:** `.PHONY` drops `dxmt`, adds `release`; `bridge` drops the x64 `steam.exe` and `helper.exe`
  (keeps `steamprobe.exe` and the arm64 pair); `presenter` builds `present_loop.exe` only; `dxmt` and `dxil-corpus`
  per `checks §8`; `dxmt-check: build wine-arm64 dxmt-tests dxmt-tests-arm64ec presenter`; `wine-arm64-check` drops
  `dxmt`; `smoke: build bridge wine-arm64`; `bridge-check: build bridge wine-arm64`; `presenter-check: build wine-arm64
  presenter`; `app: build bridge wine-arm64` as in Produces; `release: sh release/release.sh` (Task 12). Update every
  target comment. `build_test.sh`: drop the `dxmt/build.sh` rows, keep the `published.sh`, Clang and LLVM rows; its
  "make uses it" row now wants `1`.
- [ ] **Step 2: smoke.sh (L5 and L6):** tool folder from `install --tool-dir "$TOOL" --wine-app build/wine-arm64/wine.app
  --steam-exe build/bridge/arm64/steam.exe`; entry point `$TOOL/bin/macneutron launch waitforexitandrun` (or `$TOOL/proton`
  after an R0b FAIL); all compilers from `dxmt/toolchain.sh`. Rows (each prints `PASS|FAIL <name>`):
  - `dxmt exitcode` / `wined3d exitcode` → exit 2 with `"a b" c`; `dxmt d3d11probe` / `wined3d d3d11probe` → exit 0;
  - `arm64ec exitcode` (built with `arm64ec-w64-mingw32-clang`) → exit 2;
  - `32-bit game refused` (built with `i686-w64-mingw32-clang`) → non-zero, launcher.log has the 32-bit message;
  - `rosetta-era prefix renamed` (pre-create `compatdata/rosetta/pfx/drive_c/save.txt` and `version` =
    `runtime-v4.7.3`) → `pfx.rosetta/drive_c/save.txt` intact, `version` starts `wine.app `;
  - L6: `install twice is a no-op` (second run prints `unchanged`); `install defers while the runtime runs` (start
    `"$TOOL/wine.app/Contents/Resources/bin/wineserver" -p` in a prefix, then install → exit 3, then
    `wineserver -k`); `--force reinstalls` (prints `installed`); `damaged marker reinstalls` (`touch
    "$TOOL/runtime-damaged"` → `installed`, marker gone); `leftovers are cleaned` (`mkdir "$TOOL/wine.app.new"` → gone
    after install).
- [ ] **Step 3: compile.sh:** run DXC under `"$MACNEUTRON_REFERENCE/Libraries/Wine/bin/wine"` (default reference path)
  and fetch DXC itself with `dxmt/fetch.sh`'s `fetch` and the `DXC_URL`/`DXC_SHA256` pins (no new download: same pin).
  Delete `dxmt/build.sh` and `dxmt/tests/run.sh`.
- [ ] **Step 4: Run** `make smoke` and `sh dxmt/tests/build_test.sh`. Expected: every row PASS. Run `make app` and
  check `codesign --verify --strict build/MacNeutron.app/Contents/Helpers/wine.app` passes (its signature survived).
- [ ] **Step 5: Commit.**

### Task 10: `dxmt/check.sh` and `wine-arm64/check.sh` on the new launcher (L1, L2, G4)

**Files:**
- Modify: `dxmt/check.sh`, `wine-arm64/check.sh`
- Details: `checks §1.3` (items 1-14), `checks §2.3` (items 1-4, 7), flags F1, F6, F10, F13-F15

**Interfaces:**
- Consumes: Task 3's frozen reference (`MACNEUTRON_REFERENCE`), Task 7's `install` verb.

- [ ] **Step 1: dxmt/check.sh** per `checks §1.3`: arm64 only; `$WORK/ref` = clone of the frozen tool (its own CLI,
  never overwritten), `$WORK/ours` = `install` from `${MACNEUTRON_ARM64_APP:-build/wine-arm64/wine.app}` (exit code
  must be 0); `run()` picks the tool from the backend (`d3dmetal` → ref with unmapped x64 programs, `compat/ref*`;
  `dxmt` → ours, `compat/ours*`); prefixes `ours ours-A…E` and `ref ref-A…E` by `getcompatpath` in parallel;
  `stop_lanes` kills each family's servers with its own `wineserver` and `WINEMSYNC=1`; section 1 keeps only "the D3D11
  game ran our d3d11.dll" (stock/x86 lanes and the 10% comparison deleted); section 5 feeds `dxmt/pins` as the
  non-container file; L2 and section 10 (L1) run unguarded, reading `$WORK/ours/wine.app/Contents/Resources/DXMT/
  version`; section 4 renamed "the frozen D3DMetal reference still runs". `make dxmt-check` runs it twice: the x64
  programs and, with `MACNEUTRON_ARM64_TESTS`/`MACNEUTRON_ARM64_LOOP`, the ARM64EC ones.
- [ ] **Step 2: wine-arm64/check.sh** per `checks §2.3`: G4 reads `REF` (`MACNEUTRON_REFERENCE`), no CLI copy;
  `runtime_pids` covers `dxmt-*/ref` and `dxmt-*/ours`; `dxmt_lane_cmd` drops `MACNEUTRON_ARM64_PREFIX`; header
  comments updated.
- [ ] **Step 3: Run** `make dxmt-check`. Expected: `dxmt-check: all passed` for both lanes, including
  `the launcher records into the game's compat folder`, `a changed build replays d3d12_cache's recording before the
  game`, `then the game only hits`, `the unsupported op is named in the log`.
- [ ] **Step 4: Run** `make wine-arm64-check`. Expected: every step PASS, `PASS orphans`.
- [ ] **Step 5: Commit.**

### Task 11: Steam bridge and presenter through the launcher (L3, L4)

**Files:**
- Modify: `bridge/check.sh`, `bridge/probe.sh`, `presenter/check.sh`, `wine-arm64/check.sh` (`steam_bridge_cmd`)
- Details: `checks §3, §4, §5`, `checks §2.3` item 5, flags F3, F8, F9, F11

- [ ] **Step 1: bridge/check.sh:** delete the Rosetta branch; standalone mode assembles `$WORK/tool` with `install
  --steam-exe build/bridge/arm64/steam.exe` and a prefix by `getcompatpath`; a launcher pass (`MACNEUTRON_TOOL_DIR`)
  runs the rows `exit code passes through`, `arguments arrive unchanged`, `registry names a live Steam`,
  `launcher-style child still sees Steam`, `pid cleared afterwards` (`runinprefix`), `missing program exits 1`,
  `launchers may start children outside the job` through `launch waitforexitandrun`; the second-steam.exe row stays
  direct.
- [ ] **Step 2: bridge/probe.sh:** delete the Rosetta branch (no `steamclient.dll`), `FAULT=fault` always; launcher mode
  (`MACNEUTRON_TOOL_DIR`) runs `steamprobe.exe` through `launch waitforexitandrun` with `SteamAppId=480`; redaction
  unchanged.
- [ ] **Step 3: wine-arm64/check.sh steam-bridge step:** after the direct runs, assemble a tool folder and run both
  scripts through the launcher; expect `init: ok`, `steamid ok`, `auth ticket: callback, result 1`, ticket bytes > 0.
- [ ] **Step 4: presenter/check.sh (L4):** assembled tool folder, `MACNEUTRON_GRAPHICS=dxmt`, no `DYLD_INSERT_LIBRARIES`;
  inject=1 → no `MACNEUTRON_NO_METALFX`, inject=0 → `MACNEUTRON_NO_METALFX=1`; keep the 11 rows of `checks §5` (drop
  "prefix setup works with the library loaded"); add `MACNEUTRON_NO_METALFX=1 loads no presenter` (0 lines on `base`).
- [ ] **Step 5: Run** `make bridge-check`, `make presenter-check`, `make wine-arm64-check`. Expected: all PASS, no
  SteamID in any output (`LC_ALL=C /usr/bin/grep -E '7656119[0-9]{10}'` on the logs finds nothing).
- [ ] **Step 6: Commit.**

### Task 12: `release/release.sh` (R1-R5)

**Files:**
- Modify: `wine-arm64/bundle.sh` (`--release --version <V> --out <dir>`; strip; deletions; `write_source`),
  `wine-arm64/build.sh` (SOURCE via `write_source`), `wine-arm64/lib.sh` (`write_source <out> <mac>`),
  `wine-arm64/tests/licences_test.sh` (`--app <MacNeutron.app>` mode), `release/lib.sh`, `dxmt/published.sh`
- Create: `release/release.sh`, `release/verify-sources.sh`, `release/fixtures/` (R1 bad inputs, built at test time)
- Details: `build §13 (§5.2, §6.3)`, `build §14` 1-3, 11, `release §A-C`, spec §6.3 and §14

**Interfaces:**
- Consumes: Task 1 `notarize_and_staple`; Task 4 licences; Task 9 `make app` layout.
- Produces: `make release VERSION=<V>` → `build/release/<V>/{MacNeutron-<V>.zip, MacNeutron-<V>-source.tar.gz,
  SHA256SUMS}`; `release.sh --self-test`.

- [ ] **Step 1: R1 first.** Write `release.sh --self-test`: prepares throwaway copies (a dirty file, a SOURCE with
  `WINE_SERIES=dev`, one with `+dirty`, an existing tag name `v0.0.0-selftest` created and deleted in a temp clone, an
  unpublished DXMT commit id, a README containing `import-gptk`) and asserts each refusal names its input. Run it.
  Expected: FAIL (nothing implemented).
- [ ] **Step 2: Step 1 refusals** (spec §6.3 step 1 + §14): `git fetch origin`; clean tree and HEAD contained in
  `origin/main`; each tree `applied` via `build_mode`; `sh wine-arm64/build.sh` prints `wine-arm64: up to date`;
  `dxmt/published.sh build/wine-arm64-src/dxmt "$DXMT_COMMIT"`; `VERSION` matches `^[0-9]+\.[0-9]+\.[0-9]+$` and no tag
  `v$VERSION`; neither README contains `Rosetta 2`, `import-gptk` or `doesn't redistribute`. Run `--self-test`. Expected:
  PASS.
- [ ] **Step 3: Release bundle (R3):** `bundle.sh --release --version "$V" --out "build/release/$V"` — strip between the
  layout and the signing (`build §13 §5.2`: llvm-mingw's `llvm-strip --strip-debug` on PE files, `strip -S` on Mach-Os,
  delete `.a` files and `winegcc wineg++ winecpp winebuild winedump widl wrc wmc winemaker function_grep.pl`), write
  SOURCE with `MACNEUTRON_COMMIT=$(git rev-parse HEAD)` through `write_source`, version keys = `$V`; all existing
  assertions run. Record `du -sk` before and after. Then run Task 9's smoke rows (x64, ARM64EC, a DXMT test program)
  against the release `wine.app` with `MACNEUTRON_ARM64_APP`. Expected: assertions PASS, rows PASS.
- [ ] **Step 4: App + notarization (R2, R4):** `notarize_and_staple` the release `wine.app`; build `MacNeutron.app`
  (`.build/release/MacNeutronApp` → `Contents/MacOS/MacNeutron`, CLI → `Contents/Helpers/macneutron`, `ditto` the
  stapled `wine.app` → `Contents/Helpers/wine.app`, `steam.exe` → `Contents/Resources/`, `Contents/Resources/licenses/`
  = `LICENSE`, the llvm-mingw texts, a README pointing at `Contents/Helpers/wine.app/Contents/Resources/licenses/`;
  Info.plist version `$V`, minimum `27.0`); assert `lipo -archs` = `arm64` for both Swift binaries; sign the CLI then the
  app with `--options runtime --timestamp`, never `--deep`, never re-signing `wine.app`; `licences_test.sh --app`;
  `notarize_and_staple MacNeutron.app`; `spctl -a -vvv -t exec` output (stderr) contains `accepted`; zip with `ditto -c
  -k --keepParent`.
- [ ] **Step 5: Source archive (R5):** `MacNeutron-<V>-source.tar.gz` with nested tars per spec §7.2 and §14 (repo
  `git archive --prefix=MacNeutron/ HEAD`; Wine, FEX + its six SOURCE submodules, DXMT + its two submodules by `git
  archive`; lsteamclient as `tar` of its clean sparse worktree; the four tarballs) plus `SOURCES.txt` (tree, pin,
  applied commit, patch count). `release/verify-sources.sh <archive> <SOURCE>` checks every rule of spec §14's R5.
  Run it. Expected: `PASS sources`.
- [ ] **Step 6: Finish:** write `SHA256SUMS`; print the `git tag v$V` and `gh release create v$V …` commands; never run
  them. Add a `release` row to the README's build section (Task 13 writes the prose).
- [ ] **Step 7: Dry run** `make release VERSION=0.0.1-rc` is refused by the version rule; `release.sh --self-test`
  PASS. (The real run is Task 14.)
- [ ] **Step 8: Commit.**

### Task 13: Documentation and status lines

**Files:**
- Modify: `README.md`, `wine-arm64/README.md`, `docs/superpowers/specs/2026-10-02-macneutron-native-arm64-design.md`,
  every earlier spec that describes the Rosetta runtime, GPTK or `install-dxmt` (list in `release §F`), the ten
  Rosetta-era `docs/testing/acceptance-*.md`, the three `acceptance-arm64-*.md`
- Details: `release §E, §F`, spec §7.3, §13, §14

- [ ] **Step 1: README.md** per `release §E` table (download, move to Applications, requirements, setup, options,
  licences, `install` verb, 32-bit and Direct3D 9 not supported in 0.1, `runtime-v*.tar.gz` can be deleted, building
  needs the Developer ID setup, a Licence section). Never the strings `Rosetta 2`, `import-gptk`, `doesn't
  redistribute`.
- [ ] **Step 2: wine-arm64/README.md** lines in `release §E` (both the spec-named and the stale ones); "Next Wine
  rebase" lists patch 0002 under DXMT.
- [ ] **Step 3: Native spec amendments** (spec §13 and §14): lines 22, 39, 47, rows 5-9, §11's notarization line.
- [ ] **Step 4: Status lines:** "Superseded in part by `2026-10-04-macneutron-arm64-release-design.md` (the Rosetta
  runtime, GPTK, DXVK and the x86_64 DXMT build were removed in 0.1.0)." on each listed spec; "Historical: the Rosetta
  runtime was removed in 0.1.0; reproduce with the frozen reference (`tools/freeze-rosetta-reference.sh`)." under each
  Rosetta-era acceptance title; "Rosetta baselines now come from the frozen reference (`MACNEUTRON_REFERENCE`)." on the
  three arm64 records.
- [ ] **Step 5: Check:** `LC_ALL=C /usr/bin/grep -nF -e 'Rosetta 2' -e 'import-gptk' -e "doesn't redistribute"
  README.md wine-arm64/README.md` prints nothing; `release.sh`'s README refusal passes.
- [ ] **Step 6: Commit.**

### Task 14: Acceptance and the release candidate

**Needs the maintainer:** R6 and S, and the notary submission.

**Files:**
- Modify: `docs/testing/acceptance-arm64-release.md`, the spec's Status line

- [ ] **Step 1: Full runs**, each recorded with its result line: `make test`, `make smoke`, `make bridge-check`,
  `make presenter-check`, `make dxmt-check`, `make wine-arm64-check`, `release.sh --self-test`.
- [ ] **Step 2: Push gate:** `release.sh` requires HEAD in `origin/main`. Ask the maintainer to approve pushing `main`;
  push only on a yes.
- [ ] **Step 3: `make release VERSION=0.1.0`** with the signing and notary variables. Record: both submission ids,
  `spctl` verdict, `verify-sources.sh` result, sizes (wine.app before/after stripping, zip, archive), `SHA256SUMS`.
- [ ] **Step 4: Maintainer gates:** hand the zip path to the maintainer for R6 (fresh macOS account: unzip, move to
  Applications, open, setup, Steam Play, Spacewar through the bridge, `spctl -a -vvv -t exec` on the installed
  `wine.app`, `sysctl.proc_translated` 0 for every MacNeutron and Wine process) and S (SMITE 2 reaches gameplay in that
  account). Record their notes verbatim.
- [ ] **Step 5: Spec status:** "Implemented 2026-10-04 (or the date): gates pass, `docs/testing/acceptance-arm64-release.md`".
- [ ] **Step 6: Commit** and give the maintainer the printed `git tag` / `gh release create` commands. Publishing and
  installing the release over their Rosetta setup are theirs.
