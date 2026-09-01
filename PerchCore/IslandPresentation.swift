import Foundation

/// What the island should be showing right now.
///
/// The governing rule is restraint: this thing sits in the user's peripheral vision all
/// day, so the default is `hidden` and every visible state has to justify itself. Nothing
/// running, nothing to say — the notch looks untouched.
public struct IslandPresentation: Equatable, Sendable {
    public enum Mode: Equatable, Sendable { case hidden, compact, expanded }

    /// Why the island is visible, which is also what the accent colour means.
    public enum Kind: Equatable, Sendable {
        case working
        case needsInput
        case finished   // a brief acknowledgement, then back to hidden
    }

    public var mode: Mode = .hidden
    public var kind: Kind = .working
    public var primary: Session?
    public var sessions: [Session] = []
    /// Active sessions beyond `primary`, shown as a count rather than a list.
    public var extraActive: Int = 0

    /// How long a finished turn stays acknowledged before the island retreats.
    public static let finishedLinger: TimeInterval = 6

    public static func make(sessions: [Session], isHovering: Bool, now: Date = Date()) -> IslandPresentation {
        var p = IslandPresentation()
        p.sessions = sessions

        let blocked = sessions.filter(\.state.isNeedsInput)
        let working = sessions.filter(\.state.isWorking)

        // Sessions are already sorted by state rank, so the first is the most urgent.
        if let first = blocked.first {
            p.kind = .needsInput
            p.primary = first
            p.extraActive = blocked.count + working.count - 1
        } else if let first = working.first {
            p.kind = .working
            p.primary = first
            p.extraActive = working.count - 1
        } else if let justDone = sessions.first(where: {
            guard case .idle(_, let since) = $0.state else { return false }
            return now.timeIntervalSince(since) < finishedLinger
        }) {
            // Closure matters: without this the island vanishes the instant work ends and
            // you never learn it succeeded.
            p.kind = .finished
            p.primary = justDone
        }

        if isHovering {
            // Hovering is an explicit request for detail, so it wins even over `hidden`:
            // reaching for the notch on a quiet machine should confirm it's quiet, not
            // leave the pointer hovering nothing.
            p.mode = .expanded
        } else {
            p.mode = p.primary == nil ? .hidden : .compact
        }
        return p
    }

}

