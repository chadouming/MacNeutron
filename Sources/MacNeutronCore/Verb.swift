/// The Proton verbs Steam uses when it launches a game through a compatibility tool.
public enum Verb: String, Sendable, CaseIterable {
    case run
    case waitforexitandrun
    case runinprefix
    case getcompatpath
    case getnativepath
}

public enum LaunchRequestError: Error, Equatable, CustomStringConvertible {
    case missingVerb
    case unknownVerb(String)
    case missingTarget(Verb)

    public var description: String {
        switch self {
        case .missingVerb: "no verb given"
        case .unknownVerb(let verb): "unknown verb '\(verb)'"
        case .missingTarget(let verb): "verb '\(verb.rawValue)' needs a target path"
        }
    }
}

/// `proton <verb> <target> [args…]` exactly as Steam invokes it.
public struct LaunchRequest: Equatable, Sendable {
    public let verb: Verb
    /// The executable to run, or the path to convert for the get*path verbs.
    public let target: String
    /// Everything after the target, passed to the game untouched.
    public let arguments: [String]

    public static func parse(_ argv: [String]) throws(LaunchRequestError) -> LaunchRequest {
        guard let first = argv.first else { throw .missingVerb }
        guard let verb = Verb(rawValue: first) else { throw .unknownVerb(first) }
        guard argv.count >= 2 else { throw .missingTarget(verb) }
        return LaunchRequest(verb: verb, target: argv[1], arguments: Array(argv.dropFirst(2)))
    }
}
