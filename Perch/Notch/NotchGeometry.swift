import AppKit

/// Where the island lives on a given screen.
///
/// The important thing this encodes: on a notched Mac the notch is a *physical cutout*,
/// not display area — no pixels exist behind it. So the island can never draw "in" the
/// notch. It draws immediately below it, and because the cutout is physically black, a
/// pure-black body reads as the notch itself growing. That illusion is the whole design,
/// and it is unavailable on screens without a notch — hence `isAttached`.
struct NotchGeometry: Equatable {
    /// Width of the physical cutout in points. Zero on screens without one.
    let notchWidth: CGFloat
    /// Height of the menu bar strip — the y the island body starts at.
    let topInset: CGFloat
    /// Screen x of the notch centre. Not always `frame.midX`: the two menu bar
    /// fragments differ by a point on some panels.
    let centerX: CGFloat
    /// Screen frame, for positioning the host window.
    let screenFrame: CGRect

    /// True when there is a real cutout to blend into. False means the fallback design:
    /// a detached, fully rounded pill floating below the menu bar, since a black slab
    /// hanging off the menu bar with nothing above it just looks like a mistake.
    var isAttached: Bool { notchWidth > 0 }

    init(screen: NSScreen) {
        screenFrame = screen.frame

        let inset = screen.safeAreaInsets.top
        if inset > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            // The two auxiliary areas are the menu bar either side of the cutout, so
            // what's left over between them *is* the cutout.
            notchWidth = max(0, screen.frame.width - left.width - right.width)
            centerX = screen.frame.minX + left.width + notchWidth / 2
            topInset = inset
        } else {
            notchWidth = 0
            centerX = screen.frame.midX
            // No safe-area inset to read, so measure the menu bar directly.
            let measured = screen.frame.maxY - screen.visibleFrame.maxY
            topInset = measured > 0 ? measured : 24
        }
    }

    /// Copy of another geometry with the notch removed, for reviewing the detached
    /// fallback design on a machine that has a cutout.
    init(detachedLike other: NotchGeometry) {
        notchWidth = 0
        topInset = other.topInset
        centerX = other.centerX
        screenFrame = other.screenFrame
    }

    /// The screen the island should live on.
    ///
    /// A notched display wins even when it isn't the primary one, because the attached
    /// design only exists there — on any other screen the island falls back to the
    /// detached pill. The tradeoff is real: plug in an external monitor and make it
    /// primary, and the island stays on the laptop panel rather than following the menu
    /// bar. Swap the two clauses to prefer the menu bar's screen instead.
    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? NSScreen.screens.first
            ?? NSScreen.main
    }

    // MARK: - Host window

    /// The host window is deliberately fixed and oversized — big enough for the widest,
    /// tallest state the island can reach. Animating a window's frame visibly stutters,
    /// so only the SwiftUI content inside it ever changes size.
    static let hostWidth: CGFloat = 460
    static let hostHeight: CGFloat = 340

    var hostFrame: CGRect {
        CGRect(
            x: centerX - Self.hostWidth / 2,
            y: screenFrame.maxY - Self.hostHeight,
            width: Self.hostWidth,
            height: Self.hostHeight
        )
    }

}
