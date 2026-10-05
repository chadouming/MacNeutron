import Foundation

public enum PreflightError: Error, Equatable, CustomStringConvertible {
    case unsupportedSystem
    case runtimeMissing
    case thirtyTwoBit
    case unsupportedMachine(UInt16)

    public var description: String {
        switch self {
        case .unsupportedSystem: "MacNeutron needs macOS 27 or later on an Apple Silicon Mac."
        case .runtimeMissing: "MacNeutron's runtime is missing or damaged. Open MacNeutron to repair it."
        case .thirtyTwoBit: "This game is 32-bit. MacNeutron 0.1 runs 64-bit games only; 32-bit support is planned."
        case .unsupportedMachine(let machine):
            "This game is built for \(Self.name(of: machine)), which MacNeutron can't run."
        }
    }

    static func name(of machine: UInt16) -> String {
        switch machine {
        case 0x1c4: "ARM (32-bit)"
        case 0x200: "Itanium"
        default: String(format: "machine type 0x%04x", UInt32(machine))
        }
    }
}

/// Launch-time checks. `wine.app`'s signature is verified at install; here we only confirm the pieces a launch
/// needs are present and its identity reads, which costs a few `stat`s and one code-directory read.
public struct Preflight: Sendable {
    public let systemSupported: @Sendable () -> Bool
    public let identity: @Sendable (ToolLayout) -> String?

    public init(systemSupported: @escaping @Sendable () -> Bool = Preflight.isSupportedSystem,
                identity: @escaping @Sendable (ToolLayout) -> String? = { $0.identity }) {
        self.systemSupported = systemSupported
        self.identity = identity
    }

    /// macOS 27 or later on Apple Silicon.
    public static func isSupportedSystem() -> Bool {
        var arm64: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 27, minorVersion: 0,
                                                                                       patchVersion: 0))
            && sysctlbyname("hw.optional.arm64", &arm64, &size, nil, 0) == 0 && arm64 == 1
    }

    /// Returns the runtime's identity. A missing or unreadable runtime writes the damaged marker, which makes the
    /// app reinstall it. The target's machine type is checked only for the game (`waitforexitandrun`); a target that
    /// isn't PE (a script, a missing file) isn't checked.
    public func check(_ layout: ToolLayout, request: LaunchRequest) throws(PreflightError) -> String {
        guard systemSupported() else { throw .unsupportedSystem }
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: layout.wine.path(percentEncoded: false)),
              fm.isExecutableFile(atPath: layout.wineserver.path(percentEncoded: false)),
              let identity = identity(layout)
        else {
            try? Data().write(to: layout.runtimeDamagedMarker)
            throw .runtimeMissing
        }
        if request.verb == .waitforexitandrun, let machine = PEImage.machine(of: URL(filePath: request.target)) {
            switch machine {
            case PEImage.amd64, PEImage.arm64: break
            case PEImage.i386: throw .thirtyTwoBit
            default: throw .unsupportedMachine(machine)
            }
        }
        return identity
    }
}

/// Tells the user about launch-blocking failures; Steam itself shows nothing useful.
public protocol Notifier: Sendable {
    func post(title: String, message: String)
}

/// Posts through `osascript`, which needs no app bundle or entitlement.
public struct AppleScriptNotifier: Notifier {
    public init() {}

    public func post(title: String, message: String) {
        let script = "display notification \(Self.quoted(message)) with title \(Self.quoted(title))"
        _ = try? SystemProcessRunner().run(URL(filePath: "/usr/bin/osascript"), ["-e", script],
                                           environment: [:], output: nil)
    }

    /// An AppleScript string literal: backslashes and quotes escaped.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
