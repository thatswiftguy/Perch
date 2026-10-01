import PerchCore
import SwiftUI

struct MenuBarLabel: View {
    let store: SessionStore

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            if let badge { Text(badge).font(.system(size: 11, weight: .medium)) }
        }
        .foregroundStyle(needsInput > 0 ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
    }

    private var needsInput: Int { store.sessions.needsInputCount }
    private var working: Int { store.sessions.workingCount }

    private var symbol: String {
        if needsInput > 0 { return "exclamationmark.bubble.fill" }
        return working > 0 ? "bird.fill" : "bird"
    }

    private var badge: String? {
        if needsInput > 0 { return "\(needsInput)" }
        return working > 0 ? "\(working)" : nil
    }
}
