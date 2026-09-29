# MacNeutron MetalFX Upscaling and Metal 4 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Games on D3DMetal can upscale with Apple's MetalFX through their own DLSS option, and MacNeutron's Games window turns that path and D3DMetal's Metal 4 backend on or off per game.

**Architecture:** The runtime gets Apple's `nvngx-on-metalfx` bridge under its export name (`nvngx.dll` plus an `nvngx.so` link). The launch environment enables `D3DM_ENABLE_METALFX` and `D3DM_MTL4` under D3DMetal by default, and hides Apple's NVIDIA DLLs (`nvapi64,nvngx=d`) when a game opts out or runs another backend. Prefixes get `system32` stubs so Wine's loader finds the bridge. Two per-game settings and toggles drive it.

**Tech Stack:** Swift 6 (swift-testing), SwiftPM, SwiftUI, the installed winecx-gptk runtime with the user's imported GPTK 4.0b2.

**Spec:** `docs/superpowers/specs/2026-09-28-macneutron-metalfx-design.md`

## Global Constraints

- Swift 6 language mode, swift-testing; `swift test` stays green after every task (153 tests before Task 2).
- Never commit or redistribute Apple's GPTK files; the bridge is always taken from the user's own import.
- frankea/Whisky is GPL-3.0: use its documented facts only, never its code.
- Never set `CX_ACTIVE_GRAPHICS_BACKEND` (it unlocks DLSS frame generation, which hung WindowServer).
- Steam's files (`localconfig.vdf`) are edited only after the user says yes in chat, with Steam closed, after a backup. SteamIDs and persona names never go into committed files.
- Exact strings:
  - launcher note `note: this GPTK has no MetalFX bridge`;
  - prefix error `could not install the MetalFX bridge: <file>: <reason>`;
  - toggle labels "MetalFX upscaling" and "Metal 4";
  - disabled-toggle help "Needs D3DMetal (import the Game Porting Toolkit)";
  - launch options `MACNEUTRON_NO_METALFX=1` and `MACNEUTRON_NO_METAL4=1`.
- Every commit message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **A game set to DXVK while GPTK is imported runs on D3DMetal** (`GraphicsBackend.select` falls back), so MetalFX and Metal 4 must apply to it. Pinned by `dxvkSettingFallingBackToD3DMetalGetsMetalFX` (Task 4).
2. **Prefixes made before the bridge existed** (SMITE 2's) must get the `system32` stubs on the next launch without a runtime change. Pinned by `stubsAreAddedToAnUpToDatePrefix` (Task 4).
3. **A user's own `D3DM_ENABLE_METALFX` / `D3DM_MTL4` / `WINEDLLOVERRIDES` in launch options** (the gate in Task 1 sets two of them) must win over MacNeutron's defaults. Pinned by `userChoicesForTheBridgeWin` (Task 3).
4. **A runtime reinstall or GPTK re-import** rewrites `Libraries/Wine` and must bring `nvngx.dll`/`nvngx.so` back. Pinned by `runtimeReinstallKeepsTheMetalFXBridge` and `importInstallsTheMetalFXBridge` (Task 2).
5. **The files hand-installed in the Task 1 gate** (runtime `nvngx.dll`, prefix stubs) must be compatible with the automated install: repeated installs succeed, and existing stubs are left as they are. Pinned by `metalFXBridgeInstallIsIdempotent` (Task 2) and `existingStubsAreLeftAlone` (Task 4).

## File Structure

| File | Responsibility |
|---|---|
| `Sources/MacNeutronCore/ToolLayout.swift` | `metalFXBridgePE`, `metalFXBridgeUnix`, `nvapiPE`, `metalFXBridgeInstalled` |
| `Sources/MacNeutronCore/GPTKImporter.swift` | `installMetalFXBridge(layout:)`, called from `applyOverlay` |
| `Sources/MacNeutronCore/GameSettings.swift` | `metalFX`, `metal4` fields and their launch variables |
| `Sources/MacNeutronCore/LaunchEnvironment.swift` | The spec §4 table |
| `Sources/MacNeutronCore/PrefixManager.swift` | `system32` stubs when MetalFX is on |
| `Sources/MacNeutronCore/Launcher.swift` | Missing-bridge note |
| `Sources/MacNeutronApp/AppModel.swift` | Install the bridge at app start |
| `Sources/MacNeutronApp/GamesView.swift` | Two toggles |
| `README.md` | Launch options and an "Upscaling" section |
| `Tests/MacNeutronCoreTests/{Support,GPTKImporterTests,RuntimeInstallerTests,GameSettingsTests,LaunchEnvironmentTests,PrefixManagerTests,LauncherTests,AppModelTests}.swift` | Tests |
| `docs/testing/acceptance-metalfx.md` (new) | Gate and acceptance record |

---

### Task 1: Feasibility gate: DLSS through MetalFX in SMITE 2, wired by hand

**Files:**
- Create: `docs/testing/acceptance-metalfx.md`

**Interfaces:**
- Consumes: the installed runtime at `~/Library/Application Support/MacNeutron/compatibilitytools.d/macneutron` with GPTK 4.0b2 imported; SMITE 2 (app 2437170) and its prefix; the user in chat.
- Produces: the gate decision (spec §9). **If DLSS isn't offered, or crashes, stop and report to the user; Tasks 2–6 are not started.**

- [ ] **Step 1: Install the bridge into the runtime by hand**

Run:
```bash
T="$HOME/Library/Application Support/MacNeutron/compatibilitytools.d/macneutron/Libraries/Wine/lib/wine"
cp "$T/x86_64-windows/nvngx-on-metalfx.dll" "$T/x86_64-windows/nvngx.dll"
ln -sfn ../../external/libd3dshared.dylib "$T/x86_64-unix/nvngx.so"
ls -la "$T/x86_64-unix/nvngx.so"; x86_64-w64-mingw32-objdump -p "$T/x86_64-windows/nvngx.dll" | grep -m1 "^Name "
```
Expected: `nvngx.so -> ../../external/libd3dshared.dylib`, and the export name line ends with `nvngx.dll`.

- [ ] **Step 2: Add the stubs to SMITE 2's prefix**

Run:
```bash
T="$HOME/Library/Application Support/MacNeutron/compatibilitytools.d/macneutron/Libraries/Wine/lib/wine"
S="$HOME/Library/Application Support/Steam/steamapps/compatdata/2437170/pfx/drive_c/windows/system32"
for f in nvngx.dll nvapi64.dll; do [ -e "$S/$f" ] && echo "kept $f" || { cp "$T/x86_64-windows/$f" "$S/$f" && echo "added $f"; }; done
```
Expected: `added nvngx.dll`, and either `kept` or `added` for `nvapi64.dll`.

- [ ] **Step 3: Set SMITE 2's launch options (ask the user first)**

Ask in chat: "OK to quit Steam and change SMITE 2's launch options to `/usr/bin/env MTL_HUD_ENABLED=1 MACNEUTRON_LOG=1 D3DM_ENABLE_METALFX=1 D3DM_MTL4=1 %command%` (backup first)?" Wait for a yes.

Then check that Steam is closed (`pgrep -x steam_osx` prints nothing; if it doesn't, ask the user to quit Steam and wait). Then run:
```bash
cd "$HOME/Library/Application Support/Steam/userdata"
F=$(for f in */config/localconfig.vdf; do grep -q '"2437170"' "$f" && echo "$f"; done | head -1)
cp -p "$F" "$F.before-metalfx-$(date +%Y%m%d%H%M%S)"
python3 - "$F" <<'EOF'
import re, sys, os
p = sys.argv[1]; t = open(p, encoding='utf-8').read()
block = re.compile(r'(\n\t{5}"2437170"\n\t{5}\{\n)(.*?)(\n\t{5}\})', re.S)
m = block.search(t); assert m, "SMITE 2 block not found"
body = re.sub(r'\t{6}"LaunchOptions"\t\t"[^"\n]*"\n?', '', m.group(2))
new = '\t\t\t\t\t\t"LaunchOptions"\t\t"/usr/bin/env MTL_HUD_ENABLED=1 MACNEUTRON_LOG=1 D3DM_ENABLE_METALFX=1 D3DM_MTL4=1 %command%"\n' + body
t = t[:m.start()] + m.group(1) + new + m.group(3) + t[m.end():]
open(p + '.tmp', 'w', encoding='utf-8').write(t); os.replace(p + '.tmp', p)
EOF
grep -A2 '^\t\t\t\t\t"2437170"' "$F" | grep LaunchOptions
```
Expected: exactly one `LaunchOptions` line with the new value.

- [ ] **Step 4: The user checks DLSS**

Ask the user to start Steam and SMITE 2 and open its graphics settings:
1. Is DLSS offered as an upscaler?
2. If yes, set DLSS to Quality. Does the image look sharper than before? Any crash?
3. What does the Metal display show (FPS, GPU time)?

After the user reports, run:
```bash
grep -a -E "nvngx|nvapi|NGX|metalfx" -i "$HOME/Library/Logs/MacNeutron/steam-2437170.log" | tail -20
```
Expected: `Loaded ... nvapi64.dll` and `... nvngx.dll ... builtin` lines if the game probed them.

Decision (spec §9):
- **DLSS offered and works:** continue.
- **DLSS offered but fails or crashes:** record the log lines. Try once without Metal 4, by removing `D3DM_MTL4=1` the same way as step 3, after asking. If it still fails, **stop and report**.
- **DLSS not offered:** check the log for whether `nvapi64.dll` and `nvngx.dll` loaded. **Stop and report** with what's missing (for example, the adapter not reporting NVIDIA's vendor ID). Don't build the toggles on a guess.

- [ ] **Step 5: Record the gate**

Create `docs/testing/acceptance-metalfx.md`:

```markdown
# MetalFX upscaling acceptance

Spec: `docs/superpowers/specs/2026-09-28-macneutron-metalfx-design.md`.

## Feasibility gate (plan task 1), <date>

- GPTK <version from `gptk.json`>, runtime runtime-v4.7.3, macOS <`sw_vers -productVersion`>.
- Wired by hand: runtime `nvngx.dll` + `nvngx.so`; SMITE 2 prefix stubs <added/kept per file>; launch options `/usr/bin/env MTL_HUD_ENABLED=1 MACNEUTRON_LOG=1 D3DM_ENABLE_METALFX=1 D3DM_MTL4=1 %command%`.
- DLSS offered in SMITE 2: <yes/no>. DLSS Quality: <works / fails: …>. Image vs before: <user's words>.
- Metal display with DLSS Quality: <FPS>, GPU time <ms>.
- Log: <nvapi64/nvngx load lines, summarised>.
- Decision: <continue / stop>.
```

Replace every `<…>` with what was observed. Nothing personal goes in.

- [ ] **Step 6: Commit**

```bash
git add docs/testing/acceptance-metalfx.md
git commit -m "test: MetalFX feasibility gate on SMITE 2

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Install the MetalFX bridge into the runtime

**Files:**
- Modify: `Sources/MacNeutronCore/ToolLayout.swift`, `Sources/MacNeutronCore/GPTKImporter.swift:95-106`, `Tests/MacNeutronCoreTests/Support.swift`, `Tests/MacNeutronCoreTests/GPTKImporterTests.swift`, `Tests/MacNeutronCoreTests/RuntimeInstallerTests.swift`

**Interfaces:**
- Produces:
  - `ToolLayout.metalFXBridgePE: URL` (`wine/x86_64-windows/nvngx.dll`), `metalFXBridgeUnix: URL` (`wine/x86_64-unix/nvngx.so`), `nvapiPE: URL` (`wine/x86_64-windows/nvapi64.dll`), `metalFXBridgeInstalled: Bool`;
  - `public static func GPTKImporter.installMetalFXBridge(layout: ToolLayout) throws`;
  - test helper `installFakeGPTKBridges(in: ToolLayout) throws`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/MacNeutronCoreTests/Support.swift`:

```swift
/// Marks GPTK as imported and puts Apple's MetalFX bridge (under Apple's file name), its NVAPI and the
/// shared dylib into the fake runtime, as the GPTK overlay leaves them.
func installFakeGPTKBridges(in layout: ToolLayout) throws {
    try write(#"{"version":"4.0","importedAt":"2026-09-28T00:00:00Z"}"#, to: layout.gptkManifest)
    try write("apple nvngx-on-metalfx", to: layout.wineLib.appending(path: "wine/x86_64-windows/nvngx-on-metalfx.dll"))
    try write("apple nvapi64", to: layout.nvapiPE)
    try write("apple libd3dshared", to: layout.wineLib.appending(path: "external/libd3dshared.dylib"))
}
```

In `Tests/MacNeutronCoreTests/GPTKImporterTests.swift`, change `makeGPTKVolume` to take `metalFX: Bool = false`:

```swift
private func makeGPTKVolume(version: String = "3.0", omit: String? = nil, metalFX: Bool = false) throws -> URL {
```

and add inside it, before `return volume`:

```swift
    if metalFX { try write("apple nvngx-on-metalfx", to: lib.appending(path: "wine/x86_64-windows/nvngx-on-metalfx.dll")) }
```

Then append:

```swift
@Test func metalFXBridgeIsInstalledUnderItsExportName() throws {
    let layout = try makeToolLayout()
    try installFakeGPTKBridges(in: layout)
    #expect(!layout.metalFXBridgeInstalled)
    try GPTKImporter.installMetalFXBridge(layout: layout)
    #expect(try String(contentsOf: layout.metalFXBridgePE, encoding: .utf8) == "apple nvngx-on-metalfx")
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: layout.metalFXBridgeUnix.path(percentEncoded: false))
        == "../../external/libd3dshared.dylib")
    #expect(layout.metalFXBridgeInstalled)
}

@Test func metalFXBridgeInstallIsIdempotent() throws {
    // Runs at every app start, and over files a user may have put there by hand.
    let layout = try makeToolLayout()
    try installFakeGPTKBridges(in: layout)
    try GPTKImporter.installMetalFXBridge(layout: layout)
    try GPTKImporter.installMetalFXBridge(layout: layout)
    #expect(layout.metalFXBridgeInstalled)
}

@Test func payloadWithoutBridgeInstallsNothing() throws {
    let layout = try makeToolLayout()
    try GPTKImporter.installMetalFXBridge(layout: layout)
    #expect(!layout.metalFXBridgeInstalled)
    #expect(!FileManager.default.fileExists(atPath: layout.metalFXBridgePE.path(percentEncoded: false)))
}

@Test func importInstallsTheMetalFXBridge() throws {
    let layout = try makeToolLayout()
    try GPTKImporter.importGPTK(from: try makeGPTKVolume(version: "4.0", metalFX: true), into: layout)
    #expect(layout.metalFXBridgeInstalled)
}
```

Append to `Tests/MacNeutronCoreTests/RuntimeInstallerTests.swift`:

```swift
@Test func runtimeReinstallKeepsTheMetalFXBridge() throws {
    let (tarball, pin) = try makeRuntimeTarball()
    let layout = try makeToolLayout()
    try write("apple nvngx-on-metalfx", to: layout.gptkStore.appending(path: "lib/wine/x86_64-windows/nvngx-on-metalfx.dll"))
    try write("apple libd3dshared", to: layout.gptkStore.appending(path: "lib/external/libd3dshared.dylib"))
    try RuntimeInstaller.install(tarball: tarball, pin: pin, layout: layout, launcherBinary: try makeEchoLauncher())
    #expect(layout.metalFXBridgeInstalled)
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift build --build-tests 2>&1 | grep error: | sort -u | head`
Expected: FAIL to compile: `value of type 'ToolLayout' has no member 'nvapiPE'` (and `metalFXBridgeInstalled`, `installMetalFXBridge`).

- [ ] **Step 3: Implement**

In `Sources/MacNeutronCore/ToolLayout.swift`, add after `steamBridgeInstalled`:

```swift
    /// Apple's DLSS→MetalFX bridge under its PE export name, which is what Wine's builtin loader matches,
    /// with its unix half. The GPTK payload ships it as `nvngx-on-metalfx.dll`.
    public var metalFXBridgePE: URL { wineLib.appending(path: "wine/x86_64-windows/nvngx.dll") }
    public var metalFXBridgeUnix: URL { wineLib.appending(path: "wine/x86_64-unix/nvngx.so") }
    /// Apple's NVAPI, which the GPTK overlay puts in place of Wine's placeholder.
    public var nvapiPE: URL { wineLib.appending(path: "wine/x86_64-windows/nvapi64.dll") }

    public var metalFXBridgeInstalled: Bool {
        [metalFXBridgePE, metalFXBridgeUnix]
            .allSatisfy { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }
```

In `Sources/MacNeutronCore/GPTKImporter.swift`, add at the end of `applyOverlay` (after the `for name in unixBridges` loop):

```swift
        try installMetalFXBridge(layout: layout)
```

and add this function after `applyOverlay`:

```swift
    /// Makes Apple's DLSS→MetalFX bridge reachable: copied under its export name, `nvngx.dll`, with its unix
    /// half linked to the shared dylib like the other bridges. A GPTK without the bridge leaves nothing to do.
    /// Idempotent: the app runs it at every start so runtimes imported before this existed get it.
    public static func installMetalFXBridge(layout: ToolLayout) throws {
        let fm = FileManager.default
        let source = layout.wineLib.appending(path: "wine/x86_64-windows/nvngx-on-metalfx.dll")
        guard fm.fileExists(atPath: source.path(percentEncoded: false)) else { return }
        try? fm.removeItem(at: layout.metalFXBridgePE)
        try fm.copyItem(at: source, to: layout.metalFXBridgePE)
        try fm.createDirectory(at: layout.metalFXBridgeUnix.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: layout.metalFXBridgeUnix)
        try fm.createSymbolicLink(atPath: layout.metalFXBridgeUnix.path(percentEncoded: false),
                                  withDestinationPath: "../../external/libd3dshared.dylib")
    }
```

- [ ] **Step 4: Run the tests**

Run: `swift test 2>&1 | grep -E "✘|Test run with"`
Expected: PASS: `Test run with 158 tests in 0 suites passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacNeutronCore/ToolLayout.swift Sources/MacNeutronCore/GPTKImporter.swift Tests/MacNeutronCoreTests
git commit -m "feat(gptk): install Apple's MetalFX bridge under its export name

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Per-game settings and the launch environment

**Files:**
- Modify: `Sources/MacNeutronCore/GameSettings.swift`, `Sources/MacNeutronCore/LaunchEnvironment.swift:9`, `Tests/MacNeutronCoreTests/GameSettingsTests.swift:5-10`, `Tests/MacNeutronCoreTests/LaunchEnvironmentTests.swift:10,28`

**Interfaces:**
- Produces:
  - `GameSettings.metalFX: Bool?`, `GameSettings.metal4: Bool?`, and init parameters `metalFX: Bool? = nil, metal4: Bool? = nil` added last;
  - launch variables `MACNEUTRON_NO_METALFX`, `MACNEUTRON_NO_METAL4`;
  - `LaunchEnvironment.build` output `D3DM_ENABLE_METALFX`, `D3DM_MTL4`, plus `nvapi64=d;nvngx=d` in `WINEDLLOVERRIDES` when MetalFX is off.

- [ ] **Step 1: Write the failing tests**

Replace `settingsBecomeLaunchVariables` in `Tests/MacNeutronCoreTests/GameSettingsTests.swift` with:

```swift
@Test func settingsBecomeLaunchVariables() {
    #expect(GameSettings(graphics: "dxmt", log: true, avx: false, msync: false, runAs: .windows,
                         metalFX: false, metal4: false).environment == [
        "MACNEUTRON_GRAPHICS": "dxmt", "MACNEUTRON_LOG": "1", "MACNEUTRON_NO_AVX": "1", "MACNEUTRON_NO_MSYNC": "1",
        "MACNEUTRON_NO_METALFX": "1", "MACNEUTRON_NO_METAL4": "1",
    ])
    #expect(GameSettings(log: false, avx: true, msync: true, metalFX: true, metal4: true).environment.isEmpty)
}
```

In `Tests/MacNeutronCoreTests/LaunchEnvironmentTests.swift`, change two existing expectations (DXMT now hides NVIDIA's DLLs):
- `setsPrefixOverridesAndDefaults`: `#expect(env["WINEDLLOVERRIDES"] == "dxgi=n,b;d3d10core=n,b;d3d11=n,b;d3d9=b;d3d10=b;d3d12=b;nvapi64=d;nvngx=d")`
- `userSettingsWin`: `#expect(env["WINEDLLOVERRIDES"] == "dxgi=n,b;d3d10core=n,b;d3d11=b;d3d9=b;d3d10=b;d3d12=b;nvapi64=d;nvngx=d;xinput1_3=n")`

Then append:

```swift
@Test func d3dmetalTurnsOnMetalFXAndMetal4ByDefault() {
    let env = LaunchEnvironment.build(base: [:], context: context, backend: .d3dmetal, logging: false)
    #expect(env["D3DM_ENABLE_METALFX"] == "1")
    #expect(env["D3DM_MTL4"] == "1")
    #expect(env["WINEDLLOVERRIDES"] == "dxgi=b;d3d9=b;d3d10=b;d3d10core=b;d3d11=b;d3d12=b")
}

@Test func metalFXOptOutHidesTheNvidiaDLLs() {
    let env = LaunchEnvironment.build(base: ["MACNEUTRON_NO_METALFX": "1"], context: context, backend: .d3dmetal, logging: false)
    #expect(env["D3DM_ENABLE_METALFX"] == nil)
    #expect(env["WINEDLLOVERRIDES"]?.hasSuffix(";nvapi64=d;nvngx=d") == true)
    #expect(env["D3DM_MTL4"] == "1")
}

@Test func metal4OptOutDropsTheVariable() {
    let env = LaunchEnvironment.build(base: ["MACNEUTRON_NO_METAL4": "1"], context: context, backend: .d3dmetal, logging: false)
    #expect(env["D3DM_MTL4"] == nil)
    #expect(env["D3DM_ENABLE_METALFX"] == "1")
}

@Test func otherBackendsNeverSeeNvidia() {
    for backend in [GraphicsBackend.dxmt, .dxvk] {
        let env = LaunchEnvironment.build(base: [:], context: context, backend: backend, logging: false)
        #expect(env["WINEDLLOVERRIDES"]?.hasSuffix(";nvapi64=d;nvngx=d") == true)
        #expect(env["D3DM_ENABLE_METALFX"] == nil)
        #expect(env["D3DM_MTL4"] == nil)
    }
}

@Test func userChoicesForTheBridgeWin() {
    let dxmt = LaunchEnvironment.build(base: ["WINEDLLOVERRIDES": "nvapi64=b"], context: context, backend: .dxmt, logging: false)
    #expect(dxmt["WINEDLLOVERRIDES"]?.contains("nvapi64=b") == true)
    let d3dm = LaunchEnvironment.build(base: ["D3DM_MTL4": "0", "D3DM_ENABLE_METALFX": "0"],
                                       context: context, backend: .d3dmetal, logging: false)
    #expect(d3dm["D3DM_MTL4"] == "0")
    #expect(d3dm["D3DM_ENABLE_METALFX"] == "0")
}

@Test func frameGenerationStaysUnreachable() {
    // DLSS frame generation through MetalFX hung WindowServer (macOS 27, D3DMetal 4.0b2; spec §2.4).
    let env = LaunchEnvironment.build(base: [:], context: context, backend: .d3dmetal, logging: false)
    #expect(env["CX_ACTIVE_GRAPHICS_BACKEND"] == nil)
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test 2>&1 | grep -E "error:|✘ Test [a-zA-Z]+\(\) failed" | sort -u | head`
Expected: FAIL to compile, with `extra arguments at positions #6, #7 in call` for `GameSettings(...)`.

- [ ] **Step 3: Implement**

In `Sources/MacNeutronCore/GameSettings.swift`:
- Add `public var metalFX: Bool?` and `public var metal4: Bool?` after `runAs`.
- Extend the init to `public init(graphics: String? = nil, log: Bool? = nil, avx: Bool? = nil, msync: Bool? = nil, runAs: RunAs? = nil, metalFX: Bool? = nil, metal4: Bool? = nil)`, assigning both.
- In `environment`, after the msync line, add:

```swift
        if metalFX == false { env["MACNEUTRON_NO_METALFX"] = "1" }
        if metal4 == false { env["MACNEUTRON_NO_METAL4"] = "1" }
```

In `Sources/MacNeutronCore/LaunchEnvironment.swift`, replace the line
`env["WINEDLLOVERRIDES"] = mergeOverrides(backend.dllOverrides, user: base["WINEDLLOVERRIDES"])` with:

```swift
        // Apple's DLSS→MetalFX bridge and its NVAPI work only under D3DMetal. Elsewhere, or when a game opts out,
        // the game must see a plain Apple GPU, not an NVIDIA one that nothing answers for.
        let metalFX = backend == .d3dmetal && base["MACNEUTRON_NO_METALFX"] != "1"
        env["WINEDLLOVERRIDES"] = mergeOverrides(backend.dllOverrides + (metalFX ? "" : ";nvapi64,nvngx=d"),
                                                 user: base["WINEDLLOVERRIDES"])
        if metalFX, base["D3DM_ENABLE_METALFX"] == nil { env["D3DM_ENABLE_METALFX"] = "1" }
        // D3DMetal reads this only for D3D12 devices on macOS versions with Metal 4, so it is inert elsewhere.
        if backend == .d3dmetal, base["MACNEUTRON_NO_METAL4"] != "1", base["D3DM_MTL4"] == nil {
            env["D3DM_MTL4"] = "1"
        }
        // Never CX_ACTIVE_GRAPHICS_BACKEND: it unlocks DLSS frame generation, which hung WindowServer (spec §2.4).
```

- [ ] **Step 4: Run the tests**

Run: `swift test 2>&1 | grep -E "✘|Test run with"`
Expected: PASS: `Test run with 164 tests in 0 suites passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacNeutronCore/GameSettings.swift Sources/MacNeutronCore/LaunchEnvironment.swift Tests/MacNeutronCoreTests
git commit -m "feat(core): per-game MetalFX and Metal 4 settings; hide NVIDIA's DLLs when off

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Prefix stubs and the launcher note

**Files:**
- Modify: `Sources/MacNeutronCore/PrefixManager.swift`, `Sources/MacNeutronCore/Launcher.swift`, `Tests/MacNeutronCoreTests/PrefixManagerTests.swift`, `Tests/MacNeutronCoreTests/LauncherTests.swift`

**Interfaces:**
- Consumes: `ToolLayout.metalFXBridgePE`, `nvapiPE`, `metalFXBridgeInstalled`, `GPTKImporter.installMetalFXBridge`, `installFakeGPTKBridges` (Task 2); `D3DM_ENABLE_METALFX` from `LaunchEnvironment` (Task 3).
- Produces: `PrefixError.metalFXCopyFailed(String)`; `makeFixture(... gptk: Bool = false)` in `LauncherTests`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/MacNeutronCoreTests/PrefixManagerTests.swift`:

```swift
private func makeD3DMetalManager() throws -> (PrefixManager, [String: String]) {
    let layout = try makeToolLayout()
    try installFakeGPTKBridges(in: layout)
    try GPTKImporter.installMetalFXBridge(layout: layout)
    let env = steamEnvironment(dataPath: try makeTempDir().appending(path: "compatdata/42"))
    let context = try CompatContext(environment: env)
    let wineEnv = LaunchEnvironment.build(base: env, context: context, backend: .d3dmetal, logging: false)
    return (PrefixManager(context: context, layout: layout, runtimeVersion: "runtime-test",
                          runner: winebootCreatingPrefix()), wineEnv)
}

private func system32(_ manager: PrefixManager, _ name: String) -> URL {
    manager.context.prefix.appending(path: "drive_c/windows/system32/\(name)")
}

private func metalFXOffEnvironment(_ manager: PrefixManager) -> [String: String] {
    var base = steamEnvironment(dataPath: manager.context.dataPath)
    base["MACNEUTRON_NO_METALFX"] = "1"
    return LaunchEnvironment.build(base: base, context: manager.context, backend: .d3dmetal, logging: false)
}

@Test func metalFXStubsGoIntoSystem32WhenOn() throws {
    let (manager, env) = try makeD3DMetalManager()
    try manager.prepare(backend: .d3dmetal, environment: env)
    #expect(try String(contentsOf: system32(manager, "nvngx.dll"), encoding: .utf8) == "apple nvngx-on-metalfx")
    #expect(try String(contentsOf: system32(manager, "nvapi64.dll"), encoding: .utf8) == "apple nvapi64")
}

@Test func existingStubsAreLeftAlone() throws {
    let (manager, env) = try makeD3DMetalManager()
    try write("wineboot stub", to: system32(manager, "nvngx.dll"))
    try manager.prepare(backend: .d3dmetal, environment: env)
    #expect(try String(contentsOf: system32(manager, "nvngx.dll"), encoding: .utf8) == "wineboot stub")
}

@Test func noStubsWhenMetalFXIsOff() throws {
    let (manager, _) = try makeD3DMetalManager()
    try manager.prepare(backend: .d3dmetal, environment: metalFXOffEnvironment(manager))
    #expect(!FileManager.default.fileExists(atPath: system32(manager, "nvngx.dll").path(percentEncoded: false)))
}

@Test func stubsAreAddedToAnUpToDatePrefix() throws {
    // SMITE 2's prefix predates the bridge: it must get the stubs without a runtime change.
    let (manager, env) = try makeD3DMetalManager()
    try manager.prepare(backend: .d3dmetal, environment: metalFXOffEnvironment(manager))
    try manager.prepare(backend: .d3dmetal, environment: env)
    #expect(FileManager.default.fileExists(atPath: system32(manager, "nvngx.dll").path(percentEncoded: false)))
}
```

In `Tests/MacNeutronCoreTests/LauncherTests.swift`, give `makeFixture` a `gptk: Bool = false` parameter after `bridge`, and add after the `if bridge { … }` line:

```swift
    if gptk { try installFakeGPTKBridges(in: layout) }
```

Then append:

```swift
@Test func missingMetalFXBridgeIsNoted() throws {
    let f = try makeFixture(gptk: true)
    _ = f.launcher.launch(["run", "/g/Game.exe"], environment: f.env)
    #expect(f.launcherLog.contains("note: this GPTK has no MetalFX bridge"))
    try GPTKImporter.installMetalFXBridge(layout: f.launcher.layout)
    let notes = f.launcherLog.components(separatedBy: "no MetalFX bridge").count
    _ = f.launcher.launch(["run", "/g/Game.exe"], environment: f.env)
    #expect(f.launcherLog.components(separatedBy: "no MetalFX bridge").count == notes)
}

@Test func dxvkSettingFallingBackToD3DMetalGetsMetalFX() throws {
    // With GPTK imported, a game set to DXVK runs on D3DMetal (GraphicsBackend.select), so MetalFX applies.
    let f = try makeFixture(gptk: true)
    var env = f.env
    env["MACNEUTRON_GRAPHICS"] = "dxvk"
    _ = f.launcher.launch(["run", "/g/Game.exe"], environment: env)
    #expect(f.runner.calls.last?.environment["D3DM_ENABLE_METALFX"] == "1")
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test 2>&1 | grep -E "✘ Test [a-zA-Z]+\(\) failed|error:|Test run with" | sort -u | head`
Expected: FAIL. `metalFXStubsGoIntoSystem32WhenOn` and `stubsAreAddedToAnUpToDatePrefix` fail (no stub files), and so does `missingMetalFXBridgeIsNoted` (no note). `existingStubsAreLeftAlone`, `noStubsWhenMetalFXIsOff` and `dxvkSettingFallingBackToD3DMetalGetsMetalFX` already pass: they pin behaviour this task must keep.

- [ ] **Step 3: Implement**

In `Sources/MacNeutronCore/PrefixManager.swift`:
1. Add the error case and its description:

```swift
    case metalFXCopyFailed(String)
```

```swift
        case .metalFXCopyFailed(let detail): "could not install the MetalFX bridge: \(detail)"
```

2. In `prepare`, after `try deployDLLs(for: backend)`, add:

```swift
            if environment["D3DM_ENABLE_METALFX"] == "1" { try deployMetalFXStubs() }
```

3. Add after `deploySteamBridge()`:

```swift
    /// `LoadLibrary("nvngx.dll")` only looks in Wine's builtin folder when system32 has an entry for it, and
    /// prefixes made before the bridge existed have none. Existing entries (wineboot's own) are left alone.
    func deployMetalFXStubs() throws {
        for source in [layout.metalFXBridgePE, layout.nvapiPE]
        where FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) {
            let destination = "drive_c/windows/system32/\(source.lastPathComponent)"
            guard !FileManager.default.fileExists(atPath: context.prefix.appending(path: destination).path(percentEncoded: false))
            else { continue }
            do { try install(source, at: destination) } catch {
                throw PrefixError.metalFXCopyFailed("\(destination): \(error.localizedDescription)")
            }
        }
    }
```

In `Sources/MacNeutronCore/Launcher.swift`, after the line `if steamBridge { addSteamClient(to: &env) }`, add:

```swift
        if request.verb == .run || request.verb == .waitforexitandrun,
           env["D3DM_ENABLE_METALFX"] == "1", !layout.metalFXBridgeInstalled {
            log.append("note: this GPTK has no MetalFX bridge")
        }
```

- [ ] **Step 4: Run the tests**

Run: `swift test 2>&1 | grep -E "✘|Test run with"`
Expected: PASS: `Test run with 170 tests in 0 suites passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacNeutronCore/PrefixManager.swift Sources/MacNeutronCore/Launcher.swift Tests/MacNeutronCoreTests
git commit -m "feat(prefix): system32 stubs for the MetalFX bridge; launcher notes a GPTK without it

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: App start, Games window toggles, README

**Files:**
- Modify: `Sources/MacNeutronApp/AppModel.swift:72-74`, `Sources/MacNeutronApp/GamesView.swift:55-61`, `README.md`, `Tests/MacNeutronCoreTests/AppModelTests.swift`

**Interfaces:**
- Consumes: `GPTKImporter.installMetalFXBridge`, `ToolLayout.gptkImported`, `GameSettings.metalFX` and `metal4`, `GraphicsBackend.select`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/MacNeutronCoreTests/AppModelTests.swift`:

```swift
@MainActor @Test func appStartInstallsTheMetalFXBridge() throws {
    let (mode, _) = try makeMode()
    let layout = try makeToolLayout()
    try installFakeGPTKBridges(in: layout)
    _ = AppModel(steam: mode.steam, layout: layout, mode: mode, store: GameSettingsStore(directory: try makeTempDir()),
                 loginItem: FakeLoginItem(statusAfterRegister: .enabled).item)
    #expect(layout.metalFXBridgeInstalled)
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `swift test --filter appStartInstallsTheMetalFXBridge 2>&1 | grep -E "Test run with|recorded an issue"`
Expected: FAIL: `Expectation failed: layout.metalFXBridgeInstalled`.

- [ ] **Step 3: Implement**

In `Sources/MacNeutronApp/AppModel.swift` `init`, after the `writeToolFiles` line, add:

```swift
        // Runtimes whose GPTK was imported before the MetalFX bridge was installed pick it up here.
        if layout.gptkImported { try? GPTKImporter.installMetalFXBridge(layout: layout) }
```

In `Sources/MacNeutronApp/GamesView.swift`, add after `Toggle("msync", …)`:

```swift
                    Toggle("MetalFX upscaling", isOn: binding(row, \.metalFX, default: true))
                        .disabled(!runsOnD3DMetal(row))
                        .help(runsOnD3DMetal(row)
                              ? "Games that offer DLSS upscale with Apple's MetalFX: pick DLSS in the game's settings."
                              : "Needs D3DMetal (import the Game Porting Toolkit)")
                    Toggle("Metal 4", isOn: binding(row, \.metal4, default: true))
                        .disabled(!runsOnD3DMetal(row))
                        .help(runsOnD3DMetal(row) ? "D3DMetal's Metal 4 backend, for DirectX 12 games."
                                                  : "Needs D3DMetal (import the Game Porting Toolkit)")
```

and add next to `binding(_:_:default:)`:

```swift
    /// The backend this game actually launches with: DXVK falls back to D3DMetal while GPTK is imported.
    private func runsOnD3DMetal(_ row: GameRow) -> Bool {
        GraphicsBackend.select(requested: row.settings.graphics, gptkImported: model.gptkVersion != nil).backend == .d3dmetal
    }
```

In `README.md`, add two rows to the launch-options table:

```markdown
| `/usr/bin/env MACNEUTRON_NO_METALFX=1 %command%` | No MetalFX upscaling through the game's DLSS option (the game then sees a plain Apple GPU) |
| `/usr/bin/env MACNEUTRON_NO_METAL4=1 %command%` | Don't use D3DMetal's Metal 4 backend |
```

and this section after "## Steam API":

```markdown
## Upscaling

With the Game Porting Toolkit imported, games that offer NVIDIA DLSS upscale with Apple's MetalFX: pick DLSS
(Quality, Balanced or Performance) in the game's graphics settings. Apple's D3DMetal answers the game's DLSS calls
with MetalFX. It's on for every game; switch "MetalFX upscaling" off for a game in the Games window if it
misbehaves. DLSS frame generation is never enabled.
```

- [ ] **Step 4: Run the tests and build the app**

Run: `swift test 2>&1 | grep -E "✘|Test run with"`
Expected: PASS: `Test run with 171 tests in 0 suites passed`.

Run: `make app 2>&1 | tail -1 && codesign --verify --deep --strict build/MacNeutron.app && echo signed`
Expected: `signed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacNeutronApp/AppModel.swift Sources/MacNeutronApp/GamesView.swift README.md Tests/MacNeutronCoreTests/AppModelTests.swift
git commit -m "feat(app): MetalFX and Metal 4 toggles per game; install the bridge at app start

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Acceptance on the maintainer's Mac

**Files:**
- Modify: `docs/testing/acceptance-metalfx.md`

**Interfaces:**
- Consumes: everything above; the user in chat for every Steam config change and every game session.

- [ ] **Step 1: Install the new build**

Run: `osascript -e 'quit app id "io.github.chadouming.MacNeutron"'; sleep 2; open build/MacNeutron.app; sleep 4`, then:
`T="$HOME/Library/Application Support/MacNeutron/compatibilitytools.d/macneutron"; cmp "$T/bin/macneutron" build/MacNeutron.app/Contents/Helpers/macneutron && ls -la "$T/Libraries/Wine/lib/wine/x86_64-unix/nvngx.so"`
Expected: no `cmp` output, and `nvngx.so -> ../../external/libd3dshared.dylib`.

- [ ] **Step 2: Hand the settings back to MacNeutron (ask first)**

The gate's launch options set `D3DM_*` by hand, and user variables win, so they would hide MacNeutron's own toggles. Ask the user: "OK to quit Steam and set SMITE 2's launch options back to `/usr/bin/env MTL_HUD_ENABLED=1 %command%` (backup first)?" After a yes, check that Steam is closed (`pgrep -x steam_osx` prints nothing), then run:
```bash
cd "$HOME/Library/Application Support/Steam/userdata"
F=$(for f in */config/localconfig.vdf; do grep -q '"2437170"' "$f" && echo "$f"; done | head -1)
cp -p "$F" "$F.before-metalfx-acceptance-$(date +%Y%m%d%H%M%S)"
python3 - "$F" <<'PY'
import re, sys, os
p = sys.argv[1]; t = open(p, encoding='utf-8').read()
block = re.compile(r'(\n\t{5}"2437170"\n\t{5}\{\n)(.*?)(\n\t{5}\})', re.S)
m = block.search(t); assert m, "SMITE 2 block not found"
body = re.sub(r'\t{6}"LaunchOptions"\t\t"[^"\n]*"\n?', '', m.group(2))
new = '\t\t\t\t\t\t"LaunchOptions"\t\t"/usr/bin/env MTL_HUD_ENABLED=1 %command%"\n' + body
t = t[:m.start()] + m.group(1) + new + m.group(3) + t[m.end():]
open(p + '.tmp', 'w', encoding='utf-8').write(t); os.replace(p + '.tmp', p)
PY
grep -A2 '^\t\t\t\t\t"2437170"' "$F" | grep LaunchOptions
```
Expected: one `LaunchOptions` line with `/usr/bin/env MTL_HUD_ENABLED=1 %command%`.

- [ ] **Step 3: Measurements (acceptance items 1–3)**

Ask the user to measure four configurations at the same spot in SMITE 2 (for example, standing in the practice area), switching the toggles in MacNeutron's Games window between runs. Each run is a fresh launch, with DLSS Quality chosen in-game whenever MetalFX is on:

| Run | MetalFX upscaling | Metal 4 | In-game upscaler |
|---|---|---|---|
| A | on | on | DLSS Quality |
| B | on | off | DLSS Quality |
| C | off | on | game default (DLSS should be missing: acceptance item 3) |
| D | off | off | game default |

For each run, ask for: FPS and GPU time from the Metal display; whether the frame-time graph is steady or spiky; how smooth and sharp it feels. Between runs, check `~/Library/Logs/MacNeutron/launcher.log` for `note: this GPTK has no MetalFX bridge`.
Expected: no such note; DLSS is present in A and B and missing in C and D.

- [ ] **Step 4: Regression checks (acceptance item 4)**

Confirm with the user: SMITE 2 still logs in (Steam bridge), and Timberborn still starts natively.

- [ ] **Step 5: Record and commit**

Append an `## Acceptance, <date>` section to `docs/testing/acceptance-metalfx.md`. It holds the four-run table with the observed numbers and impressions, the DLSS presence per run, and items 3–4. Leave no `<…>` placeholders and nothing personal.

```bash
git add docs/testing/acceptance-metalfx.md
git commit -m "docs: MetalFX and Metal 4 acceptance results

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
