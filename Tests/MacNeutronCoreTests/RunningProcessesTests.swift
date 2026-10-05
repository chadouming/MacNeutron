import Foundation
import Testing
@testable import MacNeutronCore

@Test func thisTestProcessIsListed() throws {
    let path = try #require(realpath(Bundle.main.executablePath!, nil))
    defer { free(path) }
    #expect(RunningProcesses.executablePaths().contains(String(cString: path)))
}

@Test func aSpawnedSleepIsListedByItsExecutable() throws {
    let sleep = Process()
    sleep.executableURL = URL(filePath: "/bin/sleep")
    sleep.arguments = ["5"]
    try sleep.run()
    defer { sleep.terminate(); sleep.waitUntilExit() }
    #expect(RunningProcesses.executablePaths().contains("/bin/sleep"))
}
