import Darwin
import Foundation

/// The player's data a fresh prefix takes from the Rosetta-era prefix it replaced (renamed `pfx.rosetta…`): games keep
/// settings and local saves in the user's folders and in `HKCU\Software\<Vendor>`. Reads the old prefix only.
enum PlayerData {
    /// Per user folder: what is copied, and Wine's own folders inside it, which aren't.
    static let folders = ["AppData/Local", "AppData/LocalLow", "AppData/Roaming", "Documents", "Saved Games"]
    static let skipped: Set = ["AppData/Local/Temp", "AppData/Local/Microsoft", "AppData/Roaming/Microsoft"]
    /// `HKCU\Software\<Vendor>` keys that are Wine's, Windows' or Steam's, not a game's.
    static let systemVendors: Set = ["wine", "microsoft", "classes", "policies", "valve"]

    /// Clones the user folders' files the new prefix doesn't have yet, then appends the game-owned `user.reg` sections
    /// it has no section of. Call only while no wineserver runs: it reads `user.reg` when it starts and rewrites it.
    static func carry(from old: URL, to new: URL) throws -> (files: Int, keys: Int) {
        var files = 0
        let oldUsers = try users(in: old), newUsers = try users(in: new)
        for user in oldUsers {
            // wineboot names the user after $USER: one old user goes to the one new user, whatever the names.
            let target = oldUsers.count == 1 && newUsers.count == 1 ? newUsers[0] : user
            for folder in folders {
                files += try copyTree(old.appending(path: "drive_c/users/\(user)/\(folder)"),
                                      to: new.appending(path: "drive_c/users/\(target)/\(folder)"), relative: folder)
            }
        }
        return (files, try carryRegistry(from: old.appending(path: "user.reg"), to: new.appending(path: "user.reg")))
    }

    /// The real folders in `drive_c/users`, `Public` aside.
    private static func users(in prefix: URL) throws -> [String] {
        let dir = prefix.appending(path: "drive_c/users")
        guard isDirectory(dir) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))
            .filter { $0 != "Public" && isDirectory(dir.appending(path: $0)) }.sorted()
    }

    /// A directory, not a link to one: Wine links `Documents` and others to the Mac's folders, which are never read
    /// through (the data is already there) nor written through.
    private static func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path(percentEncoded: false), &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    /// Clones every regular file under `source` that `destination` lacks; returns how many.
    private static func copyTree(_ source: URL, to destination: URL, relative: String) throws -> Int {
        guard !skipped.contains(relative), isDirectory(source), makeDirectory(destination) else { return 0 }
        var count = 0
        for name in try FileManager.default.contentsOfDirectory(atPath: source.path(percentEncoded: false)) {
            let from = source.appending(path: name), to = destination.appending(path: name)
            var info = stat()
            guard lstat(from.path(percentEncoded: false), &info) == 0 else { continue }
            switch info.st_mode & S_IFMT {
            case S_IFDIR: count += try copyTree(from, to: to, relative: "\(relative)/\(name)")
            case S_IFREG:
                var existing = stat()
                guard lstat(to.path(percentEncoded: false), &existing) != 0 else { continue }  // never overwritten
                // COPYFILE_CLONE: an APFS clone, else a copy; it includes COPYFILE_EXCL.
                guard copyfile(from.path(percentEncoded: false), to.path(percentEncoded: false), nil,
                               copyfile_flags_t(COPYFILE_CLONE)) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                count += 1
            default: continue  // links and the rest stay behind
            }
        }
        return count
    }

    /// True when `url` is a directory now, made with its missing parents; false when it or a parent is a link or a
    /// file, which is never followed or replaced.
    private static func makeDirectory(_ url: URL) -> Bool {
        if isDirectory(url) { return true }
        var info = stat()
        guard lstat(url.path(percentEncoded: false), &info) != 0, makeDirectory(url.deletingLastPathComponent()) else {
            return false
        }
        return mkdir(url.path(percentEncoded: false), 0o755) == 0
    }

    /// Appends the old `user.reg`'s sections under `Software\<Vendor>` (a game's vendor) that the new one has no
    /// section of, verbatim; returns how many. The file is replaced atomically.
    private static func carryRegistry(from old: URL, to new: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: old.path(percentEncoded: false)) else { return 0 }
        let oldText = try String(contentsOf: old, encoding: .utf8)
        var newText = try String(contentsOf: new, encoding: .utf8)
        let taken = Set(sections(of: newText).map { $0.name.lowercased() })
        let carried = sections(of: oldText).filter { section in
            let path = section.name.components(separatedBy: #"\\"#)
            return path.count > 1 && path[0].lowercased() == "software" && !systemVendors.contains(path[1].lowercased())
                && !taken.contains(section.name.lowercased())
        }
        guard !carried.isEmpty else { return 0 }
        if !newText.hasSuffix("\n") { newText += "\n" }
        for section in carried { newText += "\n" + section.text + "\n" }
        try newText.write(to: new, atomically: true, encoding: .utf8)
        return carried.count
    }

    /// A Wine registry file's sections: each `[name] time` line with the lines up to the next one, trailing blank
    /// lines dropped. Values never start a line with `[` (they start with `"` or `@`, continuations with spaces).
    private static func sections(of text: String) -> [(name: String, text: String)] {
        var result: [(name: String, lines: [Substring])] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("["), let close = line.lastIndex(of: "]") {
                result.append((String(line[line.index(after: line.startIndex)..<close]), [line]))
            } else if !result.isEmpty {
                result[result.count - 1].lines.append(line)
            }
        }
        return result.map { section in
            var lines = section.lines
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
            return (section.name, lines.joined(separator: "\n"))
        }
    }
}
