import PerchCore
import SwiftUI

struct SessionRow: View {
    let session: Session

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 4) {
                header(now: context.date)
                status(now: context.date)
                if let stats = session.stats { contextBar(stats) }
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 12)
        .contentShape(.rect)
        .contextMenu {
            Button("Open Project Folder") {
                NSWorkspace.shared.selectFile(
                    nil, inFileViewerRootedAtPath: session.record.cwd
                )
            }
            Button("Copy Session ID") { copy(session.record.sessionId) }
            Button("Copy Project Path") { copy(session.record.cwd) }
        }
    }

    private func header(now: Date) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 8, height: 8)
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

    private func status(now: Date) -> some View {
        HStack(spacing: 5) {
            Text(statusText(now: now))
                .font(.system(size: 11))
                .foregroundStyle(
                    session.state.isNeedsInput ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary)
                )
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.leading, 15)
    }

    private func contextBar(_ stats: TranscriptStats.Snapshot) -> some View {
        HStack(spacing: 6) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(stats.isNearlyFull ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint))
                        .frame(width: max(2, geometry.size.width * stats.usedFraction))
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
            "Running · no activity seen yet"
        case .working:
            session.state.headline(detailLimit: 36) + toolCountSuffix
        case .needsInput(let reason, _):
            reason.label
        case .idle(let message, let since):
            idleText(message: message, since: since, now: now)
        }
    }

    private var toolCountSuffix: String {
        let count = session.runtime.turnToolCount
        guard count > 0 else { return "" }
        return "  ·  \(count) tool\(count == 1 ? "" : "s")"
    }

    private func idleText(message: String?, since: Date, now: Date) -> String {
        var text = "Idle · finished \(Format.ago(since, now: now))"
        if let duration = session.runtime.lastTurnDuration {
            let start = since.addingTimeInterval(-duration)
            text += " · took \(Format.elapsed(since: start, now: since))"
        }
        let backgroundTasks = session.runtime.backgroundTasks
        if backgroundTasks > 0 {
            text += " · \(backgroundTasks) background task\(backgroundTasks == 1 ? "" : "s")"
        }
        if let message {
            text += " — " + Format.truncate(Format.firstLine(message), to: 40)
        }
        return text
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
