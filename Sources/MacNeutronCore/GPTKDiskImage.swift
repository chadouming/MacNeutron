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
