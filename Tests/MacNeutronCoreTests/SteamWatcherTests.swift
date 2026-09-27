import Testing
@testable import MacNeutronCore

@Test func reportsOnlyTransitions() {
    var watcher = SteamWatcher()
    #expect(watcher.observe(running: true) == nil)
    #expect(watcher.observe(running: true) == nil)
    #expect(watcher.observe(running: false) == .quit)
    #expect(watcher.observe(running: false) == nil)
    #expect(watcher.observe(running: true) == .launched)
}
