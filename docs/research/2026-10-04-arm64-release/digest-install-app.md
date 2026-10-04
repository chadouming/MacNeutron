# SP5 interface digest: install, CLI, Steam Play mode, the app

Code at `69f0e4f` (main). Spec: `docs/superpowers/specs/2026-10-04-macneutron-arm64-release-design.md`. Read-only survey; the only
thing compiled was a throwaway `swiftc -typecheck` of a 15-line probe file in the scratchpad (Darwin API reachability, §D).

Layout: (A) the current code, file by file. (B) What has to change, per spec section. (C) Spec points the code makes awkward or
contradicts. (D) Darwin APIs and process enumeration.

---

## A. Current interfaces

### A.1 `Sources/MacNeutronCore/RuntimeInstaller.swift` (169 lines)

```swift
import CryptoKit
public struct RuntimePin: Equatable, Sendable {           // :5-16   DELETE
    public let version: String; public let url: URL; public let sha256: String
    public static let current = RuntimePin(version: "runtime-v4.7.3", url: …Libraries.tar.gz, sha256: "a4b5…fd331")
}
public enum RuntimeInstallError: Error, Equatable, CustomStringConvertible {   // :18-30
    case checksumMismatch(expected: String, actual: String)   // DELETE
    case extractFailed(Int32)                                  // DELETE
    case badArchive(String)                                    // DELETE
}
public enum RuntimeInstaller {                              // :33
    static let compatibilityTool: String                   // :34-49  KEEP (unchanged; "to_oslist" "linux")
    static let toolManifest: String                        // :50-57  CHANGE
    static let protonStub: String                          // :58-62  DELETE if R0b passes
    public static func sha256(of file: URL) throws -> String                         // :64-70   DELETE (only tarball user)
    public static func install(tarball: URL, pin: RuntimePin, layout: ToolLayout, launcherBinary: URL,
                               runner: any ProcessRunner = SystemProcessRunner()) throws   // :74-105 REPLACE
    public static func writeToolFiles(layout: ToolLayout, launcherBinary: URL) throws   // :110-133 CHANGE
    static func installFile(_ source: URL, at destination: URL) throws                  // :136-148 KEEP (reuse)
    public static func cachedDownload(_ pin: RuntimePin) async throws -> URL            // :151-160 DELETE
    public static func download(_ pin: RuntimePin, to destination: URL) async throws    // :163-168 DELETE
}
```

These are the exact current tool-file constants and writer:

```swift
    static let toolManifest = """
        "manifest"
        {
          "version" "2"
          "commandline" "/proton %verb%"
        }

        """
    static let protonStub = """
        #!/bin/sh
        exec "$(dirname "$0")/bin/macneutron" launch "$@"

        """

    public static func writeToolFiles(layout: ToolLayout, launcherBinary: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: layout.root, withIntermediateDirectories: true)
        try compatibilityTool.write(to: layout.root.appending(path: "compatibilitytool.vdf"), atomically: true, encoding: .utf8)
        try toolManifest.write(to: layout.root.appending(path: "toolmanifest.vdf"), atomically: true, encoding: .utf8)
        let stub = layout.root.appending(path: "proton")
        try protonStub.write(to: stub, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path(percentEncoded: false))
        try installFile(launcherBinary, at: layout.launcherBinary)
        // Next to the launcher, or in MacNeutron.app's Contents/Resources: steam.exe isn't Mach-O code,
        // so codesign won't accept it in Contents/Helpers.
        let helpers = launcherBinary.deletingLastPathComponent()
        let candidates = [helpers.appending(path: "steam.exe"),
                          helpers.deletingLastPathComponent().appending(path: "Resources/steam.exe")]
        if let steamExe = candidates.first(where: { fm.fileExists(atPath: $0.path(percentEncoded: false)) }) {
            try installFile(steamExe, at: layout.steamHelper)
        }
        // The presenter is Mach-O code, so in MacNeutron.app it lives in Contents/Frameworks.
        let presenters = [helpers.appending(path: "libmacneutron-present.dylib"),
                          helpers.deletingLastPathComponent().appending(path: "Frameworks/libmacneutron-present.dylib")]
        if let presenter = presenters.first(where: { fm.fileExists(atPath: $0.path(percentEncoded: false)) }) {
            try installFile(presenter, at: layout.presenterLibrary)
        }
    }
```

`installFile` (:136-148): it returns early when the source and destination resolve to the same file, and when the bytes are
equal (it reads both files whole into `Data`). Otherwise it copies to `<dest>.new` and then calls `rename(2)`. Nothing else in
the code uses `renamex_np`.

Today's `install(tarball:…)` (:74-105) runs these steps in order: sha256 check → `tar -xzf` into `runtime.staging` (through
`runner`) → checks that `Libraries/Wine/bin/{wine,wineserver}` are executable → removes `dxmt-version` and `Libraries` →
moves `Libraries` into place → `writeToolFiles` → writes `runtime-version` → `GPTKImporter.applyOverlay` if `gptk/` exists →
`DXMTInstaller.installBundled`.

### A.2 `ToolLayout.swift` (cross-reference only; another digest covers it)

`ToolLayout(root:)` and `ToolLayout(executable:)` (:7, :10-12; the executable's folder two levels up, symlinks resolved).
`static var defaultRoot` (:14-18). It has these Rosetta-era members: `libraries`, `wineLib`, `wine`, `wineserver`, `dxmt`,
`dxvk`, `gptkStore`, `gptkManifest`, `runtimeVersionFile`, `dxmtVersionFile`/`dxmtVersion`, `dxmtD3D12`/`dxmtHasD3D12`,
`dxmtReplay`, `lsteamclient{Unix,64,32}`, `runtimeVersion`, `gptkVersion`, `gptkImported`. These stay:
`launcherBinary` (`bin/macneutron`) and `steamHelper` (`bin/steam.exe`). The member `presenterLibrary`
(`lib/libmacneutron-present.dylib`) goes, because the presenter moves into `wine.app` (spec §5.3).

My area needs the following new members, named in the code's style:
- `wineApp` (`root/wine.app`)
- `wineAppNew` and `wineAppOld` (`wine.app.new`, `wine.app.old`)
- `damagedMarker` (`root/runtime-damaged`)
- `runtimeVersion: String?`, read from `wine.app/Contents/Info.plist` `CFBundleShortVersionString`
- `runtimeIdentity: String?`, the loader's CDHash
- `static let rosettaEraEntries = ["Libraries", "gptk", "gptk.json", "lib", "dxmt-version", "runtime-version", "runtime.staging", "gptk.staging"]`

`gptk.staging` is not in the spec's list (see C.9).

### A.3 `DXMTInstaller.swift`, `GPTKDiskImage.swift`, `GPTKImporter.swift`: delete all three files whole

- `DXMTInstaller.swift` (95 lines) declares:
  - `public enum DXMTInstallError { notABuild(String), noRuntime(String) }`
  - `public struct DXMTBuild: Equatable, Sendable`, with `init?(windows:unix:)`, `init?(folder:)`,
    `static func bundled(near launcherBinary: URL) -> DXMTBuild?` and `var version: String`
  - `public enum DXMTInstaller`, with `static let frontEnds`, `static func install(layout:from:) throws` and
    `@discardableResult static func installBundled(layout:launcherBinary:) throws -> Bool`
- `GPTKDiskImage.swift` (89 lines) declares:
  - `public enum GPTKDiskImageError { attachFailed(String), noRedist }`
  - `public enum GPTKDiskImage`, with `importGPTK(from:into:) throws -> GPTKManifest` and the internal `mount`, `mountPoint`,
    `attach`, `detach` (it runs `hdiutil` through a direct `Process`)
- `GPTKImporter.swift` (115 lines) declares:
  - `public enum GPTKImportError`
  - `public struct GPTKManifest: Codable`
  - `public enum GPTKImporter`, with `requiredFiles`, `unixBridges`, `locateLib(from:)`, `validate(lib:) throws(GPTKImportError)`,
    `frameworkVersion`, `importGPTK(from:into:runner:)`, `applyOverlay(layout:runner:)` and `ditto`

Callers outside these three files:
- `RuntimeInstaller.swift:102,104`
- `CommandLineTool.swift:25,48-51`
- `AppModel.swift:76,151-155`
- `Tests/MacNeutronCoreTests/Support.swift:129-143`: `makeDXMTBuild`, used by RuntimeInstallerTests:159, CommandLineToolTests:44
  and DXMTInstallerTests

### A.4 `CommandLineTool.swift` (100 lines)

```swift
public enum CommandLineTool {
    public static let usage = """
        usage: macneutron launch <verb> <target> [args...]
               macneutron import-gptk [--tool-dir <dir>] <GPTK volume | redist | redist/lib>
               macneutron install-runtime [--tool-dir <dir>] [--tarball <Libraries.tar.gz>]
               macneutron install-dxmt [--tool-dir <dir>] <build/dxmt>
        """                                                                                      // :6-11
    public static func run(_ args: [String], environment: [String: String], executable: URL) async -> Int32  // :13-60
    static func option(_ name: String, in args: inout [String]) -> String?   // :63-68 removes "--name value"; a bare flag returns nil
    static func toolLayout(_ dir: String?) -> ToolLayout                     // :70-72 (defaults to ToolLayout.defaultRoot)
    nonisolated(unsafe) private static var signalSources: [any DispatchSourceSignal]   // :75
    static func installTerminationHandlers(_ launcher: Launcher, environment: [String: String])  // :78-89 SIGTERM/SIGINT
    private static func usageError() -> Int32   // :91-94 prints usage, returns 2
    private static func failure(_ error: any Error) -> Int32   // :96-99 "macneutron: <error>", returns 1
}
```

The switch in `run`:
- `"launch"` (:17-20) runs `Launcher(layout: ToolLayout(executable: executable))`, then `installTerminationHandlers`, then
  `launcher.launch(rest, environment:)`.
- `"import-gptk"` (:21-30) is deleted.
- `"install-runtime"` (:31-43) is deleted.
- `"install-dxmt"` (:44-56) is deleted.
- `default` (:57) calls `usageError()`.

`Sources/macneutron/main.swift` (7 lines) is:
`let executable = Bundle.main.executableURL ?? URL(filePath: CommandLine.arguments[0]); exit(await CommandLineTool.run(Array(CommandLine.arguments.dropFirst()), environment: ProcessInfo.processInfo.environment, executable: executable))`.

### A.5 `SteamPlayMode.swift` (292 lines)

```swift
public enum SteamPlayStatus: Equatable, Sendable { case off, on, restartNeeded(Int), lost, problem(String) }   // :3-10
public struct SteamPlayMode: Sendable {                                       // :15
    public static let runtimeToolName = MappingPlanner.runtimeTool            // "macneutron"
    public static let nativeToolName = MappingPlanner.nativeTool              // "macneutron-native"
    public static let devConfig = "@sSteamCmdForcePlatformType linux\n"
    static let passthroughScript: String                                      // :24-35  DELETE if R0b passes
    public let steam: SteamLocation; public let tools: URL; public let backups: URL; public let intentFile: URL
    public let process: any SteamControlling
    public var verifyTimeout: Duration = .seconds(60); public var quitTimeout: Duration = .seconds(30)
    public var rosettaAvailable: @Sendable () -> Bool = { Preflight().rosettaAvailable() }   // :44 DELETE
    public init(steam: SteamLocation = SteamLocation(), root: URL = MacNeutronPaths.root,
                process: any SteamControlling = SteamProcess())               // :46-53
    var runtimeTool: URL; var nativeTool: URL; func link(_ name: String) -> URL   // :55-57
    public var isWanted: Bool; public var filesIntact: Bool                   // :60, :63-67
    public func status(plan: [String: ToolMapping]) -> SteamPlayStatus        // :69-82
    public func enable(plan:) async throws                                    // :86-88
    public func enable(planAfterQuit makePlan: () throws -> [String: ToolMapping]) async throws   // :91-120
    public func disable() async throws                                        // :122-129
    @discardableResult public func sync(plan:) throws -> Bool                 // :135-141
    public func pendingChanges(plan:) throws -> Int; public func currentMappings() throws -> [String: ToolMapping]
    static let mappingPath; public func applyMappings(_:) throws; func readConfig() throws -> [KVNode]
    @discardableResult func backupConfig() throws -> URL?
    public func installNativeTool() throws                                    // :198-220 CHANGE
    func linkTools() throws; func unlinkTools()                               // :222-234
    private func rollBack(restoring:) async; private func waitForVerification(after:head:) async -> String?
    static func verify(log: String) -> String?; static func lastSession(of log: String) -> String
}
```

The Rosetta check is `SteamPlayMode.swift:93`: `guard rosettaAvailable() else { throw SteamPlayError.rosettaMissing }`.
`SteamPlayError.rosettaMissing` and its message are at `SteamLocation.swift:89,98`.

This is the exact current passthrough script and native-tool writer:

```swift
    static let passthroughScript = """
        #!/bin/sh
        shift
        target=$1
        shift
        if [ -d "$target" ] && [ -f "$target/Contents/Info.plist" ]; then
            name=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$target/Contents/Info.plist" 2>/dev/null) || name=$(basename "$target" .app)
            target="$target/Contents/MacOS/$name"
        fi
        exec /usr/bin/arch -arm64e -arm64 -x86_64 "$target" "$@"

        """
    public func installNativeTool() throws {
        try write(<compatibilitytool.vdf: "macneutron-native", display_name "macOS native", from_oslist "macos", to_oslist "linux">,
                  to: nativeTool.appending(path: "compatibilitytool.vdf"))
        try write("\"manifest\"\n{\n  \"version\" \"2\"\n  \"commandline\" \"/passthrough.sh %verb%\"\n}\n",
                  to: nativeTool.appending(path: "toolmanifest.vdf"))
        let script = nativeTool.appending(path: "passthrough.sh")
        try write(Self.passthroughScript, to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path(percentEncoded: false))
    }
```

`installNativeTool()` is called from two places: `SteamPlayMode.swift:102` (inside `enable`) and `AppModel.swift:72`
(`if mode.isWanted { try? mode.installNativeTool() }`).

### A.6 `MappingPlanner.swift`, `SteamLocation.swift`, `SteamWatcher.swift`, `AppInfoReader.swift`: unchanged by SP5, except `rosettaMissing`

- `MappingPlanner` has `runtimeTool = "macneutron"`, `nativeTool = "macneutron-native"`, `mappableTypes`, `appPriority = 250`,
  `globalPriority = 75`, `plan(apps:runAs:)`, `current(in:)`, `claimedByOtherTools(in:)`, `merged(_:with:)` and
  `isOurs(_:)` (`hasPrefix("macneutron")`, so the R0b test tool `macneutron-r0b` would count as ours; see C.11).
  `public struct ToolMapping`, `public enum RunAs: String, Codable { mac, windows }`.
- `SteamLocation.swift`:
  - `MacNeutronPaths.{root, tools, games, backups}` (:4-12)
  - `SteamLocation` (:15-80), with `bundleMacOS`, `bundleCompatTools`, `steamDevConfig`, `configVDF`, `compatLog`, `appInfo`,
    `loginUsers`, `isInstalled`, `libraries()`, `installedAppIDs()`, `activeAccountID()` and `samePath`
  - `SteamPlayError` (:82-103), cases `steamNotInstalled, steamRunning, quitTimedOut, configUnreadable(String),
    verificationFailed(String), planDropsMacGames(Int), rosettaMissing`. **Delete `rosettaMissing`** (:89, :98).
  - `protocol SteamControlling: Sendable { isRunning() -> Bool; quit(timeout:) async throws; launch() throws }` (:106-110)
  - `SteamProcess` (:112-135). Its `isRunning` = `pgrep -x steam_osx` (:116); `quit` = `open steam://exit`, then a poll;
    `launch` = `open -a Steam`.
- `SteamWatcher` (15 lines) has `mutating func observe(running: Bool) -> Event?` with `Event { launched, quit }`.
- `AppInfoReader` has `AppInfo {appID, name, type, oslist}`, `AppInfoError` and
  `read(_:) throws -> [AppInfo]` / `parse(_:) throws(AppInfoError)` (format v29).

### A.7 `Sources/MacNeutronApp/`

**`AppModel.swift`** (302 lines):

- `struct GameRow` (:7-16) has `app`, `installed`, `var settings: GameSettings`, `id`, `name`, `isDualPlatform` and
  `runsWithMacNeutron`.
- `struct LoginItem: Sendable` (:19-23) holds three `@Sendable` closures (`status`, `register`, `unregister`). It is the
  existing test-seam pattern.
- `struct Snapshot: Sendable` (:27-36) has `runtimeVersion: String?`, `gptkVersion: String?`, `apps`, `appInfoError`,
  `installed`, `settings`, `orphans` and `status`.
- `@Observable @MainActor final class AppModel` (:39-276):
  - `let steam: SteamLocation; let layout: ToolLayout; let mode: SteamPlayMode; let store: GameSettingsStore; let loginItem: LoginItem`
  - `private(set) var runtimeVersion: String?` (:47), `private(set) var gptkVersion: String?` (:48), `status`, `games`,
    `orphans`, `appInfoError`, `loginItemStatus`, `var busy: String?`, `var errorMessage: String?`
  - `private var apps`, `watcher = SteamWatcher()`, `pollTask: Task<Void, Never>?`, `private(set) var generation = 0`
  - **init** (:63-83), exact:

    ```swift
    init(steam: SteamLocation = SteamLocation(), layout: ToolLayout = ToolLayout(root: ToolLayout.defaultRoot),
         mode: SteamPlayMode = SteamPlayMode(), store: GameSettingsStore = GameSettingsStore(),
         loginItem: LoginItem = LoginItem()) {
        self.steam = steam; self.layout = layout; self.mode = mode; self.store = store; self.loginItem = loginItem
        // Keep the passthrough script current across app updates (it's only rewritten here and on enable).
        if mode.isWanted { try? mode.installNativeTool() }
        // An updated app brings a new launcher, steam.exe and DXMT: install them without a runtime reinstall.
        if layout.runtimeVersion != nil {
            try? RuntimeInstaller.writeToolFiles(layout: layout, launcherBinary: helper)
            _ = try? DXMTInstaller.installBundled(layout: layout, launcherBinary: helper)
        }
        // Read now, not in the first refresh: the scene decides at launch whether to open the setup window.
        runtimeVersion = layout.runtimeVersion
        gptkVersion = layout.gptkVersion
        Task { await refresh() }
        startWatchingSteam()
    }
    ```

  - `var setupComplete: Bool { runtimeVersion != nil && mode.isWanted }` (:85)
  - `var steamInstalled: Bool { steam.isInstalled }` (:86)
  - `var helper: URL` (:89-95) is `<exe>/../../Helpers/macneutron` when that file exists, else `<exe dir>/macneutron`
  - `func refresh() async` (:97-104), with a detached `loadSnapshot`
  - `func apply(_ snapshot: Snapshot, generation mine: Int)` (:107-121)
  - `nonisolated static func loadSnapshot(steam:layout:store:mode:fallbackApps:) -> Snapshot` (:125-134)
  - `func plan() -> [String: ToolMapping]` (:136-138)
  - **`func installRuntime() async`** (:142-149), exact:

    ```swift
    func installRuntime() async {
        await run("Downloading and installing the runtime (461 MB, first time only)…") { [layout, helper] in
            let tarball = try await RuntimeInstaller.cachedDownload(.current)
            try await Task.detached {
                try RuntimeInstaller.install(tarball: tarball, pin: .current, layout: layout, launcherBinary: helper)
            }.value
        }
    }
    ```

  - `func importGPTK(from dmg: URL) async` (:151-155) is deleted.
  - `func enableSteamPlay() async` (:157-171), `disableSteamPlay()` (:173-175), `restartSteam()` (:178-189),
    `update(_:_:) async` (:195-214), `cleanUp(_:) async` (:216-220), `launchesAtLogin` and `setLaunchAtLogin(_:)` (:225-234)
  - `private func run(_ message: String, _ work: @escaping () async throws -> Void) async` (:238-245). It guards
    `busy == nil` ("one Steam-changing action at a time"), sets `busy`, clears `errorMessage`, runs `work`, then refreshes.
  - **Poll loop** `private func startWatchingSteam()` (:250-275), exact:

    ```swift
    private func startWatchingSteam() {
        pollTask = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                ticks += 1
                guard let self else { return }
                if ticks % 20 == 0, self.busy == nil { await self.refresh() }
                let mode = self.mode
                let running = await Task.detached { mode.process.isRunning() }.value
                switch self.watcher.observe(running: running) {
                case .quit?:
                    await self.refresh()  // Steam rewrites its app list on exit
                    if self.busy == nil, self.appInfoError == nil {
                        do { try self.mode.sync(plan: self.plan()) } catch { self.errorMessage = "\(error)" }
                        await self.refresh()
                    }
                case .launched?:
                    try? await Task.sleep(for: .seconds(20))
                    await self.refresh()
                case nil:
                    break
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
    ```

- `struct AppInfoUnreadable` (:278-281); `extension SteamPlayStatus { menuTitle, symbol }` (:283-302).

**`MacNeutronApp.swift`** (56 lines): `@main struct MacNeutronApp: App` has `@State private var model = AppModel()`. Its scenes:
- `MenuBarExtra` with `MenuContent`
- `Window("Set up MacNeutron", id: "setup")`, with `.defaultLaunchBehavior(model.setupComplete ? .suppressed : .presented)` (:24)
- `Window("Games", id: "games")`
- `Window("Free up space", id: "cleanup")`
- `Settings`

It also defines `@MainActor func show(_:with:)` and `@MainActor func raiseWindows()`.

**`MenuContent.swift`** (46 lines). The status line is :11:
`Text("Runtime \(model.runtimeVersion ?? "not installed") · D3DMetal \(model.gptkVersion ?? "not imported")")`.
The menu also shows `model.status.menuTitle` (:10) and `busy`/`error` (:12-16), the Restart and Restore buttons (:17-24), and
"Finish setup…" when `!model.setupComplete` (:26-28). Further items: Games…, Open Steam, Free up space, Show logs, Settings…
and Quit.

**`SettingsView.swift`** (76 lines). **Repair runtime** is :19-21:
`LabeledContent("Runtime") { Button("Repair runtime") { Task { await model.installRuntime() } } }`.
The rest of the file: "Run setup again" (:22-24), "Turn off Steam Play mode" (:25-28), and the busy/error rows (:29-30).
`.disabled(model.busy != nil)` is :34. `CleanupView` is :43-76.

**`SetupView.swift`** (99 lines):
- `@State private var choosingDMG` (:8)
- `nativeGames` and `windowsGames` (:10-11)
- Steps:
  1. "Install runtime" (:17-20). `done: model.runtimeVersion != nil`. Detail is `"Wine \($0) installed"`, or
     "Downloads the Wine runtime (461 MB)." Button "Install" or "Reinstall" calls `installRuntime()`.
  2. "Import Game Porting Toolkit (optional)" (:22-31), with `.dropDestination` for a `.dmg`. Delete it.
  3. "Turn on Steam Play mode" (:33-38). `.disabled(model.runtimeVersion == nil || !model.steamInstalled)`.
- The native and Windows games grid (:39-53)
- busy, error and "Install Steam for Mac first." (:55-57)
- `.disabled(model.busy != nil)` (:61)
- `.fileImporter(... [.diskImage])` (:62-64). Delete it.
- `.onAppear { refresh; raiseWindows }`
- `private struct Step<Action: View>(done:title:detail:action:)` (:78-98)

The file imports `UniformTypeIdentifiers` only for `.diskImage`, so that import can go.

**`GamesView.swift`** (94 lines). The table has three columns: "Game" (:16-21), "Runs as" (:22-34) and "Graphics" (:35-49).
The Graphics picker is
`Text("Default (DXMT)").tag("")`, `Text("D3DMetal").tag("d3dmetal")`, `Text("DXMT").tag("dxmt")`,
`Text(model.gptkVersion == nil ? "DXVK" : "DXVK (falls back to D3DMetal while GPTK is imported)").tag("dxvk")` (:40-43).
Under the table, a detail row for the selected row has toggles: Log (:54), **AVX (:55, `binding(row, \.avx, default: true)`)**,
msync (:56) and MetalFX (:57-58). The helper is `binding(_:_:default:)` (:90-93).

### A.8 `Package.swift`, `App/Info.plist`, Makefile

- `Package.swift:1` is `// swift-tools-version: 6.0`, and `:6` is `platforms: [.macOS("26.0")]`. The products are
  `macneutron` (exe), `MacNeutronApp` (exe) and `MacNeutronCore` (lib). The test target `MacNeutronCoreTests` depends on
  `["MacNeutronCore", "MacNeutronApp"]` (:16).
- `App/Info.plist`:
  - `CFBundleIdentifier io.github.chadouming.MacNeutron`
  - `CFBundleExecutable MacNeutron`
  - `CFBundleShortVersionString 0.1.0`
  - `CFBundleVersion 1`
  - `LSMinimumSystemVersion 26.0` (:12)
  - `LSUIElement true`
- Makefile:
  - `build:` is `swift build -c release` (:12-13). `test:` is `swift test` (:15-16).
  - `app: build bridge presenter dxmt` (:86-104). It copies `.build/release/MacNeutronApp` → `Contents/MacOS/MacNeutron`,
    `.build/release/macneutron` → `Contents/Helpers/macneutron` (ad-hoc signed), and `$(BRIDGE)/steam.exe` →
    `Contents/Resources/steam.exe`. It copies the presenter → `Contents/Frameworks/` (:95-97), runs `dxmt/published.sh` (:98),
    and copies DXMT → `Contents/Resources/DXMT` + `Contents/Frameworks/DXMT` (:99-103). It ends with `codesign --force --sign - $(APP)` (:104).
- Already today, `.build/release/macneutron` and the installed `bin/macneutron` are **thin arm64** (checked with `lipo -archs`).
  `swift build` builds the host architecture only, so `--arch arm64` only makes it explicit. Note: with `--arch`, SwiftPM puts
  products under `.build/arm64-apple-macosx/release`, so the Makefile should read `swift build --show-bin-path` rather than
  hard-coding `.build/release`. I haven't verified this.

### A.9 Tests (Swift Testing `@Test func` names)

**RuntimeInstallerTests.swift** (188 lines). Helpers: `private makeRuntimeTarball(includeWineserver:) -> (URL, RuntimePin)`
(:6-19) and `private makeEchoLauncher() -> URL` (:22-26).

| Test (line) | Fate |
|---|---|
| `installsRuntimeAndToolFiles` :28 | rewrite (new install; manifest `/bin/macneutron launch %verb%`; no `proton`) |
| `protonStubForwardsArgumentsFromAPathWithSpaces` :45 | delete (R0b passes) or keep (fallback) |
| `checksumMismatchChangesNothing` :57 | delete |
| `archiveWithoutWineserverKeepsOldRuntime` :67 | delete (replace: "codesign failure keeps the old copy") |
| `reinstallReappliesImportedGPTK` :77 | delete |
| `installPutsSteamExeNextToTheLauncher` :86 | keep, call the new install/writeToolFiles |
| `toolFilesRefreshReplacesAChangedLauncher` :95 | keep |
| `identicalToolFilesAreLeftAlone` :105 | keep |
| `installFindsSteamExeInTheAppsResources` :120 | keep |
| `installPutsThePresenterInTheToolFolder` :132 | delete (presenter now in wine.app) |
| `installFindsThePresenterInTheAppsFrameworks` :142 | delete |
| `reinstallAppliesTheBundledDXMTAfterGPTK` :153 | delete |
| `reinstallWithoutABundledDXMTForgetsTheOldOne` :166 | delete |
| `aSwapThatFailsDoesNotLeaveDXMTVersionClaimingOurs` :175 | delete |

**CommandLineToolTests.swift** (50 lines):

| Test | Fate |
|---|---|
| `unknownCommandPrintsUsage` :5 | keep |
| `optionParsingRemovesTheFlagAndValue` :10 | keep (fixture uses "/Volumes/GPTK" and "--tarball" as strings only; cosmetic) |
| `importGPTKRejectsANonGPTKFolder` :17 | delete |
| `installRuntimeRejectsAWrongTarball` :24 | delete (replace: `install` rejects a non-`wine.app` / missing `--wine-app`) |
| `installDXMTRejectsAFolderThatIsNotABuild` :34 | delete |
| `installDXMTInstallsABuild` :41 | delete |

**SteamPlayModeTests.swift** (263 lines). The helper `func makeMode(session:config:running:) -> (SteamPlayMode, FakeSteam)` (:5-14)
sets `mode.rosettaAvailable = { true }` at :12, and that line must be deleted. The tests:
- `enableWritesEverythingAndVerifies` :24
- `failedVerificationRollsBackWithDevConfigRemovedFirst` :35
- `unreadableConfigChangesNothing` :48
- `mappingsAreNeverWrittenWhileSteamRuns` :56
- `everyWriteIsBackedUpFirst` :61
- `syncOnlyWritesWhenThePlanChanged` :71
- `statusShowsPendingChangesAndLostFiles` :82
- `disableRemovesOnlyWhatEnableAdded` :94
- **`passthroughRunsTheMacGameItself` :106** (runs `passthrough.sh` through `SystemProcessRunner`): rewrite
- `verifiesCompatLogSessions` (parameterised, :117-125)
- `lastSessionIgnoresEarlierRuns` :127
- **`passthroughLaunchesAppBundles` :133**: rewrite (target resolution)
- **`passthroughPrefersTheAppleSiliconBuild` :149-161** (`.enabled(if:` Rosetta runtime exists `)`, `arch -x86_64 /bin/sh passthrough.sh … uname -m`): rewrite or delete
- `syncRefusesToDropMacGameProtection` :163
- `enableBuildsThePlanAfterSteamHasQuit` :174
- `intentIsRecordedBeforeSteamStartsInLinuxMode` :186
- `appsMappedToAnotherToolDontCountAsPending` :197
- `unreadableConfigLeavesSteamRunning` :207
- `failureBeforeLaunchRestartsSteamInMacMode` :214
- **`enableRequiresRosetta` :223**: delete
- `verificationHandlesACompatLogThatStartsOver` :230 (sets `rosettaAvailable` :237): delete that line
- `verificationHandlesAStartedOverLogThatOutgrewTheOldOne` :242 (sets `rosettaAvailable` :249): delete that line
- `statusReportsAnUnreadableConfig` :254

`FakeSteam.swift:19-27`: `makeFakeSteam(config:)` writes only `compatibilitytools.d/macneutron/toolmanifest.vdf`. If
`installNativeTool` starts copying `macneutron/bin/macneutron`, then this fixture must also write a fake `bin/macneutron`, or
every `enable` test fails.

**AppModelTests.swift** (113 lines). The helpers are `final class FakeLoginItem` (:12-22) and
`@MainActor private func makeModel(steamRunning:loginItem:) async throws -> (AppModel, SteamPlayMode, FakeSteam)` (:24-38),
which calls `AppModel(steam:layout: makeToolLayout() ...)`. The tests:
- `runsAsChangeAppliesImmediatelyWhenSteamIsClosed` :40
- `runsAsChangeWaitsForARestartWhileSteamRuns` :47
- `refreshKeepsTheLastGoodAppListWhenSteamsCacheIsUnreadable` :54
- `snapshotsLoadOffTheMainActor` :62 (calls `AppModel.loadSnapshot(...)`)
- `loginToggleReportsWhenMacOSWantsApproval` :75
- **`turningOnWithoutRosettaLeavesSteamRunning` :83**: delete (`mode.rosettaAvailable = { false }`)
- **`setupWindowStaysClosedOnceSetUp` :97**: rewrite (it writes `runtime-v4.7.3` to `runtimeVersionFile`; it must make a fake `wine.app` instead)
- `aSnapshotReadBeforeAChangeDoesNotUndoIt` :105

**DXMTInstallerTests.swift** (114 lines, delete the file):
- `installsBothHalvesAndTheFrontEnds` :8
- `dxmtPathsInTheToolFolder` :23
- `aFailedInstallLeavesNoVersionSoTheNextStartRetries` :31
- `anIncompleteBuildIsNotABuild` :41
- `anIncompleteBundleInstallsNothing` :48
- `refusesAToolFolderWithoutARuntime` :58
- `findsTheBuildNextToTheLauncher` :67
- `findsTheAppBundlesTwoHalves` :74
- `noBuildNearTheLauncherInstallsNothing` :83
- `theBundledBuildIsInstalledOncePerVersion` :89
- `installsTheReplayerBesideD3D12` :101
- `aBuildWithoutTheReplayerIsRefused` :109

**GPTKDiskImageTests.swift** (53 lines, delete the file): `importsFromTheNestedEvaluationImage` :32,
`leavesAnImageTheUserAlreadyOpenedMounted` :39, `rejectsImagesWithoutGPTK` :47.

**GPTKImporterTests.swift** (67 lines, delete the file): `findsLibFromVolumeRedistOrLib` :22, `importOverlaysWineAndRecordsVersion` :31,
`incompleteRedistIsRejectedBeforeCopying` :44, `unreadableVersionIsRejected` :54, `reimportReplacesTheStore` :62.

**PathsTests.swift** (51 lines):
- `readsSteamCompatEnvironment` :5, `appIDDefaultsToZero` :17 and `missingDataPathIsAnError` :22: keep.
- **`layoutPathsFollowTheRuntimeTarball` :28**: rewrite as `layoutPathsFollowWineApp` (wine = `wine.app/Contents/MacOS/wine`, …).
- `layoutFromExecutableIsTwoLevelsUp` :37: keep.
- **`runtimeAndGPTKVersionsComeFromFiles` :42**: rewrite (version from `wine.app`'s Info.plist; no GPTK).

**Support.swift** (143 lines):
- `makeTempDir()` (:24) and `write(_:to:executable:)` (:31): keep.
- `FakeRunner` (:40-61) and `winebootCreatingPrefix` (:64-73): keep.
- `makeToolLayout()` (:76-91) builds a **Rosetta tree**: `Libraries/Wine/bin/{wine,wineserver}`, `DXMT/{x64,x32}`, `DXVK`
  and `runtime-version`. It must become a fake `wine.app` tree.
- `installFakeSteamBridge(in:i386:)` (:117-122) drops the `i386` parameter.
- `installFakePresenter(in:)` (:125-127) is deleted.
- `makeDXMTBuild` (:129-143) is deleted.
- `loginUser` / `loginUsersFile` (:106-114) are untouched by SP5 and hold a SteamID-shaped fixture; they are not reproduced here.

Other users of `makeToolLayout()`, outside my area but affected by the fixture change: LauncherTests:23, PrefixManagerTests:6,
SteamBridgeTests:45, ShaderPrecacheTests:21,159, LaunchEnvironmentTests:52, PreflightTests:6-23, CommandLineToolTests:36,42,
AppModelTests:34,67,88.

### A.10 Script callers of the CLI verbs

- `Tests/Smoke/smoke.sh:15-19` calls `install-runtime` (with or without `--tarball "$MACNEUTRON_TARBALL"`), and `:20-22` calls
  `import-gptk` when `GPTK` is set. The `check()` helper at `:24-30` runs `"$TOOL/proton" waitforexitandrun …` (`:28`).
- `dxmt/check.sh:44` calls `"$ROOT/.build/release/macneutron" install-dxmt --tool-dir "$WORK/ours" "$DXMT"`.
- Nothing else under the repo's scripts or `Makefile` calls `install-runtime`, `import-gptk` or `install-dxmt`.

---

## B. Changes, per spec section

### B.1 §3.1: the tool folder, the entry points and the `passthrough` verb

**`RuntimeInstaller.swift`**
- `toolManifest` (:50-57): `"commandline" "/bin/macneutron launch %verb%"`.
- Delete `protonStub` (:58-62), and in `writeToolFiles` delete :115-117 (writing the stub and its chmod). Add `"proton"` to
  the Rosetta-era cleanup so the stale stub is removed from existing tool folders. If R0b **fails**, all of this stays as is.
- `writeToolFiles`: delete the presenter block (:127-132), because the presenter now lives in `wine.app` (§5.3). Keep the
  steam.exe candidates (:121-126). In the release, `MacNeutron.app/Contents/Resources/steam.exe` is found through
  `Helpers/../Resources/steam.exe`. For the CLI's install from `.build/…`, see C.3.

**`SteamPlayMode.swift`**
- Delete `passthroughScript` (:20-35).
- `installNativeTool()` (:198-220) writes the manifest `"commandline" "/bin/macneutron passthrough %verb%"`. It copies the CLI
  to `macneutron-native/bin/macneutron` and deletes a stale `passthrough.sh`. Two signature options:
  - **(a, laziest)** keep `installNativeTool() throws` and copy from `runtimeTool.appending(path: "bin/macneutron")`, using
    `RuntimeInstaller.installFile` (internal; same module). The file is there because `RuntimeInstaller.install` step 5 wrote
    it, and setup orders the runtime before Steam Play mode. It throws when the file is missing, and `makeFakeSteam` must then
    write a fake `bin/macneutron`.
  - **(b)** `installNativeTool(launcherBinary: URL) throws`, with both callers (`:102` in `enable`, `AppModel.swift:72`)
    passing `helper`. `enable(planAfterQuit:)` would then need the URL too, as a parameter or as a stored
    `public var launcherBinary: URL?`.

  I recommend (a): it adds no new parameters, and the two CLI copies always come from the same source.
- The AppModel must call `mode.installNativeTool()` after each completed install, not only at init (:72), so an app update
  refreshes the native copy as well.

**`CommandLineTool.swift`**: a new verb, `case "passthrough":`. Its argv is `["passthrough", <verb>, <target>, args…]`, matching
today's `shift; target=$1; shift`. I propose splitting it into testable pieces:

```swift
/// `<app>.app` → `<app>.app/Contents/MacOS/<CFBundleExecutable>` (or the bundle's base name); anything else unchanged.
static func passthroughTarget(_ path: String) -> URL
/// arm64e, arm64, x86_64: what `arch -arm64e -arm64 -x86_64` does.
static let passthroughArchitectures: [(cpu_type_t, cpu_subtype_t)] =
    [(CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64E), (CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64_ALL), (CPU_TYPE_X86_64, CPU_SUBTYPE_X86_64_ALL)]
/// posix_spawn with that preference; `replacingThisProcess` adds POSIX_SPAWN_SETEXEC (only returns on failure).
static func spawn(_ executable: URL, _ arguments: [String], environment: [String: String], replacingThisProcess: Bool) throws -> pid_t
```

- `passthroughTarget` reads `CFBundleExecutable` with `PropertyListSerialization` (as `GPTKImporter.frameworkVersion` does
  today) and drops PlistBuddy.
- Use `posix_spawnattr_setarchpref_np`. It takes cpu type **and subtype**, as `arch -arm64e -arm64` does. `setbinpref_np`
  takes only `cpu_type_t`, which can't put arm64e ahead of arm64. Both typecheck from Swift.
- The environment must be passed through, so the `envp` comes from `environment`.

**`ToolLayout`** (other digest): `wine.app`-based paths per §3.1, and the identity per §5.1.

### B.2 §3.9: installing `wine.app`

**New signature.** It keeps the code's shape, `layout: ToolLayout` and `launcherBinary`; see C.1.

```swift
public enum RuntimeInstallOutcome: Equatable, Sendable { case installed, unchanged, deferred(String) }   // String: the process path
public enum RuntimeInstallError: Error, Equatable, CustomStringConvertible {
    case notAWineApp(String)          // source has no Contents/MacOS/wine
    case signatureInvalid(Int32)      // codesign --verify --strict exit status (spec §10 row 3)
    case swapFailed(Int32)            // errno from renamex_np/rename
}
public enum RuntimeInstaller {
    @discardableResult
    public static func install(wineApp source: URL, layout: ToolLayout, launcherBinary: URL, force: Bool = false,
                               runner: any ProcessRunner = SystemProcessRunner(),
                               runningExecutables: () -> [String] = RunningProcesses.executablePaths,
                               identity: (URL) -> String? = RuntimeIdentity.of) throws -> RuntimeInstallOutcome
    public static func writeToolFiles(layout: ToolLayout, launcherBinary: URL) throws   // kept, minus proton/presenter
    static func removeRosettaEraEntries(layout: ToolLayout)
}
```

Steps, mapped to the code:
1. **Deferral.** Defer if any path from `runningExecutables()` has the prefix `layout.wineApp` (standardised path plus `/`)
   or `layout.root/Libraries/`. On deferral, return `.deferred(path)` without throwing. The AppModel needs this case to
   retry; nothing in the code today enumerates processes (§D).
2. Run `try? removeItem` on `wine.app.new` and `wine.app.old`.
3. Unless `force` or `runtime-damaged` exists: if `identity(source) == identity(layout.wineApp)` and neither is nil, skip to
   step 5 and return `.unchanged`.
4. Clone with `runner.run(/bin/cp, ["-c", "-R", src, new])`. Through `runner`, `FakeRunner` can record the call; but the "different"
   test then needs a real copy, so that test uses `SystemProcessRunner`. `FileManager.copyItem` also clones on APFS and keeps
   xattrs; it's an alternative, but unverified, so L6 decides. Then `runner.run(/usr/bin/codesign, ["--verify", "--strict", new])`;
   a non-zero status throws `signatureInvalid` and deletes `.new`. Then swap: if `wine.app` exists,
   `renamex_np(new, wineApp, UInt32(RENAME_SWAP))`, else `rename(new, wineApp)`. Then `removeItem(wine.app.new)` (now the old
   copy) and `removeItem(runtime-damaged)`.
5. `writeToolFiles(layout:launcherBinary:)`. Always.
6. `removeRosettaEraEntries`.

**`RunningProcesses`**, a new small type (e.g. `Sources/MacNeutronCore/RunningProcesses.swift`): `static func executablePaths() -> [String]`.
It calls `proc_listallpids(nil, 0)` for the count, `proc_listallpids(&pids, …)`, then `proc_pidpath(pid, &buf, UInt32(4 * MAXPATHLEN))`
per pid, skipping non-positive returns (other users' processes, exited pids).

**`CommandLineTool`**:
- New verb: `case "install":` with `--tool-dir <dir>`, `--wine-app <path>` (required), `--force` (a flag; `option(_:in:)`
  can't parse bare flags, so add `static func flag(_ name: String, in args: inout [String]) -> Bool`). It prints
  `Installed <version> (<identity 12>) into <dir>`, or `Deferred: <path> is running` (exit 0? see C.10), or
  `Unchanged …`.
- `usage`: delete :8-10; add `macneutron install [--tool-dir <dir>] --wine-app <wine.app> [--force]` and
  `macneutron passthrough <verb> <command> [args...]`.
- Delete the `import-gptk`, `install-runtime` and `install-dxmt` cases (:21-56).

**Deleted** from `RuntimeInstaller.swift`: `RuntimePin`, the three old error cases, `sha256(of:)`, `install(tarball:…)`,
`cachedDownload`, `download`, and `import CryptoKit`. The three files of A.3 go too.

**Tests**, per spec §9. New install tests in `RuntimeInstallerTests` (equal, different, forced, damaged, deferred, leftovers,
tool files always written, Rosetta-era entries removed). These need a fake `wine.app` fixture (`Contents/MacOS/wine`,
`Contents/Resources/bin/wineserver`, `Contents/Info.plist`) plus the `identity` and `runningExecutables` seams, or ad-hoc
`codesign -s -` on the fixture, as spec §9 does for the identity tests. `CommandLineToolTests` gains:
`installRequiresWineApp`, and `installWritesTheToolFolder` (with seams, or with an ad-hoc signed fixture), plus the
passthrough tests of B.1.

### B.3 §3.11: binaries and the app

**`Package.swift:6`**: `platforms: [.macOS("27.0")]`. **`App/Info.plist:12`**: `LSMinimumSystemVersion` `27.0`. **Makefile:13**:
`swift build -c release --arch arm64` (see the bin-path note in A.8).

**`AppModel.swift`**
- Delete `Snapshot.gptkVersion` (:29). Replace `runtimeVersion: String?` (:28) with
  `runtime: InstalledRuntime?`, where `struct InstalledRuntime: Equatable, Sendable { version: String; identity: String }`
  is read from `layout` (the other digest's `ToolLayout.runtimeVersion` / `runtimeIdentity`). `loadSnapshot` (:131) follows.
- Delete the property `gptkVersion` (:48) and its assignments (:80, :110). `runtimeVersion` (:47) becomes
  `private(set) var runtime: InstalledRuntime?`.
- A new property `private(set) var runtimeNotice: String?` (setup text: "Installing the runtime…", "The runtime updates after
  the game exits", or the codesign error). It is **separate from `busy`** (see C.5). Also add
  `private var installDeferred = false`.
- A new init parameter, following the `LoginItem` seam pattern: `wineAppSource: URL? = AppModel.bundledWineApp`. Add
  `static var bundledWineApp: URL?`, which is `<exe>/../../Helpers/wine.app` when it exists, else nil (dev runs and tests).
  In tests, pass `nil` so `AppModel.init` doesn't install.
- init (:71-80):
  - Delete :73-77 (the `writeToolFiles`/`DXMTInstaller` refresh gated on `runtimeVersion`).
  - Keep :72, or move it after the install.
  - Replace :79-80 with `runtime = layout.installedRuntime` (cheap: an Info.plist read, plus the CDHash from the code
    directory without validation).
  - Add `Task { await installRuntime(force: false) }` before `startWatchingSteam()`.
- `setupComplete` (:85): `runtime != nil && mode.isWanted`. "wine.app installed" means `layout.wineApp`'s loader exists and
  its version is readable.
- `installRuntime()` (:142-149) becomes `func installRuntime(force: Bool = false) async`:
  1. Set `runtimeNotice = "Installing the runtime…"`.
  2. Run `Task.detached { try RuntimeInstaller.install(wineApp: source, layout: layout, launcherBinary: helper, force: force) }`.
  3. On `.deferred(path)`, set `installDeferred = true` and the notice. On success, clear both, then
     `if mode.isWanted { try? mode.installNativeTool() }`. On an error, set `runtimeNotice`/`errorMessage` to the error.
  4. `await refresh()`.

  It does not go through `run()`, because `run` holds `busy` (C.5). Guard re-entry with a private `installing` flag.
- Delete `importGPTK(from:)` (:151-155).
- Poll loop (:250-275): before the Steam check, add
  `if self.installDeferred, !self.installing { await self.installRuntime() }` (every 3 s tick).

**`MenuContent.swift:11`**:
`Text(model.runtime.map { "Runtime \($0.version) (\($0.identity.prefix(12)))" } ?? "Runtime not installed")`.
Optionally also show `model.runtimeNotice`.

**`SettingsView.swift:20`**: `Button("Repair runtime") { Task { await model.installRuntime(force: true) } }`. Note that
`.disabled(model.busy != nil)` (:34) won't cover the install; disable the button on the model's `installing` flag.

**`SetupView.swift`**
- Step 1 becomes **Requirements**: `done: model.steamInstalled`. It replaces the trailing "Install Steam for Mac first." text
  (:57); see C.6 on macOS and Apple Silicon.
- Step 2 becomes **Runtime**: `done: model.runtime != nil`. The detail is `runtimeNotice`, or
  `"Wine \(version) (\(identity 12)) installed"`. There is no button; Settings has Repair.
- Step 3 (Steam Play) is unchanged except `.disabled(model.runtime == nil || !model.steamInstalled)` (:37).
- Delete the GPTK step (:22-31), `choosingDMG` (:8), `.fileImporter` (:62-64) and `import UniformTypeIdentifiers` (:4).

**`GamesView.swift`**
- Graphics picker (:40-43): `Text("Default (DXMT)").tag("")`, `Text("DXMT").tag("dxmt")`, `Text("wined3d (OpenGL)").tag("wined3d")`.
  This drops the `gptkVersion` reference at :43.
- Delete the AVX toggle (:55). That's a detail-row `Toggle`, not a table column (C.7). `GameSettings.avx` goes in the
  settings digest.

**`SteamPlayMode`**: delete `rosettaAvailable` (:44) and the guard at :93. Delete `SteamPlayError.rosettaMissing`
(`SteamLocation.swift:89,98`). Tests: `makeMode` :12, `enableRequiresRosetta` :223, :237, :249, and AppModelTests :83-95.
`Preflight.rosettaAvailable` and `Preflight.rosettaRuntime` belong to the Preflight digest. `passthroughPrefersTheAppleSiliconBuild`
(:149) references `Preflight.rosettaRuntime` and must go or change with it.

### B.4 §6.3 step 3: the app bundle layout

- Code locations, as read by the code:
  - `AppModel.helper` reads `Contents/Helpers/macneutron` (:89-95).
  - `writeToolFiles` finds steam.exe at `Contents/Resources/steam.exe` (:122-123).
  - The new `AppModel.bundledWineApp` reads `Contents/Helpers/wine.app`.
  - `Contents/Frameworks` (presenter, DXMT) disappears, and so do `writeToolFiles` :127-132 and `DXMTBuild.bundled`.
- `Contents/Resources/licenses/` is unread by Swift.
- Makefile `app` (:86-104). Delete the `presenter dxmt` prerequisites, :95-103 (Frameworks, published.sh, DXMT), and the
  Frameworks signing. Add `cp -c -R build/wine-arm64/wine.app $(APP)/Contents/Helpers/wine.app`. Change :104 to keep the
  ad-hoc outer sign **without** `--deep` (it has none today) and the prerequisite to `build bridge wine-arm64`. The steam.exe
  copy at :93 uses `$(BRIDGE)/steam.exe`; check that `BRIDGE` points at the arm64 build (`build/bridge/arm64/steam.exe` per
  spec; Makefile bridge digest).
- `App/Info.plist`: `CFBundleShortVersionString` stays `0.1.0`; the release script sets the version and `LSMinimumSystemVersion`.

---

## C. Awkward or contradicting points

1. **The spec's signature `install(wineApp:toolFolder:force:)` (§3.9) is incomplete.** Step 5 writes `bin/macneutron` and
   `bin/steam.exe`, so it needs the launcher's path. Every caller already has it (CLI: `executable`, `CommandLineTool.swift:38`;
   app: `helper`, `AppModel.swift:146`). Every existing API takes `layout: ToolLayout`, not a folder URL. Proposed:
   `install(wineApp:layout:launcherBinary:force:runner:…) -> RuntimeInstallOutcome`. The return value matters: "deferred" is
   not an error, and the poll loop needs to see it.
2. **`passthrough` with `POSIX_SPAWN_SETEXEC` can't be unit-tested in-process**, because it would replace the test runner.
   Spec §9 asks for tests of "target resolution and binary preference". Split it as in B.1. Test resolution as a pure
   function. Test the preference by spawning without SETEXEC (`replacingThisProcess: false`) and running `/usr/bin/arch`
   (universal arm64e/x86_64), expecting `arm64`. The exec path needs an L-gate or R0b. The test target doesn't depend on the
   `macneutron` executable (`Package.swift:16`), so tests can't run the built CLI.
3. **steam.exe for CLI-assembled tool folders.** `writeToolFiles` looks only beside the launcher or in `../Resources/`.
   `.build/release/macneutron` has neither, so `macneutron install --tool-dir … --wine-app …` from the checks and `smoke.sh`
   produces a folder without `bin/steam.exe`, and the bridge isn't installed (L3, R3's bridge probe). This needs either a
   `--steam-exe <path>` option, or the scripts copying `build/bridge/arm64/steam.exe` into `<tool>/bin/` themselves.
4. **Dev runs have no `wine.app` source.** An unbundled `.build/release/MacNeutronApp` has no `../Helpers/wine.app`. The
   start-up install must treat a nil source as "nothing to install" and show the installed one or "not installed", not
   error. `AppModel.init` runs from every `AppModelTests` test (`makeModel` :34, :88, :101), so the source must be injectable
   (nil in tests) or the tests start real installs from the test runner's bundle.
5. **A deferred install must not use `busy`.** `run()` (:238-245) holds `busy` for the whole action, and `busy` disables
   SetupView (:61) and SettingsView (:34) and gates every Steam action (:239, :256, :262). Retrying a deferred install every
   3 s through `run()` would flicker the UI and could block Steam Play actions for a whole game session. Use a separate
   `runtimeNotice` with an `installing` flag.
6. **Setup's "requirements (macOS 27, Apple Silicon)" can't be shown by the app.** With `LSMinimumSystemVersion 27.0` and a
   thin arm64 binary, the app doesn't launch on macOS 26 or on Intel, so the app never runs to explain. Only "Steam
   installed" is checkable in `SetupView`. The macOS and arch check stays meaningful only in the launcher's preflight (§3.3)
   and in Finder's own refusal. §10 row 1, "Setup explains and stops", holds only for the launcher.
7. **"GamesView loses the AVX column".** AVX is a `Toggle` in the selected row's detail strip (`GamesView.swift:55`), not a
   `TableColumn`. The table's three columns stay.
8. **"`AppModel.swift:250-275` existing 3-second poll"** matches the code exactly. But `refresh()` (`:256`) only runs every 20
   ticks when idle, so after a deferred install completes, the status line updates only via `installRuntime`'s own
   `refresh()`. That's fine if `installRuntime` refreshes.
9. **The Rosetta-era entry list (§3.1) misses `gptk.staging`** (`GPTKImporter.swift:80`, left behind if an import was
   interrupted). Also, if R0b passes, the `proton` stub must be removed from existing folders, but the list doesn't name it.
   `writeToolFiles` today *creates* `proton` (:115-117), so its removal must be explicit.
10. **CLI exit code for a deferred install** isn't specified. The checks (L6: "a real running wine process defers it") need
    to distinguish deferred from installed. I suggest exit 0 with a `deferred:` line, or a distinct code (3), and the plan
    should pick one.
11. **`MappingPlanner.isOurs` is `hasPrefix("macneutron")`** (`MappingPlanner.swift:82`). R0b's throwaway tools
    `macneutron-r0b` and `macneutron-r0b-native` (§6.2) would count as MacNeutron's own, so an app `sync` or
    `applyMappings` while R0b's mappings exist would *replace* them (`merged` drops "ours" not in the plan). R0b must run with
    the app quit, or use a name without the `macneutron` prefix.
12. **`SteamPlayMode.installNativeTool()` has no launcher input.** Under spec §3.1, `macneutron-native/bin/macneutron` must
    exist before `enable` links the tools, so `enable` now depends on the runtime install having written
    `macneutron/bin/macneutron` (option (a)) or on a new parameter (option (b)). Either way `FakeSteam.makeFakeSteam`
    (:19-27) needs a fake CLI.
13. **The "Repair runtime" plus `runtime-damaged` flow:** the launcher writes the marker (§3.3). The app reinstalls at the
    *next app start*, and the app is an always-on menu-bar app (login item). So in practice the repair happens only on
    Settings > Repair or after a relaunch, unless the poll loop also watches for `runtime-damaged`. That's a one-line
    `fileExists` check per tick; I suggest adding it.
14. **`wine.app` under App Translocation**, as source: `Bundle.main.executableURL` points into the translocated path, and
    `cp -c -R` across volumes is a full 1.3 GB copy (spec §12 acknowledges this). `cp` gives no progress, so the
    "background with progress" in the risks table (§12) has no implementation path. A spinner ("Installing the runtime…")
    is all the current code style supports.

---

## D. Darwin APIs and process enumeration

I typechecked these from Swift with `import Darwin` (scratch file, `xcrun swiftc -typecheck`, macOS 27.0 SDK). All pass:
- `renamex_np(_:_:_:)` with `UInt32(RENAME_SWAP)` (declared in `sys/stdio.h`, module `sys_stdio`)
- `proc_pidpath(pid, &buf, UInt32)` and `proc_listallpids(nil, 0)` (`libproc.h`, Darwin module `libproc`)
- `posix_spawnattr_setarchpref_np` and `posix_spawnattr_setbinpref_np`
- `posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETEXEC))`
- `CPU_TYPE_ARM64`, `CPU_SUBTYPE_ARM64E`, `CPU_SUBTYPE_ARM64_ALL`, `CPU_TYPE_X86_64`, `CPU_SUBTYPE_X86_64_ALL`

**`PROC_PIDPATHINFO_MAXSIZE` does not import** ("structure not supported"); use `4 * Int(MAXPATHLEN)`.

**How the code enumerates processes today:**
- **No Swift code enumerates processes.** The only process query is `SteamProcess.isRunning()`, which runs `/usr/bin/pgrep -x steam_osx`
  through `SystemProcessRunner` (`SteamLocation.swift:115-118`).
- `ShaderPrecache.swift:103-105` uses `sysctlbyname("kern.osversion")`, which is not process-related.
- Per spec §2, `wine-arm64/check.sh:46-58` uses `lsof -t` on the loader and server.
- `proc_pidpath` returns ≤ 0 for processes of other users and for pids that exited between the list and the query; skip those.
