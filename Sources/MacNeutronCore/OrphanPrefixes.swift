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
