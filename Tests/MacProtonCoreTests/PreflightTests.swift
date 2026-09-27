import Foundation
import Testing
@testable import MacProtonCore

@Test func passesWithRosettaAndRuntime() throws {
    try Preflight(rosettaAvailable: { true }).check(try makeToolLayout())
}

@Test func reportsMissingRosettaFirst() {
    let layout = ToolLayout(root: URL(filePath: "/nonexistent"))
    #expect(throws: PreflightError.rosettaMissing) { try Preflight(rosettaAvailable: { false }).check(layout) }
}

@Test func reportsMissingRuntime() throws {
    let layout = try makeToolLayout()
    try FileManager.default.removeItem(at: layout.wineserver)
    #expect(throws: PreflightError.runtimeMissing) { try Preflight(rosettaAvailable: { true }).check(layout) }
}

@Test func runtimeWithoutVersionFileIsIncomplete() throws {
    let layout = try makeToolLayout()
    try FileManager.default.removeItem(at: layout.runtimeVersionFile)
    #expect(throws: PreflightError.runtimeMissing) { try Preflight(rosettaAvailable: { true }).check(layout) }
}

@Test func notificationTextIsEscapedForAppleScript() {
    #expect(AppleScriptNotifier.quoted(#"Game "X" at C:\Games"#) == #""Game \"X\" at C:\\Games""#)
}
