import PerchCore
import SwiftUI

/// The island is drawn on pure black to blend with the physical cutout, so it needs its
/// own palette — the app's semantic colours assume a light or adaptive background.
enum Palette {
    static let working = Color(red: 0.52, green: 0.72, blue: 0.92)
    static let blocked = Color(red: 0.94, green: 0.62, blue: 0.15)
    static let done    = Color(red: 0.59, green: 0.77, blue: 0.35)

    static let primary   = Color.white.opacity(0.93)
    static let secondary = Color.white.opacity(0.58)
    static let tertiary  = Color.white.opacity(0.38)
    static let hairline  = Color.white.opacity(0.10)
    static let track     = Color.white.opacity(0.14)

    /// Why the island is visible, rendered as colour. Lives here rather than on
    /// `IslandPresentation` so that type stays free of SwiftUI and testable.
    static func accent(for kind: IslandPresentation.Kind) -> Color {
        switch kind {
        case .working: working
        case .needsInput: blocked
        case .finished: done
        }
    }

    static func color(for state: SessionState) -> Color {
        switch state {
        case .needsInput: blocked
        case .working: working
        case .idle: done
        case .unknown: tertiary
        }
    }
}

/// Fixed sizes shared across the island's pieces, so compact and expanded can't drift
/// apart as either is edited.
enum IslandMetrics {
    /// Expanded takes a definite width; see `IslandWidth` for why it can't hug content.
    static let expandedWidth: CGFloat = 356
    /// How far the body overhangs the cutout at minimum, per mode.
    static let compactOverhang: CGFloat = 52
    static let expandedOverhang: CGFloat = 150
    /// Beyond this the list is summarised rather than scrolled — the island is a glance,
    /// not a window.
    static let maxRows = 5
    static let contextBarWidth: CGFloat = 46
    static let dotSize: CGFloat = 6
    /// Context fraction past which the bar turns amber.
    static let contextWarning = 0.85
}

/// A status dot that breathes while work is in progress.
///
/// Kept to a slow opacity pulse on purpose — anything faster, or anything that changes
/// size, turns into a distraction on a display you stare at all day.
struct StateDot: View {
    let color: Color
    let pulsing: Bool
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: IslandMetrics.dotSize, height: IslandMetrics.dotSize)
            .opacity(pulsing ? (dim ? 0.45 : 1) : 1)
            .animation(
                pulsing ? .easeInOut(duration: 1.15).repeatForever(autoreverses: true) : .default,
                value: dim
            )
            .onAppear { dim = pulsing }
            .onChange(of: pulsing) { _, now in dim = now }
    }
}
