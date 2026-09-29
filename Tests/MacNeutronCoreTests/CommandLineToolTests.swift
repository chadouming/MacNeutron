import Foundation
import Testing
@testable import MacNeutronCore

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

@Test func installDXMTRejectsAFolderThatIsNotABuild() async throws {
    let status = await CommandLineTool.run(
        ["install-dxmt", "--tool-dir", try makeToolLayout().root.path(percentEncoded: false), try makeTempDir().path(percentEncoded: false)],
        environment: [:], executable: URL(filePath: "/x"))
    #expect(status == 1)
}

@Test func installDXMTInstallsABuild() async throws {
    let layout = try makeToolLayout()
    let folder = try makeTempDir()
    try makeDXMTBuild(in: folder)
    let status = await CommandLineTool.run(
        ["install-dxmt", "--tool-dir", layout.root.path(percentEncoded: false), folder.path(percentEncoded: false)],
        environment: [:], executable: URL(filePath: "/x"))
    #expect(status == 0)
    #expect(layout.dxmtVersion == "abc123")
}
