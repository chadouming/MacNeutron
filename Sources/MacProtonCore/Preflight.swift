import Foundation

public enum PreflightError: Error, Equatable, CustomStringConvertible {
    case rosettaMissing
    case runtimeMissing

    public var description: String {
        switch self {
        case .rosettaMissing:
            "Rosetta 2 is not installed. Run: softwareupdate --install-rosetta --agree-to-license"
        case .runtimeMissing:
            "The MacProton runtime is missing or incomplete. Repair it with: macproton install-runtime"
        }
    }
}

/// Launch-time checks. The runtime's checksum is verified at install; here we only confirm
/// the pieces a launch needs are present, which costs a few `stat`s.
public struct Preflight: Sendable {
    public static let rosettaRuntime = URL(filePath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
    public let rosettaAvailable: @Sendable () -> Bool

    public init(rosettaAvailable: @escaping @Sendable () -> Bool = {
        FileManager.default.fileExists(atPath: Preflight.rosettaRuntime.path(percentEncoded: false))
    }) {
        self.rosettaAvailable = rosettaAvailable
    }

    public func check(_ layout: ToolLayout) throws(PreflightError) {
        guard rosettaAvailable() else { throw .rosettaMissing }
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: layout.wine.path(percentEncoded: false)),
              fm.isExecutableFile(atPath: layout.wineserver.path(percentEncoded: false)),
              layout.runtimeVersion != nil
        else { throw .runtimeMissing }
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
