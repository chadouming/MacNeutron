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
