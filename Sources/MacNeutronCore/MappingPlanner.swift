import Foundation

/// A `CompatToolMapping` entry in Steam's config.vdf.
public struct ToolMapping: Equatable, Sendable {
    public let tool: String
    public let priority: Int

    public init(tool: String, priority: Int) {
        self.tool = tool
        self.priority = priority
    }
}

/// Which build of a dual-platform game to run.
public enum RunAs: String, Codable, Sendable {
    case mac, windows
}

/// Decides which compatibility tool every app should use (spec §5).
public enum MappingPlanner {
    public static let runtimeTool = "macneutron"
    public static let nativeTool = "macneutron-native"
    /// Tools such as Steam Linux Runtime or Proton must never be mapped.
    public static let mappableTypes: Set<String> = ["game", "demo", "application"]
    /// Above Valve's automatic mappings (100), so explicit entries always win.
    public static let appPriority = 250
    public static let globalPriority = 75

    public static func plan(apps: [AppInfo], runAs: [UInt32: RunAs]) -> [String: ToolMapping] {
        var plan = ["0": ToolMapping(tool: runtimeTool, priority: globalPriority)]
        for app in apps where mappableTypes.contains(app.type) {
            let windows = app.oslist.contains("windows")
            let tool: String? = if app.oslist.contains("macos") {
                runAs[app.appID] == .windows && windows ? runtimeTool : nativeTool
            } else if windows {
                runtimeTool
            } else {
                nil
            }
            if let tool { plan[String(app.appID)] = ToolMapping(tool: tool, priority: appPriority) }
        }
        return plan
    }

    /// MacNeutron's entries in an existing `CompatToolMapping` block.
    public static func current(in mappingBlock: [KVNode]) -> [String: ToolMapping] {
        var result: [String: ToolMapping] = [:]
        for entry in mappingBlock {
            guard let tool = entry.children.node(at: ["name"])?.stringValue, isOurs(tool) else { continue }
            let priority = Int(entry.children.node(at: ["priority"])?.stringValue ?? "") ?? 0
            result[KeyValues.unescape(entry.key)] = ToolMapping(tool: tool, priority: priority)
        }
        return result
    }

    /// The new `CompatToolMapping` block: other tools' entries kept, ours replaced by `plan`,
    /// sorted by app ID for a stable file.
    public static func merged(_ mappingBlock: [KVNode], with plan: [String: ToolMapping]) -> [KVNode] {
        let others = mappingBlock.filter { entry in
            !isOurs(entry.children.node(at: ["name"])?.stringValue ?? "") && plan[KeyValues.unescape(entry.key)] == nil
        }
        let ours = plan.map { appID, mapping in
            KVNode.block(appID, [
                .string("name", mapping.tool),
                .string("config", ""),
                .string("priority", String(mapping.priority)),
            ])
        }
        return (others + ours).sorted { (UInt64(KeyValues.unescape($0.key)) ?? .max) < (UInt64(KeyValues.unescape($1.key)) ?? .max) }
    }

    static func isOurs(_ tool: String) -> Bool { tool.hasPrefix(runtimeTool) }
}
