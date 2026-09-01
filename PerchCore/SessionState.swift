import Foundation

public enum NeedsInputReason: Equatable, Sendable {
    case permission     // a tool wants approval
    case agentInput     // Claude asked a question
    case other(String)

    public var label: String {
        switch self {
        case .permission: "Needs permission"
        case .agentInput: "Waiting on you"
        case .other(let s): s
        }
    }
}

public enum SessionState: Equatable, Sendable {
    /// In the registry but we've seen no events — Perch started after the session did,
    /// or hooks aren't installed yet.
    case unknown
    case working(tool: String?, detail: String?, since: Date)
    case needsInput(NeedsInputReason, since: Date)
    case idle(lastMessage: String?, since: Date)

    /// Sort weight and badge priority. `needsInput` outranks everything because it is the
    /// only state that is actually blocked on the human.
    public var rank: Int {
        switch self {
        case .needsInput: 0
        case .working: 1
        case .unknown: 2
        case .idle: 3
        }
    }

    public var since: Date? {
        switch self {
        case .unknown: nil
        case .working(_, _, let d), .needsInput(_, let d), .idle(_, let d): d
        }
    }

    public var isWorking: Bool { if case .working = self { true } else { false } }
    public var isNeedsInput: Bool { if case .needsInput = self { true } else { false } }
    public var isIdle: Bool { if case .idle = self { true } else { false } }
}

/// Everything hooks tell us about one session. The registry supplies identity and
/// liveness; this supplies behavior.
public struct SessionRuntime: Equatable, Sendable {
    public init() {}

    public var state: SessionState = .unknown
    public var model: String?
    public var title: String?
    public var transcriptPath: String?
    public var turnStart: Date?
    public var turnToolCount: Int = 0
    public var lastTurnDuration: TimeInterval?
    public var lastActivity: Date?
    /// Set on Stop when work is still running in the background, so we can say
    /// "done, but N background tasks" instead of a bare "finished".
    public var backgroundTasks: Int = 0

    /// Fold one hook event into the state machine. Callers compare `state` before and
    /// after to decide whether the change is worth a notification.
    public mutating func apply(_ event: HookEvent) {
        let at = event.date
        lastActivity = at

        if let path = event.transcriptPath { transcriptPath = path }

        // Subagents run their own tool loops. Folding those into the parent would make a
        // single `Task` call look like a storm of activity, so we take the timestamp and
        // drop the rest.
        if event.isSubagent { return }

        switch event.event {
        case .sessionStart:
            model = event.model ?? model
            title = event.sessionTitle ?? title
            state = .unknown

        case .sessionEnd:
            break  // removal is the registry's job, not ours

        case .userPromptSubmit:
            title = event.sessionTitle ?? title
            turnStart = at
            turnToolCount = 0
            backgroundTasks = 0
            state = .working(tool: nil, detail: nil, since: at)

        case .preToolUse:
            turnToolCount += 1
            state = .working(tool: event.toolName, detail: event.toolDetail, since: at)

        case .postToolUse:
            // Between tools Claude is thinking, not idle. Keep the turn's start time so
            // the elapsed counter tracks the turn rather than resetting on every tool.
            state = .working(tool: nil, detail: nil, since: turnStart ?? at)

        case .notification:
            switch event.notificationType {
            case "permission_prompt", "worker_permission_prompt":
                state = .needsInput(.permission, since: at)
            case "agent_needs_input", "elicitation_response":
                state = .needsInput(.agentInput, since: at)
            case "idle_prompt":
                state = .idle(lastMessage: nil, since: at)
            default:
                if let m = event.message { state = .needsInput(.other(m), since: at) }
            }

        case .stop:
            if let start = turnStart { lastTurnDuration = at.timeIntervalSince(start) }
            backgroundTasks = event.backgroundTaskCount
            turnStart = nil
            state = .idle(lastMessage: event.lastAssistantMessage, since: at)
        }
    }
}

extension SessionState: CustomStringConvertible {
    /// Compact one-line form for logs. Tool detail is a full shell command or file path,
    /// so it is clipped rather than dumped.
    public var description: String {
        switch self {
        case .unknown:
            "unknown"
        case .working(let tool, let detail, _):
            "working" + (tool.map { " \($0)" } ?? "")
                + (detail.map { " (\($0.prefix(60)))" } ?? "")
        case .needsInput(let reason, _):
            "needsInput · \(reason.label)"
        case .idle(let message, _):
            "idle" + (message.map { " (\($0.prefix(60)))" } ?? "")
        }
    }
}
