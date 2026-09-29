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
        // Not memory-mapped: Steam rewrites this file on exit, and a mapped file that shrinks mid-parse
        // kills the process with SIGBUS. A short read just fails to parse.
        try parse(Data(contentsOf: url))
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
