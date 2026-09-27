import Foundation

public enum KeyValuesError: Error, Equatable, CustomStringConvertible {
    case unexpected(String, offset: Int)
    case unterminatedString(offset: Int)
    case unterminatedBlock(String)

    public var description: String {
        switch self {
        case .unexpected(let what, let offset): "\(what) at byte \(offset)"
        case .unterminatedString(let offset): "unterminated string starting at byte \(offset)"
        case .unterminatedBlock(let key): "block \"\(key)\" is never closed"
        }
    }
}

/// One entry of Valve's text KeyValues (`config.vdf`, `libraryfolders.vdf`, `appmanifest_*.acf`).
/// Keys and strings are kept exactly as written, escapes included, so untouched parts of a file
/// round-trip byte for byte.
public struct KVNode: Equatable, Sendable {
    public enum Value: Equatable, Sendable {
        case string(String)
        case block([KVNode])
    }

    public var key: String
    public var value: Value

    public init(key: String, value: Value) {
        self.key = key
        self.value = value
    }

    /// A key/value pair from plain strings; quotes and backslashes are escaped for you.
    public static func string(_ key: String, _ value: String) -> KVNode {
        KVNode(key: KeyValues.escape(key), value: .string(KeyValues.escape(value)))
    }

    public static func block(_ key: String, _ children: [KVNode]) -> KVNode {
        KVNode(key: KeyValues.escape(key), value: .block(children))
    }

    /// The unescaped string value, or nil for a block.
    public var stringValue: String? {
        if case .string(let raw) = value { KeyValues.unescape(raw) } else { nil }
    }

    public var children: [KVNode] {
        if case .block(let nodes) = value { nodes } else { [] }
    }
}

public enum KeyValues {
    public static func parse(_ text: String) throws(KeyValuesError) -> [KVNode] {
        var parser = Parser(bytes: Array(text.utf8))
        return try parser.block(closing: nil)
    }

    /// Steam's own layout: tab indentation, two tabs between key and value, braces on their own lines.
    public static func serialize(_ nodes: [KVNode]) -> String {
        var out = ""
        func emit(_ nodes: [KVNode], depth: Int) {
            let indent = String(repeating: "\t", count: depth)
            for node in nodes {
                switch node.value {
                case .string(let raw):
                    out += "\(indent)\"\(node.key)\"\t\t\"\(raw)\"\n"
                case .block(let children):
                    out += "\(indent)\"\(node.key)\"\n\(indent){\n"
                    emit(children, depth: depth + 1)
                    out += "\(indent)}\n"
                }
            }
        }
        emit(nodes, depth: 0)
        return out
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func unescape(_ raw: String) -> String {
        var out = ""
        var escaping = false
        for character in raw {
            if escaping {
                out.append(character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                out.append(character)
            }
        }
        return out
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func quoted() throws(KeyValuesError) -> String {
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else {
                throw .unexpected("expected a quoted string", offset: index)
            }
            let start = index + 1
            index = start
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "\\"): index += 2
                case UInt8(ascii: "\""):
                    defer { index += 1 }
                    return String(decoding: bytes[start..<index], as: UTF8.self)
                default: index += 1
                }
            }
            throw .unterminatedString(offset: start - 1)
        }

        /// Children until the closing brace of `closing` (or end of input at the top level).
        mutating func block(closing: String?) throws(KeyValuesError) -> [KVNode] {
            var nodes: [KVNode] = []
            while true {
                skipWhitespace()
                guard index < bytes.count else {
                    if let closing { throw .unterminatedBlock(closing) }
                    return nodes
                }
                if bytes[index] == UInt8(ascii: "}") {
                    guard closing != nil else { throw .unexpected("unmatched }", offset: index) }
                    index += 1
                    return nodes
                }
                let key = try quoted()
                skipWhitespace()
                guard index < bytes.count else { throw .unexpected("missing value for \"\(key)\"", offset: index) }
                if bytes[index] == UInt8(ascii: "{") {
                    index += 1
                    nodes.append(KVNode(key: key, value: .block(try block(closing: key))))
                } else {
                    nodes.append(KVNode(key: key, value: .string(try quoted())))
                }
            }
        }
    }
}

extension Array where Element == KVNode {
    /// Case-insensitive lookup along a key path, the way Steam matches keys.
    public func node(at path: [String]) -> KVNode? {
        guard let head = path.first,
              let found = first(where: { $0.key.caseInsensitiveCompare(head) == .orderedSame })
        else { return nil }
        return path.count == 1 ? found : found.children.node(at: [String](path.dropFirst()))
    }

    /// Replaces the block at `path` with `children`, creating it and any missing parents at the end.
    public mutating func setBlock(at path: [String], children: [KVNode]) {
        guard let head = path.first else { return }
        let index = firstIndex { $0.key.caseInsensitiveCompare(head) == .orderedSame }
        var replacement = children
        if path.count > 1 {
            replacement = index.map { self[$0].children } ?? []
            replacement.setBlock(at: [String](path.dropFirst()), children: children)
        }
        if let index {
            self[index].value = .block(replacement)
        } else {
            append(.block(head, replacement))
        }
    }
}
