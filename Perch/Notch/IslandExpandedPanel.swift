import PerchCore
import SwiftUI

struct IslandExpandedPanel: View {
    let presentation: IslandPresentation
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.bottom, 9)

            if presentation.sessions.isEmpty {
                Text("No Claude sessions running")
                    .font(.system(size: 11.5))
                    .foregroundStyle(IslandPalette.tertiary)
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
                .foregroundStyle(IslandPalette.tertiary)
            Text("Perch")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(IslandPalette.secondary)
            Spacer()
            Text(presentation.sessions.activitySummary)
                .font(.system(size: 10.5))
                .foregroundStyle(IslandPalette.tertiary)
        }
    }

    private var sessionList: some View {
        let shown = presentation.sessions.prefix(IslandMetrics.maxRows)
        let hidden = presentation.sessions.count - shown.count

        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, session in
                if index > 0 {
                    Rectangle()
                        .fill(IslandPalette.hairline)
                        .frame(height: 0.5)
                        .padding(.vertical, 5)
                }
                row(session)
            }
            if hidden > 0 {
                Text("+\(hidden) more")
                    .font(.system(size: 10))
                    .foregroundStyle(IslandPalette.tertiary)
                    .padding(.top, 7)
            }
        }
    }

    private func row(_ session: Session) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                StateDot(
                    color: IslandPalette.color(for: session.state),
                    pulsing: session.state.isWorking
                )

                Text(session.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(
                        session.state.isIdle ? IslandPalette.secondary : IslandPalette.primary
                    )
                    .lineLimit(1)

                Spacer(minLength: 10)

                Text(session.state.headline(detailLimit: 22))
                    .font(.system(size: 10))
                    .foregroundStyle(
                        session.state.isNeedsInput
                            ? IslandPalette.color(for: session.state) : IslandPalette.tertiary
                    )
                    .lineLimit(1)

                if let since = session.state.since {
                    Text(Format.elapsed(since: since, now: now))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(IslandPalette.tertiary)
                }
            }

            if let stats = session.stats { contextLine(stats) }
        }
    }

    private func contextLine(_ stats: TranscriptStats.Snapshot) -> some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                Capsule().fill(IslandPalette.track)
                Capsule()
                    .fill(stats.isNearlyFull ? IslandPalette.blocked : IslandPalette.tertiary)
                    .frame(width: max(1.5, IslandMetrics.contextBarWidth * stats.usedFraction))
            }
            .frame(width: IslandMetrics.contextBarWidth, height: 2)

            Text("\(Int(stats.usedFraction * 100))%")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(IslandPalette.tertiary)

            if let branch = stats.gitBranch, !branch.isEmpty {
                Text(branch)
                    .font(.system(size: 9))
                    .foregroundStyle(IslandPalette.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 13)
    }
}
