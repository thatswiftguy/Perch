import PerchCore
import SwiftUI

struct SessionRow: View {
    let session: Session

    var body: some View {
        // Re-ticks once a second so elapsed counters stay live. Scoped to the row rather
        // than driven from the store, so nothing redraws when the popover is closed.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 4) {
                header(now: context.date)
                detail(now: context.date)
                if let stats = session.stats { contextBar(stats) }
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 12)
        .contentShape(.rect)
        .contextMenu {
            Button("Open Project Folder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.record.cwd)
            }
            Button("Copy Session ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.record.sessionId, forType: .string)
            }
            Button("Copy Project Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.record.cwd, forType: .string)
            }
        }
    }

    private func header(now: Date) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(session.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if let since = session.state.since {
                Text(Format.elapsed(since: since, now: now))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func detail(now: Date) -> some View {
        HStack(spacing: 5) {
            Text(statusText(now: now))
                .font(.system(size: 11))
                .foregroundStyle(session.state.isNeedsInput ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.leading, 15)
    }

    private func contextBar(_ stats: TranscriptStats.Snapshot) -> some View {
        HStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(stats.usedFraction > 0.85 ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint))
                        .frame(width: max(2, geo.size.width * stats.usedFraction))
                }
            }
            .frame(height: 3)

            Text("\(Format.tokens(stats.contextTokens)) / \(Format.tokens(stats.contextWindow))")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.tertiary)

            if let branch = stats.gitBranch, !branch.isEmpty {
                Text(branch)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.leading, 15)
        .padding(.top, 1)
    }

    private var color: Color {
        switch session.state {
        case .needsInput: .orange
        case .working: .blue
        case .idle: .green
        case .unknown: .gray
        }
    }

    private func statusText(now: Date) -> String {
        switch session.state {
        case .unknown:
            // Either Perch launched mid-session, or hooks aren't reporting yet.
            return "Running · no activity seen yet"

        case .working(let tool, let detail, _):
            var text = tool ?? "Thinking…"
            if let tool, let detail { text = "\(tool) · \(Format.truncate(detail, to: 36))" }
            if session.runtime.turnToolCount > 0 {
                let n = session.runtime.turnToolCount
                text += "  ·  \(n) tool\(n == 1 ? "" : "s")"
            }
            return text

        case .needsInput(let reason, _):
            return reason.label

        case .idle(let message, let since):
            var text = "Idle · finished \(Format.ago(since, now: now))"
            if let took = session.runtime.lastTurnDuration {
                text += " · took \(Format.elapsed(since: since.addingTimeInterval(-took), now: since))"
            }
            if session.runtime.backgroundTasks > 0 {
                let n = session.runtime.backgroundTasks
                text += " · \(n) background task\(n == 1 ? "" : "s")"
            }
            if let message {
                let line = message.split(separator: "\n").first.map(String.init) ?? message
                text += " — " + Format.truncate(line, to: 40)
            }
            return text
        }
    }
}
