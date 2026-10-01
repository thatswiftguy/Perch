import PerchCore
import SwiftUI

struct IslandCompactBar: View {
    let presentation: IslandPresentation
    let now: Date

    var body: some View {
        if let session = presentation.primary {
            HStack(spacing: 7) {
                StateDot(
                    color: IslandPalette.color(for: presentation.kind),
                    pulsing: presentation.kind == .working
                )

                Text(Format.truncate(session.title, to: 22))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(IslandPalette.primary)
                    .lineLimit(1)

                Text("·")
                    .font(.system(size: 11.5))
                    .foregroundStyle(IslandPalette.tertiary)

                Text(Format.truncate(status(session), to: 26))
                    .font(.system(size: 11.5))
                    .foregroundStyle(
                        presentation.kind == .needsInput
                            ? IslandPalette.color(for: presentation.kind)
                            : IslandPalette.secondary
                    )
                    .lineLimit(1)

                if let since = session.state.since {
                    Text(Format.elapsed(since: since, now: now))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(IslandPalette.tertiary)
                }

                if presentation.extraActive > 0 {
                    Text("+\(presentation.extraActive)")
                        .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(IslandPalette.secondary)
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(IslandPalette.track))
                }
            }
        }
    }

    private func status(_ session: Session) -> String {
        presentation.kind == .finished ? "Finished" : session.state.headline
    }
}
