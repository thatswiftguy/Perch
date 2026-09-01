import Foundation

/// The hook events Perch subscribes to. Claude Code exposes ~31; these seven are the
/// minimum that pins down every state in `SessionState`.
public enum HookKind: String, Codable, Sendable, CaseIterable {
    case sessionStart     = "SessionStart"
    case sessionEnd       = "SessionEnd"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse       = "PreToolUse"
    case postToolUse      = "PostToolUse"
    case notification     = "Notification"
    case stop             = "Stop"

    /// PreToolUse/PostToolUse take a tool-name matcher; an empty string matches all tools.
    /// The other events take no matcher at all.
    public var needsMatcher: Bool { self == .preToolUse || self == .postToolUse }
}

/// One line of the spool. `perch-hook` writes these; the app replays and tails them.
public struct HookEvent: Codable, Sendable {
    public let ts: Double                     // epoch seconds, stamped by the helper
    public let event: HookKind
    public let payload: [String: JSONValue]   // verbatim hook stdin

    public init(ts: Double, event: HookKind, payload: [String: JSONValue]) {
        self.ts = ts
        self.event = event
        self.payload = payload
    }

    public var date: Date { Date(timeIntervalSince1970: ts) }

    // Present on every hook payload, which is what lets events join onto the registry.
    public var sessionId: String? { payload["session_id"]?.stringValue }
    public var cwd: String? { payload["cwd"]?.stringValue }
    public var transcriptPath: String? { payload["transcript_path"]?.stringValue }

    /// Set only inside a subagent. We ignore subagent events for top-level state so a
    /// Task tool call doesn't make the parent session flicker.
    public var agentId: String? { payload["agent_id"]?.stringValue }
    public var isSubagent: Bool { agentId != nil }

    public var toolName: String? { payload["tool_name"]?.stringValue }
    public var notificationType: String? { payload["notification_type"]?.stringValue }
    public var message: String? { payload["message"]?.stringValue }
    public var reason: String? { payload["reason"]?.stringValue }
    public var model: String? { payload["model"]?.displayString }
    public var sessionTitle: String? { payload["session_title"]?.stringValue }
    public var lastAssistantMessage: String? { payload["last_assistant_message"]?.stringValue }
    public var durationMs: Double? { payload["duration_ms"]?.doubleValue }
    public var backgroundTaskCount: Int { payload["background_tasks"]?.arrayValue?.count ?? 0 }

    /// A one-line gloss of what a tool is doing, for the popover — the Bash command, the
    /// file being edited, the pattern being searched. Falls back to nil when there's
    /// nothing short and useful to show.
    public var toolDetail: String? {
        guard let input = payload["tool_input"] else { return nil }
        let candidates = ["command", "file_path", "path", "pattern", "url", "prompt"]
        for key in candidates {
            if let v = input[key]?.stringValue, !v.isEmpty {
                return v.replacingOccurrences(of: "\n", with: " ")
            }
        }
        return nil
    }
}

public extension HookEvent {
    /// Decodes newline-delimited events, skipping any line that fails to parse.
    ///
    /// Lenient on purpose: a spool truncated mid-write, or written by an older build,
    /// should cost one event rather than the whole history.
    static func decodeAll(from data: Data) -> [HookEvent] {
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(0x0A))
            .compactMap { try? decoder.decode(HookEvent.self, from: Data($0)) }
    }

    /// Every event currently in the spool file.
    static func readSpool() -> [HookEvent] {
        guard let data = try? Data(contentsOf: Paths.spool) else { return [] }
        return decodeAll(from: data)
    }
}
