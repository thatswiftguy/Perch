import Foundation

public struct IslandPresentation: Equatable, Sendable {
    public enum Mode: Equatable, Sendable { case hidden, compact, expanded }
    public enum Kind: Equatable, Sendable { case working, needsInput, finished }

    public var mode: Mode = .hidden
    public var kind: Kind = .working
    public var primary: Session?
    public var sessions: [Session] = []
    public var extraActive: Int = 0

    public static let finishedLinger: TimeInterval = 6

    public static func make(
        sessions: [Session], isHovering: Bool, now: Date = Date()
    ) -> IslandPresentation {
        var presentation = IslandPresentation()
        presentation.sessions = sessions

        let blocked = sessions.filter(\.state.isNeedsInput)
        let working = sessions.filter(\.state.isWorking)

        if let first = blocked.first {
            presentation.kind = .needsInput
            presentation.primary = first
            presentation.extraActive = blocked.count + working.count - 1
        } else if let first = working.first {
            presentation.kind = .working
            presentation.primary = first
            presentation.extraActive = working.count - 1
        } else if let justFinished = sessions.first(where: { $0.finishedRecently(now: now) }) {
            presentation.kind = .finished
            presentation.primary = justFinished
        }

        presentation.mode = isHovering ? .expanded
            : (presentation.primary == nil ? .hidden : .compact)
        return presentation
    }
}

private extension Session {
    func finishedRecently(now: Date) -> Bool {
        guard case .idle(_, let since) = state else { return false }
        return now.timeIntervalSince(since) < IslandPresentation.finishedLinger
    }
}
