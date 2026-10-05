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

