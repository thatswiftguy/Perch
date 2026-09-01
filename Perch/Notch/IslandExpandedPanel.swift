import PerchCore
import SwiftUI

/// The hovered state: every session at once, with the numbers the compact bar leaves out.
struct IslandExpandedPanel: View {
    let presentation: IslandPresentation
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.bottom, 9)

            if presentation.sessions.isEmpty {
                Text("No Claude sessions running")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
            } else {
                sessionList
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "bird.fill")
                .font(.system(size: 9))
                .foregroundStyle(Palette.tertiary)
            Text("Perch")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Palette.secondary)
            Spacer()
            Text(summary)
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.tertiary)
        }
    }

    private var sessionList: some View {
        let shown = presentation.sessions.prefix(IslandMetrics.maxRows)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, session in
                if index > 0 {
                    Rectangle()
                        .fill(Palette.hairline)
                        .frame(height: 0.5)
                        .padding(.vertical, 5)
                }
                row(session)
            }
            if presentation.sessions.count > IslandMetrics.maxRows {
                Text("+\(presentation.sessions.count - IslandMetrics.maxRows) more")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.tertiary)
                    .padding(.top, 7)
            }
        }
    }

    private func row(_ session: Session) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                StateDot(
                    color: Palette.color(for: session.state), pulsing: session.state.isWorking
                )

                Text(session.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(session.state.isIdle ? Palette.secondary : Palette.primary)
                    .lineLimit(1)

                Spacer(minLength: 10)

                Text(status(session))
                    .font(.system(size: 10))
                    .foregroundStyle(
                        session.state.isNeedsInput
                            ? Palette.color(for: session.state) : Palette.tertiary
                    )
                    .lineLimit(1)

                if let since = session.state.since {
                    Text(Format.elapsed(since: since, now: now))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Palette.tertiary)
                }
            }

            if let stats = session.stats { contextLine(stats) }
        }
    }

    private func contextLine(_ stats: TranscriptStats.Snapshot) -> some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule()
                    .fill(
                        stats.usedFraction > IslandMetrics.contextWarning
                            ? Palette.blocked : Palette.tertiary
                    )
                    .frame(width: max(1.5, IslandMetrics.contextBarWidth * stats.usedFraction))
            }
            // A fixed short bar, not a full-width one: this is a footnote to the title
            // above it, and stretched across the row it outweighs what it annotates.
            .frame(width: IslandMetrics.contextBarWidth, height: 2)

            Text("\(Int(stats.usedFraction * 100))%")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Palette.tertiary)

            if let branch = stats.gitBranch, !branch.isEmpty {
                Text(branch)
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 13)
    }

    private func status(_ session: Session) -> String {
        switch session.state {
        case .needsInput(let reason, _): reason.label
        case .working(let tool, let detail, _):
            if let tool, let detail { "\(tool) · \(Format.truncate(detail, to: 22))" }
            else { tool ?? "thinking" }
        case .idle: "idle"
        case .unknown: "running"
        }
    }

    private var summary: String {
        let blocked = presentation.sessions.count(where: { $0.state.isNeedsInput })
        let working = presentation.sessions.count(where: { $0.state.isWorking })
        var parts: [String] = []
        if blocked > 0 { parts.append("\(blocked) waiting") }
        if working > 0 { parts.append("\(working) working") }
        if parts.isEmpty {
            return presentation.sessions.isEmpty ? "" : "\(presentation.sessions.count) idle"
        }
        return parts.joined(separator: " · ")
    }
}
