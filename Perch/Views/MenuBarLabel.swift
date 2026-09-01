import PerchCore
import SwiftUI

/// The always-visible part of the app. It has room for roughly one glyph and one number,
/// so it answers exactly one question: does anything need me right now?
struct MenuBarLabel: View {
    let store: SessionStore

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            if let badge { Text(badge).font(.system(size: 11, weight: .medium)) }
        }
        // "Needs input" outranks "working" because it is the only state that is actually
        // blocked on the human — a working session needs no attention at all.
        .foregroundStyle(store.needsInputCount > 0 ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
    }

    private var symbol: String {
        if store.needsInputCount > 0 { return "exclamationmark.bubble.fill" }
        if store.workingCount > 0 { return "bird.fill" }
        return "bird"
    }

    private var badge: String? {
        if store.needsInputCount > 0 { return "\(store.needsInputCount)" }
        if store.workingCount > 0 { return "\(store.workingCount)" }
        return nil
    }
}
