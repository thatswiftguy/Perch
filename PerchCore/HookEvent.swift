import Foundation

public enum HookKind: String, Codable, Sendable, CaseIterable {
    case sessionStart     = "SessionStart"
    case sessionEnd       = "SessionEnd"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse       = "PreToolUse"
    case postToolUse      = "PostToolUse"
    case notification     = "Notification"
    case stop             = "Stop"

    public var needsMatcher: Bool { self == .preToolUse || self == .postToolUse }
}

public struct HookEvent: Codable, Sendable {
    public let ts: Double
    public let event: HookKind
    public let payload: [String: JSONValue]

    public init(ts: Double, event: HookKind, payload: [String: JSONValue]) {
        self.ts = ts
        self.event = event
        self.payload = payload
    }

    public var date: Date { Date(timeIntervalSince1970: ts) }

    public var sessionId: String? { payload["session_id"]?.stringValue }
    public var cwd: String? { payload["cwd"]?.stringValue }
    public var transcriptPath: String? { payload["transcript_path"]?.stringValue }
    public var isSubagent: Bool { payload["agent_id"]?.stringValue != nil }

    public var toolName: String? { payload["tool_name"]?.stringValue }
    public var notificationType: String? { payload["notification_type"]?.stringValue }
    public var message: String? { payload["message"]?.stringValue }
    public var model: String? { payload["model"]?.displayString }
    public var sessionTitle: String? { payload["session_title"]?.stringValue }
    public var lastAssistantMessage: String? { payload["last_assistant_message"]?.stringValue }
    public var backgroundTaskCount: Int { payload["background_tasks"]?.arrayValue?.count ?? 0 }

    public var toolDetail: String? {
        guard let input = payload["tool_input"] else { return nil }
        for key in ["command", "file_path", "path", "pattern", "url", "prompt"] {
            if let value = input[key]?.stringValue, !value.isEmpty {
                return value.replacingOccurrences(of: "\n", with: " ")
            }
        }
        return nil
    }

    public static func decodeAll(from data: Data) -> [HookEvent] {
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(0x0A))
            .compactMap { try? decoder.decode(HookEvent.self, from: Data($0)) }
    }

    public static func readSpool() -> [HookEvent] {
        guard let data = try? Data(contentsOf: Paths.spool) else { return [] }
        return decodeAll(from: data)
    }
}
