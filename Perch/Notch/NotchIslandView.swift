import PerchCore
import SwiftUI

struct NotchIslandHost: View {
    let store: SessionStore
    let geometry: NotchGeometry
    let hover: HoverState

    var body: some View {
        NotchIslandView(
            sessions: store.sessions, geometry: geometry, isHovering: hover.isHovering
        )
    }
}

struct NotchIslandView: View {
    let sessions: [Session]
    let geometry: NotchGeometry
    let isHovering: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let presentation = IslandPresentation.make(
                sessions: sessions, isHovering: isHovering, now: context.date
            )

            VStack(spacing: 0) {
                if presentation.mode != .hidden {
                    island(presentation, now: context.date)
                        .padding(.top, topPadding)
                }
                Spacer(minLength: 0)
            }
            .frame(
                width: NotchGeometry.hostWidth,
                height: NotchGeometry.hostHeight,
                alignment: .top
            )
            .animation(.spring(duration: 0.34, bounce: 0.16), value: presentation)
        }
    }

    private var topPadding: CGFloat {
        geometry.isAttached ? geometry.topInset - 0.5 : geometry.topInset + 7
    }

    @ViewBuilder
    private func island(_ presentation: IslandPresentation, now: Date) -> some View {
        let isExpanded = presentation.mode == .expanded

        Group {
            if isExpanded {
                IslandExpandedPanel(presentation: presentation, now: now)
            } else {
                IslandCompactBar(presentation: presentation, now: now)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, isExpanded ? 10 : 8)
        .padding(.bottom, isExpanded ? 12 : 9)
        .modifier(IslandWidth(isExpanded: isExpanded, minimum: minimumWidth(isExpanded)))
        .background(background)
        .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
    }

    private func minimumWidth(_ isExpanded: Bool) -> CGFloat {
        let overhang = isExpanded ? IslandMetrics.expandedOverhang : IslandMetrics.compactOverhang
        return min(geometry.notchWidth + overhang, NotchGeometry.hostWidth - 24)
    }

    private var background: some View {
        let shape = NotchShape(notchWidth: geometry.isAttached ? geometry.notchWidth : 0)
        return shape
            .fill(.black)
            .overlay(geometry.isAttached ? nil : shape.stroke(IslandPalette.hairline, lineWidth: 0.5))
            .shadow(
                color: .black.opacity(geometry.isAttached ? 0 : 0.45),
                radius: geometry.isAttached ? 0 : 12,
                y: 4
            )
    }
}

private struct IslandWidth: ViewModifier {
    let isExpanded: Bool
    let minimum: CGFloat

    func body(content: Content) -> some View {
        if isExpanded {
            content.frame(width: IslandMetrics.expandedWidth)
        } else {
            content
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: minimum)
        }
    }
}
