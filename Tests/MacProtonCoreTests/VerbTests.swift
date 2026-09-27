import Testing
@testable import MacProtonCore

@Test func parsesSteamInvocation() throws {
    let request = try LaunchRequest.parse(["waitforexitandrun", "/games/Cats/Cats.exe", "-windowed"])
    #expect(request == LaunchRequest(verb: .waitforexitandrun, target: "/games/Cats/Cats.exe", arguments: ["-windowed"]))
}

@Test func keepsArgumentsWithSpacesAndQuotesIntact() throws {
    let args = ["run", "/Steam Library/Game Dir/Game.exe", "--name=\"Player One\"", "a b", "ünïcode"]
    let request = try LaunchRequest.parse(args)
    #expect(request.target == "/Steam Library/Game Dir/Game.exe")
    #expect(request.arguments == ["--name=\"Player One\"", "a b", "ünïcode"])
}

@Test func rejectsMissingVerb() {
    #expect(throws: LaunchRequestError.missingVerb) { try LaunchRequest.parse([]) }
}

@Test func rejectsUnknownVerb() {
    #expect(throws: LaunchRequestError.unknownVerb("destroyprefix")) { try LaunchRequest.parse(["destroyprefix", "x"]) }
}

@Test func rejectsVerbWithoutTarget() {
    #expect(throws: LaunchRequestError.missingTarget(.run)) { try LaunchRequest.parse(["run"]) }
}
