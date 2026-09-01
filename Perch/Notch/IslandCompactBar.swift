import PerchCore
import SwiftUI

/// The resting state: one line naming the session that most deserves attention.
///
/// Deliberately terse. This sits in peripheral vision indefinitely, so it carries the
/// session, what it's doing, and how long — and nothing else. The full shell command and
/// the other sessions are one hover away.
struct IslandCompactBar: View {
    let presentation: IslandPresentation
    let now: Date

    var body: some View {
        if let session = presentation.primary {
            HStack(spacing: 7) {
                StateDot(color: Palette.accent(for: presentation.kind), pulsing: presentation.kind == .working)

                Text(title(session))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.primary)
                    .lineLimit(1)

                Text("·")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.tertiary)

                Text(Format.truncate(status(session), to: 26))
                    .font(.system(size: 11.5))
                    .foregroundStyle(
                        presentation.kind == .needsInput ? Palette.accent(for: presentation.kind) : Palette.secondary
                    )
                    .lineLimit(1)

                if let since = session.state.since {
                    Text(Format.elapsed(since: since, now: now))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Palette.tertiary)
                }

                if presentation.extraActive > 0 {
                    Text("+\(presentation.extraActive)")
                        .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(Palette.secondary)
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Palette.track))
                }
            }
        }
    }

    private func title(_ session: Session) -> String {
        // Character-capped rather than width-capped: the compact pill sizes itself to its
        // content, so an unbounded title would stretch it across half the screen.
        Format.truncate(session.title, to: 22)
    }

    private func status(_ session: Session) -> String {
        switch session.state {
        case .needsInput(let reason, _):
            reason.label
        case .working(let tool, _, _):
            // The tool name alone: a full shell command in the corner of your eye is
            // noise, and it's one hover away.
            tool ?? "thinking"
        case .idle:
            presentation.kind == .finished ? "finished" : "idle"
        case .unknown:
            "running"
        }
    }
}
