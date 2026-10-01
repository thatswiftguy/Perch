import PerchCore
import SwiftUI

enum IslandPalette {
    static let working = Color(red: 0.52, green: 0.72, blue: 0.92)
    static let blocked = Color(red: 0.94, green: 0.62, blue: 0.15)
    static let done    = Color(red: 0.59, green: 0.77, blue: 0.35)

    static let primary   = Color.white.opacity(0.93)
    static let secondary = Color.white.opacity(0.58)
    static let tertiary  = Color.white.opacity(0.38)
    static let hairline  = Color.white.opacity(0.10)
    static let track     = Color.white.opacity(0.14)

    static func color(for kind: IslandPresentation.Kind) -> Color {
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

enum IslandMetrics {
    static let expandedWidth: CGFloat = 356
    static let compactOverhang: CGFloat = 52
    static let expandedOverhang: CGFloat = 150
    static let maxRows = 5
    static let contextBarWidth: CGFloat = 46
    static let dotSize: CGFloat = 6
}
