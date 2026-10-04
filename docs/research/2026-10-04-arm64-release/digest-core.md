# SP5 interface digest: Swift launcher core (MacNeutronCore)

Repo `/Users/chad/Documents/MacProton` at `69f0e4f` (+ the spec's working-tree edit). Read-only. The spec,
`docs/superpowers/specs/2026-10-04-macneutron-arm64-release-design.md`, is the authority. Paths are relative to the repo.
Covers spec §3.1-3.8, §3.10 and §5.1 for `Sources/MacNeutronCore/{ToolLayout,Launcher,LaunchEnvironment,GraphicsBackend,
GameSettings,CompatContext,Preflight,PrefixManager,SteamBridge,ShaderPrecache,LauncherLog,ProcessRunner,Verb,OrphanPrefixes}.swift`
and their tests.

Package facts: `Package.swift` uses swift-tools 6.0, `platforms: [.macOS("26.0")]`, `.target(name: "MacNeutronCore")` with
**no `linkerSettings`**, and the test target depends on `MacNeutronCore` and `MacNeutronApp`. Tests use Swift Testing (`@Test func`).
No file imports `Security` today. `RuntimeInstaller.swift:1` imports `CryptoKit` and relies on autolinking, and `PrefixManager.swift:1`
imports `Darwin`.

---

## A. Current interfaces (exact)

### A.1 ToolLayout.swift (74 lines)
```swift
public struct ToolLayout: Equatable, Sendable {
    public let root: URL
    public init(root: URL)
    public init(executable: URL)            // :10-12  executable.resolvingSymlinksInPath() minus 2 components
    public static var defaultRoot: URL      // :14-18  ~/Library/Application Support/MacNeutron/compatibilitytools.d/macneutron
    public var libraries: URL               // :21  <root>/Libraries/
    public var wineLib: URL                 // :22  Libraries/Wine/lib/
    public var wine: URL                    // :23  Libraries/Wine/bin/wine
    public var wineserver: URL              // :24  Libraries/Wine/bin/wineserver
    public var dxmt: URL                    // :25  Libraries/DXMT/
    public var dxvk: URL                    // :26  Libraries/DXVK/
    public var gptkStore: URL               // :28  <root>/gptk/
    public var gptkManifest: URL            // :29  <root>/gptk.json
    public var runtimeVersionFile: URL      // :30  <root>/runtime-version
    public var launcherBinary: URL          // :31  <root>/bin/macneutron
    public var steamHelper: URL             // :33  <root>/bin/steam.exe
    public var lsteamclientUnix: URL        // :35  wineLib/wine/x86_64-unix/lsteamclient.so
    public var lsteamclient64: URL          // :36  wineLib/wine/x86_64-windows/lsteamclient.dll
    public var lsteamclient32: URL          // :37  wineLib/wine/i386-windows/lsteamclient.dll
    public var steamBridgeInstalled: Bool   // :40-43 [steamHelper, lsteamclientUnix, lsteamclient64] all exist
    public var presenterLibrary: URL        // :46  <root>/lib/libmacneutron-present.dylib
    public var presenterInstalled: Bool     // :47
    public var dxmtVersionFile: URL         // :50  <root>/dxmt-version
    public var dxmtVersion: String?         // :51-53 trimmed file contents
    public var dxmtD3D12: URL               // :55  dxmt/x64/d3d12.dll
    public var dxmtHasD3D12: Bool           // :56
    public var dxmtReplay: URL              // :58  dxmt/x64/dxmt-replay.exe
    public var runtimeVersion: String?      // :60-63 trimmed runtime-version
    public var gptkVersion: String?         // :66-71 gptk.json "version"
    public var gptkImported: Bool           // :73
}
```
Call sites outside ToolLayout:
- `ToolLayout(executable:)`: `CommandLineTool.swift:18`. `ToolLayout(root:)`/`defaultRoot`: `CommandLineTool.swift:70-72` and
  `AppModel.swift:63`.
- `wine`: `Launcher.swift:114,139`, `PrefixManager.swift:48,52`, `ShaderPrecache.swift:80`, `Preflight.swift:32` and
  `RuntimeInstaller.swift:91`.
- `wineserver`: `Launcher.swift:86,108,132`, `Preflight.swift:33` and `RuntimeInstaller.swift:91`.
- `runtimeVersion`: `Launcher.swift:68,117`, `Preflight.swift:34`, `DXMTInstaller.swift:69` and `AppModel.swift:74,79,131`.
- `gptkVersion`/`gptkImported`: `Launcher.swift:59,117` and `AppModel.swift:80,131`.
- `dxmtHasD3D12`/`dxmtD3D12`: `GraphicsBackend.swift:35,57-58` and `ShaderPrecache.swift:20`.
- `dxmtVersion`: `ShaderPrecache.swift:13` and `DXMTInstaller.swift:91`. `dxmtReplay`: `ShaderPrecache.swift:80`.
- `steamHelper`/`lsteamclient*`: `SteamBridge.swift:19-22` and `RuntimeInstaller.swift:125`. `steamBridgeInstalled`: `Launcher.swift:150`.
- `presenter*`: `Launcher.swift:161,165` and `RuntimeInstaller.swift:131`.
- `libraries`/`gptkStore`/`wineLib`/`dxmtVersionFile`/`runtimeVersionFile`: `RuntimeInstaller.swift:96-101`,
  `GPTKImporter.swift:84-98` and `DXMTInstaller.swift:71-85`.

Tests: `PathsTests.swift` has `layoutPathsFollowTheRuntimeTarball` (:28) and `layoutFromExecutableIsTwoLevelsUp` (:37), plus
`runtimeAndGPTKVersionsComeFromFiles` (:42). `SteamBridgeTests.swift` has `bridgeNeedsSteamExeAndBothHalvesOfTheClient` (:44).

### A.2 Launcher.swift (207 lines)
```swift
final class StopFlag: @unchecked Sendable { var isSet: Bool; func set() }      // :5-10 (also used by ShaderPrecache :64)
public struct Launcher: Sendable {
    public let layout: ToolLayout; public let runner: any ProcessRunner; public let log: LauncherLog
    public let notifier: any Notifier; public let preflight: Preflight; public let settings: GameSettingsStore
    public let steam: SteamLocation; let stopRequested = StopFlag()
    public init(layout: ToolLayout, runner: any ProcessRunner = SystemProcessRunner(), log: LauncherLog = .standard,
                notifier: any Notifier = AppleScriptNotifier(), preflight: Preflight = Preflight(),
                settings: GameSettingsStore = GameSettingsStore(), steam: SteamLocation = SteamLocation())   // :23-33
    public func launch(_ argv: [String], environment steamEnvironment: [String: String]) -> Int32           // :36-124
    public func terminate(environment: [String: String])                                                   // :127-133
    private func runGame(_:_:_:throughSteam:) throws -> Int32                                              // :135-140
    private func usesSteamBridge(_ verb: Verb, _ environment: [String: String]) -> Bool                    // :144-155
    private func addPresenter(to env: inout [String: String])                                              // :159-167
    private func addSteamClient(to env: inout [String: String])                                            // :170-184
    private func writeHeader(to:request:environment:)                                                      // :186-199
    private func fail(_ message: String, argv: [String], notify: Bool) -> Int32                            // :201-206
}
```
The logical blocks of `launch`:
- :40-45 parses the request and the CompatContext. A failure there calls `fail(notify:false)`.
- :46-51 merges the settings environment under the launch options. An unreadable file gets the log note
  `note: ignoring unreadable game settings for <id>: ...`.
- :52-56 runs `preflight.check(layout)`. A failure calls `fail(error.description, notify:true)`. This happens **before** `gameLog`
  is decided (:66).
- :58-59 selects the backend with `GraphicsBackend.select(requested: env["MACNEUTRON_GRAPHICS"], gptkImported:)`.
- :60 sets `logging = env["MACNEUTRON_LOG"] == "1"`.
- :61-62 calls `LaunchEnvironment.build(base:context:backend:layout:logging:)`.
- :63-64 decides on the Steam bridge and calls `addSteamClient`. :65 adds the presenter only for `.run` and `.waitforexitandrun`.
- :66-67 handles the game log and its header. :68-69 makes `PrefixManager(context:layout:runtimeVersion: layout.runtimeVersion ?? "unknown", runner:)`.
- :73-115 is the verb switch:
  - `runinprefix` runs the game only.
  - `run` calls prepare, then `removeSteamBridge` when there is no bridge, then runs the game.
  - `waitforexitandrun` calls prepare, then `wineserver -w`, then the precache block (:88-100), then either the stop check
    (:101-103, giving status 128+SIGTERM) or the game run, `wineserver -w` and `writeStampIfMissing`.
  - `getcompatpath`/`getnativepath` call `prepare(backend:environment:)` without the bridge, then
    `wine winepath.exe -w|-u <target>`.
- :116-119 writes the log line `verb=<v> appid=<id> backend=<b> runtime=<runtimeVersion|unknown> gptk=<gptkVersion|none> exit=<s>[ note=<note>]`.

`terminate` (:127-133) sets the stop flag, then `env = Steam's raw env + WINEPREFIX` and runs `wineserver -k`. It loads **no
settings and sets no WINEMSYNC**.

Caller: `CommandLineTool.swift:18-20` (`Launcher(layout: ToolLayout(executable: executable))`), with signal handlers at
`CommandLineTool.swift:78-89` that call `terminate` on a global queue.

Tests in `LauncherTests.swift`:
- `RecordingNotifier` (:5-10) and `Fixture`/`makeFixture(runner:rosetta:bridge:presenter:)` (:12-34, which uses
  `Preflight(rosettaAvailable: { rosetta })`).
- Tests: `waitForExitAndRunPreparesWaitsRunsThenWaits` :36, `runDoesNotWaitForWineserver` :57, `runInPrefixSkipsPreparation` :64,
  `getCompatPathConvertsThroughWinepath` :70, `gameArgumentsPassThroughUnchanged` :76, `unknownVerbFailsWithoutRunningAnything` :83,
  `launchingOutsideSteamFailsCleanly` :89, `invalidGraphicsSettingStillLaunchesWithDefault` :95, `missingRosettaNotifiesAndFails` :106,
  `failedPrefixSetupNotifiesAndSkipsGame` :113, `macneutronLogSendsGameOutputToPerGameLog` :120, `everyLaunchIsLoggedWithVersions` :130,
  `terminateKillsThePrefixWineserver` :137, `gameSettingsApplyUnderneathLaunchOptions` :144, `unreadableGameSettingsAreIgnored` :156,
  `gameGoesThroughSteamExeWhenTheBridgeIsInstalled` :163, `runInPrefixNeverGoesThroughSteamExe` :176, `escapeHatchStartsTheGameDirectly` :182,
  `missingBridgeStartsTheGameDirectly` :191, `accountFromLaunchOptionsWins` :198, `steamsClientPathIsLoggedAndCheckedForTheLibrary` :206,
  `escapeHatchTakesTheBridgeOutOfThePrefix` :216, `anyDirectStartTakesLeftoverBridgeFilesOut` :232, `gameLogsHideTheSteamAccount` :242,
  `presenterIsInjectedByDefault` :254, `presenterComesAfterTheUsersOwnLibraries` :261, `optingOutLeavesThePresenterOut` :270,
  `missingPresenterIsNoted` :281, `toolCommandsGetNoPresenter` :288, `presenterAndSteamBridgeTravelTogether` :295,
  `defaultBackendIsDXMTEvenWithGPTKImported` :303.

### A.3 LaunchEnvironment.swift (45 lines)
```swift
public enum LaunchEnvironment {
    public static func build(base: [String: String], context: CompatContext, backend: GraphicsBackend,
                             layout: ToolLayout, logging: Bool) -> [String: String]      // :6-24
    public static func mergeOverrides(_ ours: String, user: String?) -> String           // :28-44 (by DLL name, user wins, expands "a,b=m" to "a=m;b=m")
}
```
`build` does the following:
- :9 sets `WINEPREFIX = context.prefix` (with a trailing slash).
- :10 sets `WINEDLLOVERRIDES = mergeOverrides(backend.dllOverrides(layout:), user: base[...])`.
- :11-13 sets `WINEDEBUG`, unless the user set it: `+err,+warn,+loaddll,+steamclient` when logging, otherwise `-all`.
- :14-16 sets `ROSETTA_ADVERTISE_AVX=1` unless `MACNEUTRON_NO_AVX=1` or the user set it.
- :17-19 sets `WINEMSYNC=1` unless `MACNEUTRON_NO_MSYNC=1` or `base["WINEMSYNC"]` is set. A user's `WINEMSYNC` survives even when
  `MACNEUTRON_NO_MSYNC=1`.
- :20-22 sets `DXMT_PIPELINE_RECORD` when `ShaderPrecache.enabled(...)` and the user hasn't set it.

Callers: `Launcher.swift:61` and `PrefixManagerTests.swift:9`.

Tests in `LaunchEnvironmentTests.swift` (the file-level `context`/`layout` are at :5-6): `setsPrefixOverridesAndDefaults` :8,
`loggingTurnsOnWineDebugChannels` :18, `userSettingsWin` :23, `optOutsDropDefaults` :32, `mergeKeepsDisabledEntries` :39,
`userOverridesWinOverOurD3D12` :43, `recordsPipelinesOnlyForOurD3D12` :51.

### A.4 GraphicsBackend.swift (60 lines)
```swift
public enum GraphicsBackend: String, Sendable, CaseIterable {
    case d3dmetal, dxmt, dxvk                                                                           // :5
    public static func select(requested: String?, gptkImported: Bool) -> (backend: GraphicsBackend, note: String?)  // :9-26
    public func dllOverrides(layout: ToolLayout) -> String                                             // :32-40
    public func prefixDLLs(layout: ToolLayout) -> [(source: URL, destination: String)]                 // :44-59
}
```
- `select` trims and lowercases the request. Empty or nil gives `(.dxmt, nil)`. An unknown value gives
  `(.dxmt, "unknown MACNEUTRON_GRAPHICS '<raw>', using dxmt")`. The GPTK rules are at :17-24.
- The DXMT overrides with d3d12 are `dxgi,d3d10core,d3d11,d3d12=n,b;d3d9,d3d10=b` (:35).

Callers: `Launcher.swift:58`, `LaunchEnvironment.swift:10` and `PrefixManager.swift:62`.

Tests in `GraphicsBackendTests.swift`: `defaultsToDXMTEvenWithGPTK` :5, `unknownRequestWithGPTKFallsBackToDXMT` :11,
`d3dmetalStaysSelectableWithGPTK` :17, `dxmtTakesD3D12OnlyWithOurD3D12` :30, `dxmtDeploysOurD3D12To64BitOnly` :37,
`defaultsToDXMTWithoutGPTK` :46, `honorsRequestCaseInsensitively` :50, `unknownRequestFallsBackWithNote` :54,
`d3dmetalWithoutGPTKFallsBackToDXMT` :60, `everyBackendOverridesTheSameDLLSet` :66, `dxvkUsesWinesDXGIAndOnlyTheDLLsTheRuntimeShips` :79,
`dxmtDeploysBothArchitectures` :87, `dxvkFallsBackToD3DMetalWhenGPTKIsImported` :98. The private helper `dxmtLayout(d3d12:)` is at :24-28.

### A.5 GameSettings.swift (75 lines)
```swift
public struct GameSettings: Codable, Equatable, Sendable {
    public var graphics: String?; public var log: Bool?; public var avx: Bool?; public var msync: Bool?
    public var runAs: RunAs?; public var metalFX: Bool?                                                  // :5-10
    public init(graphics: String? = nil, log: Bool? = nil, avx: Bool? = nil, msync: Bool? = nil, runAs: RunAs? = nil,
                metalFX: Bool? = nil)                                                                    // :12-20
    public var environment: [String: String]   // :23-31 GRAPHICS, LOG=1, NO_AVX=1 (avx==false), NO_MSYNC=1, NO_METALFX=1
}
public struct GameSettingsStore: Sendable {
    public let directory: URL
    public init(directory: URL = MacNeutronPaths.games)
    func file(_ appID: String) -> URL
    public func load(_ appID: String) throws -> GameSettings     // missing file gives the defaults; a corrupt one throws
    public func save(_ settings: GameSettings, for appID: String) throws   // sortedKeys, .atomic
    public func all() -> [String: GameSettings]
    public func runAsOverrides() -> [UInt32: RunAs]
}
```
The synthesized `Codable` ignores unknown keys, so an old `"avx": false` file still decodes once the field is removed.

Callers of `avx`: `GameSettings.swift:7,12,16,27` and `GamesView.swift:55` (`Toggle("AVX", isOn: binding(row, \.avx, default: true))`).
`GamesView.swift:41,43` offers `d3dmetal`/`dxvk` tags.

Tests in `GameSettingsTests.swift`: `settingsBecomeLaunchVariables` :5 (uses `avx:`), `storeRoundTripsAndDefaultsWhenMissing` :13
(uses `graphics: "d3dmetal"`), `corruptFilesThrowAndAreSkippedByAll` :21.

### A.6 CompatContext.swift (29 lines)
```swift
public enum CompatContextError: Error, Equatable, CustomStringConvertible { case missing(String) }
public struct CompatContext: Equatable, Sendable {
    public let dataPath: URL; public let appID: String
    public init(environment env: [String: String]) throws(CompatContextError)   // STEAM_COMPAT_DATA_PATH required; SteamAppId or "0"
    public var prefix: URL       // <data>/pfx/
    public var versionFile: URL  // <data>/version   (the prefix stamp)
    public var lockFile: URL     // <data>/macneutron.lock
}
```
Tests in `PathsTests.swift`: `readsSteamCompatEnvironment` :5, `appIDDefaultsToZero` :17, `missingDataPathIsAnError` :22.
The spec needs no change here.

### A.7 Preflight.swift (58 lines)
```swift
public enum PreflightError: Error, Equatable, CustomStringConvertible {
    case rosettaMissing      // "Rosetta 2 is not installed. Run: softwareupdate --install-rosetta --agree-to-license"
    case runtimeMissing      // "The MacNeutron runtime is missing or incomplete. Repair it with: macneutron install-runtime"
}
public struct Preflight: Sendable {
    public static let rosettaRuntime = URL(filePath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
    public let rosettaAvailable: @Sendable () -> Bool
    public init(rosettaAvailable: @escaping @Sendable () -> Bool = { fileExists(rosettaRuntime) })
    public func check(_ layout: ToolLayout) throws(PreflightError)   // :29-36 rosetta, then wine+wineserver executable and runtimeVersion != nil
}
public protocol Notifier: Sendable { func post(title: String, message: String) }
public struct AppleScriptNotifier: Notifier { public init(); public func post(...); static func quoted(_:) -> String }
```
Callers: `Launcher.swift:53`. `SteamPlayMode.swift:44` has `public var rosettaAvailable: @Sendable () -> Bool = { Preflight().rosettaAvailable() }`
and uses it at :93. `SteamPlayModeTests.swift:149` uses `Preflight.rosettaRuntime`.

Tests in `PreflightTests.swift`: `passesWithRosettaAndRuntime` :5, `reportsMissingRosettaFirst` :9, `reportsMissingRuntime` :14,
`runtimeWithoutVersionFileIsIncomplete` :20, `notificationTextIsEscapedForAppleScript` :26.

### A.8 PrefixManager.swift (111 lines)
```swift
public enum PrefixError: Error, Equatable, CustomStringConvertible {
    case lockFailed(String); case winebootFailed(Int32); case dllCopyFailed(String); case steamBridgeCopyFailed(String)
}
public struct PrefixManager: Sendable {
    public let context: CompatContext; public let layout: ToolLayout; public let runtimeVersion: String; public let runner: any ProcessRunner
    public init(context: CompatContext, layout: ToolLayout, runtimeVersion: String, runner: any ProcessRunner)   // :27-32
    public var needsPreparation: Bool                       // :35-39 pfx missing OR trimmed stamp != runtimeVersion
    public func prepare(backend: GraphicsBackend, environment: [String: String], steamBridge: Bool = false) throws   // :44-59
    func deployDLLs(for backend: GraphicsBackend) throws    // :61-71 (a missing source throws dllCopyFailed)
    func deploySteamBridge() throws                         // :74-80
    public func removeSteamBridge() throws                  // :85-91 removes steam.exe, steamclient64.dll, steamclient.dll under lock
    private func install(_ source: URL, at destination: String) throws   // :93-99 removeItem + copyItem, every time
}
func withFileLock<T>(at url: URL, _ body: () throws -> T) throws -> T    // :104-111 flock; also used by LauncherLog.swift:32
```
The `prepare` body:
- :45 creates `dataPath`.
- :46 takes the lock.
- :47-55 runs only `if needsPreparation`:
  - `wine wineboot -u` with the given env, **without** `mscoree,mshtml=`. A non-zero status throws `winebootFailed`.
  - `wine reg add HKCU\Software\Wine\WineDbg /v ShowCrashDialog /t REG_DWORD /d 0 /f`, best effort.
  - Writes the stamp.
- :56 calls `deployDLLs(for: backend)` on **every** launch, and :57 calls the bridge deploy on every launch when asked.

Tests in `PrefixManagerTests.swift` (`makeManager` is at :5-11; `disableCrashDialog` is at :24-25):
- `freshPrefixRunsWinebootAndRecordsVersion` :13, `failedWinebootSkipsTheCrashDialogSetting` :27, `upToDatePrefixSkipsWineboot` :34.
- `runtimeChangeUpgradesPrefix` :42, `failedWinebootKeepsPrefixAndVersion` :51, `deploysBackendDLLsIntoBothSystemFolders` :61.
- `missingRuntimeDLLIsAnError` :72, `concurrentLaunchesRunWinebootOnce` :79.
- `systemRunnerReportsStatusAndCapturesOutput` :92. This one is really a ProcessRunner test; keep it.
- `steamBridgeIsCopiedIntoTheSteamFolder` :104, `upToDatePrefixStillGetsTheSteamBridge` :114, `thirtyTwoBitClientIsSkippedWithoutAnI386Build` :124.
- `prefixWithoutBridgeRequestGetsNoSteamFolder` :132, `dxmtDeploysOurD3D12WhenInstalled` :139.

### A.9 SteamBridge.swift (35 lines)
```swift
public enum SteamBridge {
    public static let steamExe = #"C:\Program Files (x86)\Steam\steam.exe"#
    public static func windowsPath(_ path: String) -> String          // "/" maps to "Z:\"
    static let prefixFolder = "drive_c/Program Files (x86)/Steam"
    static func prefixFiles(layout: ToolLayout) -> [(URL, String)]    // :18-25 steam.exe, steamclient64.dll (+ steamclient.dll when i386 exists)
    public static func clientDirectory(steamValue: String?, steam: SteamLocation) -> String   // :29-34
}
```
Tests in `SteamBridgeTests.swift`: `windowsPathMapsUnixPathsToDriveZ` :5, `clientDirectoryKeepsSteamsValueWhenItHoldsTheLibrary` :10,
`clientDirectoryFallsBackToTheSteamBundle` :18, `mostRecentUserIsTheActiveAccount` :25, `newestTimestampWinsWithoutMostRecent` :32,
`noLoginUsersMeansNoAccount` :39, `bridgeNeedsSteamExeAndBothHalvesOfTheClient` :44.

### A.10 ShaderPrecache.swift (108 lines)
```swift
public struct ShaderPrecache: Sendable {
    public let folder: URL; public let builds: String     // builds = "<layout.dxmtVersion ?? "none"> <osBuild>"
    public init(context: CompatContext, layout: ToolLayout, osBuild: String = ShaderPrecache.macOSBuild())
    public static func folder(for context: CompatContext) -> URL      // <data>/dxmt-pipelines
    public static func enabled(backend: GraphicsBackend, layout: ToolLayout, environment: [String: String]) -> Bool  // :19-21 dxmt && dxmtHasD3D12 && PRECACHE != "0"
    public var stampFile: URL                                          // <folder>/replayed
    public var recordings: [URL]; public var needsReplay: Bool
    public func writeStamp(); public func writeStampIfMissing()
    public func replay(layout: ToolLayout, runner: any ProcessRunner, environment: [String: String],
                       stopped: () -> Bool = { false }, progress: @escaping @Sendable (String) -> Void = { _ in },
                       pollInterval: TimeInterval = 1) -> [String]     // :54-88 runs `wine <dxmtReplay unix path> Z:<recording>`, removing DXMT_PIPELINE_RECORD
    static func lastProgress(in output: URL) -> (Int, Int)?
    public static func macOSBuild() -> String                          // :101-107 sysctlbyname("kern.osversion")
}
```
Callers: `Launcher.swift:88-100` and `LaunchEnvironment.swift:20-21`.

Tests in `ShaderPrecacheTests.swift`: the fixture `makePrecacheFixture` (:19-49) writes `layout.dxmtD3D12`, `dxmtReplay` and
`dxmtVersionFile` and uses `Preflight(rosettaAvailable: { true })`. Tests: `theGameRecordsIntoItsCompatFolder` :53,
`theFirstSessionStampsWithoutReplaying` :61, `recordingsWithoutAStampAreNotReplayed` :68, `theSameBuildsDoNotReplay` :76,
`changedBuildsReplayEveryRecordingBeforeTheGame` :84, `aFailedReplayStillStartsTheGame` :106, `theRunVerbNeitherReplaysNorStamps` :116,
`precacheCanBeTurnedOff` :125, `stoppingDuringTheReplayStartsNoGame` :137, `theReplayReportsItsProgressByQuarters` :152.

### A.11 LauncherLog.swift, ProcessRunner.swift, Verb.swift and OrphanPrefixes.swift (unchanged by the spec)
- `LauncherLog`:
  - `public struct LauncherLog: Sendable { static let rotateBytes = 1_048_576; let directory: URL; init(directory:); static var standard;
    var launcherLog: URL; func gameLog(appID: String) -> URL; func append(_ line: String) }`.
  - `gameLog` returns `steam-<appid>.log`. `append` takes `launcher.log.lock` through `withFileLock`.
  - Tests: `appendsTimestampedLines` :5, `rotatesPastOneMegabyte` :15, `gameLogIsPerApp` :24, `concurrentAppendsKeepEveryLine` :30.
- `ProcessRunner`:
  - `public protocol ProcessRunner: Sendable { func run(_ executable: URL, _ arguments: [String], environment: [String: String], output: URL?) throws -> Int32 }`.
  - `SystemProcessRunner` runs a `Process`, appends output to `output`, and returns 128+signal.
- `Verb` and `LaunchRequest`:
  - `public enum Verb: String, Sendable, CaseIterable { case run, waitforexitandrun, runinprefix, getcompatpath, getnativepath }`.
  - `LaunchRequestError { missingVerb, unknownVerb(String), missingTarget(Verb) }`.
  - `public struct LaunchRequest: Equatable, Sendable { verb, target, arguments; static func parse(_ argv: [String]) throws(LaunchRequestError) -> LaunchRequest }`.
  - Tests: `parsesSteamInvocation` :4, `keepsArgumentsWithSpacesAndQuotesIntact` :9, `rejectsMissingVerb` :16, `rejectsUnknownVerb` :20,
    `rejectsVerbWithoutTarget` :24.
- `OrphanPrefixes`:
  - `struct OrphanPrefix { appID, url, bytes }` and `enum OrphanPrefixes { static func find(in: SteamLocation) -> [OrphanPrefix];
    static func delete(_:) throws; static func size(of:) -> Int64 }`.
  - It removes the whole `compatdata/<id>`, so `pfx.rosetta` goes with it, as the spec wants.
  - Tests: `listsOnlyPrefixesOfUninstalledGames` :5, `nonSteamShortcutsAreNeverListed` :20.

### A.12 Test fixtures
- **Support.swift** (143 lines):
  - `runDir()` and the sweep (:6-21). `makeTempDir() throws -> URL` (:24-29; its path contains a space).
  - `write(_ text: String, to url: URL, executable: Bool = false) throws` (:31-37).
  - `final class FakeRunner: ProcessRunner, @unchecked Sendable` (:40-61). `Call { tool (= executable.lastPathComponent), arguments,
    environment, output }`, with `init(respond:)` and `var calls`.
  - `winebootCreatingPrefix(status: Int32 = 0, delay: TimeInterval = 0) -> FakeRunner` (:64-73). It keys on `arguments.first == "wineboot"`
    and creates `WINEPREFIX`.
  - `makeToolLayout() throws -> ToolLayout` (:76-91). It writes the Rosetta tree: `Libraries/Wine/bin/{wine,wineserver}` (executable
    `#!/bin/sh`), `Libraries/DXMT/{x64,x32}/{d3d11,d3d10core,dxgi}.dll` ("dxmt <arch> <dll>"), `Libraries/DXVK/{x64,x32}/{d3d10core,d3d11}.dll`
    and `runtime-version` ("runtime-test").
  - `steamEnvironment(dataPath:appID:)` (:93-95).
  - `makeSteamLocation(loginUsers:steamClient:)` (:99-104). `loginUser(account:timestamp:mostRecent:)` (:107-112) builds SteamID64
    values from a base constant at :108; do not reproduce it. `loginUsersFile(_:)` is at :114.
  - `installFakeSteamBridge(in:i386: Bool = true)` (:117-122) and `installFakePresenter(in:)` (:125-127).
  - `makeDXMTBuild(in:unixFolder:version:)` (:130-143, the Rosetta DXMT build used by DXMTInstaller, RuntimeInstaller and
    CommandLineTool tests).
- **FakeSteam.swift** (68 lines):
  - `okSession` and `macModeSession` strings.
  - `makeFakeSteam(config:) -> (SteamLocation, URL)` (writes `MacNeutron/compatibilitytools.d/macneutron/toolmanifest.vdf`).
  - `final class FakeSteam: SteamControlling`.
  - None of it touches launcher-core types except through `OrphanPrefixesTests`. It needs no change for this area.

Users of `makeToolLayout`/`installFakeSteamBridge`/`installFakePresenter`/`makeDXMTBuild` (number of lines): AppModelTests 3,
CommandLineToolTests 3, DXMTInstallerTests 17, GPTKDiskImageTests 3, GPTKImporterTests 4, LaunchEnvironmentTests 1, LauncherTests 3,
PrefixManagerTests 5, PreflightTests 3, RuntimeInstallerTests 7, ShaderPrecacheTests 2, SteamBridgeTests 2.

### A.13 Facts about the staged `wine.app` (`build/wine-arm64/wine.app`, read with ls, plutil and codesign)
- Info.plist has 6 keys: CFBundleExecutable=wine, CFBundleIdentifier=net.authspot.macneutron.wine, CFBundleInfoDictionaryVersion,
  CFBundleName=Wine, CFBundlePackageType=APPL and LSMinimumSystemVersion=27.0. There is **no CFBundleShortVersionString yet**; §5.1's
  bundle.sh change adds it.
- `Contents/Resources/DXMT/aarch64-windows/` holds `d3d10core.dll d3d11.dll d3d12.dll dxgi.dll dxmt-replay.exe`. None of them carries
  Wine's builtin marker (bytes 64-79). `DXMT/version` = `1fba8d25b5e29ab49012d633676a6b0d4b3b96c5+63a4969e01ba`.
- `lib/wine/aarch64-windows/{lsteamclient.dll,libarm64ecfex.dll}` and `lib/wine/aarch64-unix/lsteamclient.so` exist.
- `codesign -dvvv` prints:
  - `Format=app bundle with Mach-O thin (arm64)`, `CodeDirectory ... hashes=3+7`, `Hash type=sha256`;
  - `CDHash=576db3c001f0fff465bcdf5af8765ba4efc44b3d` (40 hex, the truncated SHA-256 CD hash);
  - `Info.plist entries=6`.

---

## B. What must change, per spec section

### §3.1 Tool folder and ToolLayout
**ToolLayout.swift: proposed shape.** The style stays the same: computed `URL` properties and `appending(path:)`.
```swift
import Foundation
import Security

public struct ToolLayout: Equatable, Sendable {
    public let root: URL
    public init(root: URL)                    // unchanged
    public init(executable: URL)              // unchanged (bin/macneutron → root; still right when Steam runs bin/macneutron directly)
    public static var defaultRoot: URL        // unchanged
    public var wineApp: URL                   // <root>/wine.app/
    public var wine: URL                      // wineApp/Contents/MacOS/wine
    public var wineserver: URL                // wineApp/Contents/Resources/bin/wineserver
    public var dxmt: URL                      // wineApp/Contents/Resources/DXMT/aarch64-windows/
    public var dxmtVersionFile: URL           // wineApp/Contents/Resources/DXMT/version
    public var dxmtVersion: String?           // unchanged body
    public var dxmtReplay: URL                // dxmt/dxmt-replay.exe
    public static let dxmtDLLs = ["d3d10core.dll", "d3d11.dll", "d3d12.dll", "dxgi.dll"]   // §3.4 step 6
    public var lsteamclient: URL              // wineApp/Contents/Resources/lib/wine/aarch64-windows/lsteamclient.dll (renamed from lsteamclient64)
    public var lsteamclientUnix: URL          // wineApp/Contents/Resources/lib/wine/aarch64-unix/lsteamclient.so
    public var launcherBinary: URL            // unchanged
    public var steamHelper: URL               // unchanged (bin/steam.exe)
    public var steamBridgeInstalled: Bool     // [steamHelper, lsteamclientUnix, lsteamclient]
    public var runtimeDamagedMarker: URL      // <root>/runtime-damaged (§3.3, §3.9)
    public var runtimeVersion: String?        // CFBundleShortVersionString from Contents/Info.plist (see D.6: not Bundle(url:))
    public var identity: String?              // §5.1, lowercase hex of kSecCodeInfoUnique; nil when unsigned or unreadable
    /// "<version> (<identity, 12 hex digits>)" for launcher.log (§3.10) and the menu (§3.9).
    public var runtimeLabel: String           // optional helper; avoids formatting the same thing in two places
    public static let rosettaEraEntries = ["Libraries", "gptk", "gptk.json", "lib", "dxmt-version", "runtime-version", "runtime.staging"]
}
```
- **Delete:** `libraries`, `wineLib`, `dxvk`, `gptkStore`, `gptkManifest`, `runtimeVersionFile`, `lsteamclient32`, `presenterLibrary`,
  `presenterInstalled`, `dxmtD3D12`, `dxmtHasD3D12`, `gptkVersion` and `gptkImported`. Our `d3d12.dll` is always in wine.app, so every
  `dxmtHasD3D12` branch goes away.
- **Same-commit breakages outside this area:**
  - `RuntimeInstaller.swift:90-104,131`, `GPTKImporter.swift` (deleted), `DXMTInstaller.swift` (deleted) and `CommandLineTool.swift:7-56`.
  - `AppModel.swift:74-80,109-110,131`, `SetupView.swift:17-23,37`, `MenuContent.swift:11` and `GamesView.swift:41-43,55`.
- **The R0b entry points are outside my files:**
  - `toolManifest`/`protonStub` live at `RuntimeInstaller.swift:50-62` and are written at :110-117.
  - The `passthrough` verb would be a `CommandLineTool` subcommand, not a `Verb` case: `Verb` is Proton's set and `LaunchRequest.parse`
    rejects anything else. Today's script and `installNativeTool` are at `SteamPlayMode.swift:20-34,195-218`. See D.11.
- **Tests:**
  - Rewrite `PathsTests.layoutPathsFollowTheRuntimeTarball` (:28) into `layoutPathsFollowWineApp`. Keep `layoutFromExecutableIsTwoLevelsUp`.
  - Rewrite `runtimeAndGPTKVersionsComeFromFiles` (:42) into `runtimeVersionComesFromWineAppInfoPlist` (and a nil case).
  - Add the identity tests (see §5.1).

### §3.2 Per-game settings
- **GameSettings.swift:**
  - Delete `avx` (:7), its init parameter (:12,16) and the `MACNEUTRON_NO_AVX` line (:27). The new init is
    `init(graphics: String? = nil, log: Bool? = nil, msync: Bool? = nil, runAs: RunAs? = nil, metalFX: Bool? = nil)`.
  - Old files with `"avx"` still decode with the synthesized Codable; no custom decoder is needed.
- **GraphicsBackend.select:** old `graphics` values (`d3dmetal`, `dxvk`) already fall into the "unknown" branch and come back as
  `(.dxmt, note)`. Optionally give them their own wording, e.g. `"'d3dmetal' was removed in 0.1, using dxmt"`.
- **Tests:**
  - `GameSettingsTests.settingsBecomeLaunchVariables` (:5): drop `avx:` and the `MACNEUTRON_NO_AVX` key.
  - `storeRoundTripsAndDefaultsWhenMissing` (:13): use `"wined3d"`.
  - New `oldSettingsFilesStillLoad`: write `{"avx":false,"graphics":"d3dmetal"}`, then `load` → `GameSettings(graphics: "d3dmetal")`.
  - New launcher test `oldGraphicsValueRunsDXMTWithANote`: settings with `graphics: "dxvk"` → `backend=dxmt` and a `note=` on the log line.

### §3.3 Preflight
Proposed shape. It keeps the closure injection used by `rosettaAvailable`.
```swift
public enum PreflightError: Error, Equatable, CustomStringConvertible {
    case unsupportedSystem          // §10 row 1 (the spec gives no exact text; propose "MacNeutron needs macOS 27 or later on an Apple Silicon Mac.")
    case runtimeMissing             // "MacNeutron's runtime is missing or damaged. Open MacNeutron to repair it."
    case thirtyTwoBit               // "This game is 32-bit. MacNeutron 0.1 runs 64-bit games only; 32-bit support is planned."
    case unsupportedMachine(UInt16) // "This game is built for <name>, which MacNeutron can't run." (names: 0x1c4 ARM (32-bit), 0x200 Itanium, else String(format: "machine type 0x%04x"))
}
public struct Preflight: Sendable {
    public let systemSupported: @Sendable () -> Bool    // default: ProcessInfo.isOperatingSystemAtLeast(27,0,0) && sysctl hw.optional.arm64 == 1
    public let identity: @Sendable (ToolLayout) -> String?   // default: { $0.identity }; lets launcher tests use an unsigned fake wine.app
    public init(systemSupported: ... = { ... }, identity: ... = { $0.identity })
    /// Returns the runtime identity, which the launcher reuses for the prefix stamp and the log line.
    public func check(_ layout: ToolLayout, request: LaunchRequest) throws(PreflightError) -> String
}
public enum PEImage { public static func machine(of url: URL) -> UInt16? }   // nil = not a PE file (see C.1)
```
- **Order:**
  - Check `systemSupported()`.
  - Check that `wine` and `wineserver` are executable and the identity is non-nil. Otherwise write `runtimeDamagedMarker` with
    `try? Data().write(to:)` and throw `.runtimeMissing`.
  - Only for `waitforexitandrun`, check the target: when `PEImage.machine(of: URL(filePath: request.target))` is `0x8664` or `0xAA64`,
    pass; `0x14c` throws `.thirtyTwoBit`; any other machine throws `.unsupportedMachine(m)`; nil passes.
- **The `run` + i386 skip is not an error.** Do it in `Launcher.launch` right after preflight:
  `if request.verb == .run, PEImage.machine(of: URL(filePath: request.target)) == 0x14c { log.append("skipped 32-bit installer \(name)"); return 0 }`.
  An alternative is an outcome enum returned by `check`, but the launcher branch is smaller.
- `sysctl` reading can copy the pattern in `ShaderPrecache.macOSBuild()` (:101-107): `var v: Int32 = 0; var n = MemoryLayout<Int32>.size;
  sysctlbyname("hw.optional.arm64", &v, &n, nil, 0) == 0 && v == 1`.
- **Delete:** `rosettaMissing`, `rosettaRuntime` and `rosettaAvailable` (:4,9-10,20-27,30).
  - Cross-area: `SteamPlayMode.swift:44,93`, `SteamPlayError.rosettaMissing` (`SteamLocation.swift:89,98`),
    `SteamPlayModeTests.swift:12,149,223-226,237,249` and `AppModelTests.swift:83-93`.
- **Launcher.swift:52-56:**
  - Becomes `let identity: String; do { identity = try preflight.check(layout, request: request) } catch { return fail(...) }`.
  - Move `logging`/`gameLog` (:60,66) above it so `fail` can also append to the game log, as §10 rows 2, 5 and 6 require. See D.8.
- **Tests:**
  - `PreflightTests`:
    - Delete `passesWithRosettaAndRuntime` (:5) and `reportsMissingRosettaFirst` (:9).
    - Rewrite `reportsMissingRuntime` (:14).
    - Replace `runtimeWithoutVersionFileIsIncomplete` (:20) with `unreadableIdentityIsDamagedAndMarked`, which asserts that the marker exists.
    - Keep `notificationTextIsEscapedForAppleScript`.
    - New tests: `unsupportedSystemIsRefusedFirst`, `x64AndArm64TargetsPass` (0x8664, 0xAA64), `i386TargetIsThirtyTwoBit`,
      `otherMachineIsNamed` (0x1c4), `nonPETargetIsNotChecked` (a script and a missing file), `targetIsCheckedOnlyForWaitForExitAndRun`.
  - `LauncherTests`:
    - Replace `missingRosettaNotifiesAndFails` (:106) with `missingRuntimeNotifiesAndFails` and `runSkipsA32BitInstaller` (exit 0, no
      runner calls, no notification, the log line).
    - Add `thirtyTwoBitGameIsRefusedWithItsMessage`.
    - `makeFixture` (:20-34) drops `rosetta:` and passes `Preflight(systemSupported: { true }, identity: { _ in "0123456789abcdef0123" })`.
  - `ShaderPrecacheTests.makePrecacheFixture` (:41) needs the same change.

### §3.4 Prefixes
Proposed shape:
```swift
public enum PrefixError: Error, Equatable, CustomStringConvertible {
    case lockFailed(String); case winebootFailed(Int32); case dllCopyFailed(String); case steamBridgeCopyFailed(String)
    case emulatorSetupFailed(Int32)      // NEW: the FEX reg add (see D.4)
}
public struct PrefixManager: Sendable {
    public let context: CompatContext; public let layout: ToolLayout; public let identity: String
    public let runner: any ProcessRunner; public let log: LauncherLog
    public init(context: CompatContext, layout: ToolLayout, identity: String, runner: any ProcessRunner, log: LauncherLog)
    public static func stamp(identity: String, msync: Bool) -> String   // "wine.app <identity> msync=<0|1>"
    static let preparingStamp = "wine.app preparing"
    public func prepare(environment: [String: String], steamBridge: Bool = false) throws     // `backend:` parameter removed
    public func removeSteamBridge() throws                                                    // unchanged
}
```
- **`prepare` under `withFileLock(at: context.lockFile)`:**
  - Set `msync = (Int(env["WINEMSYNC"] ?? "") ?? 0) != 0` (atoi semantics, patch 0015:568), `want = stamp(identity, msync)` and
    `recorded = trimmed versionFile`.
  - If `pfx` exists and `recorded == want`, there is nothing to do.
  - If `pfx` exists and `recorded` has the prefix `"wine.app \(identity) msync="` (msync-only):
    - `old = env` with `WINEMSYNC` set to `"1"` when the recorded field is `1`, removed otherwise.
    - Run `runner.run(layout.wineserver, ["-k"], environment: old)` and log `note: msync changed, stopped the prefix's wineserver`.
    - Write `want`.
  - Otherwise:
    - a. If `pfx` exists and `!(recorded?.hasPrefix("wine.app ") ?? false)`, rename it to the first free `pfx.rosetta`, `pfx.rosetta-2`, …
      (`FileManager.moveItem`) and log it.
    - b. Write `preparingStamp`.
    - c. `wine wineboot -u` with `WINEDLLOVERRIDES = LaunchEnvironment.mergeOverrides("mscoree,mshtml=", user: env["WINEDLLOVERRIDES"])`.
      Put the user's string last so an explicit user choice wins; drop "user:" order if the spec means ours wins. A non-zero status
      throws `winebootFailed`.
    - d. `wine reg add HKLM\Software\Microsoft\Wow64\amd64 /ve /d libarm64ecfex.dll /f`. Argv: `["reg","add",#"HKLM\Software\Microsoft\Wow64\amd64"#,"/ve","/d","libarm64ecfex.dll","/f"]`.
    - e. The ShowCrashDialog `reg add` (as today, best effort).
    - f. Copy `ToolLayout.dxmtDLLs` from `layout.dxmt` to `drive_c/windows/system32/<name>`.
    - g. `wineserver -w`, then write `want`.
  - Then `if steamBridge { deploySteamBridge() }`, every launch, copying when different (§3.5).
- **Delete:** `runtimeVersion` (:24,27,30), `needsPreparation` (:35-39; or replace it with an internal state enum) and
  `deployDLLs(for:)` (:61-71). The DLL copy moves into the prepare branch and stops running on every launch.
- **Launcher.swift:68-69:** becomes `PrefixManager(context:, layout:, identity: identity, runner:, log:)`. The `prepare(backend:...)`
  calls at :77, :84 and :112 drop `backend:`.
- **Tests** (`PrefixManagerTests`; `makeManager` :5-11 changes to `identity: "id1"` and `LaunchEnvironment.build` without `layout:`):
  - `freshPrefixRunsWinebootAndRecordsVersion` (:13): expect the calls `wineboot -u`, FEX `reg add`, crash-dialog `reg add` and
    `wineserver -w`, the stamp `wine.app id1 msync=1`, and wineboot's `WINEDLLOVERRIDES` containing `mscoree=;mshtml=`.
  - `failedWinebootSkipsTheCrashDialogSetting` (:27): keep it, and also assert no FEX `reg add`.
  - `upToDatePrefixSkipsWineboot` (:34): keep.
  - `runtimeChangeUpgradesPrefix` (:42): rewrite. Writing `runtime-old` now means **rename to `pfx.rosetta`**. Use
    `wine.app id0 msync=1` for the "identity changed → prepare in place, no rename" case.
  - `failedWinebootKeepsPrefixAndVersion` (:51): **inverts**. The stamp ends up `wine.app preparing`, the save file survives, and the
    next prepare retries without renaming.
  - `deploysBackendDLLsIntoBothSystemFolders` (:61): rewrite to `copiesDXMTIntoSystem32Only` (4 DLLs, no `syswow64`).
  - `missingRuntimeDLLIsAnError` (:72): keep, but against `layout.dxmt`.
  - `concurrentLaunchesRunWinebootOnce` (:79): keep.
  - `steamBridgeIsCopiedIntoTheSteamFolder` (:104): no `steamclient.dll`.
  - `thirtyTwoBitClientIsSkippedWithoutAnI386Build` (:124): delete.
  - `dxmtDeploysOurD3D12WhenInstalled` (:139): fold into the DXMT copy test.
  - New: `rosettaEraPrefixIsRenamedNeverDeleted`, `renameNumbersPastTakenNames`, `preparingStampIsRetriedInPlace`,
    `msyncOnlyChangeKillsTheServerUnderTheOldMode` (`wineserver -k` with old `WINEMSYNC`, no wineboot) and
    `failedFEXRegistrationFailsThePreparation`.
- **LauncherTests `waitForExitAndRunPreparesWaitsRunsThenWaits` (:36-55)** expects this call list:
  `wine wineboot -u`, `wine reg add HKLM\…\amd64 …`, `wine reg add HKCU\…WineDbg …`, `wineserver -w` (end of preparation),
  `wineserver -w` (:86), `wine /g/Game.exe -windowed` and `wineserver -w`. **Flag:** that is two back-to-back `-w` calls on a first
  launch. They are harmless, and the plan can keep both.

### §3.5 Steam bridge
- `SteamBridge.prefixFiles(layout:)` (:18-25) becomes `[(layout.steamHelper, "\(prefixFolder)/steam.exe"), (layout.lsteamclient, "\(prefixFolder)/steamclient64.dll")]`.
  Delete the i386 branch.
- `PrefixManager.install(_:at:)` (:93-99) gets a skip: compare `attributesOfItem` `.size` and `.modificationDate` of the source and the
  target, and return when both match. After copying, set the target's `.modificationDate` to the source's explicitly. See D.9.
- `removeSteamBridge` (:85-91) keeps the `steamclient.dll` name, which is harmless and cleans up.
- `Launcher.addSteamClient` (:170-184) and `usesSteamBridge` (:144-155) are unchanged.
- **Tests:**
  - `installFakeSteamBridge(in:)` drops `i386:` and writes `layout.lsteamclient`.
  - `SteamBridgeTests.bridgeNeedsSteamExeAndBothHalvesOfTheClient` (:44): drop `i386: false`.
  - New `PrefixManagerTests.unchangedBridgeFilesAreNotRecopied` (inode or mtime unchanged on the second prepare) and
    `changedBridgeFileIsRecopied`.

### §3.6 Graphics
```swift
public enum GraphicsBackend: String, Sendable, CaseIterable {
    case dxmt, wined3d
    public static func select(requested: String?) -> (backend: GraphicsBackend, note: String?)   // gptkImported removed
    public var dllOverrides: String {   // property, no layout
        switch self {
        case .dxmt: "dxgi,d3d10core,d3d11,d3d12=n,b;d3d9,d3d10=b"
        case .wined3d: "dxgi,d3d9,d3d10,d3d10core,d3d11,d3d12=b"
        }
    }
}
```
- **Delete:** `prefixDLLs(layout:)` (:44-59), the GPTK branches (:17-24) and the `d3dmetal`/`dxvk` cases.
- **Tests** (`GraphicsBackendTests`):
  - Delete `unknownRequestWithGPTKFallsBackToDXMT`, `dxmtDeploysOurD3D12To64BitOnly`, `dxvkUsesWinesDXGIAndOnlyTheDLLsTheRuntimeShips`,
    `dxmtDeploysBothArchitectures`, `dxvkFallsBackToD3DMetalWhenGPTKIsImported` and the `dxmtLayout` helper.
  - Rewrite:
    - `defaultsToDXMTEvenWithGPTK` and `defaultsToDXMTWithoutGPTK` become `defaultsToDXMT`.
    - `d3dmetalStaysSelectableWithGPTK` and `d3dmetalWithoutGPTKFallsBackToDXMT` become `removedBackendsReadAsDXMTWithANote`
      (d3dmetal, dxvk).
    - `dxmtTakesD3D12OnlyWithOurD3D12` becomes `overrideStringsPerBackend`.
    - `honorsRequestCaseInsensitively` uses `" WINED3D "`.
  - Keep `unknownRequestFallsBackWithNote` and `everyBackendOverridesTheSameDLLSet` (drop its layout loop).
- **Launcher.swift:58-59:** `GraphicsBackend.select(requested: environment["MACNEUTRON_GRAPHICS"])`.

### §3.7 Environment
- `LaunchEnvironment.build(base:context:backend:logging:)` drops `layout:`.
  - :10 becomes `mergeOverrides(backend.dllOverrides, user:)`.
  - Delete :14-16 (`ROSETTA_ADVERTISE_AVX`).
  - :17-19 keeps `WINEMSYNC=1` unless `MACNEUTRON_NO_MSYNC=1`. Spec: "then unset", so in that case `env.removeValue(forKey: "WINEMSYNC")`.
    Today a user's `WINEMSYNC` survives; see D.5.
  - :20 becomes `ShaderPrecache.enabled(backend:environment:)`.
  - `MACNEUTRON_PRESENT=1` unless `MACNEUTRON_NO_METALFX=1` (and unless the user set it). Where it goes is a decision; see D.7.
- **Delete** `Launcher.addPresenter` (:157-167) and its call at :65. Nothing sets `DYLD_INSERT_LIBRARIES` any more.
- **`terminate` (:127-133):**
  - Merge `try? settings.load(context.appID).environment` under the raw env, as `launch` does at :48.
  - Then `env = LaunchEnvironment.build(base: merged, context: context, backend: GraphicsBackend.select(requested: merged["MACNEUTRON_GRAPHICS"]).backend, logging: false)`.
  - Then `wineserver -k`.
  - Factoring `mergedEnvironment(context:steam:)` out of `launch` avoids duplicating it.
- **Tests:**
  - `LaunchEnvironmentTests`:
    - `setsPrefixOverridesAndDefaults` (:8) expects `"dxgi=n,b;d3d10core=n,b;d3d11=n,b;d3d12=n,b;d3d9=b;d3d10=b"` and drops the AVX line.
    - `userSettingsWin` (:23) drops `ROSETTA_ADVERTISE_AVX` and expects `dxgi=n,b;d3d10core=n,b;d3d11=b;d3d12=n,b;d3d9=b;d3d10=b;xinput1_3=n`.
    - `optOutsDropDefaults` (:32) drops AVX and adds the `MACNEUTRON_NO_METALFX` → no `MACNEUTRON_PRESENT` case.
    - Rename `userOverridesWinOverOurD3D12` (:43) to `userOverridesWin`; it needs no layout.
    - `recordsPipelinesOnlyForOurD3D12` (:51) becomes `recordsPipelinesForDXMTOnly` (dxmt yes, wined3d no, `PRECACHE=0` no, the user's
      path wins).
    - New `wined3dOverridesUseBuiltins`.
  - `LauncherTests`:
    - The 6 presenter tests (:254-301) become `presenterIsAskedForByDefault` (`MACNEUTRON_PRESENT == "1"`, no `DYLD_INSERT_LIBRARIES`),
      `optingOutLeavesThePresenterOff` (launch option and `GameSettings(metalFX: false)`) and `toolCommandsGetNoPresenter` if the verb
      gating stays.
    - Delete `presenterComesAfterTheUsersOwnLibraries` and `missingPresenterIsNoted`.
    - `terminateKillsThePrefixWineserver` (:137) adds `WINEMSYNC == "1"`, and a settings `msync: false` case where `WINEMSYNC` is nil.
  - The `hasPrefix("dxgi=n,b;d3d10core=n,b;d3d11=n,b")` checks at `LauncherTests.swift:100,151` stay true unchanged.

### §3.8 Shader pre-caching
- `ShaderPrecache.enabled(backend: GraphicsBackend, environment: [String: String]) -> Bool` is `backend == .dxmt && environment["MACNEUTRON_PRECACHE"] != "0"`.
  `layout:` and `dxmtHasD3D12` are dropped.
- `init(context:layout:osBuild:)` and `replay(layout:runner:environment:...)` keep their signatures. They pick up the new paths through
  `layout.dxmtVersion`, `layout.wine` and `layout.dxmtReplay`. The replayer argument is still the Unix path of
  `.../DXMT/aarch64-windows/dxmt-replay.exe`. `wine` takes a Unix path, as it does today.
- **Tests:**
  - `makePrecacheFixture` (:19-49) stops writing `dxmtD3D12`. It writes the replayer and `DXMT/version` inside the fake wine.app (or
    Support does) and changes the Preflight injection.
  - `changedBuildsReplayEveryRecordingBeforeTheGame` (:84) uses `layout.dxmtReplay`, whose path changes automatically.
  - The others are unchanged. Optionally add `aRosettaEraStampReplaysOnce` (stamp `1fba8d2… <build>` against `1fba8d2…+63a4969e01ba <build>`).

### §3.10 Stopping and logs
- `terminate`: see §3.7.
- `Launcher.swift:116-117` becomes `"verb=… appid=… backend=… runtime=\(layout.runtimeVersion ?? "unknown") (\(identity.prefix(12))) exit=…"`.
  Use `ToolLayout.runtimeLabel` if it is added; the menu needs the same string.
- Delete `gptk=`.
- **Tests:**
  - `everyLaunchIsLoggedWithVersions` (:130) expects `verb=run appid=42 backend=dxmt runtime=test (0123456789ab) exit=0`, with the
    injected identity and an Info.plist version of `test`.
  - Delete `defaultBackendIsDXMTEvenWithGPTKImported` (:303).

### §5.1 Identity (Security.framework)
- `ToolLayout.identity`, or a free function `codeIdentity(of bundle: URL) -> String?`:
  ```swift
  import Security
  public var identity: String? {
      var code: SecStaticCode?
      var info: CFDictionary?
      guard SecStaticCodeCreateWithPath(wineApp as CFURL, [], &code) == errSecSuccess, let code,
            SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
            let unique = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data
      else { return nil }
      return unique.map { String(format: "%02x", $0) }.joined()   // 40 hex, equals codesign's CDHash=
  }
  ```
  - Pass the **bundle** URL. `codesign -dvvv wine.app` shows that the bundle's CDHash is the loader's code directory (`Executable=…/MacOS/wine`).
  - `kSecCSSigningInformation` is what patch 0007 already uses (`wine-arm64/patches/wine/0007-*.patch:93-95`). Whether
    `kSecCodeInfoUnique` also comes back with default flags (`[]`) is unverified; the identity test settles it.
  - An unsigned bundle gives success with no `kSecCodeInfoUnique`, so the result is nil.
  - A missing path makes `SecStaticCodeCreateWithPath` fail, so the result is nil.
- **Linking:** `import Security` autolinks (the Clang module carries `link framework "Security"`), as `import CryptoKit` does in
  `RuntimeInstaller.swift:1` with no `linkerSettings`. **Package.swift needs no change** for Security.
- **Cost:** it reads the code directory only and validates no resources. It is fine per launch, but call it once and pass the result
  around (`Preflight.check` returns it).
- **New tests** (`IdentityTests.swift`, or in `PathsTests`), using real ad-hoc signing:
  - Helper `makeSignedWineApp(at dir: URL, loader: URL = URL(filePath: "/usr/bin/true"), shortVersion: String = "test") throws -> URL`:
    - Write `Contents/Info.plist` (CFBundleExecutable=wine, CFBundleIdentifier=test.wine, CFBundleShortVersionString) with
      `PropertyListSerialization`.
    - Copy `loader` to `Contents/MacOS/wine`.
    - Run `SystemProcessRunner().run(URL(filePath: "/usr/bin/codesign"), ["-s", "-", "-f", bundle.path], environment: [:], output: nil) == 0`.
    - Test precedent for running real processes: `PrefixManagerTests.systemRunnerReportsStatusAndCapturesOutput` (:92).
    - Copying a platform binary and re-signing it ad hoc works with `-f`. The loader is never executed.
  - `identityMatchesCodesignsCDHash`: compare with `codesign -dvvv` stderr `CDHash=`. Optional; it pins the format.
  - `bundlesDifferingOnlyInTheLoaderDiffer`: `/usr/bin/true` against `/usr/bin/false`.
  - `bundlesDifferingOnlyInInfoPlistDiffer`: same loader, different `CFBundleVersion`.
  - `resigningIdenticalBitsKeepsTheIdentity`: run codesign `-f -s -` twice. Ad hoc has no timestamp, so it is stable.
  - `unsignedOrMissingBundleHasNoIdentity`.
- The §3.9 install tests (outside my files) need `codesign --verify --strict` to pass, so their source bundles must be signed **after**
  all their content is written.

---

## C. Binary reading and signing notes

### C.1 PE header: there is no PE reader in the repo
- The only binary parser is `AppInfoReader.swift`. Its `Cursor` (:113-142) is `private`, its errors are typed `AppInfoError`, and it
  reads the **whole file** (`Data(contentsOf:)` at :40), which is wrong for a multi-GB game exe. Don't promote it.
- Proposed new file, `Sources/MacNeutronCore/PEImage.swift` (about 20 lines, header-only reads):
  ```swift
  public enum PEImage {
      public static let i386: UInt16 = 0x014c, amd64: UInt16 = 0x8664, arm64: UInt16 = 0xAA64
      /// The COFF `Machine` of a PE file, or nil when `url` isn't one (missing, a script, a .bat, truncated).
      public static func machine(of url: URL) -> UInt16? {
          guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
          defer { try? h.close() }
          guard let dos = try? h.read(upToCount: 64), dos.count == 64, dos[0] == 0x4D, dos[1] == 0x5A else { return nil }  // "MZ"
          let lfanew = (0..<4).reduce(UInt32(0)) { $0 | UInt32(dos[0x3C + $1]) << (8 * $1) }
          guard lfanew < 1 << 20, (try? h.seek(toOffset: UInt64(lfanew))) != nil,
                let nt = try? h.read(upToCount: 6), nt.count == 6, nt.starts(with: [0x50, 0x45, 0, 0]) else { return nil }  // "PE\0\0"
          return UInt16(nt[4]) | UInt16(nt[5]) << 8
      }
  }
  ```
  - Careful: `Data` slices keep their parent's indices. `read(upToCount:)` returns a fresh `Data`, so `[0]` is safe.
- Machine values: ARM64EC images report 0x8664 and ARM64X report 0xAA64. A .NET AnyCPU exe is 0x14c, so it gets the 32-bit message,
  which the spec accepts.
- Tests write synthetic bytes:
  - 64-byte DOS header with `e_lfanew=0x80`, `PE\0\0`, machine.
  - A shell script.
  - A truncated `MZ`.
  - A missing file.

### C.2 Ad-hoc signing in tests
`/usr/bin/codesign -s - -f <bundle>` on a temp bundle. The details are in §5.1 above. Two notes:
- `makeTempDir` paths contain a space, which codesign handles because argv is passed directly.
- Keep these tests few: each codesign takes tens of ms. Launcher, Prefix and Precache tests should use the injected identity, not
  signing (see D.1).

---

## D. Flags: where the code makes the spec awkward or contradicts it

1. **An unsigned fake `wine.app` fails preflight.**
   - §3.3 step 2 requires a readable identity. If Support's fake tree is unsigned, every launcher, precache and prefix test fails.
   - Recommendation: inject the identity on `Preflight` (`identity: @Sendable (ToolLayout) -> String?`, the same style as
     `rosettaAvailable` today), with `check` returning it.
   - Test the real Security call only in the identity suite.
   - The alternative is one ad-hoc-signed template per test process, cloned per test. It is more realistic but slower and couples
     every test to `codesign`.
2. **The stamp scheme inverts two existing tests.**
   - `runtimeChangeUpgradesPrefix` (PrefixManagerTests:42) writes `runtime-old`, which now means "Rosetta-era → rename".
   - `failedWinebootKeepsPrefixAndVersion` (:51) expects the old stamp kept, but step 2 writes `wine.app preparing` before wineboot.
   - Rewrite both; don't try to preserve them.
3. **The DXMT copy moves from every launch to prepare-only.**
   - Today `deployDLLs` runs outside `needsPreparation` (PrefixManager.swift:56). Under §3.4 step 6 the DLLs are only refreshed when
     the identity changes.
   - That is correct, because the identity covers DXMT. But a user who deletes `system32/d3d11.dll` won't get it back until the next
     runtime update. Accept and state it.
4. **§3.4 step 4: is the FEX registration fatal?**
   - The spec is silent. Without it, x64 code runs on Wine's `xtajit64` stub, so every x64 game fails confusingly.
   - Recommend throwing (`PrefixError.emulatorSetupFailed(Int32)`), unlike ShowCrashDialog's best effort. The stamp stays
     `wine.app preparing`, so the next launch retries.
5. **WINEMSYNC derivation.**
   - The stamp's msync field must come from the **built env** (`WINEMSYNC` with `atoi` semantics, patch 0015:568), not from the
     setting. Launch options may set `WINEMSYNC=0`.
   - §3.7 "unset when NO_MSYNC" differs from today's `LaunchEnvironment.swift:17`, where a user `WINEMSYNC` survives `MACNEUTRON_NO_MSYNC=1`.
     Pick one; the spec says unset.
   - The msync client/server agreement check lives in the client (patch 0015:736-747). `wineserver -k` likely doesn't care, but doing
     what the spec says costs nothing.
6. **`runtimeVersion` from Info.plist must not use `Bundle(url:)`.**
   - Foundation caches `Bundle` per path for the process lifetime, so the long-lived app would show a stale version after a reinstall
     or swap.
   - Read `Contents/Info.plist` with `PropertyListSerialization` (or `NSDictionary(contentsOf:)`) each time.
   - Today's staged bundle has **no** `CFBundleShortVersionString` until §5.1's bundle.sh change, so nil has to be tolerated
     ("unknown"). Preflight must check the identity, never the version.
7. **Where `MACNEUTRON_PRESENT=1` goes (§3.7).**
   - Today the presenter is added only for `run`/`waitforexitandrun` (Launcher.swift:65; test `toolCommandsGetNoPresenter`).
   - If `LaunchEnvironment.build` sets it, it also reaches wineboot, winepath and `dxmt-replay.exe`. That is probably harmless, because
     only `winemetal.so` reads it, but a replay may load the presenter.
   - Default: keep today's verb gating, as a 2-line helper replacing `addPresenter`.
8. **§10 wants game-log lines for failures.**
   - Today `fail` (Launcher.swift:201-206) writes `launcher.log`, stderr and the notification only, and preflight runs before `gameLog`
     exists (:53 vs :66).
   - Move `logging`/`gameLog` above preflight and have `fail` append to the game log when it is set.
   - The "entitlement refused" row (patch 0007's `fatal_error` text) **cannot be detected** today. Without `MACNEUTRON_LOG=1` Wine's
     stderr is inherited, not captured (`runGame` :139 passes `output: gameLog` = nil). Notifying on it needs always-on stderr capture
     or a pre-exec entitlement check in Swift (the same Security call with `kSecCodeInfoEntitlementsDict`). The spec doesn't say which.
9. **Copy-when-different (§3.5) depends on mtime preservation.**
   - Compare `.size` and `.modificationDate`. Whether `FileManager.copyItem` preserves the source mtime is unverified here, because no
     builds were allowed.
   - If it doesn't, every launch recopies 57 MB. So set `.modificationDate` on the target explicitly after copying, and assert in a
     test that a second prepare doesn't recopy (same inode, or a sentinel mtime).
10. **§3.3 step 1 is nearly unreachable in the CLI.**
    - Once `Package.swift` says `.macOS("27.0")` and the CLI is arm64-only, dyld refuses to load it on macOS 26 or Intel before
      `main` runs.
    - The check stays for the message and the tests (injected), but the "launch exits non-zero with the same text" row of §10 can't
      actually happen.
    - `hw.optional.arm64` is 1 even under Rosetta, which doesn't matter here.
11. **The §3.1 passthrough verb (outside my files, at the boundary).**
    - `posix_spawnattr_setbinpref_np` takes a `cpu_type_t` only, so it can't express "arm64e before arm64".
    - `arch -arm64e -arm64 -x86_64` uses `posix_spawnattr_setarchpref_np` (type and subtype: `CPU_TYPE_ARM64`/`CPU_SUBTYPE_ARM64E`,
      `CPU_TYPE_ARM64`/`CPU_SUBTYPE_ARM64_ALL`, `CPU_TYPE_X86_64`/`CPU_SUBTYPE_X86_64_ALL`), plus `POSIX_SPAWN_SETEXEC`.
    - `.app` resolution: `Bundle(url:)?.executableURL`, falling back to `Contents/MacOS/<basename>`, replaces PlistBuddy. A one-shot
      CLI has no caching issue.
    - Tests can only cover resolution and the preference table; never call SETEXEC in-process.
12. **A leftover `proton` stub after R0b.**
    - The §3.1 Rosetta-era removal list doesn't include `proton`. If R0b passes, existing tool folders keep a dead `proton` stub.
    - Add it to the removal list, or have `writeToolFiles` delete it when the manifest no longer points to it.
13. **`run` + i386 and Steam's `iscriptevaluator.exe`.**
    - LauncherTests use `run /g/iscriptevaluator.exe --get-current-step 42`. If Steam's own `iscriptevaluator.exe` is i386 (on Linux
      Proton it lives in Steam's `legacycompat/`), §3.3's skip turns **every** install-script run into "exit 0, skipped". That is
      probably what's wanted, but it means install scripts never run, not just 32-bit redistributables.
    - The file isn't present on this Mac (0 `run` launches ever), so it is unverified. Worth one line in the plan.
14. **Every launch now carries `wineserver -w` twice** on a first prepare: step 7 inside the lock, then Launcher.swift:86. This is
    harmless, and the second returns at once.
15. **Cross-area compile coupling: these must land in the same commit as the core changes.**
    - The ToolLayout and Preflight deletions break `RuntimeInstaller.swift`, `CommandLineTool.swift`, `SteamPlayMode.swift:44,93`,
      `SteamLocation.swift:89,98`, `AppModel.swift:74-80,109-110,131`, `SetupView.swift:17-37`, `MenuContent.swift:11` and
      `GamesView.swift:41-55`.
    - They also break the tests `DXMTInstallerTests`, `GPTKImporterTests`, `GPTKDiskImageTests`, `RuntimeInstallerTests`,
      `CommandLineToolTests:17-50`, `SteamPlayModeTests:12,149,223-249` and `AppModelTests:83-99`.
    - `Support.swift`'s `makeDXMTBuild` (:130-143) and `installFakePresenter` (:125-127) go too.
16. **§10 says the old `avx` value is "noted on each launch"; §3.2 says unknown keys are ignored.**
    - The synthesized Codable can't see an unknown key, so noting it needs a custom decoder or a raw-JSON peek.
    - Recommend following §3.2 (ignore silently) and noting only old `graphics` values, which `select` already does.
