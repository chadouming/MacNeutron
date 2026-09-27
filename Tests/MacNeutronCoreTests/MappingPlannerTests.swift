import Foundation
import Testing
@testable import MacNeutronCore

private func app(_ id: UInt32, _ oslist: Set<String>, type: String = "game") -> AppInfo {
    AppInfo(appID: id, name: "App \(id)", type: type, oslist: oslist)
}

@Test(arguments: [
    (Set(["macos"]), "macneutron-native"),
    (Set(["windows"]), "macneutron"),
    (Set(["windows", "macos"]), "macneutron-native"),
    (Set(["macos", "linux"]), "macneutron-native"),
    (Set(["windows", "linux"]), "macneutron"),
    (Set(["windows", "macos", "linux"]), "macneutron-native"),
])
func routesByPlatform(oslist: Set<String>, tool: String) {
    #expect(MappingPlanner.plan(apps: [app(10, oslist)], runAs: [:])["10"] == ToolMapping(tool: tool, priority: 250))
}

@Test func linuxOnlyAndToolsAreNotMapped() {
    let plan = MappingPlanner.plan(apps: [app(1, ["linux"]), app(2, ["windows"], type: "tool"), app(3, ["windows"], type: "dlc")],
                                   runAs: [:])
    #expect(plan.keys.sorted() == ["0"])
}

@Test func globalEntryAlwaysPointsAtTheRuntime() {
    #expect(MappingPlanner.plan(apps: [], runAs: [:])["0"] == ToolMapping(tool: "macneutron", priority: 75))
}

@Test func runAsWindowsOnlyAppliesToDualPlatformGames() {
    let plan = MappingPlanner.plan(apps: [app(1, ["windows", "macos"]), app(2, ["macos"])],
                                   runAs: [1: .windows, 2: .windows])
    #expect(plan["1"]?.tool == "macneutron")
    #expect(plan["2"]?.tool == "macneutron-native")
}

@Test func mergeKeepsOtherToolsAndReplacesOurs() throws {
    let existing = [
        KVNode.block("440", [.string("name", "proton_9"), .string("config", ""), .string("priority", "250")]),
        KVNode.block("99", [.string("name", "macneutron"), .string("config", ""), .string("priority", "250")]),
    ]
    let plan = ["0": ToolMapping(tool: "macneutron", priority: 75), "20": ToolMapping(tool: "macneutron-native", priority: 250)]
    let merged = MappingPlanner.merged(existing, with: plan)
    #expect(merged.map(\.key) == ["0", "20", "440"])
    #expect(MappingPlanner.current(in: merged) == plan)
    #expect(merged.node(at: ["440", "name"])?.stringValue == "proton_9")
}

@Test func planWinsOverAnotherToolForTheSameApp() {
    let existing = [KVNode.block("20", [.string("name", "proton_9"), .string("priority", "250")])]
    let merged = MappingPlanner.merged(existing, with: ["20": ToolMapping(tool: "macneutron", priority: 250)])
    #expect(merged.count == 1)
    #expect(merged.node(at: ["20", "name"])?.stringValue == "macneutron")
}
