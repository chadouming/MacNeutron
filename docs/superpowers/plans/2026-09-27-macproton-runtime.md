# MacProton Runtime (Sub-project 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `macproton` compatibility tool. It is a Swift CLI that implements Proton's verbs for Steam, on top of a pinned CrossOver-based Wine runtime with D3DMetal, DXMT and DXVK backends, and it can be installed into a Steam compatibility-tools folder.

**Architecture:**
- One Swift package. The `MacProtonCore` library holds all the logic: verb parsing, building the environment, prefix management, GPTK import and runtime install.
- Every child process goes through a `ProcessRunner` protocol, so unit tests never start Wine.
- A thin `macproton` executable calls `CommandLineTool.run`.
- The folder Steam sees contains two VDF manifests, a two-line `proton` shell stub that `exec`s `bin/macproton launch`, and the unpacked runtime in `Libraries/`.

**Tech Stack:** Swift 6.4 (tools-version 6.0, Swift 6 language mode), swift-testing, Foundation/CryptoKit/Darwin only, winecx-gptk `runtime-v4.7.3`, mingw-w64 (smoke binaries only).

**Spec:** `docs/superpowers/specs/2026-09-27-macproton-runtime-design.md`

## Global Constraints

- **Platform:** Apple Silicon only, macOS 26 or later: `platforms: [.macOS("26.0")]`. Rosetta 2 is required at runtime.
- **Dependencies:** none from third parties. Only Foundation, CryptoKit, Darwin, Dispatch and swift-testing.
- **Apple files:** never shipped. `import-gptk` copies D3DMetal from the user's own GPTK.
- **Tool identity:** name `macproton`, `from_oslist "windows"`, `to_oslist "linux"`, `commandline "/proton %verb%"`. The tool name must never contain `arm64`, because Steam ignores those.
- **Runtime pin:** `runtime-v4.7.3`, `https://github.com/dappermint/winecx-gptk/releases/download/runtime-v4.7.3/Libraries.tar.gz`, SHA-256 `a4b5d63493f80698cce5cad8e7212d9a51c8292037b00c478f4652636fcfd331`.
- **Default locations:**
  - Tool folder: `~/Library/Application Support/MacProton/compatibilitytools.d/macproton`
  - Logs: `~/Library/Logs/MacProton`
  - Download cache: `~/Library/Caches/MacProton`
- **Paths contain spaces** (Steam lives in "Application Support"). Always pass argument arrays to `Process`; never build shell command strings.
- **Prefix safety:** nothing under a prefix's `drive_c` is ever deleted.
- **The launcher never throws to Steam.** Every failure becomes exit 1 plus a `launcher.log` line. Failures that block a launch also post a notification.

## Review Focus

These inputs are implied by the spec but easy to miss. Each is pinned by a test in the task that owns the code.

1. **Paths with spaces**, e.g. `…/Application Support/…/compatdata/<appid>`, must work end to end. Covered by Task 2 (`readsSteamCompatEnvironment`), Task 10 (`protonStubForwardsArgumentsFromAPathWithSpaces`) and Task 12 (the smoke work dir contains a space).
2. **Game arguments with spaces, quotes, Unicode or empty strings** reach Wine unchanged. Covered by Task 1 (`keepsArgumentsWithSpacesAndQuotesIntact`), Task 8 (`gameArgumentsPassThroughUnchanged`) and Task 12 (`exitcode.exe` must see exactly 2 arguments).
3. **A mistyped `MACPROTON_GRAPHICS` in Steam launch options** still launches with the default backend and logs why. Covered by Task 3 (`unknownRequestFallsBackWithNote`) and Task 8 (`invalidGraphicsSettingStillLaunchesWithDefault`).
4. **Two launches at once on first run** (Steam starts `iscriptevaluator` with `run` alongside the game) must not run `wineboot` twice. Covered by Task 5 (`concurrentLaunchesRunWinebootOnce`).
5. **Steam's Stop button** (SIGTERM) must kill the game's Wine processes, not just the launcher. Covered by Task 8 (`terminateKillsThePrefixWineserver`), Task 11 (signal handler) and Task 13 (run D).

## File Structure

| File | Responsibility |
|---|---|
| `Package.swift` | Package: `MacProtonCore` library, `macproton` executable (from Task 11), tests |
| `Makefile` | `build`, `test`, `smoke` |
| `Sources/MacProtonCore/Verb.swift` | `Verb`, `LaunchRequest.parse` |
| `Sources/MacProtonCore/CompatContext.swift` | Reads `STEAM_COMPAT_DATA_PATH` and `SteamAppId`; prefix, version and lock paths |
| `Sources/MacProtonCore/ToolLayout.swift` | Every path inside the tool folder; runtime and GPTK versions |
| `Sources/MacProtonCore/GraphicsBackend.swift` | Backend selection, DLL overrides, DLLs copied into the prefix |
| `Sources/MacProtonCore/LaunchEnvironment.swift` | Wine environment; merging `WINEDLLOVERRIDES` |
| `Sources/MacProtonCore/ProcessRunner.swift` | `ProcessRunner` protocol, `SystemProcessRunner` |
| `Sources/MacProtonCore/PrefixManager.swift` | Prefix create/upgrade under `flock`, DLL deployment |
| `Sources/MacProtonCore/LauncherLog.swift` | `launcher.log` with rotation; per-game log path |
| `Sources/MacProtonCore/Preflight.swift` | Rosetta and runtime checks; `Notifier`, `AppleScriptNotifier` |
| `Sources/MacProtonCore/Launcher.swift` | The verbs; the SIGTERM kill |
| `Sources/MacProtonCore/GPTKImporter.swift` | GPTK validation, store, overlay, `gptk.json` |
| `Sources/MacProtonCore/RuntimeInstaller.swift` | `RuntimePin`, checksum, extract, tool files, download |
| `Sources/MacProtonCore/CommandLineTool.swift` | Subcommands, option parsing, signal handlers |
| `Sources/macproton/main.swift` | Entry point |
| `Tests/MacProtonCoreTests/*.swift` | Unit tests; `Support.swift` holds the fakes and fixtures |
| `Tests/Smoke/{exitcode.c,d3d11probe.c,smoke.sh}` | Real-Wine smoke test |
| `docs/testing/acceptance-runtime.md` | Manual Steam acceptance test and results |
| `README.md` | Build, install and per-game options |

## Execution Notes

- **The code has been checked.** Every code block below compiled and passed (65 tests, no warnings) under Swift 6.4 / Xcode 27 in a scratch package on 2026-09-27. Copy it verbatim.
- **Running tests.** The full suite (`swift test`) takes under a second, so each task runs all of it. The expected count is cumulative.
- **Tasks 12 and 13 need the user's approval before starting.** Together they:
  - install Homebrew's `mingw-w64`;
  - download the 461 MB runtime;
  - need the user to download GPTK from developer.apple.com;
  - change the user's Steam setup;
  - add a free game license to the user's account.
- **macOS is case-insensitive.** `tests/` and `Tests/` are the same folder, so always write `Tests/`.

---

### Task 1: Package scaffold and verb parsing

**Files:**
- Create: `Package.swift`, `.gitignore`, `Makefile`
- Create: `Sources/MacProtonCore/Verb.swift`
- Test: `Tests/MacProtonCoreTests/VerbTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum Verb: String { run, waitforexitandrun, runinprefix, getcompatpath, getnativepath }`; `struct LaunchRequest { verb: Verb; target: String; arguments: [String]; static func parse(_ argv: [String]) throws(LaunchRequestError) -> LaunchRequest }`; `enum LaunchRequestError { missingVerb, unknownVerb(String), missingTarget(Verb) }`.

- [ ] **Step 1: Create the package files**

`Package.swift` (library and tests only; Task 11 adds the executable once it has a `main.swift`):

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacProton",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "MacProtonCore", targets: ["MacProtonCore"]),
    ],
    targets: [
        .target(name: "MacProtonCore"),
        .testTarget(name: "MacProtonCoreTests", dependencies: ["MacProtonCore"]),
    ]
)
```

```text
.build/
.swiftpm/
```

`Makefile` (recipe lines start with a tab):

```make
.PHONY: build test

build:
	swift build -c release

test:
	swift test
```

- [ ] **Step 2: Write the failing test**

```swift
import Testing
@testable import MacProtonCore

@Test func parsesSteamInvocation() throws {
    let request = try LaunchRequest.parse(["waitforexitandrun", "/games/Cats/Cats.exe", "-windowed"])
    #expect(request == LaunchRequest(verb: .waitforexitandrun, target: "/games/Cats/Cats.exe", arguments: ["-windowed"]))
}

@Test func keepsArgumentsWithSpacesAndQuotesIntact() throws {
    let args = ["run", "/Steam Library/Game Dir/Game.exe", "--name=\"Player One\"", "a b", "ünïcode"]
    let request = try LaunchRequest.parse(args)
    #expect(request.target == "/Steam Library/Game Dir/Game.exe")
    #expect(request.arguments == ["--name=\"Player One\"", "a b", "ünïcode"])
}

@Test func rejectsMissingVerb() {
    #expect(throws: LaunchRequestError.missingVerb) { try LaunchRequest.parse([]) }
}

@Test func rejectsUnknownVerb() {
    #expect(throws: LaunchRequestError.unknownVerb("destroyprefix")) { try LaunchRequest.parse(["destroyprefix", "x"]) }
}

@Test func rejectsVerbWithoutTarget() {
    #expect(throws: LaunchRequestError.missingTarget(.run)) { try LaunchRequest.parse(["run"]) }
}
```

- [ ] **Step 3: Run it and confirm it fails**

Run: `swift test 2>&1 | tail -5`
Expected: `error: 'macproton': target 'MacProtonCore' referenced in product 'MacProtonCore' is empty`. The library has no sources yet, so SwiftPM stops before compiling the test. The package name in the message is the folder name.

- [ ] **Step 4: Implement**

```swift
/// The Proton verbs Steam uses when it launches a game through a compatibility tool.
public enum Verb: String, Sendable, CaseIterable {
    case run
    case waitforexitandrun
    case runinprefix
    case getcompatpath
    case getnativepath
}

public enum LaunchRequestError: Error, Equatable, CustomStringConvertible {
    case missingVerb
    case unknownVerb(String)
    case missingTarget(Verb)

    public var description: String {
        switch self {
        case .missingVerb: "no verb given"
        case .unknownVerb(let verb): "unknown verb '\(verb)'"
        case .missingTarget(let verb): "verb '\(verb.rawValue)' needs a target path"
        }
    }
}

/// `proton <verb> <target> [args…]` exactly as Steam invokes it.
public struct LaunchRequest: Equatable, Sendable {
    public let verb: Verb
    /// The executable to run, or the path to convert for the get*path verbs.
    public let target: String
    /// Everything after the target, passed to the game untouched.
    public let arguments: [String]

    public static func parse(_ argv: [String]) throws(LaunchRequestError) -> LaunchRequest {
        guard let first = argv.first else { throw .missingVerb }
        guard let verb = Verb(rawValue: first) else { throw .unknownVerb(first) }
        guard argv.count >= 2 else { throw .missingTarget(verb) }
        return LaunchRequest(verb: verb, target: argv[1], arguments: Array(argv.dropFirst(2)))
    }
}
```

- [ ] **Step 5: Run it and confirm it passes**

Run: `swift test 2>&1 | tail -3`
Expected: `Test run with 5 tests in 0 suites passed`

- [ ] **Step 6: Commit**

```bash
git add Package.swift .gitignore Makefile Sources Tests
git commit -m "feat: parse Proton verbs from Steam's command line"
```

---

### Task 2: Steam compat context and tool layout

**Files:**
- Create: `Sources/MacProtonCore/CompatContext.swift`, `Sources/MacProtonCore/ToolLayout.swift`
- Test: `Tests/MacProtonCoreTests/Support.swift`, `Tests/MacProtonCoreTests/PathsTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct CompatContext { dataPath: URL; appID: String; init(environment: [String: String]) throws(CompatContextError); prefix: URL; versionFile: URL; lockFile: URL }`
  - `enum CompatContextError { missing(String) }`
  - `struct ToolLayout { root: URL; init(root:); init(executable:); static defaultRoot: URL; libraries, wineLib, wine, wineserver, dxmt, dxvk, gptkStore, gptkManifest, runtimeVersionFile, launcherBinary: URL; runtimeVersion: String?; gptkVersion: String?; gptkImported: Bool }`
  - Test helpers `makeTempDir() throws -> URL` (the path contains a space) and `write(_:to:executable:) throws`.

- [ ] **Step 1: Write the test helpers and the failing tests**

`Tests/MacProtonCoreTests/Support.swift`:

```swift
import Foundation
@testable import MacProtonCore

/// A fresh temp directory whose path contains a space, like Steam's "Application Support".
func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "macproton tests/\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func write(_ text: String, to url: URL, executable: Bool = false) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
    if executable {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
    }
}
```

`Tests/MacProtonCoreTests/PathsTests.swift`:

```swift
import Foundation
import Testing
@testable import MacProtonCore

@Test func readsSteamCompatEnvironment() throws {
    let context = try CompatContext(environment: [
        "STEAM_COMPAT_DATA_PATH": "/Users/me/Library/Application Support/Steam/steamapps/compatdata/42",
        "SteamAppId": "42",
    ])
    #expect(context.appID == "42")
    #expect(context.prefix.path(percentEncoded: false)
        == "/Users/me/Library/Application Support/Steam/steamapps/compatdata/42/pfx/")
    #expect(context.versionFile.lastPathComponent == "version")
    #expect(context.lockFile.lastPathComponent == "macproton.lock")
}

@Test func appIDDefaultsToZero() throws {
    let context = try CompatContext(environment: ["STEAM_COMPAT_DATA_PATH": "/tmp/x", "SteamAppId": ""])
    #expect(context.appID == "0")
}

@Test func missingDataPathIsAnError() {
    #expect(throws: CompatContextError.missing("STEAM_COMPAT_DATA_PATH")) {
        try CompatContext(environment: ["SteamAppId": "42"])
    }
}

@Test func layoutPathsFollowTheRuntimeTarball() {
    let layout = ToolLayout(root: URL(filePath: "/t/macproton", directoryHint: .isDirectory))
    #expect(layout.wine.path(percentEncoded: false) == "/t/macproton/Libraries/Wine/bin/wine")
    #expect(layout.wineserver.path(percentEncoded: false) == "/t/macproton/Libraries/Wine/bin/wineserver")
    #expect(layout.wineLib.path(percentEncoded: false) == "/t/macproton/Libraries/Wine/lib/")
    #expect(layout.dxmt.path(percentEncoded: false) == "/t/macproton/Libraries/DXMT/")
    #expect(layout.gptkStore.path(percentEncoded: false) == "/t/macproton/gptk/")
}

@Test func layoutFromExecutableIsTwoLevelsUp() {
    let layout = ToolLayout(executable: URL(filePath: "/t/macproton/bin/macproton"))
    #expect(layout.root.path(percentEncoded: false).hasSuffix("/t/macproton/"))
}

@Test func runtimeAndGPTKVersionsComeFromFiles() throws {
    let layout = ToolLayout(root: try makeTempDir())
    #expect(layout.runtimeVersion == nil)
    #expect(!layout.gptkImported)
    try write("runtime-v4.7.3\n", to: layout.runtimeVersionFile)
    try write(#"{"version":"3.0","importedAt":"2026-09-27T00:00:00Z"}"#, to: layout.gptkManifest)
    #expect(layout.runtimeVersion == "runtime-v4.7.3")
    #expect(layout.gptkVersion == "3.0")
    #expect(layout.gptkImported)
}
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `swift test 2>&1 | tail -5`
Expected: the build fails with `cannot find 'CompatContext' in scope`.

- [ ] **Step 3: Implement**

`Sources/MacProtonCore/CompatContext.swift`:

```swift
import Foundation

public enum CompatContextError: Error, Equatable, CustomStringConvertible {
    case missing(String)

    public var description: String {
        switch self {
        case .missing(let name): "\(name) is not set; macproton launch must be started by Steam"
        }
    }
}

/// The per-game paths Steam hands a compatibility tool through its environment.
public struct CompatContext: Equatable, Sendable {
    public let dataPath: URL
    public let appID: String

    public init(environment env: [String: String]) throws(CompatContextError) {
        guard let data = env["STEAM_COMPAT_DATA_PATH"], !data.isEmpty else {
            throw .missing("STEAM_COMPAT_DATA_PATH")
        }
        dataPath = URL(filePath: data, directoryHint: .isDirectory)
        appID = env["SteamAppId"].flatMap { $0.isEmpty ? nil : $0 } ?? "0"
    }

    public var prefix: URL { dataPath.appending(path: "pfx", directoryHint: .isDirectory) }
    public var versionFile: URL { dataPath.appending(path: "version") }
    public var lockFile: URL { dataPath.appending(path: "macproton.lock") }
}
```

`Sources/MacProtonCore/ToolLayout.swift`:

```swift
import Foundation

/// Where everything lives inside the `macproton` compatibility tool folder.
public struct ToolLayout: Equatable, Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// `<root>/bin/macproton` → `<root>`.
    public init(executable: URL) {
        root = executable.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
    }

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(
            path: "Library/Application Support/MacProton/compatibilitytools.d/macproton",
            directoryHint: .isDirectory)
    }

    /// The winecx-gptk runtime tarball unpacks to `Libraries/{Wine,DXMT,DXVK}`.
    public var libraries: URL { root.appending(path: "Libraries", directoryHint: .isDirectory) }
    public var wineLib: URL { libraries.appending(path: "Wine/lib", directoryHint: .isDirectory) }
    public var wine: URL { libraries.appending(path: "Wine/bin/wine") }
    public var wineserver: URL { libraries.appending(path: "Wine/bin/wineserver") }
    public var dxmt: URL { libraries.appending(path: "DXMT", directoryHint: .isDirectory) }
    public var dxvk: URL { libraries.appending(path: "DXVK", directoryHint: .isDirectory) }
    /// Pristine copy of the imported GPTK `lib`; outside `Libraries` so a runtime update keeps it.
    public var gptkStore: URL { root.appending(path: "gptk", directoryHint: .isDirectory) }
    public var gptkManifest: URL { root.appending(path: "gptk.json") }
    public var runtimeVersionFile: URL { root.appending(path: "runtime-version") }
    public var launcherBinary: URL { root.appending(path: "bin/macproton") }

    public var runtimeVersion: String? {
        (try? String(contentsOf: runtimeVersionFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The imported D3DMetal version from `gptk.json`, or nil when GPTK is not imported.
    public var gptkVersion: String? {
        guard let data = try? Data(contentsOf: gptkManifest),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["version"] as? String
    }

    public var gptkImported: Bool { gptkVersion != nil }
}
```

- [ ] **Step 4: Run them and confirm they pass**

Run: `swift test 2>&1 | tail -3`
Expected: `Test run with 11 tests in 0 suites passed`

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "feat: read Steam's compat environment and model the tool folder"
```

---

### Task 3: Graphics backend selection

**Files:**
- Create: `Sources/MacProtonCore/GraphicsBackend.swift`
- Test: `Tests/MacProtonCoreTests/GraphicsBackendTests.swift`

**Interfaces:**
- Consumes: `ToolLayout.libraries`, `.dxmt`, `.dxvk` (Task 2).
- Produces: `enum GraphicsBackend: String { d3dmetal, dxmt, dxvk }`; `static func select(requested: String?, gptkImported: Bool) -> (backend: GraphicsBackend, note: String?)`; `var dllOverrides: String`; `func prefixDLLs(layout: ToolLayout) -> [(source: URL, destination: String)]`, where `destination` is relative to the prefix (`drive_c/windows/system32/<dll>` or `drive_c/windows/syswow64/<dll>`).

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import MacProtonCore

@Test func defaultsToD3DMetalWhenGPTKIsImported() {
    let choice = GraphicsBackend.select(requested: nil, gptkImported: true)
    #expect(choice.backend == .d3dmetal)
    #expect(choice.note == nil)
}

@Test func defaultsToDXMTWithoutGPTK() {
    #expect(GraphicsBackend.select(requested: nil, gptkImported: false).backend == .dxmt)
}

@Test func honorsRequestCaseInsensitively() {
    #expect(GraphicsBackend.select(requested: " DXVK ", gptkImported: true).backend == .dxvk)
}

@Test func unknownRequestFallsBackWithNote() {
    let choice = GraphicsBackend.select(requested: "vulkan", gptkImported: false)
    #expect(choice.backend == .dxmt)
    #expect(choice.note == "unknown MACPROTON_GRAPHICS 'vulkan', using dxmt")
}

@Test func d3dmetalWithoutGPTKFallsBackToDXMT() {
    let choice = GraphicsBackend.select(requested: "d3dmetal", gptkImported: false)
    #expect(choice.backend == .dxmt)
    #expect(choice.note != nil)
}

@Test func everyBackendOverridesTheSameDLLSet() {
    let managed: Set = ["dxgi", "d3d9", "d3d10", "d3d10core", "d3d11", "d3d12"]
    for backend in GraphicsBackend.allCases {
        let names = backend.dllOverrides.split(separator: ";").flatMap {
            $0.split(separator: "=")[0].split(separator: ",").map(String.init)
        }
        #expect(Set(names) == managed, "\(backend)")
        #expect(names.count == managed.count, "\(backend) repeats a DLL")
    }
}

@Test func dxmtDeploysBothArchitectures() {
    let layout = ToolLayout(root: URL(filePath: "/t", directoryHint: .isDirectory))
    let dlls = GraphicsBackend.dxmt.prefixDLLs(layout: layout)
    #expect(dlls.count == 6)
    #expect(dlls.contains { $0.source.path(percentEncoded: false) == "/t/Libraries/DXMT/x64/d3d11.dll"
        && $0.destination == "drive_c/windows/system32/d3d11.dll" })
    #expect(dlls.contains { $0.source.path(percentEncoded: false) == "/t/Libraries/DXMT/x32/dxgi.dll"
        && $0.destination == "drive_c/windows/syswow64/dxgi.dll" })
    #expect(GraphicsBackend.d3dmetal.prefixDLLs(layout: layout).isEmpty)
}
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `swift test 2>&1 | tail -5`
Expected: the build fails with `cannot find 'GraphicsBackend' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// How Direct3D reaches Metal for one launch.
public enum GraphicsBackend: String, Sendable, CaseIterable {
    case d3dmetal, dxmt, dxvk

    /// Honors `MACPROTON_GRAPHICS` when valid; otherwise D3DMetal if GPTK is imported, else DXMT.
    /// `note` explains any fallback so the launcher can log it.
    public static func select(requested: String?, gptkImported: Bool) -> (backend: GraphicsBackend, note: String?) {
        let fallback: GraphicsBackend = gptkImported ? .d3dmetal : .dxmt
        guard let raw = requested?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else {
            return (fallback, nil)
        }
        guard let backend = GraphicsBackend(rawValue: raw) else {
            return (fallback, "unknown MACPROTON_GRAPHICS '\(raw)', using \(fallback.rawValue)")
        }
        if backend == .d3dmetal && !gptkImported {
            return (.dxmt, "d3dmetal requested but GPTK is not imported, using dxmt")
        }
        return (backend, nil)
    }

    /// `WINEDLLOVERRIDES` for this backend. Every backend names every D3D DLL any backend
    /// manages, so DLLs a previous backend left in the prefix can never leak into this launch.
    public var dllOverrides: String {
        switch self {
        case .d3dmetal: "dxgi,d3d9,d3d10,d3d10core,d3d11,d3d12=b"
        case .dxmt: "dxgi,d3d10core,d3d11=n,b;d3d9,d3d10,d3d12=b"
        case .dxvk: "dxgi,d3d9,d3d10core,d3d11=n,b;d3d10,d3d12=b"
        }
    }

    /// Native DLLs copied into the prefix: runtime file → path inside the prefix.
    /// D3DMetal needs none: GPTK is overlaid onto Wine's own builtins.
    public func prefixDLLs(layout: ToolLayout) -> [(source: URL, destination: String)] {
        let (dir, names): (URL, [String]) = switch self {
        case .d3dmetal: (layout.libraries, [])
        case .dxmt: (layout.dxmt, ["d3d11.dll", "d3d10core.dll", "dxgi.dll"])
        case .dxvk: (layout.dxvk, ["d3d9.dll", "d3d10core.dll", "d3d11.dll", "dxgi.dll"])
        }
        return names.flatMap { name in
            [
                (dir.appending(path: "x64/\(name)"), "drive_c/windows/system32/\(name)"),
                (dir.appending(path: "x32/\(name)"), "drive_c/windows/syswow64/\(name)"),
            ]
        }
    }
}
```

- [ ] **Step 4: Run them and confirm they pass**

Run: `swift test 2>&1 | tail -3`
Expected: `Test run with 18 tests in 0 suites passed`

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "feat: choose D3DMetal, DXMT or DXVK per launch"
```

---

### Task 4: Wine launch environment

**Files:**
- Create: `Sources/MacProtonCore/LaunchEnvironment.swift`
- Test: `Tests/MacProtonCoreTests/LaunchEnvironmentTests.swift`

**Interfaces:**
- Consumes: `CompatContext.prefix` (Task 2), `GraphicsBackend.dllOverrides` (Task 3).
- Produces: `enum LaunchEnvironment { static func build(base: [String: String], context: CompatContext, backend: GraphicsBackend, logging: Bool) -> [String: String]; static func mergeOverrides(_ ours: String, user: String?) -> String }`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import MacProtonCore

private let context = try! CompatContext(environment: ["STEAM_COMPAT_DATA_PATH": "/c/42", "SteamAppId": "42"])

@Test func setsPrefixOverridesAndDefaults() {
    let env = LaunchEnvironment.build(base: ["PATH": "/usr/bin"], context: context, backend: .dxmt, logging: false)
    #expect(env["WINEPREFIX"] == "/c/42/pfx/")
    #expect(env["WINEDLLOVERRIDES"] == "dxgi=n,b;d3d10core=n,b;d3d11=n,b;d3d9=b;d3d10=b;d3d12=b")
    #expect(env["WINEDEBUG"] == "-all")
    #expect(env["ROSETTA_ADVERTISE_AVX"] == "1")
    #expect(env["WINEMSYNC"] == "1")
    #expect(env["PATH"] == "/usr/bin")
}

@Test func loggingTurnsOnWineDebugChannels() {
    let env = LaunchEnvironment.build(base: [:], context: context, backend: .dxmt, logging: true)
    #expect(env["WINEDEBUG"] == "+err,+warn,+loaddll")
}

@Test func userSettingsWin() {
    let env = LaunchEnvironment.build(
        base: ["WINEDEBUG": "+seh", "ROSETTA_ADVERTISE_AVX": "0", "WINEDLLOVERRIDES": "d3d11=b;xinput1_3=n"],
        context: context, backend: .dxmt, logging: true)
    #expect(env["WINEDEBUG"] == "+seh")
    #expect(env["ROSETTA_ADVERTISE_AVX"] == "0")
    #expect(env["WINEDLLOVERRIDES"] == "dxgi=n,b;d3d10core=n,b;d3d11=b;d3d9=b;d3d10=b;d3d12=b;xinput1_3=n")
}

@Test func optOutsDropDefaults() {
    let env = LaunchEnvironment.build(base: ["MACPROTON_NO_AVX": "1", "MACPROTON_NO_MSYNC": "1"],
                                      context: context, backend: .dxmt, logging: false)
    #expect(env["ROSETTA_ADVERTISE_AVX"] == nil)
    #expect(env["WINEMSYNC"] == nil)
}

@Test func mergeKeepsDisabledEntries() {
    #expect(LaunchEnvironment.mergeOverrides("a=b", user: "c=") == "a=b;c=")
}
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `swift test 2>&1 | tail -5`
Expected: the build fails with `cannot find 'LaunchEnvironment' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

public enum LaunchEnvironment {
    /// Wine's environment: Steam's (including the user's launch-option variables) plus ours.
    /// Anything the user set explicitly wins over our defaults.
    public static func build(base: [String: String], context: CompatContext, backend: GraphicsBackend,
                             logging: Bool) -> [String: String] {
        var env = base
        env["WINEPREFIX"] = context.prefix.path(percentEncoded: false)
        env["WINEDLLOVERRIDES"] = mergeOverrides(backend.dllOverrides, user: base["WINEDLLOVERRIDES"])
        if base["WINEDEBUG"] == nil {
            env["WINEDEBUG"] = logging ? "+err,+warn,+loaddll" : "-all"
        }
        if base["MACPROTON_NO_AVX"] != "1", base["ROSETTA_ADVERTISE_AVX"] == nil {
            env["ROSETTA_ADVERTISE_AVX"] = "1"
        }
        if base["MACPROTON_NO_MSYNC"] != "1", base["WINEMSYNC"] == nil {
            env["WINEMSYNC"] = "1"
        }
        return env
    }

    /// Merges two `WINEDLLOVERRIDES` strings by DLL name, `user` winning. Wine looks entries up
    /// in a sorted list, so a repeated name would make the winner arbitrary.
    public static func mergeOverrides(_ ours: String, user: String?) -> String {
        var order: [String] = []
        var modes: [String: String] = [:]
        for spec in [ours, user ?? ""] {
            for entry in spec.split(separator: ";") {
                let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let mode = parts.count == 2 ? String(parts[1]) : ""
                for name in parts[0].split(separator: ",") {
                    let key = name.trimmingCharacters(in: .whitespaces)
                    guard !key.isEmpty else { continue }
                    if modes[key] == nil { order.append(key) }
                    modes[key] = mode
                }
            }
        }
        return order.map { "\($0)=\(modes[$0]!)" }.joined(separator: ";")
    }
}
```

- [ ] **Step 4: Run them and confirm they pass**

Run: `swift test 2>&1 | tail -3`
Expected: `Test run with 23 tests in 0 suites passed`

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "feat: build Wine's environment with user settings winning"
```

---

### Task 5: Process runner and prefix manager

**Files:**
- Create: `Sources/MacProtonCore/ProcessRunner.swift`, `Sources/MacProtonCore/PrefixManager.swift`
- Modify: `Tests/MacProtonCoreTests/Support.swift` (append)
- Test: `Tests/MacProtonCoreTests/PrefixManagerTests.swift`

**Interfaces:**
- Consumes: `CompatContext` (Task 2), `ToolLayout` (Task 2), `GraphicsBackend.prefixDLLs` (Task 3), `LaunchEnvironment.build` (Task 4, tests only).
- Produces:
  - `protocol ProcessRunner: Sendable { func run(_ executable: URL, _ arguments: [String], environment: [String: String], output: URL?) throws -> Int32 }`
  - `struct SystemProcessRunner: ProcessRunner`
  - `struct PrefixManager { init(context:layout:runtimeVersion:runner:); needsPreparation: Bool; func prepare(backend: GraphicsBackend, environment: [String: String]) throws }`
  - `enum PrefixError { lockFailed(String), winebootFailed(Int32), dllCopyFailed(String) }`
  - Test helpers `FakeRunner` (with `.calls: [Call]`, where `Call` has `tool`, `arguments`, `environment` and `output`), `winebootCreatingPrefix(status:delay:)`, `makeToolLayout()` and `steamEnvironment(dataPath:appID:)`.

- [ ] **Step 1: Append the fakes and fixtures to `Tests/MacProtonCoreTests/Support.swift`**

```swift
/// Records every process the code under test would start, and answers with `respond`.
final class FakeRunner: ProcessRunner, @unchecked Sendable {
    struct Call: Equatable {
        let tool: String
        let arguments: [String]
        let environment: [String: String]
        let output: URL?
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let respond: @Sendable (Call) -> Int32

    init(respond: @escaping @Sendable (Call) -> Int32 = { _ in 0 }) { self.respond = respond }

    var calls: [Call] { lock.withLock { recorded } }

    func run(_ executable: URL, _ arguments: [String], environment: [String: String], output: URL?) throws -> Int32 {
        let call = Call(tool: executable.lastPathComponent, arguments: arguments, environment: environment, output: output)
        lock.withLock { recorded.append(call) }
        return respond(call)
    }
}

/// A FakeRunner whose `wineboot` creates the prefix like the real one does.
func winebootCreatingPrefix(status: Int32 = 0, delay: TimeInterval = 0) -> FakeRunner {
    FakeRunner { call in
        if call.arguments.first == "wineboot", let prefix = call.environment["WINEPREFIX"] {
            Thread.sleep(forTimeInterval: delay)
            if status == 0 { try? FileManager.default.createDirectory(atPath: prefix, withIntermediateDirectories: true) }
            return status
        }
        return 0
    }
}

/// A tool folder with a fake runtime: executable wine/wineserver, DXMT and DXVK DLLs, runtime-version.
func makeToolLayout() throws -> ToolLayout {
    let layout = ToolLayout(root: try makeTempDir().appending(path: "macproton", directoryHint: .isDirectory))
    try write("#!/bin/sh\n", to: layout.wine, executable: true)
    try write("#!/bin/sh\n", to: layout.wineserver, executable: true)
    for arch in ["x64", "x32"] {
        for dll in ["d3d11.dll", "d3d10core.dll", "dxgi.dll"] {
            try write("dxmt \(arch) \(dll)", to: layout.dxmt.appending(path: "\(arch)/\(dll)"))
        }
        for dll in ["d3d9.dll", "d3d10core.dll", "d3d11.dll", "dxgi.dll"] {
            try write("dxvk \(arch) \(dll)", to: layout.dxvk.appending(path: "\(arch)/\(dll)"))
        }
    }
    try write("runtime-test", to: layout.runtimeVersionFile)
    return layout
}

func steamEnvironment(dataPath: URL, appID: String = "3419430") -> [String: String] {
    ["STEAM_COMPAT_DATA_PATH": dataPath.path(percentEncoded: false), "SteamAppId": appID, "PATH": "/usr/bin:/bin"]
}
```

- [ ] **Step 2: Write the failing tests**

`Tests/MacProtonCoreTests/PrefixManagerTests.swift`:

```swift
import Foundation
import Testing
@testable import MacProtonCore

private func makeManager(_ runner: FakeRunner) throws -> (PrefixManager, [String: String]) {
    let layout = try makeToolLayout()
    let env = steamEnvironment(dataPath: try makeTempDir().appending(path: "compatdata/42"))
    let context = try CompatContext(environment: env)
    let wineEnv = LaunchEnvironment.build(base: env, context: context, backend: .dxmt, logging: false)
    return (PrefixManager(context: context, layout: layout, runtimeVersion: "runtime-test", runner: runner), wineEnv)
}

@Test func freshPrefixRunsWinebootAndRecordsVersion() throws {
    let runner = winebootCreatingPrefix()
    let (manager, env) = try makeManager(runner)
    try manager.prepare(backend: .dxmt, environment: env)
    #expect(runner.calls.map(\.arguments) == [["wineboot", "-u"]])
    #expect(runner.calls[0].environment["WINEPREFIX"] == manager.context.prefix.path(percentEncoded: false))
    #expect(try String(contentsOf: manager.context.versionFile, encoding: .utf8) == "runtime-test")
    #expect(!manager.needsPreparation)
}

@Test func upToDatePrefixSkipsWineboot() throws {
    let runner = winebootCreatingPrefix()
    let (manager, env) = try makeManager(runner)
    try manager.prepare(backend: .dxmt, environment: env)
    try manager.prepare(backend: .dxmt, environment: env)
    #expect(runner.calls.count == 1)
}

@Test func runtimeChangeUpgradesPrefix() throws {
    let runner = winebootCreatingPrefix()
    let (manager, env) = try makeManager(runner)
    try manager.prepare(backend: .dxmt, environment: env)
    try write("runtime-old", to: manager.context.versionFile)
    try manager.prepare(backend: .dxmt, environment: env)
    #expect(runner.calls.count == 2)
}

@Test func failedWinebootKeepsPrefixAndVersion() throws {
    let (manager, env) = try makeManager(winebootCreatingPrefix(status: 3))
    let save = manager.context.prefix.appending(path: "drive_c/users/steamuser/save.dat")
    try write("progress", to: save)
    try write("runtime-old", to: manager.context.versionFile)
    #expect(throws: PrefixError.winebootFailed(3)) { try manager.prepare(backend: .dxmt, environment: env) }
    #expect(try String(contentsOf: save, encoding: .utf8) == "progress")
    #expect(try String(contentsOf: manager.context.versionFile, encoding: .utf8) == "runtime-old")
}

@Test func deploysBackendDLLsIntoBothSystemFolders() throws {
    let (manager, env) = try makeManager(winebootCreatingPrefix())
    try manager.prepare(backend: .dxmt, environment: env)
    let system32 = manager.context.prefix.appending(path: "drive_c/windows/system32/d3d11.dll")
    let syswow64 = manager.context.prefix.appending(path: "drive_c/windows/syswow64/d3d11.dll")
    #expect(try String(contentsOf: system32, encoding: .utf8) == "dxmt x64 d3d11.dll")
    #expect(try String(contentsOf: syswow64, encoding: .utf8) == "dxmt x32 d3d11.dll")
    try manager.prepare(backend: .dxvk, environment: env)
    #expect(try String(contentsOf: system32, encoding: .utf8) == "dxvk x64 d3d11.dll")
}

@Test func concurrentLaunchesRunWinebootOnce() async throws {
    // Steam starts iscriptevaluator (`run`) and the game close together on first launch.
    let runner = winebootCreatingPrefix(delay: 0.3)
    let (manager, env) = try makeManager(runner)
    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<2 {
            group.addTask { try manager.prepare(backend: .dxmt, environment: env) }
        }
        try await group.waitForAll()
    }
    #expect(runner.calls.filter { $0.arguments.first == "wineboot" }.count == 1)
}

@Test func systemRunnerReportsStatusAndCapturesOutput() throws {
    let log = try makeTempDir().appending(path: "out.log")
    let status = try SystemProcessRunner().run(URL(filePath: "/bin/sh"), ["-c", "echo \"$1\"; exit 3", "sh", "a b"],
                                               environment: [:], output: log)
    #expect(status == 3)
    #expect(try String(contentsOf: log, encoding: .utf8) == "a b\n")
}
```

- [ ] **Step 3: Run them and confirm they fail**

Run: `swift test 2>&1 | tail -5`
Expected: the build fails with `cannot find type 'ProcessRunner' in scope`.

- [ ] **Step 4: Implement**

`Sources/MacProtonCore/ProcessRunner.swift`:

```swift
import Foundation

/// Starts child processes. A protocol so tests can record calls instead of running Wine.
public protocol ProcessRunner: Sendable {
    /// Runs `executable` to completion and returns its exit status (128 + signal if killed).
    /// Output is appended to `output` when given, otherwise inherited from this process.
    func run(_ executable: URL, _ arguments: [String], environment: [String: String], output: URL?) throws -> Int32
}

public struct SystemProcessRunner: ProcessRunner {
    public init() {}

    public func run(_ executable: URL, _ arguments: [String], environment: [String: String],
                    output: URL?) throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        var handle: FileHandle?
        if let output {
            let path = output.path(percentEncoded: false)
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            let file = try FileHandle(forWritingTo: output)
            try file.seekToEnd()
            process.standardOutput = file
            process.standardError = file
            handle = file
        }
        defer { try? handle?.close() }
        try process.run()
        process.waitUntilExit()
        return process.terminationReason == .uncaughtSignal
            ? 128 + process.terminationStatus : process.terminationStatus
    }
}
```

`Sources/MacProtonCore/PrefixManager.swift`:

```swift
import Darwin
import Foundation

public enum PrefixError: Error, Equatable, CustomStringConvertible {
    case lockFailed(String)
    case winebootFailed(Int32)
    case dllCopyFailed(String)

    public var description: String {
        switch self {
        case .lockFailed(let reason): "could not lock the prefix: \(reason)"
        case .winebootFailed(let status): "prefix setup failed (wineboot exit \(status)); the prefix was left unchanged"
        case .dllCopyFailed(let detail): "could not install graphics DLLs: \(detail)"
        }
    }
}

/// Creates, upgrades and equips a game's Wine prefix at `compatdata/<appid>/pfx`.
public struct PrefixManager: Sendable {
    public let context: CompatContext
    public let layout: ToolLayout
    public let runtimeVersion: String
    public let runner: any ProcessRunner

    public init(context: CompatContext, layout: ToolLayout, runtimeVersion: String, runner: any ProcessRunner) {
        self.context = context
        self.layout = layout
        self.runtimeVersion = runtimeVersion
        self.runner = runner
    }

    /// True when the prefix is missing or was last prepared by a different runtime.
    public var needsPreparation: Bool {
        guard FileManager.default.fileExists(atPath: context.prefix.path(percentEncoded: false)) else { return true }
        let recorded = try? String(contentsOf: context.versionFile, encoding: .utf8)
        return recorded?.trimmingCharacters(in: .whitespacesAndNewlines) != runtimeVersion
    }

    /// Runs `wineboot -u` when needed, then installs the backend's DLLs. Holds the prefix lock only
    /// for this preparation, never while the game runs. On failure the version is not recorded,
    /// so the next launch retries; nothing under `drive_c` is ever deleted.
    public func prepare(backend: GraphicsBackend, environment: [String: String]) throws {
        try FileManager.default.createDirectory(at: context.dataPath, withIntermediateDirectories: true)
        try withFileLock(at: context.lockFile) {
            if needsPreparation {
                let status = try runner.run(layout.wine, ["wineboot", "-u"], environment: environment, output: nil)
                guard status == 0 else { throw PrefixError.winebootFailed(status) }
                try runtimeVersion.write(to: context.versionFile, atomically: true, encoding: .utf8)
            }
            try deployDLLs(for: backend)
        }
    }

    func deployDLLs(for backend: GraphicsBackend) throws {
        let fm = FileManager.default
        for (source, destination) in backend.prefixDLLs(layout: layout) {
            // ponytail: a runtime without a 32-bit build of a DLL just skips it.
            guard fm.fileExists(atPath: source.path(percentEncoded: false)) else { continue }
            let target = context.prefix.appending(path: destination)
            do {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: target.path(percentEncoded: false)) { try fm.removeItem(at: target) }
                try fm.copyItem(at: source, to: target)
            } catch {
                throw PrefixError.dllCopyFailed("\(destination): \(error.localizedDescription)")
            }
        }
    }
}

/// Exclusive `flock(2)` on `url` for the duration of `body`. Separate `open`s conflict even
/// within one process, so this also serialises threads.
func withFileLock<T>(at url: URL, _ body: () throws -> T) throws -> T {
    let fd = open(url.path(percentEncoded: false), O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { throw PrefixError.lockFailed(String(cString: strerror(errno))) }
    defer { close(fd) }
    guard flock(fd, LOCK_EX) == 0 else { throw PrefixError.lockFailed(String(cString: strerror(errno))) }
    defer { flock(fd, LOCK_UN) }
    return try body()
}
```

- [ ] **Step 5: Run them and confirm they pass**

Run: `swift test 2>&1 | tail -3`
Expected: `Test run with 30 tests in 0 suites passed`. `concurrentLaunchesRunWinebootOnce` takes about 0.3 s, which is expected.

- [ ] **Step 6: Commit**

```bash
git add Sources Tests
git commit -m "feat: create and upgrade Wine prefixes under a file lock"
```

---

### Task 6: Launcher log

**Files:**
- Create: `Sources/MacProtonCore/LauncherLog.swift`
- Test: `Tests/MacProtonCoreTests/LauncherLogTests.swift`

**Interfaces:**
- Consumes: `makeTempDir` (Task 2, tests).
- Produces: `struct LauncherLog { static rotateBytes = 1_048_576; directory: URL; init(directory:); static standard; launcherLog: URL; func gameLog(appID: String) -> URL; func append(_ line: String) }`. `append` never throws. `gameLog` creates the directory.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import MacProtonCore

@Test func appendsTimestampedLines() throws {
    let log = LauncherLog(directory: try makeTempDir().appending(path: "Logs"))
    log.append("verb=run exit=0")
    log.append("verb=run exit=1")
    let lines = try String(contentsOf: log.launcherLog, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 2)
    #expect(lines[1].hasSuffix(" verb=run exit=1"))
    #expect(lines[0].hasPrefix("20"))
}

@Test func rotatesPastOneMegabyte() throws {
    let log = LauncherLog(directory: try makeTempDir())
    try Data(count: LauncherLog.rotateBytes + 1).write(to: log.launcherLog)
    log.append("fresh")
    let rotated = log.directory.appending(path: "launcher.log.1")
    #expect(FileManager.default.fileExists(atPath: rotated.path(percentEncoded: false)))
    #expect(try String(contentsOf: log.launcherLog, encoding: .utf8).hasSuffix(" fresh\n"))
}

@Test func gameLogIsPerApp() throws {
    let log = LauncherLog(directory: try makeTempDir().appending(path: "Logs"))
    #expect(log.gameLog(appID: "42").lastPathComponent == "steam-42.log")
    #expect(FileManager.default.fileExists(atPath: log.directory.path(percentEncoded: false)))
}
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `swift test 2>&1 | tail -5`
Expected: the build fails with `cannot find 'LauncherLog' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// `~/Library/Logs/MacProton`: one line per launch in `launcher.log`, plus opt-in per-game Wine logs.
public struct LauncherLog: Sendable {
    public static let rotateBytes = 1_048_576
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public static var standard: LauncherLog {
        LauncherLog(directory: FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/MacProton", directoryHint: .isDirectory))
    }

    public var launcherLog: URL { directory.appending(path: "launcher.log") }

    /// Creates the log folder and returns `steam-<appid>.log`.
    public func gameLog(appID: String) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "steam-\(appID).log")
    }

    /// Appends a timestamped line, rotating to `launcher.log.1` past `rotateBytes`.
    /// Never throws: a logging problem must not stop a game from launching.
    public func append(_ line: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = launcherLog.path(percentEncoded: false)
        if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber, size.intValue > Self.rotateBytes {
            let rotated = directory.appending(path: "launcher.log.1")
            try? fm.removeItem(at: rotated)
            try? fm.moveItem(at: launcherLog, to: rotated)
        }
        let data = Data("\(Date().formatted(.iso8601)) \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: launcherLog) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: launcherLog)
        }
    }
}
```

- [ ] **Step 4: Run them and confirm they pass**

Run: `swift test 2>&1 | tail -3`
Expected: `Test run with 33 tests in 0 suites passed`

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "feat: log one line per launch with rotation"
```

---

### Task 7: Preflight checks and notifications

**Files:**
- Create: `Sources/MacProtonCore/Preflight.swift`
- Test: `Tests/MacProtonCoreTests/PreflightTests.swift`

**Interfaces:**
- Consumes: `ToolLayout` (Task 2), `SystemProcessRunner` (Task 5), `makeToolLayout` (Task 5, tests).
- Produces:
  - `struct Preflight { static rosettaRuntime: URL; init(rosettaAvailable: @escaping @Sendable () -> Bool = <file check>); func check(_ layout: ToolLayout) throws(PreflightError) }`
  - `enum PreflightError { rosettaMissing, runtimeMissing }`, where `description` is the message shown to the user
  - `protocol Notifier: Sendable { func post(title: String, message: String) }`
  - `struct AppleScriptNotifier: Notifier` with `static func quoted(_:) -> String`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import MacProtonCore

@Test func passesWithRosettaAndRuntime() throws {
    try Preflight(rosettaAvailable: { true }).check(try makeToolLayout())
}

@Test func reportsMissingRosettaFirst() {
    let layout = ToolLayout(root: URL(filePath: "/nonexistent"))
    #expect(throws: PreflightError.rosettaMissing) { try Preflight(rosettaAvailable: { false }).check(layout) }
}

@Test func reportsMissingRuntime() throws {
    let layout = try makeToolLayout()
    try FileManager.default.removeItem(at: layout.wineserver)
    #expect(throws: PreflightError.runtimeMissing) { try Preflight(rosettaAvailable: { true }).check(layout) }
}

@Test func runtimeWithoutVersionFileIsIncomplete() throws {
    let layout = try makeToolLayout()
    try FileManager.default.removeItem(at: layout.runtimeVersionFile)
    #expect(throws: PreflightError.runtimeMissing) { try Preflight(rosettaAvailable: { true }).check(layout) }
}

@Test func notificationTextIsEscapedForAppleScript() {
    #expect(AppleScriptNotifier.quoted(#"Game "X" at C:\Games"#) == #""Game \"X\" at C:\\Games""#)
}
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `swift test 2>&1 | tail -5`
Expected: the build fails with `cannot find 'Preflight' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

public enum PreflightError: Error, Equatable, CustomStringConvertible {
    case rosettaMissing
    case runtimeMissing

    public var description: String {
        switch self {
        case .rosettaMissing:
            "Rosetta 2 is not installed. Run: softwareupdate --install-rosetta --agree-to-license"
        case .runtimeMissing:
            "The MacProton runtime is missing or incomplete. Repair it with: macproton install-runtime"
        }
    }
}

/// Launch-time checks. The runtime's checksum is verified at install; here we only confirm
/// the pieces a launch needs are present, which costs a few `stat`s.
public struct Preflight: Sendable {
    public static let rosettaRuntime = URL(filePath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
    public let rosettaAvailable: @Sendable () -> Bool

    public init(rosettaAvailable: @escaping @Sendable () -> Bool = {
        FileManager.default.fileExists(atPath: Preflight.rosettaRuntime.path(percentEncoded: false))
    }) {
        self.rosettaAvailable = rosettaAvailable
    }

    public func check(_ layout: ToolLayout) throws(PreflightError) {
        guard rosettaAvailable() else { throw .rosettaMissing }
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: layout.wine.path(percentEncoded: false)),
              fm.isExecutableFile(atPath: layout.wineserver.path(percentEncoded: false)),
              layout.runtimeVersion != nil
        else { throw .runtimeMissing }
    }
}

/// Tells the user about launch-blocking failures; Steam itself shows nothing useful.
public protocol Notifier: Sendable {
    func post(title: String, message: String)
}

/// Posts through `osascript`, which needs no app bundle or entitlement.
public struct AppleScriptNotifier: Notifier {
    public init() {}

    public func post(title: String, message: String) {
        let script = "display notification \(Self.quoted(message)) with title \(Self.quoted(title))"
        _ = try? SystemProcessRunner().run(URL(filePath: "/usr/bin/osascript"), ["-e", script],
                                           environment: [:], output: nil)
    }

    /// An AppleScript string literal: backslashes and quotes escaped.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
```

- [ ] **Step 4: Run them and confirm they pass**

Run: `swift test 2>&1 | tail -3`
Expected: `Test run with 38 tests in 0 suites passed`

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "feat: check Rosetta and runtime before launch, notify on failure"
```

---

### Task 8: Launcher (the Proton verbs)

**Files:**
- Create: `Sources/MacProtonCore/Launcher.swift`
- Test: `Tests/MacProtonCoreTests/LauncherTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–7: `LaunchRequest.parse`, `CompatContext`, `ToolLayout`, `GraphicsBackend.select`, `LaunchEnvironment.build`, `ProcessRunner`, `PrefixManager.prepare`, `LauncherLog`, `Preflight.check`, `Notifier`.
- Produces: `struct Launcher { init(layout:runner:log:notifier:preflight:) (all but layout defaulted); func launch(_ argv: [String], environment: [String: String]) -> Int32; func terminate(environment: [String: String]) }`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import MacProtonCore

final class RecordingNotifier: Notifier, @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    var posted: [String] { lock.withLock { messages } }
    func post(title: String, message: String) { lock.withLock { messages.append(message) } }
}

private struct Fixture {
    let launcher: Launcher
    let runner: FakeRunner
    let notifier: RecordingNotifier
    let env: [String: String]
}

private func makeFixture(runner: FakeRunner = winebootCreatingPrefix(), rosetta: Bool = true) throws -> Fixture {
    let notifier = RecordingNotifier()
    let launcher = Launcher(layout: try makeToolLayout(), runner: runner,
                            log: LauncherLog(directory: try makeTempDir().appending(path: "Logs")),
                            notifier: notifier, preflight: Preflight(rosettaAvailable: { rosetta }))
    let env = steamEnvironment(dataPath: try makeTempDir().appending(path: "compatdata/42"), appID: "42")
    return Fixture(launcher: launcher, runner: runner, notifier: notifier, env: env)
}

@Test func waitForExitAndRunWaitsPreparesRunsThenWaits() throws {
    let runner = FakeRunner { call in
        if call.arguments.first == "wineboot", let prefix = call.environment["WINEPREFIX"] {
            try? FileManager.default.createDirectory(atPath: prefix, withIntermediateDirectories: true)
        }
        return call.arguments.first == "/g/Game.exe" ? 7 : 0
    }
    let f = try makeFixture(runner: runner)
    let status = f.launcher.launch(["waitforexitandrun", "/g/Game.exe", "-windowed"], environment: f.env)
    #expect(status == 7)
    #expect(runner.calls.map { [$0.tool] + $0.arguments } == [
        ["wineserver", "-w"],
        ["wine", "wineboot", "-u"],
        ["wine", "/g/Game.exe", "-windowed"],
        ["wineserver", "-w"],
    ])
}

@Test func runDoesNotWaitForWineserver() throws {
    let f = try makeFixture()
    #expect(f.launcher.launch(["run", "/g/iscriptevaluator.exe", "--get-current-step", "42"], environment: f.env) == 0)
    #expect(!f.runner.calls.contains { $0.tool == "wineserver" })
    #expect(f.runner.calls.last?.arguments == ["/g/iscriptevaluator.exe", "--get-current-step", "42"])
}

@Test func runInPrefixSkipsPreparation() throws {
    let f = try makeFixture()
    #expect(f.launcher.launch(["runinprefix", "/g/tool.exe"], environment: f.env) == 0)
    #expect(f.runner.calls.map(\.arguments) == [["/g/tool.exe"]])
}

@Test func getCompatPathConvertsThroughWinepath() throws {
    let f = try makeFixture()
    #expect(f.launcher.launch(["getcompatpath", "/g/save"], environment: f.env) == 0)
    #expect(f.runner.calls.last?.arguments == ["winepath.exe", "-w", "/g/save"])
}

@Test func gameArgumentsPassThroughUnchanged() throws {
    let f = try makeFixture()
    let args = ["/Steam Library/My Game/Game.exe", "--name=\"Player One\"", "a b", "ünïcode", ""]
    _ = f.launcher.launch(["run"] + args, environment: f.env)
    #expect(f.runner.calls.last?.arguments == args)
}

@Test func unknownVerbFailsWithoutRunningAnything() throws {
    let f = try makeFixture()
    #expect(f.launcher.launch(["destroyprefix", "/g/Game.exe"], environment: f.env) == 1)
    #expect(f.runner.calls.isEmpty)
}

@Test func launchingOutsideSteamFailsCleanly() throws {
    let f = try makeFixture()
    #expect(f.launcher.launch(["run", "/g/Game.exe"], environment: ["PATH": "/usr/bin"]) == 1)
    #expect(f.runner.calls.isEmpty)
}

@Test func invalidGraphicsSettingStillLaunchesWithDefault() throws {
    let f = try makeFixture()
    var env = f.env
    env["MACPROTON_GRAPHICS"] = "vulkan"
    #expect(f.launcher.launch(["run", "/g/Game.exe"], environment: env) == 0)
    #expect(f.runner.calls.last?.environment["WINEDLLOVERRIDES"]?.hasPrefix("dxgi=n,b;d3d10core=n,b;d3d11=n,b") == true)
    let logged = try String(contentsOf: f.launcher.log.launcherLog, encoding: .utf8)
    #expect(logged.contains("backend=dxmt"))
    #expect(logged.contains("note=unknown MACPROTON_GRAPHICS 'vulkan'"))
}

@Test func missingRosettaNotifiesAndFails() throws {
    let f = try makeFixture(rosetta: false)
    #expect(f.launcher.launch(["run", "/g/Game.exe"], environment: f.env) == 1)
    #expect(f.runner.calls.isEmpty)
    #expect(f.notifier.posted.first?.contains("softwareupdate --install-rosetta") == true)
}

@Test func failedPrefixSetupNotifiesAndSkipsGame() throws {
    let f = try makeFixture(runner: winebootCreatingPrefix(status: 5))
    #expect(f.launcher.launch(["waitforexitandrun", "/g/Game.exe"], environment: f.env) == 1)
    #expect(!f.runner.calls.contains { $0.arguments.first == "/g/Game.exe" })
    #expect(f.notifier.posted.count == 1)
}

@Test func macprotonLogSendsGameOutputToPerGameLog() throws {
    let f = try makeFixture()
    var env = f.env
    env["MACPROTON_LOG"] = "1"
    _ = f.launcher.launch(["run", "/g/Game.exe"], environment: env)
    let gameLog = f.launcher.log.gameLog(appID: "42")
    #expect(f.runner.calls.last?.output == gameLog)
    #expect(try String(contentsOf: gameLog, encoding: .utf8).contains("WINEDEBUG=+err,+warn,+loaddll"))
}

@Test func everyLaunchIsLoggedWithVersions() throws {
    let f = try makeFixture()
    _ = f.launcher.launch(["run", "/g/Game.exe"], environment: f.env)
    let line = try String(contentsOf: f.launcher.log.launcherLog, encoding: .utf8)
    #expect(line.contains("verb=run appid=42 backend=dxmt runtime=runtime-test gptk=none exit=0"))
}

@Test func terminateKillsThePrefixWineserver() throws {
    let f = try makeFixture()
    f.launcher.terminate(environment: f.env)
    #expect(f.runner.calls.map { [$0.tool] + $0.arguments } == [["wineserver", "-k"]])
    #expect(f.runner.calls[0].environment["WINEPREFIX"]?.hasSuffix("compatdata/42/pfx/") == true)
}
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `swift test 2>&1 | tail -5`
Expected: the build fails with `cannot find 'Launcher' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Implements the `proton` verbs Steam calls on a compatibility tool.
public struct Launcher: Sendable {
    public let layout: ToolLayout
    public let runner: any ProcessRunner
    public let log: LauncherLog
    public let notifier: any Notifier
    public let preflight: Preflight

    public init(layout: ToolLayout, runner: any ProcessRunner = SystemProcessRunner(), log: LauncherLog = .standard,
                notifier: any Notifier = AppleScriptNotifier(), preflight: Preflight = Preflight()) {
        self.layout = layout
        self.runner = runner
        self.log = log
        self.notifier = notifier
        self.preflight = preflight
    }

    /// Returns the exit code for Steam. Never throws: every failure is logged and becomes exit 1.
    public func launch(_ argv: [String], environment: [String: String]) -> Int32 {
        let request: LaunchRequest
        let context: CompatContext
        do {
            request = try LaunchRequest.parse(argv)
            context = try CompatContext(environment: environment)
        } catch {
            return fail("\(error)", argv: argv, notify: false)
        }
        do {
            try preflight.check(layout)
        } catch {
            return fail(error.description, argv: argv, notify: true)
        }

        let (backend, note) = GraphicsBackend.select(requested: environment["MACPROTON_GRAPHICS"],
                                                     gptkImported: layout.gptkImported)
        let logging = environment["MACPROTON_LOG"] == "1"
        let env = LaunchEnvironment.build(base: environment, context: context, backend: backend, logging: logging)
        let gameLog = logging ? log.gameLog(appID: context.appID) : nil
        if let gameLog { writeHeader(to: gameLog, request: request, environment: env) }
        let prefix = PrefixManager(context: context, layout: layout, runtimeVersion: layout.runtimeVersion ?? "unknown",
                                   runner: runner)

        do {
            let status: Int32
            switch request.verb {
            case .runinprefix:
                status = try runGame(request, env, gameLog)
            case .run:
                try prefix.prepare(backend: backend, environment: env)
                status = try runGame(request, env, gameLog)
            case .waitforexitandrun:
                // Let a previous session in this prefix (e.g. the redistributable installer) finish first.
                _ = try runner.run(layout.wineserver, ["-w"], environment: env, output: nil)
                try prefix.prepare(backend: backend, environment: env)
                status = try runGame(request, env, gameLog)
                // Keep Steam's "running" state until every process in the prefix is gone
                // (covers launchers that start the real game and exit).
                _ = try runner.run(layout.wineserver, ["-w"], environment: env, output: nil)
            case .getcompatpath, .getnativepath:
                try prefix.prepare(backend: backend, environment: env)
                let flag = request.verb == .getcompatpath ? "-w" : "-u"
                status = try runner.run(layout.wine, ["winepath.exe", flag, request.target], environment: env, output: nil)
            }
            var line = "verb=\(request.verb.rawValue) appid=\(context.appID) backend=\(backend.rawValue)"
                + " runtime=\(layout.runtimeVersion ?? "unknown") gptk=\(layout.gptkVersion ?? "none") exit=\(status)"
            if let note { line += " note=\(note)" }
            log.append(line)
            return status
        } catch {
            return fail("\(error)", argv: argv, notify: true)
        }
    }

    /// Steam's Stop button sends SIGTERM: kill every Wine process in the game's prefix.
    public func terminate(environment: [String: String]) {
        guard let context = try? CompatContext(environment: environment) else { return }
        var env = environment
        env["WINEPREFIX"] = context.prefix.path(percentEncoded: false)
        _ = try? runner.run(layout.wineserver, ["-k"], environment: env, output: nil)
    }

    private func runGame(_ request: LaunchRequest, _ env: [String: String], _ gameLog: URL?) throws -> Int32 {
        try runner.run(layout.wine, [request.target] + request.arguments, environment: env, output: gameLog)
    }

    private func writeHeader(to gameLog: URL, request: LaunchRequest, environment: [String: String]) {
        var text = "=== \(Date().formatted(.iso8601)) \(request.verb.rawValue) \(request.target) \(request.arguments)\n"
        for key in environment.keys.sorted() { text += "\(key)=\(environment[key]!)\n" }
        if let handle = try? FileHandle(forWritingTo: gameLog) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        } else {
            try? Data(text.utf8).write(to: gameLog)
        }
    }

    private func fail(_ message: String, argv: [String], notify: Bool) -> Int32 {
        log.append("error: \(message) argv=\(argv)")
        FileHandle.standardError.write(Data("macproton: \(message)\n".utf8))
        if notify { notifier.post(title: "MacProton", message: message) }
        return 1
    }
}
```

- [ ] **Step 4: Run them and confirm they pass**

Run: `swift test 2>&1 | tail -3`
Expected: `Test run with 51 tests in 0 suites passed`

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "feat: implement Proton verbs for Steam"
```

---

### Task 9: GPTK importer

**Files:**
- Create: `Sources/MacProtonCore/GPTKImporter.swift`
- Test: `Tests/MacProtonCoreTests/GPTKImporterTests.swift`

**Interfaces:**
- Consumes: `ToolLayout.gptkStore`, `.gptkManifest`, `.wineLib`, `.gptkVersion` (Task 2); `ProcessRunner`, `SystemProcessRunner` (Task 5).
- Produces:
  - `enum GPTKImporter { static requiredFiles: [String]; static unixBridges: [String]; static func locateLib(from: URL) -> URL?; static func validate(lib: URL) throws(GPTKImportError) -> String; static func importGPTK(from: URL, into: ToolLayout, runner:) throws -> GPTKManifest; static func applyOverlay(layout: ToolLayout, runner:) throws }`
  - `struct GPTKManifest: Codable { version: String; importedAt: Date }`
  - `enum GPTKImportError { notFound(String), missingFiles([String]), versionUnreadable, copyFailed(Int32) }`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import MacProtonCore

/// A fake GPTK volume: `<volume>/redist/lib/...` with D3DMetal version `version`.
private func makeGPTKVolume(version: String = "3.0", omit: String? = nil) throws -> URL {
    let volume = try makeTempDir().appending(path: "Evaluation environment for Windows games 3.0")
    let lib = volume.appending(path: "redist/lib")
    for file in GPTKImporter.requiredFiles where file != omit && !file.hasSuffix(".framework") {
        try write("apple \(file)", to: lib.appending(path: file))
    }
    if omit != "external/D3DMetal.framework" {
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": version],
                                                       format: .xml, options: 0)
        let info = lib.appending(path: "external/D3DMetal.framework/Versions/A/Resources/Info.plist")
        try FileManager.default.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
        try plist.write(to: info)
    }
    return volume
}

@Test func findsLibFromVolumeRedistOrLib() throws {
    let volume = try makeGPTKVolume()
    let lib = volume.appending(path: "redist/lib")
    for source in [volume, volume.appending(path: "redist"), lib] {
        #expect(GPTKImporter.locateLib(from: source)?.standardizedFileURL == lib.standardizedFileURL)
    }
    #expect(GPTKImporter.locateLib(from: try makeTempDir()) == nil)
}

@Test func importOverlaysWineAndRecordsVersion() throws {
    let layout = try makeToolLayout()
    let manifest = try GPTKImporter.importGPTK(from: try makeGPTKVolume(version: "3.0"), into: layout)
    #expect(manifest.version == "3.0")
    #expect(layout.gptkVersion == "3.0")
    let forwarder = layout.wineLib.appending(path: "wine/x86_64-windows/d3d12.dll")
    #expect(try String(contentsOf: forwarder, encoding: .utf8) == "apple wine/x86_64-windows/d3d12.dll")
    let bridge = layout.wineLib.appending(path: "wine/x86_64-unix/d3d11.so").path(percentEncoded: false)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: bridge) == "../../external/libd3dshared.dylib")
    #expect(FileManager.default.fileExists(atPath: layout.gptkStore.appending(path: "lib/external/libd3dshared.dylib")
        .path(percentEncoded: false)))
}

@Test func incompleteRedistIsRejectedBeforeCopying() throws {
    let layout = try makeToolLayout()
    let volume = try makeGPTKVolume(omit: "wine/x86_64-windows/d3d12.dll")
    #expect(throws: GPTKImportError.missingFiles(["wine/x86_64-windows/d3d12.dll"])) {
        try GPTKImporter.importGPTK(from: volume, into: layout)
    }
    #expect(!FileManager.default.fileExists(atPath: layout.gptkStore.path(percentEncoded: false)))
    #expect(!layout.gptkImported)
}

@Test func unreadableVersionIsRejected() throws {
    let layout = try makeToolLayout()
    let volume = try makeGPTKVolume()
    try FileManager.default.removeItem(at: volume.appending(
        path: "redist/lib/external/D3DMetal.framework/Versions/A/Resources/Info.plist"))
    #expect(throws: GPTKImportError.versionUnreadable) { try GPTKImporter.importGPTK(from: volume, into: layout) }
}

@Test func reimportReplacesTheStore() throws {
    let layout = try makeToolLayout()
    try GPTKImporter.importGPTK(from: try makeGPTKVolume(version: "3.0"), into: layout)
    try GPTKImporter.importGPTK(from: try makeGPTKVolume(version: "4.0b2"), into: layout)
    #expect(layout.gptkVersion == "4.0b2")
}
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `swift test 2>&1 | tail -5`
Expected: the build fails with `cannot find 'GPTKImporter' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

public enum GPTKImportError: Error, Equatable, CustomStringConvertible {
    case notFound(String)
    case missingFiles([String])
    case versionUnreadable
    case copyFailed(Int32)

    public var description: String {
        switch self {
        case .notFound(let path):
            "no GPTK redist found at \(path); pass the mounted GPTK volume, its redist folder, or redist/lib"
        case .missingFiles(let files): "not a complete GPTK redist, missing: \(files.joined(separator: ", "))"
        case .versionUnreadable: "could not read the D3DMetal version from D3DMetal.framework"
        case .copyFailed(let status): "copying GPTK files failed (ditto exit \(status))"
        }
    }
}

public struct GPTKManifest: Codable, Equatable, Sendable {
    public let version: String
    public let importedAt: Date
}

/// Imports Apple's D3DMetal from a user-downloaded Game Porting Toolkit. We never ship Apple's files.
public enum GPTKImporter {
    /// Present in every supported GPTK `redist/lib` (3.0 and 4.0 beta).
    public static let requiredFiles = [
        "external/D3DMetal.framework",
        "external/libd3dshared.dylib",
        "wine/x86_64-windows/d3d10.dll",
        "wine/x86_64-windows/d3d11.dll",
        "wine/x86_64-windows/d3d12.dll",
        "wine/x86_64-windows/dxgi.dll",
    ]
    /// Unix halves of the forwarders; each is a symlink to `external/libd3dshared.dylib`.
    public static let unixBridges = ["d3d10.so", "d3d11.so", "d3d12.so", "dxgi.so"]

    /// Accepts the mounted volume, its `redist` folder, or `redist/lib`.
    public static func locateLib(from source: URL) -> URL? {
        [source, source.appending(path: "lib"), source.appending(path: "redist/lib")].first {
            FileManager.default.fileExists(
                atPath: $0.appending(path: "external/libd3dshared.dylib").path(percentEncoded: false))
        }
    }

    /// Checks every required file and returns the D3DMetal version.
    public static func validate(lib: URL) throws(GPTKImportError) -> String {
        let missing = requiredFiles.filter {
            !FileManager.default.fileExists(atPath: lib.appending(path: $0).path(percentEncoded: false))
        }
        guard missing.isEmpty else { throw .missingFiles(missing) }
        guard let version = frameworkVersion(lib.appending(path: "external/D3DMetal.framework")) else {
            throw .versionUnreadable
        }
        return version
    }

    static func frameworkVersion(_ framework: URL) -> String? {
        for plist in ["Versions/A/Resources/Info.plist", "Resources/Info.plist"] {
            guard let data = try? Data(contentsOf: framework.appending(path: plist)),
                  let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let version = dict["CFBundleShortVersionString"] as? String, !version.isEmpty
            else { continue }
            return version
        }
        return nil
    }

    /// Validates before copying anything, keeps a pristine copy in the store (so runtime
    /// updates can re-apply it), overlays it onto Wine, then records `gptk.json`.
    @discardableResult
    public static func importGPTK(from source: URL, into layout: ToolLayout,
                                  runner: any ProcessRunner = SystemProcessRunner()) throws -> GPTKManifest {
        guard let lib = locateLib(from: source) else {
            throw GPTKImportError.notFound(source.path(percentEncoded: false))
        }
        let version = try validate(lib: lib)
        let fm = FileManager.default
        let staging = layout.root.appending(path: "gptk.staging", directoryHint: .isDirectory)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try ditto(lib, staging.appending(path: "lib"), runner: runner)
        try? fm.removeItem(at: layout.gptkStore)
        try fm.moveItem(at: staging, to: layout.gptkStore)
        try applyOverlay(layout: layout, runner: runner)
        let manifest = GPTKManifest(version: version, importedAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: layout.gptkManifest, options: .atomic)
        return manifest
    }

    /// Copies the stored GPTK `lib` over `Libraries/Wine/lib` and points the unix bridges at libd3dshared.
    public static func applyOverlay(layout: ToolLayout, runner: any ProcessRunner = SystemProcessRunner()) throws {
        try ditto(layout.gptkStore.appending(path: "lib"), layout.wineLib, runner: runner)
        let fm = FileManager.default
        let unixDir = layout.wineLib.appending(path: "wine/x86_64-unix", directoryHint: .isDirectory)
        try fm.createDirectory(at: unixDir, withIntermediateDirectories: true)
        for name in unixBridges {
            let link = unixDir.appending(path: name)
            try? fm.removeItem(at: link)
            try fm.createSymbolicLink(atPath: link.path(percentEncoded: false),
                                      withDestinationPath: "../../external/libd3dshared.dylib")
        }
    }

    /// `ditto` merges into an existing tree and keeps framework symlinks and signatures intact.
    static func ditto(_ from: URL, _ to: URL, runner: any ProcessRunner) throws {
        let status = try runner.run(URL(filePath: "/usr/bin/ditto"),
                                    [from.path(percentEncoded: false), to.path(percentEncoded: false)],
                                    environment: [:], output: nil)
        guard status == 0 else { throw GPTKImportError.copyFailed(status) }
    }
}
```

- [ ] **Step 4: Run them and confirm they pass**

Run: `swift test 2>&1 | tail -3`
Expected: `Test run with 56 tests in 0 suites passed`

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "feat: import D3DMetal from a user-supplied GPTK"
```

---

### Task 10: Runtime installer

**Files:**
- Create: `Sources/MacProtonCore/RuntimeInstaller.swift`
- Test: `Tests/MacProtonCoreTests/RuntimeInstallerTests.swift`

**Interfaces:**
- Consumes: `ToolLayout` (Task 2), `ProcessRunner` (Task 5), `GPTKImporter.applyOverlay` (Task 9).
- Produces:
  - `struct RuntimePin { version: String; url: URL; sha256: String; static current }`
  - `enum RuntimeInstaller { static func sha256(of: URL) throws -> String; static func install(tarball: URL, pin: RuntimePin, layout: ToolLayout, launcherBinary: URL, runner:) throws; static func download(_ pin: RuntimePin, to: URL) async throws }`
  - `enum RuntimeInstallError { checksumMismatch(expected:actual:), extractFailed(Int32), badArchive(String) }`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import MacProtonCore

/// A tiny tarball shaped like winecx-gptk's `Libraries.tar.gz`, and a pin that matches it.
private func makeRuntimeTarball(includeWineserver: Bool = true) throws -> (URL, RuntimePin) {
    let src = try makeTempDir()
    try write("#!/bin/sh\necho wine\n", to: src.appending(path: "Libraries/Wine/bin/wine"), executable: true)
    if includeWineserver {
        try write("#!/bin/sh\n", to: src.appending(path: "Libraries/Wine/bin/wineserver"), executable: true)
    }
    try write("dxmt", to: src.appending(path: "Libraries/DXMT/x64/d3d11.dll"))
    let tarball = try makeTempDir().appending(path: "Libraries.tar.gz")
    let status = try SystemProcessRunner().run(URL(filePath: "/usr/bin/tar"),
        ["-czf", tarball.path(percentEncoded: false), "-C", src.path(percentEncoded: false), "Libraries"],
        environment: [:], output: nil)
    #expect(status == 0)
    return (tarball, RuntimePin(version: "runtime-test-1", url: tarball, sha256: try RuntimeInstaller.sha256(of: tarball)))
}

/// Stands in for bin/macproton: prints each argument on its own line.
private func makeEchoLauncher() throws -> URL {
    let url = try makeTempDir().appending(path: "macproton")
    try write("#!/bin/sh\nfor a in \"$@\"; do echo \"$a\"; done\n", to: url, executable: true)
    return url
}

@Test func installsRuntimeAndToolFiles() throws {
    let (tarball, pin) = try makeRuntimeTarball()
    let layout = ToolLayout(root: try makeTempDir().appending(path: "compatibilitytools.d/macproton"))
    try RuntimeInstaller.install(tarball: tarball, pin: pin, layout: layout, launcherBinary: try makeEchoLauncher())
    let fm = FileManager.default
    #expect(fm.isExecutableFile(atPath: layout.wine.path(percentEncoded: false)))
    #expect(layout.runtimeVersion == "runtime-test-1")
    #expect(fm.isExecutableFile(atPath: layout.root.appending(path: "proton").path(percentEncoded: false)))
    #expect(fm.isExecutableFile(atPath: layout.launcherBinary.path(percentEncoded: false)))
    let tool = try String(contentsOf: layout.root.appending(path: "compatibilitytool.vdf"), encoding: .utf8)
    #expect(tool.contains(#""to_oslist"    "linux""#))
    let manifest = try String(contentsOf: layout.root.appending(path: "toolmanifest.vdf"), encoding: .utf8)
    #expect(manifest.contains(#""commandline" "/proton %verb%""#))
    #expect(!fm.fileExists(atPath: layout.root.appending(path: "runtime.staging").path(percentEncoded: false)))
}

@Test func protonStubForwardsArgumentsFromAPathWithSpaces() throws {
    let (tarball, pin) = try makeRuntimeTarball()
    let layout = ToolLayout(root: try makeTempDir().appending(path: "Application Support/macproton"))
    try RuntimeInstaller.install(tarball: tarball, pin: pin, layout: layout, launcherBinary: try makeEchoLauncher())
    let out = try makeTempDir().appending(path: "out.txt")
    let status = try SystemProcessRunner().run(layout.root.appending(path: "proton"),
        ["waitforexitandrun", "/Steam Library/Game.exe", "a b", "\"q\""], environment: [:], output: out)
    #expect(status == 0)
    #expect(try String(contentsOf: out, encoding: .utf8)
        == "launch\nwaitforexitandrun\n/Steam Library/Game.exe\na b\n\"q\"\n")
}

@Test func checksumMismatchChangesNothing() throws {
    let (tarball, pin) = try makeRuntimeTarball()
    let layout = try makeToolLayout()
    let bad = RuntimePin(version: pin.version, url: pin.url, sha256: String(repeating: "0", count: 64))
    #expect(throws: RuntimeInstallError.self) {
        try RuntimeInstaller.install(tarball: tarball, pin: bad, layout: layout, launcherBinary: try makeEchoLauncher())
    }
    #expect(layout.runtimeVersion == "runtime-test")
}

@Test func archiveWithoutWineserverKeepsOldRuntime() throws {
    let (tarball, pin) = try makeRuntimeTarball(includeWineserver: false)
    let layout = try makeToolLayout()
    #expect(throws: RuntimeInstallError.badArchive("missing Libraries/Wine/bin/wineserver")) {
        try RuntimeInstaller.install(tarball: tarball, pin: pin, layout: layout, launcherBinary: try makeEchoLauncher())
    }
    #expect(FileManager.default.isExecutableFile(atPath: layout.wineserver.path(percentEncoded: false)))
    #expect(layout.runtimeVersion == "runtime-test")
}

@Test func reinstallReappliesImportedGPTK() throws {
    let (tarball, pin) = try makeRuntimeTarball()
    let layout = try makeToolLayout()
    try write("apple dxgi", to: layout.gptkStore.appending(path: "lib/wine/x86_64-windows/dxgi.dll"))
    try RuntimeInstaller.install(tarball: tarball, pin: pin, layout: layout, launcherBinary: try makeEchoLauncher())
    let dxgi = layout.wineLib.appending(path: "wine/x86_64-windows/dxgi.dll")
    #expect(try String(contentsOf: dxgi, encoding: .utf8) == "apple dxgi")
}
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `swift test 2>&1 | tail -5`
Expected: the build fails with `cannot find 'RuntimePin' in scope`.

- [ ] **Step 3: Implement**

```swift
import CryptoKit
import Foundation

/// The Wine runtime release MacProton is tested against.
public struct RuntimePin: Equatable, Sendable {
    public let version: String
    public let url: URL
    public let sha256: String

    /// winecx-gptk: CrossOver 26.3 changes on Wine 11.17, with DXMT 0.80 and DXVK-macOS 1.10.3.
    /// ponytail: upstream release; point `url` at the chadouming/winecx-gptk fork before the first public release.
    public static let current = RuntimePin(
        version: "runtime-v4.7.3",
        url: URL(string: "https://github.com/dappermint/winecx-gptk/releases/download/runtime-v4.7.3/Libraries.tar.gz")!,
        sha256: "a4b5d63493f80698cce5cad8e7212d9a51c8292037b00c478f4652636fcfd331")
}

public enum RuntimeInstallError: Error, Equatable, CustomStringConvertible {
    case checksumMismatch(expected: String, actual: String)
    case extractFailed(Int32)
    case badArchive(String)

    public var description: String {
        switch self {
        case .checksumMismatch(let expected, let actual): "runtime checksum mismatch: expected \(expected), got \(actual)"
        case .extractFailed(let status): "extracting the runtime failed (tar exit \(status))"
        case .badArchive(let detail): "the runtime archive is not a Wine runtime: \(detail)"
        }
    }
}

/// Installs the Wine runtime and the Steam-facing tool files into a `macproton` tool folder.
public enum RuntimeInstaller {
    static let compatibilityTool = """
        "compatibilitytools"
        {
          "compat_tools"
          {
            "macproton"
            {
              "install_path" "."
              "display_name" "MacProton"
              "from_oslist"  "windows"
              "to_oslist"    "linux"
            }
          }
        }

        """
    static let toolManifest = """
        "manifest"
        {
          "version" "2"
          "commandline" "/proton %verb%"
        }

        """
    static let protonStub = """
        #!/bin/sh
        exec "$(dirname "$0")/bin/macproton" launch "$@"

        """

    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Verifies the tarball, extracts it to a staging folder, and only then replaces the old runtime.
    /// Re-applies an imported GPTK, since the new Wine tree does not contain it.
    public static func install(tarball: URL, pin: RuntimePin, layout: ToolLayout, launcherBinary: URL,
                               runner: any ProcessRunner = SystemProcessRunner()) throws {
        let actual = try sha256(of: tarball)
        guard actual == pin.sha256 else {
            throw RuntimeInstallError.checksumMismatch(expected: pin.sha256, actual: actual)
        }
        let fm = FileManager.default
        try fm.createDirectory(at: layout.root, withIntermediateDirectories: true)
        let staging = layout.root.appending(path: "runtime.staging", directoryHint: .isDirectory)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let status = try runner.run(URL(filePath: "/usr/bin/tar"),
                                    ["-xzf", tarball.path(percentEncoded: false), "-C", staging.path(percentEncoded: false)],
                                    environment: [:], output: nil)
        guard status == 0 else { throw RuntimeInstallError.extractFailed(status) }
        let extracted = ToolLayout(root: staging)
        for required in [extracted.wine, extracted.wineserver]
        where !fm.isExecutableFile(atPath: required.path(percentEncoded: false)) {
            throw RuntimeInstallError.badArchive("missing Libraries/Wine/bin/\(required.lastPathComponent)")
        }
        try? fm.removeItem(at: layout.libraries)
        try fm.moveItem(at: extracted.libraries, to: layout.libraries)
        try writeToolFiles(layout: layout, launcherBinary: launcherBinary)
        try pin.version.write(to: layout.runtimeVersionFile, atomically: true, encoding: .utf8)
        if fm.fileExists(atPath: layout.gptkStore.path(percentEncoded: false)) {
            try GPTKImporter.applyOverlay(layout: layout, runner: runner)
        }
    }

    static func writeToolFiles(layout: ToolLayout, launcherBinary: URL) throws {
        let fm = FileManager.default
        try compatibilityTool.write(to: layout.root.appending(path: "compatibilitytool.vdf"), atomically: true, encoding: .utf8)
        try toolManifest.write(to: layout.root.appending(path: "toolmanifest.vdf"), atomically: true, encoding: .utf8)
        let stub = layout.root.appending(path: "proton")
        try protonStub.write(to: stub, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path(percentEncoded: false))
        try fm.createDirectory(at: layout.launcherBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
        if launcherBinary.resolvingSymlinksInPath() != layout.launcherBinary.resolvingSymlinksInPath() {
            try? fm.removeItem(at: layout.launcherBinary)
            try fm.copyItem(at: launcherBinary, to: layout.launcherBinary)
        }
    }

    /// Downloads to a temporary file first, so an interrupted download never lands at `destination`.
    public static func download(_ pin: RuntimePin, to destination: URL) async throws {
        let (temporary, response) = try await URLSession.shared.download(from: pin.url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}
```

- [ ] **Step 4: Run them and confirm they pass**

Run: `swift test 2>&1 | tail -3`
Expected: `Test run with 61 tests in 0 suites passed`

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "feat: install the pinned Wine runtime and Steam tool files"
```

---

### Task 11: `macproton` CLI

**Files:**
- Modify: `Package.swift` (add the executable product and target)
- Create: `Sources/MacProtonCore/CommandLineTool.swift`, `Sources/macproton/main.swift`, `README.md`
- Test: `Tests/MacProtonCoreTests/CommandLineToolTests.swift`

**Interfaces:**
- Consumes: `Launcher` (Task 8), `GPTKImporter.importGPTK` (Task 9), `RuntimeInstaller`, `RuntimePin.current` (Task 10), `ToolLayout(executable:)`, `ToolLayout.defaultRoot` (Task 2).
- Produces: `enum CommandLineTool { static usage: String; static func run(_ args: [String], environment: [String: String], executable: URL) async -> Int32; static func option(_ name: String, in args: inout [String]) -> String? }`. Exit codes: 0 on success, 1 on failure, 2 on bad usage. Subcommands: `launch <verb> <target> [args...]`, `import-gptk [--tool-dir <dir>] <path>`, `install-runtime [--tool-dir <dir>] [--tarball <path>]`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import MacProtonCore

@Test func unknownCommandPrintsUsage() async {
    #expect(await CommandLineTool.run(["frobnicate"], environment: [:], executable: URL(filePath: "/x")) == 2)
    #expect(await CommandLineTool.run([], environment: [:], executable: URL(filePath: "/x")) == 2)
}

@Test func optionParsingRemovesTheFlagAndValue() {
    var args = ["--tool-dir", "/a b/tool", "/Volumes/GPTK"]
    #expect(CommandLineTool.option("--tool-dir", in: &args) == "/a b/tool")
    #expect(args == ["/Volumes/GPTK"])
    #expect(CommandLineTool.option("--tarball", in: &args) == nil)
}

@Test func importGPTKRejectsANonGPTKFolder() async throws {
    let tool = try makeTempDir().path(percentEncoded: false)
    let status = await CommandLineTool.run(["import-gptk", "--tool-dir", tool, try makeTempDir().path(percentEncoded: false)],
                                           environment: [:], executable: URL(filePath: "/x"))
    #expect(status == 1)
}

@Test func installRuntimeRejectsAWrongTarball() async throws {
    let bogus = try makeTempDir().appending(path: "Libraries.tar.gz")
    try write("not a runtime", to: bogus)
    let status = await CommandLineTool.run(
        ["install-runtime", "--tool-dir", try makeTempDir().path(percentEncoded: false),
         "--tarball", bogus.path(percentEncoded: false)],
        environment: [:], executable: URL(filePath: "/x"))
    #expect(status == 1)
}
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `swift test 2>&1 | tail -5`
Expected: the build fails with `cannot find 'CommandLineTool' in scope`.

- [ ] **Step 3: Implement**

Replace `Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacProton",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "macproton", targets: ["macproton"]),
        .library(name: "MacProtonCore", targets: ["MacProtonCore"]),
    ],
    targets: [
        .target(name: "MacProtonCore"),
        .executableTarget(name: "macproton", dependencies: ["MacProtonCore"]),
        .testTarget(name: "MacProtonCoreTests", dependencies: ["MacProtonCore"]),
    ]
)
```

`Sources/MacProtonCore/CommandLineTool.swift`:

```swift
import Dispatch
import Foundation

/// `macproton` subcommands. Kept out of main.swift so they can be tested.
public enum CommandLineTool {
    public static let usage = """
        usage: macproton launch <verb> <target> [args...]
               macproton import-gptk [--tool-dir <dir>] <GPTK volume | redist | redist/lib>
               macproton install-runtime [--tool-dir <dir>] [--tarball <Libraries.tar.gz>]
        """

    public static func run(_ args: [String], environment: [String: String], executable: URL) async -> Int32 {
        guard let command = args.first else { return usageError() }
        var rest = Array(args.dropFirst())
        switch command {
        case "launch":
            let launcher = Launcher(layout: ToolLayout(executable: executable))
            installTerminationHandlers(launcher, environment: environment)
            return launcher.launch(rest, environment: environment)
        case "import-gptk":
            let layout = toolLayout(option("--tool-dir", in: &rest))
            guard rest.count == 1 else { return usageError() }
            do {
                let manifest = try GPTKImporter.importGPTK(from: URL(filePath: rest[0]), into: layout)
                print("Imported D3DMetal \(manifest.version) into \(layout.root.path(percentEncoded: false))")
                return 0
            } catch {
                return failure(error)
            }
        case "install-runtime":
            let layout = toolLayout(option("--tool-dir", in: &rest))
            let tarballPath = option("--tarball", in: &rest)
            guard rest.isEmpty else { return usageError() }
            do {
                let tarball = if let tarballPath { URL(filePath: tarballPath) } else { try await cachedDownload(.current) }
                try RuntimeInstaller.install(tarball: tarball, pin: .current, layout: layout, launcherBinary: executable)
                print("Installed \(RuntimePin.current.version) into \(layout.root.path(percentEncoded: false))")
                return 0
            } catch {
                return failure(error)
            }
        default:
            return usageError()
        }
    }

    /// Removes `--name value` from `args` and returns the value.
    static func option(_ name: String, in args: inout [String]) -> String? {
        guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
        let value = args[index + 1]
        args.removeSubrange(index...index + 1)
        return value
    }

    static func toolLayout(_ dir: String?) -> ToolLayout {
        ToolLayout(root: dir.map { URL(filePath: $0, directoryHint: .isDirectory) } ?? ToolLayout.defaultRoot)
    }

    static func cachedDownload(_ pin: RuntimePin) async throws -> URL {
        let cache = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Caches/MacProton", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let tarball = cache.appending(path: "\(pin.version).tar.gz")
        if !FileManager.default.fileExists(atPath: tarball.path(percentEncoded: false)) {
            print("Downloading \(pin.url.absoluteString)")
            try await RuntimeInstaller.download(pin, to: tarball)
        }
        return tarball
    }

    // ponytail: global signal sources for the process's single launch; never mutated after setup.
    nonisolated(unsafe) private static var signalSources: [any DispatchSourceSignal] = []

    /// Steam's Stop button (SIGTERM) and Ctrl-C kill the game's Wine processes, then exit.
    static func installTerminationHandlers(_ launcher: Launcher, environment: [String: String]) {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler {
                launcher.terminate(environment: environment)
                exit(128 + sig)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private static func usageError() -> Int32 {
        FileHandle.standardError.write(Data((usage + "\n").utf8))
        return 2
    }

    private static func failure(_ error: any Error) -> Int32 {
        FileHandle.standardError.write(Data("macproton: \(error)\n".utf8))
        return 1
    }
}
```

`Sources/macproton/main.swift`:

```swift
import Foundation
import MacProtonCore

let executable = Bundle.main.executableURL ?? URL(filePath: CommandLine.arguments[0])
exit(await CommandLineTool.run(Array(CommandLine.arguments.dropFirst()),
                               environment: ProcessInfo.processInfo.environment,
                               executable: executable))
```

`README.md`:

~~~~markdown
# MacProton

Proton for macOS: Windows games from your Steam library, launched by the native macOS Steam
client and translated by Wine and Apple's D3DMetal.

**Status:** sub-project 1 (the runtime) is in progress. Design: `docs/superpowers/specs/`.

**Requirements:** Apple Silicon, macOS 26 or later, Rosetta 2, Xcode 27 (Swift 6).

## Build and test

```sh
make build   # swift build -c release
make test    # unit tests
make smoke   # real Wine; needs `brew install mingw-w64`
```

## Install the runtime

```sh
.build/release/macproton install-runtime                  # downloads the pinned Wine runtime (461 MB)
.build/release/macproton import-gptk "/Volumes/<GPTK>"    # optional: Apple's GPTK from developer.apple.com
```

MacProton never ships Apple's files; `import-gptk` copies D3DMetal from the GPTK you downloaded.

## Per-game options (Steam launch options)

| Option | Effect |
|---|---|
| `MACPROTON_GRAPHICS=d3dmetal\|dxmt\|dxvk %command%` | Pick the Direct3D backend |
| `MACPROTON_LOG=1 %command%` | Wine log in `~/Library/Logs/MacProton/steam-<appid>.log` |
| `MACPROTON_NO_AVX=1 %command%` | Don't advertise AVX through Rosetta |
| `MACPROTON_NO_MSYNC=1 %command%` | Turn off msync |
~~~~

- [ ] **Step 4: Run the tests and try the binary**

Run: `swift test 2>&1 | tail -3`
Expected: `Test run with 65 tests in 0 suites passed`

Run: `swift build -c release && .build/release/macproton; echo "exit=$?"`
Expected: the three usage lines, then `exit=2`.

Run: `STEAM_COMPAT_DATA_PATH=/tmp/x .build/release/macproton launch run /x.exe; echo "exit=$?"`
Expected: `macproton: The MacProton runtime is missing or incomplete. Repair it with: macproton install-runtime`, then `exit=1`. A matching macOS notification appears.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources Tests README.md
git commit -m "feat: macproton CLI with launch, import-gptk and install-runtime"
```

---

### Task 12: Real-Wine smoke test

> **Ask the user first.** This task installs Homebrew's `mingw-w64` and downloads the 461 MB runtime. The d3dmetal half needs the user to download GPTK from developer.apple.com and mount it. Run without `GPTK` if they haven't.

**Files:**
- Create: `Tests/Smoke/exitcode.c`, `Tests/Smoke/d3d11probe.c`, `Tests/Smoke/smoke.sh`
- Modify: `Makefile` (add `smoke`)

**Interfaces:**
- Consumes: the `macproton` binary (Task 11). It runs `install-runtime --tool-dir`, `import-gptk --tool-dir`, and the installed `proton` stub.
- Produces: `make smoke`, which exits 0 only when every backend passes both probes.

- [ ] **Step 1: Install the cross-compiler**

Run: `brew install mingw-w64 && x86_64-w64-mingw32-gcc --version | head -1`
Expected: a `x86_64-w64-mingw32-gcc (GCC) …` version line.

- [ ] **Step 2: Write the probes and the script**

`Tests/Smoke/exitcode.c`:

```c
/* Prints its arguments and exits with their count, so the smoke test can tell that
   arguments with spaces reached the game as single arguments. */
#include <stdio.h>

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) printf("arg %d: [%s]\n", i, argv[i]);
    return argc - 1;
}
```

`Tests/Smoke/d3d11probe.c`:

```c
/* Creates a D3D11 device and swap chain on a small window; exits 0 on success. */
#include <windows.h>
#include <d3d11.h>
#include <stdio.h>

int main(void) {
    WNDCLASSA wc = {0};
    wc.lpfnWndProc = DefWindowProcA;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.lpszClassName = "d3d11probe";
    RegisterClassA(&wc);
    HWND hwnd = CreateWindowA("d3d11probe", "d3d11probe", WS_OVERLAPPEDWINDOW, 0, 0, 64, 64,
                              NULL, NULL, wc.hInstance, NULL);

    DXGI_SWAP_CHAIN_DESC sd = {0};
    sd.BufferCount = 1;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = hwnd;
    sd.SampleDesc.Count = 1;
    sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;

    IDXGISwapChain *swap = NULL;
    ID3D11Device *device = NULL;
    ID3D11DeviceContext *context = NULL;
    D3D_FEATURE_LEVEL level = 0;
    HRESULT hr = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0,
                                               D3D11_SDK_VERSION, &sd, &swap, &device, &level, &context);
    printf("D3D11CreateDeviceAndSwapChain: hr=0x%08lx feature_level=0x%x\n", (unsigned long)hr, (unsigned)level);
    return FAILED(hr) ? 1 : 0;
}
```

`Tests/Smoke/smoke.sh`:

```sh
#!/bin/sh
# Real-Wine smoke test (spec section 7). Not run in CI: GitHub's macOS runners are unreliable for GPU work.
# Needs: `brew install mingw-w64`, and network on the first run (461 MB runtime download, then cached).
# Optional: MACPROTON_TARBALL=<Libraries.tar.gz> skips the download; GPTK=<mounted GPTK volume> adds d3dmetal.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="${TMPDIR:-/tmp}/macproton smoke"   # a space on purpose: Steam's paths have one
TOOL="$WORK/tool"
rm -rf "$WORK/compatdata"
mkdir -p "$WORK/bin"

x86_64-w64-mingw32-gcc -O2 -o "$WORK/bin/exitcode.exe" "$ROOT/Tests/Smoke/exitcode.c"
x86_64-w64-mingw32-gcc -O2 -o "$WORK/bin/d3d11probe.exe" "$ROOT/Tests/Smoke/d3d11probe.c" -ld3d11 -luser32

if [ -n "${MACPROTON_TARBALL:-}" ]; then
  "$ROOT/.build/release/macproton" install-runtime --tool-dir "$TOOL" --tarball "$MACPROTON_TARBALL"
else
  "$ROOT/.build/release/macproton" install-runtime --tool-dir "$TOOL"
fi
if [ -n "${GPTK:-}" ]; then
  "$TOOL/bin/macproton" import-gptk --tool-dir "$TOOL" "$GPTK"
fi

fail=0
check() { # backend exe expected-exit [args...]
  backend=$1; exe=$2; want=$3; shift 3
  set +e
  STEAM_COMPAT_DATA_PATH="$WORK/compatdata/$backend" SteamAppId=0 MACPROTON_GRAPHICS=$backend \
    "$TOOL/proton" waitforexitandrun "$WORK/bin/$exe" "$@"
  got=$?
  set -e
  if [ "$got" -eq "$want" ]; then echo "PASS $backend $exe"; else echo "FAIL $backend $exe: exit $got, want $want"; fail=1; fi
}

backends="dxmt dxvk"
if [ -f "$TOOL/gptk.json" ]; then backends="d3dmetal $backends"; fi
for backend in $backends; do
  check "$backend" exitcode.exe 2 "a b" "c"
  check "$backend" d3d11probe.exe 0
done
tail -n 6 "$HOME/Library/Logs/MacProton/launcher.log"
exit $fail
```

Replace `Makefile` (recipe lines start with a tab):

```make
.PHONY: build test smoke

build:
	swift build -c release

test:
	swift test

# Real Wine; see Tests/Smoke/smoke.sh for prerequisites.
smoke: build
	sh Tests/Smoke/smoke.sh
```

- [ ] **Step 3: Run the smoke test**

Run: `make smoke` (add `GPTK="/Volumes/<GPTK volume>"` if the user has mounted GPTK)
Expected: `PASS dxmt exitcode.exe`, `PASS dxmt d3d11probe.exe`, `PASS dxvk exitcode.exe`, `PASS dxvk d3d11probe.exe`, plus the two `d3dmetal` lines when GPTK is given. Then the last `launcher.log` lines. The script exits 0. The first launch per backend creates a prefix and takes longer.

If it fails:
- **`badArchive` from `install-runtime`:** the real tarball's top-level folder isn't `Libraries/`. List it with `tar -tzf ~/Library/Caches/MacProton/runtime-v4.7.3.tar.gz | head`, then fix the paths in `ToolLayout` and the test fixture in `RuntimeInstallerTests`. Don't work around it in the script.
- **`d3d11probe` fails on `dxmt`/`dxvk`:** rerun a single case with `MACPROTON_LOG=1` and read `~/Library/Logs/MacProton/steam-0.log`.
- **GPTK import fails validation:** the error lists the missing files. Compare with `ls -R` of the GPTK `redist/lib` and update `GPTKImporter.requiredFiles`, with a test fixture for that GPTK version.

- [ ] **Step 4: Update the spec's §8.1 with the outcome**

Edit `docs/superpowers/specs/2026-09-27-macproton-runtime-design.md` §8 item 1. Record whether GPTK 3.0 or 4.0 was used, whether d3dmetal passed, and the date.

- [ ] **Step 5: Commit**

```bash
git add Tests/Smoke Makefile docs/superpowers/specs
git commit -m "test: real-Wine smoke test across graphics backends"
```

---

### Task 13: Steam acceptance test

> **Ask the user first.** This task changes the user's Steam setup, may add a free game license to their account, and needs them watching the game window. Follow the doc's step 2 (hide installed games) without exception. Skipping it deletes their installed games' files.

**Files:**
- Create: `docs/testing/acceptance-runtime.md`

**Interfaces:**
- Consumes: the installed tool from Task 12's flow, or `macproton install-runtime` into the default tool folder.
- Produces: a filled-in results row, the spec's acceptance criterion (§7) demonstrated, and §8.4 resolved.

- [ ] **Step 1: Write the checklist**

~~~~markdown
# Runtime acceptance test (sub-project 1)

Manual. Proves a Windows-only game installs and runs from native macOS Steam's Play button
through `macproton`, before the menu-bar app (sub-project 3) automates Steam Play mode.

**Warning:** in Steam Play mode, Steam unmounts installed games that have no mapping for the
active platform: their files are deleted and redownloaded later. Step 2 hides every installed
game from Steam first. Do not skip it.

## 1. Install

```sh
make build
.build/release/macproton install-runtime
.build/release/macproton import-gptk "/Volumes/<GPTK volume>"   # optional, enables d3dmetal
```

## 2. Hide installed games from Steam

Quit Steam (Steam > Quit Steam), then:

```sh
S="$HOME/Library/Application Support/Steam"
mkdir -p "$HOME/macproton-hidden-manifests"
mv "$S"/steamapps/appmanifest_*.acf "$HOME/macproton-hidden-manifests/"
```

## 3. Enable Steam Play mode by hand

```sh
echo '@sSteamCmdForcePlatformType linux' > "$S/Steam.AppBundle/Steam/Contents/MacOS/steam_dev.cfg"
open -a Steam --env "STEAM_EXTRA_COMPAT_TOOLS_PATHS=$HOME/Library/Application Support/MacProton/compatibilitytools.d/macproton"
```

Check: `grep macproton "$S/logs/compat_log.txt"` shows `Registering tool macproton` and
`Loaded manifest for tool macproton`, and no `Ignoring tool macproton`.

## 4. Pick the acceptance game

A free, Windows-only D3D11 game. In its Steam Properties > Compatibility, force "MacProton",
then install it. Check it does not need the Steam API (that needs sub-project 2's bridge):

```sh
llvm-objdump -p "$S/steamapps/common/<Game>/<Game>.exe" | grep -i "DLL Name"
```

If `steam_api64.dll` is listed, uninstall and pick another game. Record the choice below.

## 5. Run

| Run | Launch options | Pass when |
|---|---|---|
| A | (none; d3dmetal if GPTK imported, else dxmt) | Main menu renders; Steam shows the game as running |
| B | `MACPROTON_GRAPHICS=dxmt %command%` | Same |
| C | `MACPROTON_LOG=1 %command%` | `~/Library/Logs/MacProton/steam-<appid>.log` has the environment and Wine output |
| D | (none), then press Stop in Steam | Game closes; Steam stops showing it as running |

After each run, `~/Library/Logs/MacProton/launcher.log` has a `verb=waitforexitandrun` line
with the expected backend.

## 6. Revert

1. Uninstall the acceptance game in Steam, then quit Steam.
2. Restore everything:
   ```sh
   rm "$S/Steam.AppBundle/Steam/Contents/MacOS/steam_dev.cfg"
   mv "$HOME/macproton-hidden-manifests"/appmanifest_*.acf "$S/steamapps/"
   rmdir "$HOME/macproton-hidden-manifests"
   open -a Steam
   ```
3. Check `$S/logs/content_log.txt` shows no download for the restored games.

## Results

| Date | Game (appid) | GPTK | Run A | Run B | Run C | Run D | Notes |
|---|---|---|---|---|---|---|---|
~~~~

- [ ] **Step 2: Install into the default tool folder**

Run: `swift build -c release && .build/release/macproton install-runtime`
Expected: `Installed runtime-v4.7.3 into /Users/<you>/Library/Application Support/MacProton/compatibilitytools.d/macproton/`

- [ ] **Step 3: Carry out doc steps 2–6 with the user**

Expected: runs A–D pass, and step 6's check shows no redownload of the restored games.

- [ ] **Step 4: Record the results**

Add a row to the doc's Results table. Update the spec's §8 item 4 with the chosen game.

- [ ] **Step 5: Commit**

```bash
git add docs/testing/acceptance-runtime.md docs/superpowers/specs
git commit -m "test: Steam acceptance run for the macproton runtime"
```
