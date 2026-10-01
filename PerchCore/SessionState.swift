import Foundation

public enum NeedsInputReason: Equatable, Sendable {
    case permission
    case agentInput
    case other(String)

    public var label: String {
        switch self {
        case .permission: "Needs permission"
        case .agentInput: "Waiting on you"
        case .other(let message): message
        }
    }
}

public enum SessionState: Equatable, Sendable {
    case unknown
    case working(tool: String?, detail: String?, since: Date)
    case needsInput(NeedsInputReason, since: Date)
    case idle(lastMessage: String?, since: Date)

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
        case .working(_, _, let date), .needsInput(_, let date), .idle(_, let date): date
        }
    }

    public var isWorking: Bool { if case .working = self { true } else { false } }
    public var isNeedsInput: Bool { if case .needsInput = self { true } else { false } }
    public var isIdle: Bool { if case .idle = self { true } else { false } }

    public var headline: String {
        switch self {
        case .unknown: "Running"
        case .working(let tool, _, _): tool ?? "Thinking"
        case .needsInput(let reason, _): reason.label
        case .idle: "Idle"
        }
    }

    public func headline(detailLimit: Int) -> String {
        guard case .working(let tool?, let detail?, _) = self else { return headline }
        return "\(tool) · \(Format.truncate(detail, to: detailLimit))"
    }
}

extension SessionState: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unknown:
            "unknown"
        case .working(let tool, let detail, _):
            "working" + (tool.map { " · \($0)" } ?? "")
                + (detail.map { " · \(Format.truncate($0, to: 60))" } ?? "")
        case .needsInput(let reason, _):
            "needs input · \(reason.label)"
        case .idle(let message, _):
            "idle" + (message.map { " · \(Format.truncate(Format.firstLine($0), to: 50))" } ?? "")
        }
    }
}

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
    public var backgroundTasks: Int = 0

    public mutating func apply(_ event: HookEvent) {
        let at = event.date
        lastActivity = at

        if let path = event.transcriptPath { transcriptPath = path }
        guard !event.isSubagent else { return }

        switch event.event {
        case .sessionStart:
            model = event.model ?? model
            title = event.sessionTitle ?? title
            state = .unknown

        case .sessionEnd:
            break

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
                if let message = event.message { state = .needsInput(.other(message), since: at) }
            }

        case .stop:
            if let turnStart { lastTurnDuration = at.timeIntervalSince(turnStart) }
            backgroundTasks = event.backgroundTaskCount
            turnStart = nil
            state = .idle(lastMessage: event.lastAssistantMessage, since: at)
        }
    }
}
