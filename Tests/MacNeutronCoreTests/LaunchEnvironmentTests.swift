import Foundation
import Testing
@testable import MacNeutronCore

private let context = try! CompatContext(environment: ["STEAM_COMPAT_DATA_PATH": "/c/42", "SteamAppId": "42"])
private let layout = ToolLayout(root: URL(filePath: "/nonexistent/", directoryHint: .isDirectory))

@Test func setsPrefixOverridesAndDefaults() {
    let env = LaunchEnvironment.build(base: ["PATH": "/usr/bin"], context: context, backend: .dxmt, layout: layout, logging: false)
    #expect(env["WINEPREFIX"] == "/c/42/pfx/")
    #expect(env["WINEDLLOVERRIDES"] == "dxgi=n,b;d3d10core=n,b;d3d11=n,b;d3d9=b;d3d10=b;d3d12=b")
    #expect(env["WINEDEBUG"] == "-all")
    #expect(env["ROSETTA_ADVERTISE_AVX"] == "1")
    #expect(env["WINEMSYNC"] == "1")
    #expect(env["PATH"] == "/usr/bin")
}

@Test func loggingTurnsOnWineDebugChannels() {
    let env = LaunchEnvironment.build(base: [:], context: context, backend: .dxmt, layout: layout, logging: true)
    #expect(env["WINEDEBUG"] == "+err,+warn,+loaddll,+steamclient")
}

@Test func userSettingsWin() {
    let env = LaunchEnvironment.build(
        base: ["WINEDEBUG": "+seh", "ROSETTA_ADVERTISE_AVX": "0", "WINEDLLOVERRIDES": "d3d11=b;xinput1_3=n"],
        context: context, backend: .dxmt, layout: layout, logging: true)
    #expect(env["WINEDEBUG"] == "+seh")
    #expect(env["ROSETTA_ADVERTISE_AVX"] == "0")
    #expect(env["WINEDLLOVERRIDES"] == "dxgi=n,b;d3d10core=n,b;d3d11=b;d3d9=b;d3d10=b;d3d12=b;xinput1_3=n")
}

@Test func optOutsDropDefaults() {
    let env = LaunchEnvironment.build(base: ["MACNEUTRON_NO_AVX": "1", "MACNEUTRON_NO_MSYNC": "1"],
                                      context: context, backend: .dxmt, layout: layout, logging: false)
    #expect(env["ROSETTA_ADVERTISE_AVX"] == nil)
    #expect(env["WINEMSYNC"] == nil)
}

@Test func mergeKeepsDisabledEntries() {
    #expect(LaunchEnvironment.mergeOverrides("a=b", user: "c=") == "a=b;c=")
}

@Test func userOverridesWinOverOurD3D12() throws {
    let layout = ToolLayout(root: try makeTempDir())
    try write("ours", to: layout.dxmtD3D12)
    let env = LaunchEnvironment.build(base: ["WINEDLLOVERRIDES": "d3d12=b"], context: context, backend: .dxmt,
                                      layout: layout, logging: false)
    #expect(env["WINEDLLOVERRIDES"] == "dxgi=n,b;d3d10core=n,b;d3d11=n,b;d3d12=b;d3d9=b;d3d10=b")
}

@Test func recordsPipelinesOnlyForOurD3D12() throws {
    let ours = try makeToolLayout()
    try write("ours d3d12", to: ours.dxmtD3D12)
    func record(_ base: [String: String], _ backend: GraphicsBackend, _ layout: ToolLayout) -> String? {
        LaunchEnvironment.build(base: base, context: context, backend: backend, layout: layout, logging: false)["DXMT_PIPELINE_RECORD"]
    }
    #expect(record([:], .dxmt, ours) == "/c/42/dxmt-pipelines")
    #expect(record(["MACNEUTRON_PRECACHE": "0"], .dxmt, ours) == nil)
    #expect(record([:], .d3dmetal, ours) == nil)
    #expect(record([:], .dxmt, layout) == nil)  // the runtime's DXMT 0.80: no d3d12.dll
    #expect(record(["DXMT_PIPELINE_RECORD": "/mine"], .dxmt, ours) == "/mine")
}
