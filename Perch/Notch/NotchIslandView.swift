import PerchCore
import SwiftUI

/// Reads the store and the hover flag, then hands plain values down. Keeping the drawing
/// layer free of both makes it renderable off-screen for design review — see
/// `IslandSnapshot`.
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

/// Positions the island within its host window and swaps between its two states.
struct NotchIslandView: View {
    let sessions: [Session]
    let geometry: NotchGeometry
    let isHovering: Bool

    var body: some View {
        // Ticks once a second so elapsed counters advance and the `finished`
        // acknowledgement times itself out without any external timer.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let presentation = IslandPresentation.make(
                sessions: sessions, isHovering: isHovering, now: context.date
            )

            VStack(spacing: 0) {
                if presentation.mode != .hidden {
                    island(presentation, now: context.date)
                        // Attached: flush with the menu bar's bottom edge, overlapping by
                        // a hairline so antialiasing can't leave a seam. Detached has no
                        // cutout to hide behind, so it needs a deliberate gap instead —
                        // flush there just looks welded on.
                        .padding(.top, geometry.isAttached
                                 ? geometry.topInset - 0.5
                                 : geometry.topInset + 7)
                }
                Spacer(minLength: 0)
            }
            .frame(
                width: NotchGeometry.hostWidth, height: NotchGeometry.hostHeight, alignment: .top
            )
            .animation(.spring(duration: 0.34, bounce: 0.16), value: presentation)
        }
    }

    @ViewBuilder
    private func island(_ p: IslandPresentation, now: Date) -> some View {
        Group {
            switch p.mode {
            case .expanded: IslandExpandedPanel(presentation: p, now: now)
            case .compact, .hidden: IslandCompactBar(presentation: p, now: now)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, p.mode == .expanded ? 10 : 8)
        .padding(.bottom, p.mode == .expanded ? 12 : 9)
        .modifier(IslandWidth(mode: p.mode, minimum: minimumWidth(p)))
        .background(background)
        .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
    }

    /// Keeps the body wider than the cutout it hangs from. An island exactly as wide as
    /// the notch reads as the notch simply being taller, which loses the distinction
    /// between "there is a cutout here" and "something is happening".
    private func minimumWidth(_ p: IslandPresentation) -> CGFloat {
        let overhang = p.mode == .expanded
            ? IslandMetrics.expandedOverhang
            : IslandMetrics.compactOverhang
        return min(geometry.notchWidth + overhang, NotchGeometry.hostWidth - 24)
    }

    private var background: some View {
        let shape = NotchShape(notchWidth: geometry.isAttached ? geometry.notchWidth : 0)
        return shape
            .fill(.black)
            // A shadow would betray the blend on an attached island, but the detached
            // fallback needs one to read as floating rather than painted on.
            .overlay(geometry.isAttached ? nil : shape.stroke(Palette.hairline, lineWidth: 0.5))
            .shadow(
                color: .black.opacity(geometry.isAttached ? 0 : 0.45),
                radius: geometry.isAttached ? 0 : 12, y: 4
            )
    }
}

/// Sizing differs by mode, and the difference matters.
///
/// Compact hugs its content: a `maxWidth` here would make the frame greedy and stretch a
/// three-word status across the full host window, which is how the first version looked.
/// Expanded takes a fixed width instead, because its rows use spacers to push status and
/// elapsed time to the trailing edge and need a definite width to push against.
private struct IslandWidth: ViewModifier {
    let mode: IslandPresentation.Mode
    let minimum: CGFloat

    func body(content: Content) -> some View {
        if mode == .expanded {
            content.frame(width: IslandMetrics.expandedWidth)
        } else {
            content
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: minimum)
        }
    }
}
