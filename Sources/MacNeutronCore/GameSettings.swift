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
