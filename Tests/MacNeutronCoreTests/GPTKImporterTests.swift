import Foundation
import Testing
@testable import MacNeutronCore

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
