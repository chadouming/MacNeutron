/// Turns periodic "is Steam running?" checks into launch and quit events.
public struct SteamWatcher: Sendable {
    public enum Event: Equatable, Sendable { case launched, quit }

    private var wasRunning: Bool?

    public init() {}

    /// The first observation only records the state; later ones report changes.
    public mutating func observe(running: Bool) -> Event? {
        defer { wasRunning = running }
        guard let wasRunning, wasRunning != running else { return nil }
        return running ? .launched : .quit
    }
}
