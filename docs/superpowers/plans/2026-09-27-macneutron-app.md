# MacNeutron App (Sub-project 3a) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the project to MacNeutron and build its menu-bar app, which installs the runtime, imports GPTK, turns Steam Play mode on and off safely (keeping Mac games native), keeps Steam's mappings current, and offers per-game settings.

**Architecture:**
- **Core logic** lives in `MacNeutronCore`, with no UI, behind protocols and fake Steam folders so it's unit-tested.
- **The SwiftUI app** is a SwiftPM executable target (`MacNeutronApp`) with a thin `@Observable` model over the core.
- **Packaging:** `make app` assembles an ad-hoc-signed `build/MacNeutron.app` with the `macneutron` CLI in `Contents/Helpers`.

**Tech Stack:** Swift 6.4 (tools-version 6.0), SwiftUI (MenuBarExtra, Window, Table, `fileImporter`), ServiceManagement (`SMAppService`), swift-testing, `hdiutil`.

**Spec:** `docs/superpowers/specs/2026-09-27-macneutron-app-design.md` (builds on `2026-09-27-macproton-runtime-design.md`).

## Global Constraints

- **Platform:** macOS 26 or later, Apple Silicon. `platforms: [.macOS("26.0")]`.
- **Dependencies:** none from third parties.
- **Names:**
  - product "MacNeutron", bundle ID `io.github.chadouming.MacNeutron`, `LSUIElement` YES;
  - Steam tools `macneutron` (Windows → linux) and `macneutron-native` (macos → linux);
  - environment variables `MACNEUTRON_*`.
- **Paths:**
  - MacNeutron data: `~/Library/Application Support/MacNeutron/{compatibilitytools.d,games,backups,steam-play-enabled}`
  - Steam's bundle folder: `~/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/{steam_dev.cfg,compatibilitytools.d}`
- **Invariant (spec §8):** `steam_dev.cfg` never exists unless both tools resolve through the bundle's `compatibilitytools.d` **and** every Mac game is mapped.
  - Enable writes `steam_dev.cfg` **last**.
  - Rollback and disable remove it **first**.
- **`config.vdf`:**
  - it is never written while Steam runs;
  - every write is backed up first (newest 10 kept), re-parsed and compared, then written atomically;
  - only `CompatToolMapping` entries naming a `macneutron*` tool are changed.
- **Mapping priorities:** per-app 250, global `"0"` 75. Only `type` ∈ {`game`, `demo`, `application`} are mapped.
- **Never accept a license agreement for the user.** `hdiutil attach` runs with stdin closed.

## Review Focus

Each item below is pinned by a test in the task that owns the code.

1. **Your real Steam files.** `config.vdf` must round-trip byte for byte and `appinfo.vdf` must parse (both exercised when `MACNEUTRON_REAL_STEAM=1`). Covered by Task 3 `roundTripsTheRealConfigFile` and Task 4 `readsTheRealAppCache`.
2. **Other tools' mappings.** A user's existing Proton mapping or other `CompatToolMapping` entry survives every write. Covered by Task 5 `mergeKeepsOtherToolsAndReplacesOurs` and Task 7 `disableRemovesOnlyWhatEnableAdded`.
3. **Interrupted or failed enable.** Steam must never be left in Linux mode without protection. Covered by Task 7 `failedVerificationRollsBackWithDevConfigRemovedFirst` (launches record `[true, false]`) and `unreadableConfigChangesNothing`.
4. **Launch-option variables beat per-game settings,** and a corrupt settings file never blocks a launch. Covered by Task 9 `gameSettingsApplyUnderneathLaunchOptions` and `unreadableGameSettingsAreIgnored`.
5. **A GPTK image that isn't GPTK,** or a nested image. Covered by Task 11 `rejectsImagesWithoutGPTK` and `importsFromTheNestedEvaluationImage`, using real disk images built by `hdiutil`.

## File Structure

| File | Responsibility |
|---|---|
| `Sources/MacNeutronCore/KeyValues.swift` | Text VDF parse and serialize with byte-exact round trip; path lookup and replace |
| `Sources/MacNeutronCore/AppInfoReader.swift` | Binary `appinfo.vdf` v29 → `[AppInfo]` |
| `Sources/MacNeutronCore/MappingPlanner.swift` | `ToolMapping`, `RunAs`, routing plan, merging into `CompatToolMapping` |
| `Sources/MacNeutronCore/SteamLocation.swift` | `MacNeutronPaths`, `SteamLocation`, `SteamPlayError`, `SteamControlling`, `SteamProcess` |
| `Sources/MacNeutronCore/SteamPlayMode.swift` | `SteamPlayStatus`, enable, disable, sync, status, backups, tool links, log verification |
| `Sources/MacNeutronCore/SteamWatcher.swift` | Turns "running?" polls into launch and quit events |
| `Sources/MacNeutronCore/GameSettings.swift` | `GameSettings`, `GameSettingsStore` (`games/<appid>.json`) |
| `Sources/MacNeutronCore/OrphanPrefixes.swift` | Leftover `compatdata` of uninstalled games |
| `Sources/MacNeutronCore/GPTKDiskImage.swift` | Mount GPTK `.dmg` (and the nested image) read-only and import |
| `Sources/MacNeutronApp/*.swift` | SwiftUI app: `MacNeutronApp`, `AppModel`, `MenuContent`, `SetupView`, `GamesView`, `SettingsView` (+ `CleanupView`) |
| `App/Info.plist` | Bundle metadata for `make app` |
| `docs/testing/acceptance-app.md` | Manual acceptance steps and results |

## Execution Notes

- **The code has been checked.** Every code block compiled and passed under Swift 6.4 / Xcode 27 in a scratch copy on 2026-09-27: 106 tests, clean release build.
- **The app was checked by hand.** Its setup window was confirmed visible and correct. The first builds opened it *behind* other windows, which `raiseWindows()` in Task 12 fixes.
- **Running tests.** Each task runs the full suite (`swift test`) and states the cumulative count.
  - Task 11's disk-image tests make real `hdiutil` images, so the suite takes about 30 s from then on.
  - The two real-Steam tests are skipped unless `MACNEUTRON_REAL_STEAM=1`.
- **Tasks 1 and 13 change the user's Steam setup and need their go-ahead first.** Task 1 must pass before Task 7's code is used for real; its decision rule is in the task.
- **macOS is case-insensitive.** Always write `Tests/`.

---

### Task 1: Verify approach B (Steam scans `compatibilitytools.d` inside its bundle)

> **Ask the user first.** This quits and restarts Steam, hides installed games' manifests for the duration, and turns on Steam Play mode briefly.

**Files:** none in the repo. Record the result in spec §10.1.

**Interfaces:** Consumes nothing. Produces the decision **B confirmed** or **switch to C**.

- [ ] **Step 1: Quit Steam and hide installed games**

```bash
S="$HOME/Library/Application Support/Steam"; B="$S/Steam.AppBundle/Steam/Contents/MacOS"
open steam://exit; while pgrep -x steam_osx >/dev/null; do sleep 1; done
mkdir -p "$HOME/macneutron-hidden-manifests" && mv "$S"/steamapps/appmanifest_*.acf "$HOME/macneutron-hidden-manifests/"
```

- [ ] **Step 2: Install a probe tool outside the bundle, link it into the bundle, and turn on Linux mode**

```bash
S="$HOME/Library/Application Support/Steam"; B="$S/Steam.AppBundle/Steam/Contents/MacOS"
PROBE="$HOME/Library/Application Support/MacNeutron/probe/macneutron-probe"; mkdir -p "$PROBE" "$B/compatibilitytools.d"
printf '"compatibilitytools"\n{\n "compat_tools"\n {\n  "macneutron-probe"\n  {\n   "install_path" "."\n   "display_name" "Probe"\n   "from_oslist" "windows"\n   "to_oslist" "linux"\n  }\n }\n}\n' > "$PROBE/compatibilitytool.vdf"
printf '"manifest"\n{\n "version" "2"\n "commandline" "/probe.sh %%verb%%"\n}\n' > "$PROBE/toolmanifest.vdf"
ln -s "$PROBE" "$B/compatibilitytools.d/macneutron-probe"
echo '@sSteamCmdForcePlatformType linux' > "$B/steam_dev.cfg"
mv "$S/logs/compat_log.txt" "$S/logs/compat_log.before-probe.txt" 2>/dev/null; true
```

- [ ] **Step 3: Start Steam without `STEAM_EXTRA_COMPAT_TOOLS_PATHS` and read the log**

Run: `open -a Steam; sleep 40; grep -E "macneutron-probe|Recording non-user mapping" "$HOME/Library/Application Support/Steam/logs/compat_log.txt" | head -3`
Expected: `Registering tool macneutron-probe, AppID 0` and at least one `Recording non-user mapping` line.

- [ ] **Step 4: Revert**

```bash
S="$HOME/Library/Application Support/Steam"; B="$S/Steam.AppBundle/Steam/Contents/MacOS"
open steam://exit; while pgrep -x steam_osx >/dev/null; do sleep 1; done
rm -f "$B/steam_dev.cfg" "$B/compatibilitytools.d/macneutron-probe"; rmdir "$B/compatibilitytools.d"
rm -rf "$HOME/Library/Application Support/MacNeutron/probe"
mv "$HOME/macneutron-hidden-manifests"/appmanifest_*.acf "$S/steamapps/" && rmdir "$HOME/macneutron-hidden-manifests"
open -a Steam
```

Check: 40 s later, `grep "AppID 1062090" "$S/logs/content_log.txt" | tail -2` shows no new update line for Timberborn.

- [ ] **Step 5: Decide and record**
  - **The probe registered:** B is confirmed. Add "**Verified 2026-MM-DD:** Steam registers tools symlinked into the bundle's `compatibilitytools.d` with no environment variable" under spec §10.1, and continue.
  - **It did not register:** **stop.** Task 7's `linkTools()` has to become approach C (a LaunchAgent running `launchctl setenv STEAM_EXTRA_COMPAT_TOOLS_PATHS` at load); re-plan Task 7 before executing it. Tasks 2–6 don't depend on this and can go ahead.

---

### Task 2: Rename MacProton → MacNeutron

**Files:**
- Rename: `Sources/MacProtonCore` → `Sources/MacNeutronCore`, `Sources/macproton` → `Sources/macneutron`, `Tests/MacProtonCoreTests` → `Tests/MacNeutronCoreTests`
- Modify (text): every tracked file under `Package.swift`, `Makefile`, `README.md`, `Sources`, `Tests` and `docs/testing`. The historical specs and plans in `docs/superpowers` are left as written.

**Interfaces:**
- Consumes: the runtime from sub-project 1.
- Produces: module `MacNeutronCore`, CLI `macneutron`, Steam tool `macneutron` (display "MacNeutron"), `ToolLayout.defaultRoot` under `~/Library/Application Support/MacNeutron/compatibilitytools.d/macneutron`, logs `~/Library/Logs/MacNeutron`, cache `~/Library/Caches/MacNeutron`, variables `MACNEUTRON_*`.

- [ ] **Step 1: Run the rename**

```sh
#!/bin/sh
# Task 1 of the app plan: MacProton -> MacNeutron in code, tests, build files and user docs.
# Historical specs/plans under docs/superpowers are left as written.
set -eu
git mv Sources/MacProtonCore Sources/MacNeutronCore
git mv Sources/macproton Sources/macneutron
git mv Tests/MacProtonCoreTests Tests/MacNeutronCoreTests
files=$(git ls-files Package.swift Makefile README.md Sources Tests docs/testing)
sed -i '' -e 's/MacProtonCore/MacNeutronCore/g' -e 's/MacProton/MacNeutron/g' \
          -e 's/macproton/macneutron/g' -e 's/MACPROTON_/MACNEUTRON_/g' $files
```

Run it from the repo root: `sh rename.sh && rm rename.sh`. Save the script to a temp path first, or paste its lines into the shell.

- [ ] **Step 2: Confirm nothing was missed and everything passes**

Run: `git grep -n -i macproton -- Sources Tests Package.swift Makefile README.md docs/testing; swift test 2>&1 | tail -1`
Expected: no `git grep` output, then `Test run with 69 tests in 0 suites passed`.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "refactor: rename MacProton to MacNeutron"
```

---

### Task 3: KeyValues (Valve's text VDF)

**Files:**
- Create: `Sources/MacNeutronCore/KeyValues.swift`
- Test: `Tests/MacNeutronCoreTests/KeyValuesTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct KVNode { var key: String; var value: Value (enum string(String) | block([KVNode])); static func string(_:_:) / block(_:_:) (escape for you); var stringValue: String?; var children: [KVNode] }`
  - `enum KeyValues { static func parse(_:) throws(KeyValuesError) -> [KVNode]; static func serialize(_:) -> String; static func escape/unescape }`
  - `extension [KVNode] { func node(at: [String]) -> KVNode?; mutating func setBlock(at:children:) }`
  - Test fixture `steamConfigFixture`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import MacNeutronCore

/// Shaped like Steam's config.vdf: tabs, nested blocks, escaped JSON inside a value.
let steamConfigFixture = """
    "InstallConfigStore"
    {
    \t"Software"
    \t{
    \t\t"Valve"
    \t\t{
    \t\t\t"Steam"
    \t\t\t{
    \t\t\t\t"AutoUpdateWindowEnabled"\t\t"0"
    \t\t\t\t"Recent"\t\t"{\\"version\\":2,\\"data\\":[]}"
    \t\t\t\t"CompatToolMapping"
    \t\t\t\t{
    \t\t\t\t\t"440"
    \t\t\t\t\t{
    \t\t\t\t\t\t"name"\t\t"proton_9"
    \t\t\t\t\t\t"config"\t\t""
    \t\t\t\t\t\t"priority"\t\t"250"
    \t\t\t\t\t}
    \t\t\t\t}
    \t\t\t}
    \t\t}
    \t}
    }

    """

@Test func roundTripsSteamFilesByteForByte() throws {
    #expect(KeyValues.serialize(try KeyValues.parse(steamConfigFixture)) == steamConfigFixture)
}

@Test func looksUpPathsCaseInsensitively() throws {
    let nodes = try KeyValues.parse(steamConfigFixture)
    let mapping = nodes.node(at: ["InstallConfigStore", "software", "valve", "steam", "CompatToolMapping", "440"])
    #expect(mapping?.children.node(at: ["name"])?.stringValue == "proton_9")
    #expect(nodes.node(at: ["InstallConfigStore", "Software", "Valve", "Steam", "Recent"])?.stringValue
        == #"{"version":2,"data":[]}"#)
}

@Test func replacingOneBlockLeavesTheRestUntouched() throws {
    var nodes = try KeyValues.parse(steamConfigFixture)
    let path = ["InstallConfigStore", "Software", "Valve", "Steam", "CompatToolMapping"]
    nodes.setBlock(at: path, children: [.block("0", [.string("name", "macneutron")])])
    let out = KeyValues.serialize(nodes)
    #expect(!out.contains("proton_9"))
    #expect(out.contains("\t\t\t\t\t\"0\"\n\t\t\t\t\t{\n\t\t\t\t\t\t\"name\"\t\t\"macneutron\"\n"))
    #expect(out.contains("\"Recent\"\t\t\"{\\\"version\\\":2,\\\"data\\\":[]}\""))
}

@Test func setBlockCreatesMissingParents() {
    var nodes: [KVNode] = []
    nodes.setBlock(at: ["a", "b"], children: [.string("k", #"say "hi" \o/"#)])
    #expect(nodes.node(at: ["a", "b", "k"])?.stringValue == #"say "hi" \o/"#)
    #expect(KeyValues.serialize(nodes).contains("\"k\"\t\t\"say \\\"hi\\\" \\\\o/\""))
}

@Test func rejectsBrokenInput() {
    #expect(throws: KeyValuesError.unterminatedBlock("a")) { try KeyValues.parse("\"a\"\n{\n\"k\" \"v\"\n") }
    #expect(throws: KeyValuesError.self) { try KeyValues.parse("\"a\" \"unterminated") }
    #expect(throws: KeyValuesError.self) { try KeyValues.parse("}") }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MACNEUTRON_REAL_STEAM"] == "1"))
func roundTripsTheRealConfigFile() throws {
    let config = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Steam/config/config.vdf")
    let text = try String(contentsOf: config, encoding: .utf8)
    #expect(KeyValues.serialize(try KeyValues.parse(text)) == text)
}
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `swift test 2>&1 | grep -m1 "error:"`
Expected: `cannot find 'KeyValues' in scope`

- [ ] **Step 3: Implement**

```swift
import Foundation

public enum KeyValuesError: Error, Equatable, CustomStringConvertible {
    case unexpected(String, offset: Int)
    case unterminatedString(offset: Int)
    case unterminatedBlock(String)

    public var description: String {
        switch self {
        case .unexpected(let what, let offset): "\(what) at byte \(offset)"
        case .unterminatedString(let offset): "unterminated string starting at byte \(offset)"
        case .unterminatedBlock(let key): "block \"\(key)\" is never closed"
        }
    }
}

/// One entry of Valve's text KeyValues (`config.vdf`, `libraryfolders.vdf`, `appmanifest_*.acf`).
/// Keys and strings are kept exactly as written, escapes included, so untouched parts of a file
/// round-trip byte for byte.
public struct KVNode: Equatable, Sendable {
    public enum Value: Equatable, Sendable {
        case string(String)
        case block([KVNode])
    }

    public var key: String
    public var value: Value

    public init(key: String, value: Value) {
        self.key = key
        self.value = value
    }

    /// A key/value pair from plain strings; quotes and backslashes are escaped for you.
    public static func string(_ key: String, _ value: String) -> KVNode {
        KVNode(key: KeyValues.escape(key), value: .string(KeyValues.escape(value)))
    }

    public static func block(_ key: String, _ children: [KVNode]) -> KVNode {
        KVNode(key: KeyValues.escape(key), value: .block(children))
    }

    /// The unescaped string value, or nil for a block.
    public var stringValue: String? {
        if case .string(let raw) = value { KeyValues.unescape(raw) } else { nil }
    }

    public var children: [KVNode] {
        if case .block(let nodes) = value { nodes } else { [] }
    }
}

public enum KeyValues {
    public static func parse(_ text: String) throws(KeyValuesError) -> [KVNode] {
        var parser = Parser(bytes: Array(text.utf8))
        return try parser.block(closing: nil)
    }

    /// Steam's own layout: tab indentation, two tabs between key and value, braces on their own lines.
    public static func serialize(_ nodes: [KVNode]) -> String {
        var out = ""
        func emit(_ nodes: [KVNode], depth: Int) {
            let indent = String(repeating: "\t", count: depth)
            for node in nodes {
                switch node.value {
                case .string(let raw):
                    out += "\(indent)\"\(node.key)\"\t\t\"\(raw)\"\n"
                case .block(let children):
                    out += "\(indent)\"\(node.key)\"\n\(indent){\n"
                    emit(children, depth: depth + 1)
                    out += "\(indent)}\n"
                }
            }
        }
        emit(nodes, depth: 0)
        return out
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func unescape(_ raw: String) -> String {
        var out = ""
        var escaping = false
        for character in raw {
            if escaping {
                out.append(character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                out.append(character)
            }
        }
        return out
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func quoted() throws(KeyValuesError) -> String {
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else {
                throw .unexpected("expected a quoted string", offset: index)
            }
            let start = index + 1
            index = start
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "\\"): index += 2
                case UInt8(ascii: "\""):
                    defer { index += 1 }
                    return String(decoding: bytes[start..<index], as: UTF8.self)
                default: index += 1
                }
            }
            throw .unterminatedString(offset: start - 1)
        }

        /// Children until the closing brace of `closing` (or end of input at the top level).
        mutating func block(closing: String?) throws(KeyValuesError) -> [KVNode] {
            var nodes: [KVNode] = []
            while true {
                skipWhitespace()
                guard index < bytes.count else {
                    if let closing { throw .unterminatedBlock(closing) }
                    return nodes
                }
                if bytes[index] == UInt8(ascii: "}") {
                    guard closing != nil else { throw .unexpected("unmatched }", offset: index) }
                    index += 1
                    return nodes
                }
                let key = try quoted()
                skipWhitespace()
                guard index < bytes.count else { throw .unexpected("missing value for \"\(key)\"", offset: index) }
                if bytes[index] == UInt8(ascii: "{") {
                    index += 1
                    nodes.append(KVNode(key: key, value: .block(try block(closing: key))))
                } else {
                    nodes.append(KVNode(key: key, value: .string(try quoted())))
                }
            }
        }
    }
}

extension Array where Element == KVNode {
    /// Case-insensitive lookup along a key path, the way Steam matches keys.
    public func node(at path: [String]) -> KVNode? {
        guard let head = path.first,
              let found = first(where: { $0.key.caseInsensitiveCompare(head) == .orderedSame })
        else { return nil }
        return path.count == 1 ? found : found.children.node(at: [String](path.dropFirst()))
    }

    /// Replaces the block at `path` with `children`, creating it and any missing parents at the end.
    public mutating func setBlock(at path: [String], children: [KVNode]) {
        guard let head = path.first else { return }
        let index = firstIndex { $0.key.caseInsensitiveCompare(head) == .orderedSame }
        var replacement = children
        if path.count > 1 {
            replacement = index.map { self[$0].children } ?? []
            replacement.setBlock(at: [String](path.dropFirst()), children: children)
        }
        if let index {
            self[index].value = .block(replacement)
        } else {
            append(.block(head, replacement))
        }
    }
}
```

- [ ] **Step 4: Run them and confirm they pass, including against the real file**

Run: `swift test 2>&1 | tail -1 && MACNEUTRON_REAL_STEAM=1 swift test --filter roundTripsTheRealConfigFile 2>&1 | tail -1`
Expected: `Test run with 75 tests in 0 suites passed`, then `Test run with 1 test in 0 suites passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "feat: parse and write Valve's text KeyValues byte for byte"
```

---

### Task 4: AppInfoReader (binary `appinfo.vdf` v29)

**Files:**
- Create: `Sources/MacNeutronCore/AppInfoReader.swift`
- Test: `Tests/MacNeutronCoreTests/AppInfoFixture.swift`, `Tests/MacNeutronCoreTests/AppInfoReaderTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct AppInfo { appID: UInt32; name: String; type: String (lowercased); oslist: Set<String> }`
  - `enum AppInfoReader { static let magicV29: UInt32; static func read(_: URL) throws -> [AppInfo]; static func parse(_: Data) throws(AppInfoError) -> [AppInfo] }`
  - `enum AppInfoError { unsupportedFormat(UInt32), truncated(offset:), unknownValueType(UInt8, offset:) }`
  - Test helper `makeAppInfoV29(_:magic:) -> Data`.

- [ ] **Step 1: Write the fixture writer and the failing tests**

`Tests/MacNeutronCoreTests/AppInfoFixture.swift`:

```swift
import Foundation
@testable import MacNeutronCore

/// Writes a minimal appinfo.vdf v29 the way Steam lays it out, for tests.
func makeAppInfoV29(_ apps: [AppInfo], magic: UInt32 = AppInfoReader.magicV29) -> Data {
    var strings: [String] = []
    func index(_ key: String) -> UInt32 {
        if let found = strings.firstIndex(of: key) { return UInt32(found) }
        strings.append(key)
        return UInt32(strings.count - 1)
    }
    func le<T: FixedWidthInteger>(_ value: T) -> [UInt8] { withUnsafeBytes(of: value.littleEndian) { Array($0) } }

    var body: [UInt8] = []
    for app in apps {
        var kv: [UInt8] = []
        func section(_ key: String) { kv += [0x00] + le(index(key)) }
        func string(_ key: String, _ value: String) { kv += [0x01] + le(index(key)) + Array(value.utf8) + [0] }
        section("appinfo")
        kv += [0x02] + le(index("appid")) + le(app.appID)
        section("common")
        string("name", app.name)
        string("type", app.type.capitalized)
        string("oslist", app.oslist.sorted().joined(separator: ","))
        kv += [0x07] + le(index("gameid")) + le(UInt64(app.appID))
        kv += [0x08, 0x08, 0x08]  // end common, end appinfo, end of tree
        let header = le(UInt32(0)) + le(UInt32(0)) + le(UInt64(0)) + [UInt8](repeating: 0, count: 20)
            + le(UInt32(0)) + [UInt8](repeating: 0, count: 20)
        body += le(app.appID) + le(UInt32(header.count + kv.count)) + header + kv
    }
    body += le(UInt32(0))
    let tableOffset = 4 + 4 + 8 + body.count
    var table = le(UInt32(strings.count))
    for string in strings { table += Array(string.utf8) + [0] }
    return Data(le(magic) + le(UInt32(1)) + le(UInt64(tableOffset)) + body + table)
}
```

`Tests/MacNeutronCoreTests/AppInfoReaderTests.swift`:

```swift
import Foundation
import Testing
@testable import MacNeutronCore

@Test func readsNameTypeAndPlatforms() throws {
    let apps = [
        AppInfo(appID: 1062090, name: "Timberborn", type: "game", oslist: ["windows", "macos"]),
        AppInfo(appID: 2977660, name: "Cats", type: "game", oslist: ["windows"]),
        AppInfo(appID: 1628350, name: "Steam Linux Runtime", type: "tool", oslist: ["linux"]),
    ]
    #expect(try AppInfoReader.parse(makeAppInfoV29(apps)) == apps)
}

@Test func rejectsOtherFormats() {
    #expect(throws: AppInfoError.unsupportedFormat(0x0756_4428)) {
        try AppInfoReader.parse(makeAppInfoV29([], magic: 0x0756_4428))
    }
}

@Test func rejectsTruncatedFiles() {
    let data = makeAppInfoV29([AppInfo(appID: 1, name: "A", type: "game", oslist: ["windows"])])
    #expect(throws: AppInfoError.self) { try AppInfoReader.parse(data.prefix(40)) }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MACNEUTRON_REAL_STEAM"] == "1"))
func readsTheRealAppCache() throws {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Steam/appcache/appinfo.vdf")
    let timberborn = try AppInfoReader.read(url).first { $0.appID == 1062090 }
    #expect(timberborn?.oslist == ["windows", "macos"])
    #expect(timberborn?.type == "game")
}
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `swift test 2>&1 | grep -m1 "error:"`
Expected: `cannot find type 'AppInfo' in scope`

- [ ] **Step 3: Implement**

```swift
import Foundation

/// What MacNeutron needs to know about one Steam app.
public struct AppInfo: Equatable, Sendable {
    public let appID: UInt32
    public let name: String
    /// Lowercased `common/type`, e.g. "game", "tool", "dlc".
    public let type: String
    /// `common/oslist`, e.g. ["windows", "macos"].
    public let oslist: Set<String>

    public init(appID: UInt32, name: String, type: String, oslist: Set<String>) {
        self.appID = appID
        self.name = name
        self.type = type
        self.oslist = oslist
    }
}

public enum AppInfoError: Error, Equatable, CustomStringConvertible {
    case unsupportedFormat(UInt32)
    case truncated(offset: Int)
    case unknownValueType(UInt8, offset: Int)

    public var description: String {
        switch self {
        case .unsupportedFormat(let magic):
            String(format: "Steam's app cache uses format 0x%08x, which MacNeutron doesn't understand yet", magic)
        case .truncated(let offset): "Steam's app cache ends early (byte \(offset))"
        case .unknownValueType(let type, let offset): "Steam's app cache has unknown value type \(type) at byte \(offset)"
        }
    }
}

/// Reads Steam's binary `appcache/appinfo.vdf`, format v29 (keys are indices into a string table).
public enum AppInfoReader {
    public static let magicV29: UInt32 = 0x0756_4429

    public static func read(_ url: URL) throws -> [AppInfo] {
        try parse(Data(contentsOf: url, options: .alwaysMapped))
    }

    public static func parse(_ data: Data) throws(AppInfoError) -> [AppInfo] {
        var cursor = Cursor(bytes: [UInt8](data))
        let magic = try cursor.u32()
        guard magic == magicV29 else { throw .unsupportedFormat(magic) }
        _ = try cursor.u32()  // universe
        let tableOffset = Int(try cursor.u64())
        let strings = try stringTable(bytes: cursor.bytes, at: tableOffset)

        var apps: [AppInfo] = []
        while true {
            let appID = try cursor.u32()
            if appID == 0 { break }
            let size = Int(try cursor.u32())
            let end = cursor.offset + size
            guard end <= cursor.bytes.count else { throw .truncated(offset: cursor.offset) }
            // info state, last updated, PICS token, text SHA-1, change number, binary SHA-1
            try cursor.skip(4 + 4 + 8 + 20 + 4 + 20)
            apps.append(try app(appID: appID, cursor: &cursor, end: end, strings: strings))
            cursor.offset = end
        }
        return apps
    }

    private static func stringTable(bytes: [UInt8], at offset: Int) throws(AppInfoError) -> [String] {
        var cursor = Cursor(bytes: bytes, offset: offset)
        let count = Int(try cursor.u32())
        var strings: [String] = []
        strings.reserveCapacity(count)
        for _ in 0..<count { strings.append(try cursor.cString()) }
        return strings
    }

    /// Walks the binary KeyValues tree, keeping only `<root>/common/{name,type,oslist}`.
    private static func app(appID: UInt32, cursor: inout Cursor, end: Int,
                            strings: [String]) throws(AppInfoError) -> AppInfo {
        var path: [String] = []
        var name = "", type = "", oslist = ""
        while cursor.offset < end {
            let valueType = try cursor.u8()
            if valueType == 0x08 {
                if path.isEmpty { break }
                path.removeLast()
                continue
            }
            let keyIndex = Int(try cursor.u32())
            guard keyIndex < strings.count else { throw .truncated(offset: cursor.offset) }
            let key = strings[keyIndex]
            switch valueType {
            case 0x00: path.append(key)
            case 0x01:
                let value = try cursor.cString()
                if path.count == 2, path[1] == "common" {
                    switch key {
                    case "name": name = value
                    case "type": type = value.lowercased()
                    case "oslist": oslist = value
                    default: break
                    }
                }
            case 0x02, 0x03, 0x04, 0x06: try cursor.skip(4)
            case 0x07, 0x0A: try cursor.skip(8)
            default: throw .unknownValueType(valueType, offset: cursor.offset - 5)
            }
        }
        let platforms = Set(oslist.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        return AppInfo(appID: appID, name: name, type: type, oslist: platforms.subtracting([""]))
    }

    private struct Cursor {
        let bytes: [UInt8]
        var offset = 0

        mutating func skip(_ count: Int) throws(AppInfoError) {
            guard offset + count <= bytes.count else { throw .truncated(offset: offset) }
            offset += count
        }

        mutating func u8() throws(AppInfoError) -> UInt8 {
            try skip(1)
            return bytes[offset - 1]
        }

        mutating func u32() throws(AppInfoError) -> UInt32 {
            try skip(4)
            return (0..<4).reduce(0) { $0 | UInt32(bytes[offset - 4 + $1]) << (8 * $1) }
        }

        mutating func u64() throws(AppInfoError) -> UInt64 {
            try skip(8)
            return (0..<8).reduce(0) { $0 | UInt64(bytes[offset - 8 + $1]) << (8 * $1) }
        }

        mutating func cString() throws(AppInfoError) -> String {
            guard let terminator = bytes[offset...].firstIndex(of: 0) else { throw .truncated(offset: offset) }
            defer { offset = terminator + 1 }
            return String(decoding: bytes[offset..<terminator], as: UTF8.self)
        }
    }
}
```

- [ ] **Step 4: Run them and confirm they pass, including against the real file**

Run: `swift test 2>&1 | tail -1 && MACNEUTRON_REAL_STEAM=1 swift test --filter readsTheRealAppCache 2>&1 | tail -1`
Expected: `Test run with 79 tests in 0 suites passed`, then `Test run with 1 test in 0 suites passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "feat: read Steam's binary app cache (appinfo.vdf v29)"
```

---

### Task 5: MappingPlanner

**Files:**
- Create: `Sources/MacNeutronCore/MappingPlanner.swift`
- Test: `Tests/MacNeutronCoreTests/MappingPlannerTests.swift`

**Interfaces:**
- Consumes: `AppInfo` (Task 4); `KVNode`, `KeyValues.unescape` (Task 3).
- Produces:
  - `struct ToolMapping { tool: String; priority: Int }`
  - `enum RunAs: String, Codable { mac, windows }`
  - `enum MappingPlanner { runtimeTool = "macneutron"; nativeTool = "macneutron-native"; mappableTypes; appPriority = 250; globalPriority = 75; plan(apps:runAs:) -> [String: ToolMapping]; current(in: [KVNode]) -> [String: ToolMapping]; merged(_: [KVNode], with:) -> [KVNode] }`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import MacNeutronCore

private func app(_ id: UInt32, _ oslist: Set<String>, type: String = "game") -> AppInfo {
    AppInfo(appID: id, name: "App \(id)", type: type, oslist: oslist)
}

@Test(arguments: [
    (Set(["macos"]), "macneutron-native"),
    (Set(["windows"]), "macneutron"),
    (Set(["windows", "macos"]), "macneutron-native"),
    (Set(["macos", "linux"]), "macneutron-native"),
    (Set(["windows", "linux"]), "macneutron"),
    (Set(["windows", "macos", "linux"]), "macneutron-native"),
])
func routesByPlatform(oslist: Set<String>, tool: String) {
    #expect(MappingPlanner.plan(apps: [app(10, oslist)], runAs: [:])["10"] == ToolMapping(tool: tool, priority: 250))
}

@Test func linuxOnlyAndToolsAreNotMapped() {
    let plan = MappingPlanner.plan(apps: [app(1, ["linux"]), app(2, ["windows"], type: "tool"), app(3, ["windows"], type: "dlc")],
                                   runAs: [:])
    #expect(plan.keys.sorted() == ["0"])
}

@Test func globalEntryAlwaysPointsAtTheRuntime() {
    #expect(MappingPlanner.plan(apps: [], runAs: [:])["0"] == ToolMapping(tool: "macneutron", priority: 75))
}

@Test func runAsWindowsOnlyAppliesToDualPlatformGames() {
    let plan = MappingPlanner.plan(apps: [app(1, ["windows", "macos"]), app(2, ["macos"])],
                                   runAs: [1: .windows, 2: .windows])
    #expect(plan["1"]?.tool == "macneutron")
    #expect(plan["2"]?.tool == "macneutron-native")
}

@Test func mergeKeepsOtherToolsAndReplacesOurs() throws {
    let existing = [
        KVNode.block("440", [.string("name", "proton_9"), .string("config", ""), .string("priority", "250")]),
        KVNode.block("99", [.string("name", "macneutron"), .string("config", ""), .string("priority", "250")]),
    ]
    let plan = ["0": ToolMapping(tool: "macneutron", priority: 75), "20": ToolMapping(tool: "macneutron-native", priority: 250)]
    let merged = MappingPlanner.merged(existing, with: plan)
    #expect(merged.map(\.key) == ["0", "20", "440"])
    #expect(MappingPlanner.current(in: merged) == plan)
    #expect(merged.node(at: ["440", "name"])?.stringValue == "proton_9")
}

@Test func planWinsOverAnotherToolForTheSameApp() {
    let existing = [KVNode.block("20", [.string("name", "proton_9"), .string("priority", "250")])]
    let merged = MappingPlanner.merged(existing, with: ["20": ToolMapping(tool: "macneutron", priority: 250)])
    #expect(merged.count == 1)
    #expect(merged.node(at: ["20", "name"])?.stringValue == "macneutron")
}
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `swift test 2>&1 | grep -m1 "error:"`
Expected: `cannot find 'MappingPlanner' in scope`

- [ ] **Step 3: Implement**

```swift
import Foundation

/// A `CompatToolMapping` entry in Steam's config.vdf.
public struct ToolMapping: Equatable, Sendable {
    public let tool: String
    public let priority: Int

    public init(tool: String, priority: Int) {
        self.tool = tool
        self.priority = priority
    }
}

/// Which build of a dual-platform game to run.
public enum RunAs: String, Codable, Sendable {
    case mac, windows
}

/// Decides which compatibility tool every app should use (spec §5).
public enum MappingPlanner {
    public static let runtimeTool = "macneutron"
    public static let nativeTool = "macneutron-native"
    /// Tools such as Steam Linux Runtime or Proton must never be mapped.
    public static let mappableTypes: Set<String> = ["game", "demo", "application"]
    /// Above Valve's automatic mappings (100), so explicit entries always win.
    public static let appPriority = 250
    public static let globalPriority = 75

    public static func plan(apps: [AppInfo], runAs: [UInt32: RunAs]) -> [String: ToolMapping] {
        var plan = ["0": ToolMapping(tool: runtimeTool, priority: globalPriority)]
        for app in apps where mappableTypes.contains(app.type) {
            let windows = app.oslist.contains("windows")
            let tool: String? = if app.oslist.contains("macos") {
                runAs[app.appID] == .windows && windows ? runtimeTool : nativeTool
            } else if windows {
                runtimeTool
            } else {
                nil
            }
            if let tool { plan[String(app.appID)] = ToolMapping(tool: tool, priority: appPriority) }
        }
        return plan
    }

    /// MacNeutron's entries in an existing `CompatToolMapping` block.
    public static func current(in mappingBlock: [KVNode]) -> [String: ToolMapping] {
        var result: [String: ToolMapping] = [:]
        for entry in mappingBlock {
            guard let tool = entry.children.node(at: ["name"])?.stringValue, isOurs(tool) else { continue }
            let priority = Int(entry.children.node(at: ["priority"])?.stringValue ?? "") ?? 0
            result[KeyValues.unescape(entry.key)] = ToolMapping(tool: tool, priority: priority)
        }
        return result
    }

    /// The new `CompatToolMapping` block: other tools' entries kept, ours replaced by `plan`,
    /// sorted by app ID for a stable file.
    public static func merged(_ mappingBlock: [KVNode], with plan: [String: ToolMapping]) -> [KVNode] {
        let others = mappingBlock.filter { entry in
            !isOurs(entry.children.node(at: ["name"])?.stringValue ?? "") && plan[KeyValues.unescape(entry.key)] == nil
        }
        let ours = plan.map { appID, mapping in
            KVNode.block(appID, [
                .string("name", mapping.tool),
                .string("config", ""),
                .string("priority", String(mapping.priority)),
            ])
        }
        return (others + ours).sorted { (UInt64(KeyValues.unescape($0.key)) ?? .max) < (UInt64(KeyValues.unescape($1.key)) ?? .max) }
    }

    static func isOurs(_ tool: String) -> Bool { tool.hasPrefix(runtimeTool) }
}
```

- [ ] **Step 4: Run them and confirm they pass**

Run: `swift test 2>&1 | tail -1`
Expected: `Test run with 85 tests in 0 suites passed`

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "feat: plan compatibility-tool mappings for every Steam app"
```

---

### Task 6: SteamLocation and SteamProcess

**Files:**
- Create: `Sources/MacNeutronCore/SteamLocation.swift`
- Test: `Tests/MacNeutronCoreTests/FakeSteam.swift`, `Tests/MacNeutronCoreTests/SteamLocationTests.swift`

**Interfaces:**
- Consumes: `KeyValues` (Task 3); `SystemProcessRunner` (runtime).
- Produces:
  - `enum MacNeutronPaths { root, tools, games, backups }`
  - `struct SteamLocation { root; bundleMacOS; bundleCompatTools; steamDevConfig; configVDF; compatLog; appInfo; isInstalled; libraries() -> [URL]; installedAppIDs() -> Set<UInt32> }`
  - `enum SteamPlayError { steamNotInstalled, steamRunning, quitTimedOut, configUnreadable(String), verificationFailed(String) }`
  - `protocol SteamControlling: Sendable { isRunning() -> Bool; quit(timeout: Duration) async throws; launch() throws }`
  - `struct SteamProcess: SteamControlling`
  - Test helpers `okSession`, `macModeSession`, `makeFakeSteam(config:) -> (SteamLocation, URL)`, `FakeSteam` (with `launchesWithDevConfig: [Bool]`).

- [ ] **Step 1: Write the test helpers and the failing test**

`Tests/MacNeutronCoreTests/FakeSteam.swift`:

```swift
import Foundation
@testable import MacNeutronCore

let okSession = """
    [2026-09-27 12:00:00] Client version: 1788652215
    [2026-09-27 12:00:00] Registering tool macneutron, AppID 0
    [2026-09-27 12:00:00] Registering tool macneutron-native, AppID 0
    [2026-09-27 12:00:01] Recording non-user mapping for 3064690 at priority 100 to tool proton-10

    """
let macModeSession = """
    [2026-09-27 12:00:00] Client version: 1788652215
    [2026-09-27 12:00:00] Registering tool macneutron, AppID 0
    [2026-09-27 12:00:00] Ignoring tool macneutron as it's for a different target platform linux.

    """

/// A Steam install in a temp folder: app bundle, config.vdf, and MacNeutron's runtime tool.
func makeFakeSteam(config: String = steamConfigFixture) throws -> (SteamLocation, URL) {
    let base = try makeTempDir()
    let steam = SteamLocation(root: base.appending(path: "Steam", directoryHint: .isDirectory))
    try FileManager.default.createDirectory(at: steam.bundleMacOS, withIntermediateDirectories: true)
    try write(config, to: steam.configVDF)
    let root = base.appending(path: "MacNeutron", directoryHint: .isDirectory)
    try write("\"manifest\" {}", to: root.appending(path: "compatibilitytools.d/macneutron/toolmanifest.vdf"))
    return (steam, root)
}

/// Stands in for the Steam client: launching appends `session` to compat_log.txt.
final class FakeSteam: SteamControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var running: Bool
    private var devConfigAtLaunch: [Bool] = []
    let steam: SteamLocation
    let session: String

    init(steam: SteamLocation, running: Bool = false, session: String = okSession) {
        self.steam = steam
        self.running = running
        self.session = session
    }

    var launchesWithDevConfig: [Bool] { lock.withLock { devConfigAtLaunch } }

    func isRunning() -> Bool { lock.withLock { running } }

    func quit(timeout: Duration) async throws { lock.withLock { running = false } }

    func launch() throws {
        let hasDevConfig = FileManager.default.fileExists(atPath: steam.steamDevConfig.path(percentEncoded: false))
        lock.withLock {
            running = true
            devConfigAtLaunch.append(hasDevConfig)
        }
        let old = (try? String(contentsOf: steam.compatLog, encoding: .utf8)) ?? ""
        try write(old + session, to: steam.compatLog)
    }
}
```

`Tests/MacNeutronCoreTests/SteamLocationTests.swift`:

```swift
import Foundation
import Testing
@testable import MacNeutronCore

@Test func findsLibrariesAndInstalledApps() throws {
    let (steam, _) = try makeFakeSteam()
    let extra = try makeTempDir().appending(path: "Games Drive", directoryHint: .isDirectory)
    try write("""
        "libraryfolders"
        {
        \t"0"
        {
        \t\t"path"\t\t"\(steam.root.path(percentEncoded: false))"
        \t}
        \t"1"
        \t{
        \t\t"path"\t\t"\(extra.path(percentEncoded: false))"
        \t}
        }
        """, to: steam.root.appending(path: "steamapps/libraryfolders.vdf"))
    try write("", to: steam.root.appending(path: "steamapps/appmanifest_1062090.acf"))
    try write("", to: extra.appending(path: "steamapps/appmanifest_2977660.acf"))
    #expect(steam.libraries().count == 2)
    #expect(steam.installedAppIDs() == [1062090, 2977660])
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `swift test 2>&1 | grep -m1 "error:"`
Expected: `cannot find type 'SteamLocation' in scope`

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Where MacNeutron keeps its own files.
public enum MacNeutronPaths {
    public static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/MacNeutron", directoryHint: .isDirectory)
    }
    public static var tools: URL { root.appending(path: "compatibilitytools.d", directoryHint: .isDirectory) }
    public static var games: URL { root.appending(path: "games", directoryHint: .isDirectory) }
    public static var backups: URL { root.appending(path: "backups", directoryHint: .isDirectory) }
}

/// Paths inside the native macOS Steam installation.
public struct SteamLocation: Equatable, Sendable {
    public let root: URL

    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Steam", directoryHint: .isDirectory)) {
        self.root = root
    }

    public var bundleMacOS: URL { root.appending(path: "Steam.AppBundle/Steam/Contents/MacOS", directoryHint: .isDirectory) }
    public var bundleCompatTools: URL { bundleMacOS.appending(path: "compatibilitytools.d", directoryHint: .isDirectory) }
    public var steamDevConfig: URL { bundleMacOS.appending(path: "steam_dev.cfg") }
    public var configVDF: URL { root.appending(path: "config/config.vdf") }
    public var compatLog: URL { root.appending(path: "logs/compat_log.txt") }
    public var appInfo: URL { root.appending(path: "appcache/appinfo.vdf") }

    public var isInstalled: Bool { FileManager.default.fileExists(atPath: bundleMacOS.path(percentEncoded: false)) }

    /// Every library's `steamapps` folder, the Steam root's own first, from `libraryfolders.vdf`.
    public func libraries() -> [URL] {
        let own = root.appending(path: "steamapps", directoryHint: .isDirectory)
        var result = [own]
        let file = own.appending(path: "libraryfolders.vdf")
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let nodes = try? KeyValues.parse(text) else { return result }
        for entry in nodes.node(at: ["libraryfolders"])?.children ?? [] {
            guard let path = entry.children.node(at: ["path"])?.stringValue else { continue }
            let steamapps = URL(filePath: path, directoryHint: .isDirectory).appending(path: "steamapps", directoryHint: .isDirectory)
            if !result.contains(where: { Self.samePath($0, steamapps) }) { result.append(steamapps) }
        }
        return result
    }

    /// App IDs with an `appmanifest_<id>.acf` in any library.
    public func installedAppIDs() -> Set<UInt32> {
        var ids = Set<UInt32>()
        for library in libraries() {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: library.path(percentEncoded: false))) ?? []
            for name in names where name.hasPrefix("appmanifest_") && name.hasSuffix(".acf") {
                if let id = UInt32(name.dropFirst("appmanifest_".count).dropLast(".acf".count)) { ids.insert(id) }
            }
        }
        return ids
    }

    static func samePath(_ a: URL, _ b: URL) -> Bool {
        func normal(_ url: URL) -> String {
            var path = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return path
        }
        return normal(a) == normal(b)
    }
}

public enum SteamPlayError: Error, Equatable, CustomStringConvertible {
    case steamNotInstalled
    case steamRunning
    case quitTimedOut
    case configUnreadable(String)
    case verificationFailed(String)

    public var description: String {
        switch self {
        case .steamNotInstalled: "Steam isn't installed in ~/Library/Application Support/Steam."
        case .steamRunning: "Steam is running. Quit Steam to apply changes."
        case .quitTimedOut: "Steam didn't quit within 30 seconds. Quit it yourself, then try again."
        case .configUnreadable(let detail): "Steam's settings file couldn't be read, so MacNeutron didn't change it (\(detail))."
        case .verificationFailed(let problem): "Steam Play mode didn't start correctly, so it was turned off again: \(problem)"
        }
    }
}

/// Starting and stopping Steam. A protocol so tests never touch the real client.
public protocol SteamControlling: Sendable {
    func isRunning() -> Bool
    func quit(timeout: Duration) async throws
    func launch() throws
}

public struct SteamProcess: SteamControlling {
    public init() {}

    public func isRunning() -> Bool {
        (try? SystemProcessRunner().run(URL(filePath: "/usr/bin/pgrep"), ["-x", "steam_osx"],
                                        environment: [:], output: URL(filePath: "/dev/null"))) == 0
    }

    /// Asks Steam to exit through its own URL handler, then waits for the process to go away.
    public func quit(timeout: Duration) async throws {
        guard isRunning() else { return }
        _ = try SystemProcessRunner().run(URL(filePath: "/usr/bin/open"), ["steam://exit"],
                                          environment: ProcessInfo.processInfo.environment, output: nil)
        let deadline = ContinuousClock.now + timeout
        while isRunning() {
            guard ContinuousClock.now < deadline else { throw SteamPlayError.quitTimedOut }
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    public func launch() throws {
        _ = try SystemProcessRunner().run(URL(filePath: "/usr/bin/open"), ["-a", "Steam"],
                                          environment: ProcessInfo.processInfo.environment, output: nil)
    }
}
```

- [ ] **Step 4: Run it and confirm it passes**

Run: `swift test 2>&1 | tail -1`
Expected: `Test run with 86 tests in 0 suites passed`

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "feat: locate Steam's files and libraries; quit and launch Steam"
```

---

### Task 7: SteamPlayMode

> Requires Task 1's decision **B confirmed**.

**Files:**
- Create: `Sources/MacNeutronCore/SteamPlayMode.swift`
- Test: `Tests/MacNeutronCoreTests/SteamPlayModeTests.swift`

**Interfaces:**
- Consumes: `SteamLocation`, `SteamControlling`, `SteamPlayError`, `MacNeutronPaths` (Task 6); `MappingPlanner`, `ToolMapping` (Task 5); `KeyValues` (Task 3).
- Produces:
  - `enum SteamPlayStatus { off, on, restartNeeded(Int), lost }`
  - `struct SteamPlayMode { init(steam:root:process:); steam; tools; backups; intentFile; process; verifyTimeout; quitTimeout; isWanted; filesIntact; status(plan:) -> SteamPlayStatus; enable(plan:) async throws; disable() async throws; sync(plan:) throws -> Bool; pendingChanges(plan:) throws -> Int; currentMappings() throws -> [String: ToolMapping]; applyMappings(_:) throws; static verify(log:) -> String?; static lastSession(of:) -> String }`
  - Test helpers `makeMode(session:config:running:)`, `samplePlan`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import MacNeutronCore

func makeMode(session: String = okSession, config: String = steamConfigFixture,
              running: Bool = false) throws -> (SteamPlayMode, FakeSteam) {
    let (steam, root) = try makeFakeSteam(config: config)
    let fake = FakeSteam(steam: steam, running: running, session: session)
    var mode = SteamPlayMode(steam: steam, root: root, process: fake)
    mode.verifyTimeout = .seconds(2)
    return (mode, fake)
}

let samplePlan = [
    "0": ToolMapping(tool: "macneutron", priority: 75),
    "1062090": ToolMapping(tool: "macneutron-native", priority: 250),
    "2977660": ToolMapping(tool: "macneutron", priority: 250),
]

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

@Test func enableWritesEverythingAndVerifies() async throws {
    let (mode, fake) = try makeMode()
    try await mode.enable(plan: samplePlan)
    #expect(mode.isWanted)
    #expect(mode.filesIntact)
    #expect(try mode.currentMappings() == samplePlan)
    #expect(fake.launchesWithDevConfig == [true])
    #expect(mode.status(plan: samplePlan) == .on)
    #expect(try String(contentsOf: mode.steam.steamDevConfig, encoding: .utf8) == "@sSteamCmdForcePlatformType linux\n")
}

@Test func failedVerificationRollsBackWithDevConfigRemovedFirst() async throws {
    let (mode, fake) = try makeMode(session: macModeSession)
    let original = try String(contentsOf: mode.steam.configVDF, encoding: .utf8)
    await #expect(throws: SteamPlayError.verificationFailed("Steam started as a Mac client and ignored MacNeutron")) {
        try await mode.enable(plan: samplePlan)
    }
    #expect(!exists(mode.steam.steamDevConfig))
    #expect(!exists(mode.link("macneutron")))
    #expect(try String(contentsOf: mode.steam.configVDF, encoding: .utf8) == original)
    #expect(!mode.isWanted)
    #expect(fake.launchesWithDevConfig == [true, false])
}

@Test func unreadableConfigChangesNothing() async throws {
    let (mode, fake) = try makeMode(config: "\"InstallConfigStore\"\n{\n")
    await #expect(throws: SteamPlayError.self) { try await mode.enable(plan: samplePlan) }
    #expect(!exists(mode.steam.steamDevConfig))
    #expect(!exists(mode.link("macneutron")))
    #expect(fake.launchesWithDevConfig.isEmpty)
}

@Test func mappingsAreNeverWrittenWhileSteamRuns() throws {
    let (mode, _) = try makeMode(running: true)
    #expect(throws: SteamPlayError.steamRunning) { try mode.applyMappings(samplePlan) }
}

@Test func everyWriteIsBackedUpFirst() throws {
    let (mode, _) = try makeMode()
    let original = try Data(contentsOf: mode.steam.configVDF)
    try mode.applyMappings(samplePlan)
    let backups = try FileManager.default.contentsOfDirectory(at: mode.backups, includingPropertiesForKeys: nil)
    #expect(backups.count == 1)
    #expect(try Data(contentsOf: backups[0]) == original)
    #expect(try String(contentsOf: mode.steam.configVDF, encoding: .utf8).contains("\"proton_9\""))
}

@Test func syncOnlyWritesWhenThePlanChanged() async throws {
    let (mode, fake) = try makeMode()
    try await mode.enable(plan: samplePlan)
    try await fake.quit(timeout: .seconds(1))
    #expect(try mode.sync(plan: samplePlan) == false)
    var newPlan = samplePlan
    newPlan["3419430"] = ToolMapping(tool: "macneutron-native", priority: 250)
    #expect(try mode.sync(plan: newPlan) == true)
    #expect(try mode.currentMappings() == newPlan)
}

@Test func statusShowsPendingChangesAndLostFiles() async throws {
    let (mode, _) = try makeMode()
    #expect(mode.status(plan: samplePlan) == .off)
    try await mode.enable(plan: samplePlan)
    var newPlan = samplePlan
    newPlan["1"] = ToolMapping(tool: "macneutron", priority: 250)
    newPlan["2977660"] = nil
    #expect(mode.status(plan: newPlan) == .restartNeeded(2))
    try FileManager.default.removeItem(at: mode.steam.steamDevConfig)  // what a Steam update does
    #expect(mode.status(plan: samplePlan) == .lost)
}

@Test func disableRemovesOnlyWhatEnableAdded() async throws {
    let (mode, fake) = try makeMode()
    try await mode.enable(plan: samplePlan)
    try await mode.disable()
    #expect(!exists(mode.steam.steamDevConfig))
    #expect(!exists(mode.link("macneutron-native")))
    #expect(try mode.currentMappings().isEmpty)
    #expect(try String(contentsOf: mode.steam.configVDF, encoding: .utf8).contains("\"proton_9\""))
    #expect(!mode.isWanted)
    #expect(fake.launchesWithDevConfig == [true, false])
}

@Test func passthroughRunsTheMacGameItself() async throws {
    let (mode, _) = try makeMode()
    try await mode.enable(plan: samplePlan)
    let out = try makeTempDir().appending(path: "out.txt")
    let status = try SystemProcessRunner().run(mode.link("macneutron-native").appending(path: "passthrough.sh"),
                                               ["waitforexitandrun", "/bin/echo", "a b"], environment: [:], output: out)
    #expect(status == 0)
    #expect(try String(contentsOf: out, encoding: .utf8) == "a b\n")
}

@Test(arguments: [
    (okSession, nil),
    (macModeSession, "Steam started as a Mac client and ignored MacNeutron"),
    ("Client version: 1\nRegistering tool macneutron, AppID 0\nRecording non-user mapping", "Steam didn't find MacNeutron's tools"),
    ("Client version: 1\nRegistering tool macneutron, AppID 0\nRegistering tool macneutron-native, AppID 0\n",
     "Steam didn't switch to Steam Play mode"),
] as [(String, String?)])
func verifiesCompatLogSessions(log: String, problem: String?) {
    #expect(SteamPlayMode.verify(log: log) == problem)
}

@Test func lastSessionIgnoresEarlierRuns() {
    #expect(SteamPlayMode.verify(log: SteamPlayMode.lastSession(of: macModeSession + okSession)) == nil)
    #expect(SteamPlayMode.verify(log: SteamPlayMode.lastSession(of: okSession + macModeSession)) != nil)
}
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `swift test 2>&1 | grep -m1 "error:"`
Expected: `cannot find type 'SteamPlayMode' in scope`

- [ ] **Step 3: Implement**

```swift
import Foundation

public enum SteamPlayStatus: Equatable, Sendable {
    case off
    case on
    case restartNeeded(Int)
    case lost
}

/// Turns Steam Play mode on and off and keeps Steam's mappings current (spec §4).
/// Invariant: `steam_dev.cfg` never exists unless both tools resolve through Steam's bundle and every
/// Mac game is mapped. Writes happen in the order that keeps it true even when interrupted.
public struct SteamPlayMode: Sendable {
    public static let runtimeToolName = MappingPlanner.runtimeTool
    public static let nativeToolName = MappingPlanner.nativeTool
    public static let devConfig = "@sSteamCmdForcePlatformType linux\n"

    public let steam: SteamLocation
    public let tools: URL
    public let backups: URL
    public let intentFile: URL
    public let process: any SteamControlling
    public var verifyTimeout: Duration = .seconds(60)
    public var quitTimeout: Duration = .seconds(30)

    public init(steam: SteamLocation = SteamLocation(), root: URL = MacNeutronPaths.root,
                process: any SteamControlling = SteamProcess()) {
        self.steam = steam
        self.tools = root.appending(path: "compatibilitytools.d", directoryHint: .isDirectory)
        self.backups = root.appending(path: "backups", directoryHint: .isDirectory)
        self.intentFile = root.appending(path: "steam-play-enabled")
        self.process = process
    }

    var runtimeTool: URL { tools.appending(path: Self.runtimeToolName, directoryHint: .isDirectory) }
    var nativeTool: URL { tools.appending(path: Self.nativeToolName, directoryHint: .isDirectory) }
    func link(_ name: String) -> URL { steam.bundleCompatTools.appending(path: name) }

    /// The user turned Steam Play mode on and hasn't turned it off.
    public var isWanted: Bool { exists(intentFile) }

    /// Everything `enable` writes is still in place (a Steam update can wipe its bundle).
    public var filesIntact: Bool {
        exists(steam.steamDevConfig)
            && exists(link(Self.runtimeToolName).appending(path: "toolmanifest.vdf"))
            && exists(link(Self.nativeToolName).appending(path: "toolmanifest.vdf"))
    }

    public func status(plan: [String: ToolMapping]) -> SteamPlayStatus {
        guard isWanted else { return .off }
        guard filesIntact else { return .lost }
        if process.isRunning(), let log = try? String(contentsOf: steam.compatLog, encoding: .utf8),
           Self.verify(log: Self.lastSession(of: log)) != nil {
            return .lost
        }
        let pending = (try? pendingChanges(plan: plan)) ?? 0
        return pending > 0 ? .restartNeeded(pending) : .on
    }

    // MARK: Flows

    public func enable(plan: [String: ToolMapping]) async throws {
        guard steam.isInstalled else { throw SteamPlayError.steamNotInstalled }
        try await process.quit(timeout: quitTimeout)
        _ = try readConfig()
        let backup = try backupConfig()
        do {
            try installNativeTool()
            try linkTools()
            try applyMappings(plan)
            try write(Self.devConfig, to: steam.steamDevConfig)  // last
        } catch {
            try? FileManager.default.removeItem(at: steam.steamDevConfig)
            unlinkTools()
            throw error
        }
        let logStart = size(of: steam.compatLog)
        try process.launch()
        if let problem = await waitForVerification(since: logStart) {
            await rollBack(restoring: backup)
            throw SteamPlayError.verificationFailed(problem)
        }
        try write("", to: intentFile)
    }

    public func disable() async throws {
        try await process.quit(timeout: quitTimeout)
        try? FileManager.default.removeItem(at: steam.steamDevConfig)  // first
        unlinkTools()
        try applyMappings([:])
        try? FileManager.default.removeItem(at: intentFile)
        try process.launch()
    }

    /// Brings `config.vdf` up to date with `plan`. Call only while Steam is closed.
    @discardableResult
    public func sync(plan: [String: ToolMapping]) throws -> Bool {
        guard isWanted, filesIntact, try pendingChanges(plan: plan) > 0 else { return false }
        try applyMappings(plan)
        return true
    }

    // MARK: Building blocks

    public func pendingChanges(plan: [String: ToolMapping]) throws -> Int {
        let current = try currentMappings()
        let keys = Set(current.keys).union(plan.keys)
        return keys.filter { current[$0] != plan[$0] }.count
    }

    public func currentMappings() throws -> [String: ToolMapping] {
        MappingPlanner.current(in: try readConfig().node(at: Self.mappingPath)?.children ?? [])
    }

    static let mappingPath = ["InstallConfigStore", "Software", "Valve", "Steam", "CompatToolMapping"]

    /// Replaces MacNeutron's entries in `CompatToolMapping` with `plan`: backup, edit, re-parse check, atomic write.
    public func applyMappings(_ plan: [String: ToolMapping]) throws {
        guard !process.isRunning() else { throw SteamPlayError.steamRunning }
        var nodes = try readConfig()
        let existing = nodes.node(at: Self.mappingPath)?.children ?? []
        nodes.setBlock(at: Self.mappingPath, children: MappingPlanner.merged(existing, with: plan))
        let text = KeyValues.serialize(nodes)
        guard let check = try? KeyValues.parse(text), check == nodes else {
            throw SteamPlayError.configUnreadable("the edited file didn't read back identically")
        }
        _ = try backupConfig()
        try write(text, to: steam.configVDF)
    }

    func readConfig() throws -> [KVNode] {
        guard exists(steam.configVDF) else { return [] }
        do {
            return try KeyValues.parse(try String(contentsOf: steam.configVDF, encoding: .utf8))
        } catch {
            throw SteamPlayError.configUnreadable("\(error)")
        }
    }

    /// Copies `config.vdf` to `backups/config-<timestamp>.vdf`, keeping the newest 10.
    @discardableResult
    func backupConfig() throws -> URL? {
        guard exists(steam.configVDF) else { return nil }
        let fm = FileManager.default
        try fm.createDirectory(at: backups, withIntermediateDirectories: true)
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))
            .replacingOccurrences(of: ":", with: "-")
        let backup = backups.appending(path: "config-\(stamp).vdf")
        try fm.copyItem(at: steam.configVDF, to: backup)
        let all = (try? fm.contentsOfDirectory(atPath: backups.path(percentEncoded: false)))?
            .filter { $0.hasPrefix("config-") }.sorted() ?? []
        for old in all.dropLast(10) { try? fm.removeItem(at: backups.appending(path: old)) }
        return backup
    }

    func installNativeTool() throws {
        try write("""
            "compatibilitytools"
            {
              "compat_tools"
              {
                "\(Self.nativeToolName)"
                {
                  "install_path" "."
                  "display_name" "macOS native"
                  "from_oslist"  "macos"
                  "to_oslist"    "linux"
                }
              }
            }

            """, to: nativeTool.appending(path: "compatibilitytool.vdf"))
        try write("\"manifest\"\n{\n  \"version\" \"2\"\n  \"commandline\" \"/passthrough.sh %verb%\"\n}\n",
                  to: nativeTool.appending(path: "toolmanifest.vdf"))
        let script = nativeTool.appending(path: "passthrough.sh")
        // Steam passes "<verb> <command…>"; run the Mac game itself, keeping this PID for Steam's tracking.
        try write("#!/bin/sh\nshift\nexec \"$@\"\n", to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path(percentEncoded: false))
    }

    func linkTools() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: steam.bundleCompatTools, withIntermediateDirectories: true)
        for (name, target) in [(Self.runtimeToolName, runtimeTool), (Self.nativeToolName, nativeTool)] {
            let url = link(name)
            try? fm.removeItem(at: url)
            try fm.createSymbolicLink(at: url, withDestinationURL: target)
        }
    }

    func unlinkTools() {
        for name in [Self.runtimeToolName, Self.nativeToolName] { try? FileManager.default.removeItem(at: link(name)) }
    }

    private func rollBack(restoring backup: URL?) async {
        try? FileManager.default.removeItem(at: steam.steamDevConfig)  // first
        try? await process.quit(timeout: quitTimeout)
        unlinkTools()
        if let backup {
            try? FileManager.default.removeItem(at: steam.configVDF)
            try? FileManager.default.copyItem(at: backup, to: steam.configVDF)
        }
        try? process.launch()
    }

    private func waitForVerification(since offset: Int) async -> String? {
        let deadline = ContinuousClock.now + verifyTimeout
        var problem: String? = "Steam didn't write its compatibility log"
        repeat {
            if let data = try? Data(contentsOf: steam.compatLog), data.count > offset {
                problem = Self.verify(log: String(decoding: data.dropFirst(offset), as: UTF8.self))
                if problem == nil { return nil }
            }
            try? await Task.sleep(for: .seconds(1))
        } while ContinuousClock.now < deadline
        return problem
    }

    /// nil when a Steam session's compat log shows both tools registered in Linux mode; otherwise the problem.
    static func verify(log: String) -> String? {
        if log.contains("Ignoring tool \(runtimeToolName)") {
            return "Steam started as a Mac client and ignored MacNeutron"
        }
        guard log.contains("Registering tool \(runtimeToolName),"), log.contains("Registering tool \(nativeToolName),") else {
            return "Steam didn't find MacNeutron's tools"
        }
        guard log.contains("Recording non-user mapping") else {
            return "Steam didn't switch to Steam Play mode"
        }
        return nil
    }

    /// The text from the last "Client version:" line on: the current Steam session.
    static func lastSession(of log: String) -> String {
        guard let range = log.range(of: "Client version:", options: .backwards) else { return log }
        return String(log[range.lowerBound...])
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    private func size(of url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.size] as? NSNumber)?.intValue ?? 0
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
```

- [ ] **Step 4: Run them and confirm they pass**

Run: `swift test 2>&1 | tail -1`
Expected: `Test run with 97 tests in 0 suites passed`. The suite takes about 2 s now, because the rollback test waits out its verification timeout.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "feat: turn Steam Play mode on and off safely and keep mappings current"
```

---

### Task 8: SteamWatcher

**Files:**
- Create: `Sources/MacNeutronCore/SteamWatcher.swift`
- Test: `Tests/MacNeutronCoreTests/SteamWatcherTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `struct SteamWatcher { enum Event { launched, quit }; mutating func observe(running: Bool) -> Event? }`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import MacNeutronCore

@Test func reportsOnlyTransitions() {
    var watcher = SteamWatcher()
    #expect(watcher.observe(running: true) == nil)
    #expect(watcher.observe(running: true) == nil)
    #expect(watcher.observe(running: false) == .quit)
    #expect(watcher.observe(running: false) == nil)
    #expect(watcher.observe(running: true) == .launched)
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `swift test 2>&1 | grep -m1 "error:"`
Expected: `cannot find 'SteamWatcher' in scope`

- [ ] **Step 3: Implement**

```swift
/// Turns periodic "is Steam running?" checks into launch and quit events.
public struct SteamWatcher: Sendable {
    public enum Event: Equatable, Sendable { case launched, quit }

    private var wasRunning: Bool?

    public init() {}

    /// The first observation only records the state; later ones report changes.
    public mutating func observe(running: Bool) -> Event? {
        defer { wasRunning = running }
        guard let wasRunning, wasRunning != running else { return nil }
        return running ? .launched : .quit
    }
}
```

- [ ] **Step 4: Run it and confirm it passes**

Run: `swift test 2>&1 | tail -1`
Expected: `Test run with 98 tests in 0 suites passed`

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "feat: turn Steam running checks into launch and quit events"
```

---

### Task 9: Per-game settings and the launcher hook

**Files:**
- Create: `Sources/MacNeutronCore/GameSettings.swift`
- Modify: `Sources/MacNeutronCore/Launcher.swift` (init and the start of `launch`)
- Test: `Tests/MacNeutronCoreTests/GameSettingsTests.swift`; modify `Tests/MacNeutronCoreTests/LauncherTests.swift`

**Interfaces:**
- Consumes: `RunAs` (Task 5); `MacNeutronPaths.games` (Task 6); `Launcher`, `LauncherLog` (runtime).
- Produces:
  - `struct GameSettings: Codable { graphics: String?; log: Bool?; avx: Bool?; msync: Bool?; runAs: RunAs?; var environment: [String: String] }`
  - `struct GameSettingsStore { directory; load(_:) throws -> GameSettings; save(_:for:) throws; all() -> [String: GameSettings]; runAsOverrides() -> [UInt32: RunAs] }`
  - `Launcher.settings: GameSettingsStore` (a new init parameter, defaulted).

- [ ] **Step 1: Write the failing tests**

`Tests/MacNeutronCoreTests/GameSettingsTests.swift`:

```swift
import Foundation
import Testing
@testable import MacNeutronCore

@Test func settingsBecomeLaunchVariables() {
    #expect(GameSettings(graphics: "dxmt", log: true, avx: false, msync: false, runAs: .windows).environment == [
        "MACNEUTRON_GRAPHICS": "dxmt", "MACNEUTRON_LOG": "1", "MACNEUTRON_NO_AVX": "1", "MACNEUTRON_NO_MSYNC": "1",
    ])
    #expect(GameSettings(log: false, avx: true, msync: true).environment.isEmpty)
}

@Test func storeRoundTripsAndDefaultsWhenMissing() throws {
    let store = GameSettingsStore(directory: try makeTempDir().appending(path: "games"))
    #expect(try store.load("7") == GameSettings())
    try store.save(GameSettings(graphics: "d3dmetal", runAs: .windows), for: "7")
    #expect(try store.load("7") == GameSettings(graphics: "d3dmetal", runAs: .windows))
    #expect(store.runAsOverrides() == [7: .windows])
}

@Test func corruptFilesThrowAndAreSkippedByAll() throws {
    let store = GameSettingsStore(directory: try makeTempDir())
    try write("{", to: store.directory.appending(path: "8.json"))
    #expect(throws: (any Error).self) { try store.load("8") }
    #expect(store.all().isEmpty)
}
```

In `Tests/MacNeutronCoreTests/LauncherTests.swift`, inside `makeFixture`, replace the `Launcher(...)` construction with:

```swift
    let launcher = Launcher(layout: try makeToolLayout(), runner: runner,
                            log: LauncherLog(directory: try makeTempDir().appending(path: "Logs")),
                            notifier: notifier, preflight: Preflight(rosettaAvailable: { rosetta }),
                            settings: GameSettingsStore(directory: try makeTempDir().appending(path: "games")))
```

and append at the end of the file:

```swift
@Test func gameSettingsApplyUnderneathLaunchOptions() throws {
    let f = try makeFixture()
    try f.launcher.settings.save(GameSettings(graphics: "dxvk", log: true, msync: false), for: "42")
    var env = f.env
    env["MACNEUTRON_GRAPHICS"] = "dxmt"  // typed into Steam's launch options: wins
    _ = f.launcher.launch(["run", "/g/Game.exe"], environment: env)
    let wine = try #require(f.runner.calls.last?.environment)
    #expect(wine["WINEDLLOVERRIDES"]?.hasPrefix("dxgi=n,b;d3d10core=n,b;d3d11=n,b") == true)  // dxmt
    #expect(wine["WINEDEBUG"] == "+err,+warn,+loaddll")
    #expect(wine["WINEMSYNC"] == nil)
}

@Test func unreadableGameSettingsAreIgnored() throws {
    let f = try makeFixture()
    try write("{ not json", to: f.launcher.settings.directory.appending(path: "42.json"))
    #expect(f.launcher.launch(["run", "/g/Game.exe"], environment: f.env) == 0)
    #expect(try String(contentsOf: f.launcher.log.launcherLog, encoding: .utf8).contains("ignoring unreadable game settings for 42"))
}
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `swift test 2>&1 | grep -m1 "error:"`
Expected: `cannot find 'GameSettingsStore' in scope`

- [ ] **Step 3: Implement**

`Sources/MacNeutronCore/GameSettings.swift`:

```swift
import Foundation

/// Per-game choices from the app's games window. Every field is optional; nil means default.
public struct GameSettings: Codable, Equatable, Sendable {
    public var graphics: String?
    public var log: Bool?
    public var avx: Bool?
    public var msync: Bool?
    public var runAs: RunAs?

    public init(graphics: String? = nil, log: Bool? = nil, avx: Bool? = nil, msync: Bool? = nil, runAs: RunAs? = nil) {
        self.graphics = graphics
        self.log = log
        self.avx = avx
        self.msync = msync
        self.runAs = runAs
    }

    /// The launch-option variables these settings stand for (`runAs` is for the mapping planner only).
    public var environment: [String: String] {
        var env: [String: String] = [:]
        if let graphics { env["MACNEUTRON_GRAPHICS"] = graphics }
        if log == true { env["MACNEUTRON_LOG"] = "1" }
        if avx == false { env["MACNEUTRON_NO_AVX"] = "1" }
        if msync == false { env["MACNEUTRON_NO_MSYNC"] = "1" }
        return env
    }
}

/// `games/<appid>.json`, written atomically so the launcher never reads half a file.
public struct GameSettingsStore: Sendable {
    public let directory: URL

    public init(directory: URL = MacNeutronPaths.games) { self.directory = directory }

    func file(_ appID: String) -> URL { directory.appending(path: "\(appID).json") }

    /// Missing file → defaults. A file that exists but can't be decoded throws.
    public func load(_ appID: String) throws -> GameSettings {
        let url = file(appID)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return GameSettings() }
        return try JSONDecoder().decode(GameSettings.self, from: Data(contentsOf: url))
    }

    public func save(_ settings: GameSettings, for appID: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(settings).write(to: file(appID), options: .atomic)
    }

    /// Every readable settings file, keyed by app ID.
    public func all() -> [String: GameSettings] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        var result: [String: GameSettings] = [:]
        for name in names where name.hasSuffix(".json") {
            let appID = String(name.dropLast(".json".count))
            if let settings = try? load(appID) { result[appID] = settings }
        }
        return result
    }

    /// `runAs` choices for the mapping planner.
    public func runAsOverrides() -> [UInt32: RunAs] {
        var result: [UInt32: RunAs] = [:]
        for (appID, settings) in all() {
            if let id = UInt32(appID), let runAs = settings.runAs { result[id] = runAs }
        }
        return result
    }
}
```

In `Sources/MacNeutronCore/Launcher.swift`:

1. Replace the stored properties' tail and the initializer with:

```swift
    public let preflight: Preflight
    public let settings: GameSettingsStore

    public init(layout: ToolLayout, runner: any ProcessRunner = SystemProcessRunner(), log: LauncherLog = .standard,
                notifier: any Notifier = AppleScriptNotifier(), preflight: Preflight = Preflight(),
                settings: GameSettingsStore = GameSettingsStore()) {
        self.layout = layout
        self.runner = runner
        self.log = log
        self.notifier = notifier
        self.preflight = preflight
        self.settings = settings
    }
```

2. Change the signature line of `launch` and add the first statement:

```swift
    public func launch(_ argv: [String], environment steamEnvironment: [String: String]) -> Int32 {
        var environment = steamEnvironment
        let request: LaunchRequest
```

3. Immediately before `do { try preflight.check(layout) } catch {`, insert:

```swift
        do {
            // Per-game settings from the app sit underneath; variables from Steam launch options win.
            environment = try settings.load(context.appID).environment.merging(environment) { _, launchOption in launchOption }
        } catch {
            log.append("note: ignoring unreadable game settings for \(context.appID): \(error)")
        }
```

- [ ] **Step 4: Run them and confirm they pass**

Run: `swift test 2>&1 | tail -1`
Expected: `Test run with 103 tests in 0 suites passed`

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "feat: per-game settings the launcher applies under launch options"
```

---

### Task 10: OrphanPrefixes

**Files:**
- Create: `Sources/MacNeutronCore/OrphanPrefixes.swift`
- Test: `Tests/MacNeutronCoreTests/OrphanPrefixesTests.swift`

**Interfaces:**
- Consumes: `SteamLocation.libraries()` and `installedAppIDs()` (Task 6); `makeFakeSteam` (Task 6 tests).
- Produces: `struct OrphanPrefix { appID: String; url: URL; bytes: Int64 }`; `enum OrphanPrefixes { find(in:) -> [OrphanPrefix]; delete(_:) throws }`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import MacNeutronCore

@Test func listsOnlyPrefixesOfUninstalledGames() throws {
    let (steam, _) = try makeFakeSteam()
    let compatdata = steam.root.appending(path: "steamapps/compatdata")
    try write("installed", to: compatdata.appending(path: "1062090/pfx/system.reg"))
    try write("appmanifest", to: steam.root.appending(path: "steamapps/appmanifest_1062090.acf"))
    try write(String(repeating: "x", count: 10_000), to: compatdata.appending(path: "2977660/pfx/drive_c/big.bin"))
    try write("shared", to: compatdata.appending(path: "0/pfx/x"))
    let orphans = OrphanPrefixes.find(in: steam)
    #expect(orphans.map(\.appID) == ["2977660"])
    #expect(orphans[0].bytes >= 10_000)
    try OrphanPrefixes.delete(orphans)
    #expect(OrphanPrefixes.find(in: steam).isEmpty)
    #expect(FileManager.default.fileExists(atPath: compatdata.appending(path: "1062090").path(percentEncoded: false)))
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `swift test 2>&1 | grep -m1 "error:"`
Expected: `cannot find 'OrphanPrefixes' in scope`

- [ ] **Step 3: Implement**

```swift
import Foundation

/// A game's Wine prefix left behind after the game was uninstalled (Steam doesn't delete it on macOS).
public struct OrphanPrefix: Equatable, Sendable {
    public let appID: String
    public let url: URL
    public let bytes: Int64
}

public enum OrphanPrefixes {
    public static func find(in steam: SteamLocation) -> [OrphanPrefix] {
        let installed = steam.installedAppIDs()
        var result: [OrphanPrefix] = []
        for library in steam.libraries() {
            let compatdata = library.appending(path: "compatdata", directoryHint: .isDirectory)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: compatdata.path(percentEncoded: false))) ?? []
            for name in names.sorted() {
                guard let id = UInt32(name), id != 0, !installed.contains(id) else { continue }
                let url = compatdata.appending(path: name, directoryHint: .isDirectory)
                result.append(OrphanPrefix(appID: name, url: url, bytes: size(of: url)))
            }
        }
        return result
    }

    public static func delete(_ prefixes: [OrphanPrefix]) throws {
        for prefix in prefixes { try FileManager.default.removeItem(at: prefix.url) }
    }

    static func size(of folder: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in items {
            let values = try? item.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }
}
```

- [ ] **Step 4: Run it and confirm it passes**

Run: `swift test 2>&1 | tail -1`
Expected: `Test run with 104 tests in 0 suites passed`

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "feat: find and delete prefixes left by uninstalled games"
```

---

### Task 11: Import GPTK from its disk image; move the cached download into RuntimeInstaller

**Files:**
- Create: `Sources/MacNeutronCore/GPTKDiskImage.swift`
- Modify: `Sources/MacNeutronCore/RuntimeInstaller.swift`, `Sources/MacNeutronCore/CommandLineTool.swift`
- Test: `Tests/MacNeutronCoreTests/GPTKDiskImageTests.swift`

**Interfaces:**
- Consumes: `GPTKImporter` and `ToolLayout` (runtime).
- Produces:
  - `enum GPTKDiskImage { static func importGPTK(from: URL, into: ToolLayout) throws -> GPTKManifest }`
  - `enum GPTKDiskImageError { attachFailed(String), noRedist }`
  - `RuntimeInstaller.cachedDownload(_: RuntimePin) async throws -> URL` (public), which the app uses.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import MacNeutronCore

/// A real disk image built with hdiutil from a folder.
private func makeDMG(from folder: URL, named name: String, in dir: URL) throws -> URL {
    let dmg = dir.appending(path: name)
    let status = try SystemProcessRunner().run(URL(filePath: "/usr/bin/hdiutil"),
        ["create", "-quiet", "-srcfolder", folder.path(percentEncoded: false), "-format", "UDRO", "-fs", "HFS+",
         dmg.path(percentEncoded: false)], environment: [:], output: nil)
    #expect(status == 0)
    return dmg
}

@Test func importsFromTheNestedEvaluationImage() throws {
    let work = try makeTempDir()
    let inner = work.appending(path: "inner", directoryHint: .isDirectory)
    for file in GPTKImporter.requiredFiles where !file.hasSuffix(".framework") {
        try write("apple", to: inner.appending(path: "redist/lib/\(file)"))
    }
    let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "4.0b2"], format: .xml, options: 0)
    let info = inner.appending(path: "redist/lib/external/D3DMetal.framework/Versions/A/Resources/Info.plist")
    try FileManager.default.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
    try plist.write(to: info)
    let outer = work.appending(path: "outer", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: outer, withIntermediateDirectories: true)
    _ = try makeDMG(from: inner, named: "Evaluation environment for Windows games 4.0 beta 2.dmg", in: outer)
    let gptk = try makeDMG(from: outer, named: "Game_Porting_Toolkit.dmg", in: work)

    let layout = try makeToolLayout()
    let manifest = try GPTKDiskImage.importGPTK(from: gptk, into: layout)
    #expect(manifest.version == "4.0b2")
    #expect(layout.gptkVersion == "4.0b2")
}

@Test func rejectsImagesWithoutGPTK() throws {
    let work = try makeTempDir()
    let folder = work.appending(path: "stuff", directoryHint: .isDirectory)
    try write("hello", to: folder.appending(path: "readme.txt"))
    let dmg = try makeDMG(from: folder, named: "other.dmg", in: work)
    #expect(throws: GPTKDiskImageError.noRedist) { try GPTKDiskImage.importGPTK(from: dmg, into: try makeToolLayout()) }
}
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `swift test 2>&1 | grep -m1 "error:"`
Expected: `cannot find 'GPTKDiskImage' in scope`

- [ ] **Step 3: Implement**

`Sources/MacNeutronCore/GPTKDiskImage.swift`:

```swift
import Foundation

public enum GPTKDiskImageError: Error, Equatable, CustomStringConvertible {
    case attachFailed(String)
    case noRedist

    public var description: String {
        switch self {
        case .attachFailed(let name):
            "\(name) couldn't be opened. If it shows a license agreement, open it once in Finder and accept it, then try again."
        case .noRedist: "This disk image doesn't contain Apple's Game Porting Toolkit redistributable."
        }
    }
}

/// Imports D3DMetal straight from Apple's GPTK .dmg: mounts it (and the nested "Evaluation environment"
/// image) read-only, runs `GPTKImporter`, then unmounts everything.
public enum GPTKDiskImage {
    public static func importGPTK(from dmg: URL, into layout: ToolLayout) throws -> GPTKManifest {
        let outer = try attach(dmg)
        defer { detach(outer) }
        if GPTKImporter.locateLib(from: outer) != nil { return try GPTKImporter.importGPTK(from: outer, into: layout) }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: outer.path(percentEncoded: false))) ?? []
        guard let nested = names.first(where: { $0.hasPrefix("Evaluation environment") && $0.hasSuffix(".dmg") }) else {
            throw GPTKDiskImageError.noRedist
        }
        let inner = try attach(outer.appending(path: nested))
        defer { detach(inner) }
        guard GPTKImporter.locateLib(from: inner) != nil else { throw GPTKDiskImageError.noRedist }
        return try GPTKImporter.importGPTK(from: inner, into: layout)
    }

    /// `hdiutil attach` with stdin closed, so a license prompt fails instead of being accepted for the user.
    static func attach(_ image: URL) throws -> URL {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/hdiutil")
        process.arguments = ["attach", "-nobrowse", "-readonly", "-plist", image.path(percentEncoded: false)]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mount = entities.compactMap({ $0["mount-point"] as? String }).first
        else { throw GPTKDiskImageError.attachFailed(image.lastPathComponent) }
        return URL(filePath: mount, directoryHint: .isDirectory)
    }

    static func detach(_ mountPoint: URL) {
        _ = try? SystemProcessRunner().run(URL(filePath: "/usr/bin/hdiutil"),
                                           ["detach", "-quiet", "-force", mountPoint.path(percentEncoded: false)],
                                           environment: [:], output: nil)
    }
}
```

In `Sources/MacNeutronCore/RuntimeInstaller.swift`, add above `download(_:to:)`:

```swift
    /// The pinned tarball in `~/Library/Caches/MacNeutron`, downloading it on first use.
    public static func cachedDownload(_ pin: RuntimePin) async throws -> URL {
        let cache = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Caches/MacNeutron", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let tarball = cache.appending(path: "\(pin.version).tar.gz")
        if !FileManager.default.fileExists(atPath: tarball.path(percentEncoded: false)) {
            try await download(pin, to: tarball)
        }
        return tarball
    }
```

In `Sources/MacNeutronCore/CommandLineTool.swift`:
- Delete `static func cachedDownload(_:)`.
- In `install-runtime`, replace the `let tarball = …` line with:

```swift
                if tarballPath == nil { print("Downloading \(RuntimePin.current.url.absoluteString) (first time only)") }
                let tarball = if let tarballPath { URL(filePath: tarballPath) } else { try await RuntimeInstaller.cachedDownload(.current) }
```

- [ ] **Step 4: Run them and confirm they pass**

Run: `swift test 2>&1 | tail -1 && hdiutil info | grep -c "Evaluation environment"`
Expected: `Test run with 106 tests in 0 suites passed` (about 30 s), then `0`, meaning no test image was left attached.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "feat: import D3DMetal straight from Apple's GPTK disk image"
```

---

### Task 12: The SwiftUI menu-bar app

**Files:**
- Modify: `Package.swift` (add the `MacNeutronApp` product and target), `Makefile` (`app` target), `.gitignore` (`build/`), `README.md`
- Create: `App/Info.plist`, `Sources/MacNeutronApp/{MacNeutronApp,AppModel,MenuContent,SetupView,GamesView,SettingsView}.swift`

**Interfaces:**
- Consumes: every core unit above, including `RuntimeInstaller.cachedDownload`.
- Produces:
  - `make app` builds `build/MacNeutron.app` (`Contents/MacOS/MacNeutron`, `Contents/Helpers/macneutron`), ad-hoc signed.
  - Scenes: `MenuBarExtra`; windows `setup`, `games` and `cleanup`; `Settings`.

- [ ] **Step 1: Package, bundle metadata and build target**

`Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacNeutron",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "macneutron", targets: ["macneutron"]),
        .executable(name: "MacNeutronApp", targets: ["MacNeutronApp"]),
        .library(name: "MacNeutronCore", targets: ["MacNeutronCore"]),
    ],
    targets: [
        .target(name: "MacNeutronCore"),
        .executableTarget(name: "macneutron", dependencies: ["MacNeutronCore"]),
        .executableTarget(name: "MacNeutronApp", dependencies: ["MacNeutronCore"]),
        .testTarget(name: "MacNeutronCoreTests", dependencies: ["MacNeutronCore"]),
    ]
)
```

`App/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>io.github.chadouming.MacNeutron</string>
	<key>CFBundleName</key><string>MacNeutron</string>
	<key>CFBundleDisplayName</key><string>MacNeutron</string>
	<key>CFBundleExecutable</key><string>MacNeutron</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>0.1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>26.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
```

`Makefile` (recipe lines start with a tab):

```make
.PHONY: build test smoke app

APP = build/MacNeutron.app

build:
	swift build -c release

test:
	swift test

# Real Wine; see Tests/Smoke/smoke.sh for prerequisites.
smoke: build
	sh Tests/Smoke/smoke.sh

# Ad-hoc signed MacNeutron.app with the macneutron CLI inside it.
app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Helpers
	cp App/Info.plist $(APP)/Contents/Info.plist
	cp .build/release/MacNeutronApp $(APP)/Contents/MacOS/MacNeutron
	cp .build/release/macneutron $(APP)/Contents/Helpers/macneutron
	codesign --force --sign - $(APP)/Contents/Helpers/macneutron
	codesign --force --sign - $(APP)
```

Append `build/` to `.gitignore`.

- [ ] **Step 2: The model**

`Sources/MacNeutronApp/AppModel.swift`:

```swift
import AppKit
import MacNeutronCore
import Observation
import ServiceManagement

/// One row of the games window.
struct GameRow: Identifiable, Equatable {
    let app: AppInfo
    let installed: Bool
    var settings: GameSettings

    var id: UInt32 { app.appID }
    var name: String { app.name.isEmpty ? "App \(app.appID)" : app.name }
    var isDualPlatform: Bool { app.oslist.contains("macos") && app.oslist.contains("windows") }
    var runsWithMacNeutron: Bool { !app.oslist.contains("macos") || (isDualPlatform && settings.runAs == .windows) }
}

/// Everything the menu, setup, games and settings views show, and every action they take.
@Observable @MainActor
final class AppModel {
    let steam: SteamLocation
    let layout: ToolLayout
    let mode: SteamPlayMode
    let store: GameSettingsStore

    private(set) var runtimeVersion: String?
    private(set) var gptkVersion: String?
    private(set) var status: SteamPlayStatus = .off
    private(set) var games: [GameRow] = []
    private(set) var orphans: [OrphanPrefix] = []
    private(set) var appInfoError: String?
    var busy: String?
    var errorMessage: String?

    private var apps: [AppInfo] = []
    private var watcher = SteamWatcher()
    private var pollTask: Task<Void, Never>?

    init(steam: SteamLocation = SteamLocation(), layout: ToolLayout = ToolLayout(root: ToolLayout.defaultRoot),
         mode: SteamPlayMode = SteamPlayMode(), store: GameSettingsStore = GameSettingsStore()) {
        self.steam = steam
        self.layout = layout
        self.mode = mode
        self.store = store
        refresh()
        startWatchingSteam()
    }

    var setupComplete: Bool { runtimeVersion != nil && mode.isWanted }
    var steamInstalled: Bool { steam.isInstalled }

    /// The `macneutron` CLI inside the app bundle (or next to the executable during development).
    var helper: URL {
        let executable = Bundle.main.executableURL ?? URL(filePath: CommandLine.arguments[0])
        let bundled = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Helpers/macneutron")
        return FileManager.default.fileExists(atPath: bundled.path(percentEncoded: false))
            ? bundled : executable.deletingLastPathComponent().appending(path: "macneutron")
    }

    func refresh() {
        runtimeVersion = layout.runtimeVersion
        gptkVersion = layout.gptkVersion
        do {
            apps = try AppInfoReader.read(steam.appInfo)
            appInfoError = nil
        } catch {
            apps = []
            appInfoError = "\(error)"
        }
        let installed = steam.installedAppIDs()
        let settings = store.all()
        games = apps.filter { MappingPlanner.mappableTypes.contains($0.type) && !$0.oslist.isDisjoint(with: ["windows", "macos"]) }
            .map { GameRow(app: $0, installed: installed.contains($0.appID), settings: settings[String($0.appID)] ?? GameSettings()) }
            .sorted { ($0.installed ? 0 : 1, $0.name.lowercased()) < ($1.installed ? 0 : 1, $1.name.lowercased()) }
        orphans = OrphanPrefixes.find(in: steam)
        status = mode.status(plan: plan())
    }

    func plan() -> [String: ToolMapping] {
        MappingPlanner.plan(apps: apps, runAs: store.runAsOverrides())
    }

    // MARK: Setup

    func installRuntime() async {
        await run("Downloading and installing the runtime (461 MB, first time only)…") { [layout, helper] in
            let tarball = try await RuntimeInstaller.cachedDownload(.current)
            try await Task.detached {
                try RuntimeInstaller.install(tarball: tarball, pin: .current, layout: layout, launcherBinary: helper)
            }.value
        }
    }

    func importGPTK(from dmg: URL) async {
        await run("Importing the Game Porting Toolkit…") { [layout] in
            _ = try await Task.detached { try GPTKDiskImage.importGPTK(from: dmg, into: layout) }.value
        }
    }

    func enableSteamPlay() async {
        guard appInfoError == nil else {
            errorMessage = "MacNeutron can't read Steam's app list, so it can't protect your Mac games: \(appInfoError ?? "")"
            return
        }
        await run("Turning on Steam Play mode and restarting Steam…") { [mode] in
            try await mode.enable(plan: self.plan())
        }
    }

    func disableSteamPlay() async {
        await run("Turning off Steam Play mode and restarting Steam…") { [mode] in try await mode.disable() }
    }

    /// Quit Steam, write pending mappings (or restore lost files), start Steam again.
    func restartSteam() async {
        if status == .lost {
            await enableSteamPlay()
            return
        }
        await run("Restarting Steam…") { [mode] in
            try await mode.process.quit(timeout: .seconds(30))
            try mode.sync(plan: self.plan())
            try mode.process.launch()
        }
    }

    // MARK: Games

    func update(_ appID: UInt32, _ change: (inout GameSettings) -> Void) {
        guard let index = games.firstIndex(where: { $0.id == appID }) else { return }
        change(&games[index].settings)
        do {
            try store.save(games[index].settings, for: String(appID))
        } catch {
            errorMessage = "Couldn't save settings for \(games[index].name): \(error.localizedDescription)"
        }
        status = mode.status(plan: plan())
    }

    func cleanUp(_ selected: [OrphanPrefix]) {
        do { try OrphanPrefixes.delete(selected) } catch { errorMessage = error.localizedDescription }
        orphans = OrphanPrefixes.find(in: steam)
    }

    // MARK: Settings

    var launchesAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            errorMessage = "Couldn't change the login item: \(error.localizedDescription)"
        }
    }

    // MARK: Plumbing

    private func run(_ message: String, _ work: @escaping () async throws -> Void) async {
        busy = message
        errorMessage = nil
        do { try await work() } catch { errorMessage = "\(error)" }
        busy = nil
        refresh()
    }

    /// Every 3 s: when Steam quits, bring its mappings up to date; 20 s after it starts, re-check the files.
    private func startWatchingSteam() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                switch self.watcher.observe(running: self.mode.process.isRunning()) {
                case .quit?:
                    if self.busy == nil { _ = try? self.mode.sync(plan: self.plan()) }
                    self.refresh()
                case .launched?:
                    try? await Task.sleep(for: .seconds(20))
                    self.refresh()
                case nil:
                    break
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

extension SteamPlayStatus {
    var menuTitle: String {
        switch self {
        case .off: "Steam Play mode off"
        case .on: "Steam Play mode on"
        case .restartNeeded(let count): "Restart Steam to apply \(count) \(count == 1 ? "change" : "changes")"
        case .lost: "Steam Play mode was turned off by a Steam update"
        }
    }

    var symbol: String {
        switch self {
        case .off: "atom"
        case .on: "atom"
        case .restartNeeded: "exclamationmark.circle"
        case .lost: "exclamationmark.triangle"
        }
    }
}
```

- [ ] **Step 3: The app and the menu**

`Sources/MacNeutronApp/MacNeutronApp.swift`:

```swift
import AppKit
import MacNeutronCore
import SwiftUI

@main
struct MacNeutronApp: App {
    @State private var model = AppModel()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)  // menu-bar app, even when run unbundled
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environment(model)
        } label: {
            Image(systemName: model.status.symbol)
        }

        Window("Set up MacNeutron", id: "setup") {
            SetupView().environment(model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(model.setupComplete ? .suppressed : .presented)

        Window("Games", id: "games") {
            GamesView().environment(model)
        }

        Window("Free up space", id: "cleanup") {
            CleanupView().environment(model)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView().environment(model)
        }
    }
}

/// Brings a window to the front; a menu-bar app is never active on its own.
@MainActor func show(_ id: String, with openWindow: OpenWindowAction) {
    openWindow(id: id)
    raiseWindows()
}

/// `activate()` is only a request since macOS 14 and is refused while another app is frontmost, so the
/// window is also ordered front explicitly, on the next run-loop pass once SwiftUI has created it.
@MainActor func raiseWindows() {
    NSApplication.shared.activate()
    DispatchQueue.main.async {
        for window in NSApplication.shared.windows where window.isVisible && window.level == .normal {
            window.orderFrontRegardless()
        }
    }
}
```

`Sources/MacNeutronApp/MenuContent.swift`:

```swift
import AppKit
import MacNeutronCore
import SwiftUI

struct MenuContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.status.menuTitle)
        Text("Runtime \(model.runtimeVersion ?? "not installed") · D3DMetal \(model.gptkVersion ?? "not imported")")
        if let busy = model.busy { Text(busy) }
        switch model.status {
        case .restartNeeded, .lost:
            Button(model.status == .lost ? "Restore Steam Play mode" : "Restart Steam") {
                Task { await model.restartSteam() }
            }
        default:
            EmptyView()
        }
        Divider()
        if !model.setupComplete {
            Button("Finish setup…") { show("setup", with: openWindow) }
        }
        Button("Games…") {
            model.refresh()
            show("games", with: openWindow)
        }
        Button("Open Steam") { try? model.mode.process.launch() }
        if !model.orphans.isEmpty {
            let bytes = model.orphans.reduce(Int64(0)) { $0 + $1.bytes }
            Button("Free up space (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))") {
                show("cleanup", with: openWindow)
            }
        }
        Button("Show logs") { NSWorkspace.shared.open(LauncherLog.standard.directory) }
        Divider()
        SettingsLink { Text("Settings…") }
        Button("Quit MacNeutron") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
```

- [ ] **Step 4: Setup, games, settings and cleanup windows**

`Sources/MacNeutronApp/SetupView.swift`:

```swift
import AppKit
import MacNeutronCore
import SwiftUI
import UniformTypeIdentifiers

struct SetupView: View {
    @Environment(AppModel.self) private var model
    @State private var choosingDMG = false

    private var nativeGames: [GameRow] { model.games.filter { !$0.runsWithMacNeutron } }
    private var windowsGames: [GameRow] { model.games.filter(\.runsWithMacNeutron) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Set up MacNeutron", systemImage: "atom").font(.title2)

            Step(done: model.runtimeVersion != nil, title: "Install runtime",
                 detail: model.runtimeVersion.map { "Wine \($0) installed" } ?? "Downloads the Wine runtime (461 MB).") {
                Button(model.runtimeVersion == nil ? "Install" : "Reinstall") { Task { await model.installRuntime() } }
            }

            Step(done: model.gptkVersion != nil, title: "Import Game Porting Toolkit (optional)",
                 detail: model.gptkVersion.map { "D3DMetal \($0) imported. Drop a newer .dmg here to update." }
                     ?? "Drop Apple's Game_Porting_Toolkit .dmg here, or choose it. Without it, games use DXMT.") {
                Button("Choose…") { choosingDMG = true }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let dmg = urls.first(where: { $0.pathExtension == "dmg" }) else { return false }
                Task { await model.importGPTK(from: dmg) }
                return true
            }

            Step(done: model.mode.isWanted, title: "Turn on Steam Play mode",
                 detail: "Steam restarts. Your Mac games stay native and protected.") {
                Button("Turn on and restart Steam") { Task { await model.enableSteamPlay() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.runtimeVersion == nil || !model.steamInstalled)
            }
            if !model.mode.isWanted {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                    GridRow {
                        Label("Stay native (\(nativeGames.count))", systemImage: "apple.logo")
                        Label("Run with MacNeutron (\(windowsGames.count))", systemImage: "square.grid.2x2")
                    }
                    .foregroundStyle(.secondary)
                    GridRow {
                        Text(summary(nativeGames))
                        Text(summary(windowsGames))
                    }
                }
                .font(.callout)
                .padding(.leading, 30)
            }

            if let busy = model.busy { ProgressView(busy).controlSize(.small) }
            if let error = model.errorMessage { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if !model.steamInstalled { Text("Install Steam for Mac first.").foregroundStyle(.red) }
        }
        .padding(20)
        .frame(width: 560)
        .disabled(model.busy != nil)
        .fileImporter(isPresented: $choosingDMG, allowedContentTypes: [.diskImage]) { result in
            if case .success(let dmg) = result { Task { await model.importGPTK(from: dmg) } }
        }
        .onAppear {
            model.refresh()
            raiseWindows()  // a menu-bar app isn't active on its own, so the window would open behind everything
        }
    }

    private func summary(_ rows: [GameRow]) -> String {
        let installed = rows.filter(\.installed).map(\.name)
        let names = installed.isEmpty ? rows.prefix(3).map(\.name) : installed.prefix(4).map { $0 }
        return names.isEmpty ? "None" : names.joined(separator: ", ") + (rows.count > names.count ? "…" : "")
    }
}

private struct Step<Action: View>: View {
    let done: Bool
    let title: String
    let detail: String
    @ViewBuilder let action: Action

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(done ? .green : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            action
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }
}
```

`Sources/MacNeutronApp/GamesView.swift`:

```swift
import MacNeutronCore
import SwiftUI

struct GamesView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var selection: UInt32?

    private var rows: [GameRow] {
        search.isEmpty ? model.games : model.games.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Table(rows, selection: $selection) {
                TableColumn("Game") { row in
                    HStack {
                        Text(row.name)
                        if row.installed { Text("Installed").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                TableColumn("Runs as") { row in
                    if row.isDualPlatform {
                        Picker("", selection: Binding(
                            get: { row.settings.runAs ?? .mac },
                            set: { value in model.update(row.id) { $0.runAs = value == .mac ? nil : value } })) {
                            Text("Mac version").tag(RunAs.mac)
                            Text("Windows version").tag(RunAs.windows)
                        }
                        .labelsHidden()
                    } else {
                        Text(row.app.oslist.contains("macos") ? "Mac version" : "Windows").foregroundStyle(.secondary)
                    }
                }
                TableColumn("Graphics") { row in
                    if row.runsWithMacNeutron {
                        Picker("", selection: Binding(
                            get: { row.settings.graphics ?? "" },
                            set: { value in model.update(row.id) { $0.graphics = value.isEmpty ? nil : value } })) {
                            Text("Default (\(model.gptkVersion == nil ? "DXMT" : "D3DMetal"))").tag("")
                            Text("D3DMetal").tag("d3dmetal")
                            Text("DXMT").tag("dxmt")
                            Text(model.gptkVersion == nil ? "DXVK" : "DXVK (falls back to D3DMetal while GPTK is imported)").tag("dxvk")
                        }
                        .labelsHidden()
                    } else {
                        Text("Native").foregroundStyle(.secondary)
                    }
                }
            }
            if let row = rows.first(where: { $0.id == selection }), row.runsWithMacNeutron {
                HStack(spacing: 16) {
                    Text(row.name).bold()
                    Toggle("Log", isOn: binding(row, \.log, default: false))
                    Toggle("AVX", isOn: binding(row, \.avx, default: true))
                    Toggle("msync", isOn: binding(row, \.msync, default: true))
                    Spacer()
                }
                .padding(10)
            }
            if case .restartNeeded = model.status {
                HStack {
                    Text(model.status.menuTitle).foregroundStyle(.orange)
                    Spacer()
                    Button("Restart Steam") { Task { await model.restartSteam() } }
                }
                .padding(10)
            }
        }
        .searchable(text: $search)
        .frame(minWidth: 640, minHeight: 360)
        .overlay {
            if let error = model.appInfoError {
                ContentUnavailableView("Steam's app list couldn't be read", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            }
        }
    }

    private func binding(_ row: GameRow, _ key: WritableKeyPath<GameSettings, Bool?>, default value: Bool) -> Binding<Bool> {
        Binding(get: { row.settings[keyPath: key] ?? value },
                set: { newValue in model.update(row.id) { $0[keyPath: key] = newValue == value ? nil : newValue } })
    }
}
```

`Sources/MacNeutronApp/SettingsView.swift`:

```swift
import MacNeutronCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var confirmingTurnOff = false

    var body: some View {
        Form {
            Toggle("Open MacNeutron at login", isOn: Binding(get: { model.launchesAtLogin }, set: { model.setLaunchAtLogin($0) }))
            LabeledContent("Runtime") {
                Button("Repair runtime") { Task { await model.installRuntime() } }
            }
            LabeledContent("Setup") {
                Button("Run setup again") { show("setup", with: openWindow) }
            }
            LabeledContent("Steam Play mode") {
                Button("Turn off Steam Play mode", role: .destructive) { confirmingTurnOff = true }
                    .disabled(!model.mode.isWanted)
            }
            if let busy = model.busy { ProgressView(busy).controlSize(.small) }
            if let error = model.errorMessage { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .disabled(model.busy != nil)
        .confirmationDialog("Turn off Steam Play mode?", isPresented: $confirmingTurnOff) {
            Button("Turn off and restart Steam", role: .destructive) { Task { await model.disableSteamPlay() } }
        } message: {
            Text("Windows games will be removed from disk and need downloading again if you turn this back on. Saves inside their prefixes are kept.")
        }
    }
}

struct CleanupView: View {
    @Environment(AppModel.self) private var model
    @State private var selected = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Leftover data from games you've uninstalled").font(.headline)
            if model.orphans.isEmpty {
                Text("Nothing to clean up.").foregroundStyle(.secondary)
            }
            ForEach(model.orphans, id: \.appID) { orphan in
                Toggle(isOn: Binding(get: { selected.contains(orphan.appID) },
                                     set: { if $0 { selected.insert(orphan.appID) } else { selected.remove(orphan.appID) } })) {
                    HStack {
                        Text(model.games.first { String($0.id) == orphan.appID }?.name ?? "App \(orphan.appID)")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: orphan.bytes, countStyle: .file)).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Delete selected", role: .destructive) {
                    model.cleanUp(model.orphans.filter { selected.contains($0.appID) })
                    selected.removeAll()
                }
                .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
```

- [ ] **Step 5: README**

~~~~markdown
# MacNeutron

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

## The app

```sh
make app                    # build/MacNeutron.app, ad-hoc signed, with the CLI inside
open build/MacNeutron.app
```

The first launch opens a setup window: install the runtime, optionally import Apple's Game
Porting Toolkit (drop its `.dmg`), then turn on Steam Play mode. After that, MacNeutron lives
in the menu bar. It keeps Steam's mappings current so your Mac games stay native, and its
Games window sets the graphics backend and options per game.

## Install the runtime from the command line

```sh
.build/release/macneutron install-runtime                  # downloads the pinned Wine runtime (461 MB)
.build/release/macneutron import-gptk "/Volumes/<GPTK>"    # optional: Apple's GPTK from developer.apple.com
```

MacNeutron never ships Apple's files; `import-gptk` copies D3DMetal from the GPTK you downloaded.

## Per-game options

Use the app's Games window, or Steam launch options:

Start launch options with `/usr/bin/env`. macOS Steam runs them without a shell, so the Linux-style
`VAR=value %command%` fails to launch.

| Launch options | Effect |
|---|---|
| `/usr/bin/env MACNEUTRON_GRAPHICS=d3dmetal\|dxmt\|dxvk %command%` | Pick the Direct3D backend (`dxvk` is unavailable while GPTK is imported and falls back to `d3dmetal`) |
| `/usr/bin/env MACNEUTRON_LOG=1 %command%` | Wine log in `~/Library/Logs/MacNeutron/steam-<appid>.log` |
| `/usr/bin/env MACNEUTRON_NO_AVX=1 %command%` | Don't advertise AVX through Rosetta |
| `/usr/bin/env MACNEUTRON_NO_MSYNC=1 %command%` | Turn off msync |
~~~~

- [ ] **Step 6: Build, test and look at it**

Run: `swift test 2>&1 | tail -1 && make app 2>&1 | grep -E "warning:|error:"; codesign -dv build/MacNeutron.app 2>&1 | grep Identifier`
Expected: `Test run with 106 tests in 0 suites passed`, no warnings or errors, `Identifier=io.github.chadouming.MacNeutron`.

Run: `open build/MacNeutron.app`
Expected, with the runtime not yet installed under the MacNeutron paths:
- the **"Set up MacNeutron" window opens in front**, with three steps and the "Stay native" / "Run with MacNeutron" preview;
- an atom icon appears in the menu bar, and its menu shows "Steam Play mode off", the versions line, Finish setup…, Games…, Open Steam, Show logs, Settings… and Quit MacNeutron.

Ask the user to confirm what they see: a menu-bar app's windows aren't reliably visible to screenshot tools. Then quit the app from its menu.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Makefile .gitignore README.md App Sources
git commit -m "feat: MacNeutron menu-bar app with setup, games and settings"
```

---

### Task 13: App acceptance

> **Ask the user first.** This turns on Steam Play mode for real through the app, installs and plays a game, and turns it off again.

**Files:**
- Create: `docs/testing/acceptance-app.md`
- Modify: the spec's §9 acceptance line, with the result

**Interfaces:** Consumes the whole app. Produces a results row.

- [ ] **Step 1: Write the checklist**

```markdown
# App acceptance test (sub-project 3a)

Manual, on a Mac with at least one installed Mac-only game (Timberborn here) and GPTK available.
Record results at the bottom.

## Steps

1. `make app && open build/MacNeutron.app`. The setup window opens in front.
2. **Install runtime:** step 1 turns green.
3. **Import GPTK:** drop `~/Downloads/Game_Porting_Toolkit_*.dmg` on step 2. It turns green and shows the D3DMetal version.
4. **Turn on Steam Play mode:** the preview lists Timberborn under "Stay native". Click "Turn on and restart Steam". Steam restarts; the menu shows "Steam Play mode on".
5. **Timberborn is protected:** `grep "AppID 1062090" "$HOME/Library/Application Support/Steam/logs/content_log.txt" | tail -3` shows no new update, and it launches from Play.
6. **A Windows game:** install "Cats" from Steam and press Play. It renders; `launcher.log` shows `backend=d3dmetal`.
7. **Per-game graphics:** in Games…, set Cats to DXMT and play again. `launcher.log` shows `backend=dxmt`.
8. **Runs as:** switch a dual-platform game to "Windows version". The menu shows "Restart Steam to apply 1 change". Click it, and after the restart the game's Properties show MacNeutron.
9. **Free up space:** uninstall Cats in Steam. "Free up space" appears; delete its prefix.
10. **Turn off:** Settings → Turn off Steam Play mode → confirm. Steam restarts in Mac mode, and Timberborn is still installed with no download.

## Results

| Date | Steps passed | Notes |
|---|---|---|
```

- [ ] **Step 2: Carry it out with the user.** Expected: steps 1–10 all pass. Timberborn is never unmounted.

- [ ] **Step 3: Record and commit**

```bash
git add docs/testing/acceptance-app.md docs/superpowers/specs
git commit -m "test: MacNeutron app acceptance run"
```
