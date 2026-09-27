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
