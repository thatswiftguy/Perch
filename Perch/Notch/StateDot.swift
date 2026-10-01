import SwiftUI

struct StateDot: View {
    let color: Color
    let pulsing: Bool

    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: IslandMetrics.dotSize, height: IslandMetrics.dotSize)
            .opacity(pulsing && dimmed ? 0.45 : 1)
            .animation(
                pulsing ? .easeInOut(duration: 1.15).repeatForever(autoreverses: true) : .default,
                value: dimmed
            )
            .onAppear { dimmed = pulsing }
            .onChange(of: pulsing) { _, isPulsing in dimmed = isPulsing }
    }
}
