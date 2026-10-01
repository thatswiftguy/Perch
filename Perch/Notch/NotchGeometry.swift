import AppKit

struct NotchGeometry: Equatable {
    static let hostWidth: CGFloat = 460
    static let hostHeight: CGFloat = 340

    let notchWidth: CGFloat
    let topInset: CGFloat
    let centerX: CGFloat
    let screenFrame: CGRect

    var isAttached: Bool { notchWidth > 0 }

    var hostFrame: CGRect {
        CGRect(
            x: centerX - Self.hostWidth / 2,
            y: screenFrame.maxY - Self.hostHeight,
            width: Self.hostWidth,
            height: Self.hostHeight
        )
    }

    init(screen: NSScreen) {
        screenFrame = screen.frame

        let inset = screen.safeAreaInsets.top
        if inset > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            notchWidth = max(0, screen.frame.width - left.width - right.width)
            centerX = screen.frame.minX + left.width + notchWidth / 2
            topInset = inset
        } else {
            notchWidth = 0
            centerX = screen.frame.midX
            let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
            topInset = menuBarHeight > 0 ? menuBarHeight : 24
        }
    }

    init(detachedLike other: NotchGeometry) {
        notchWidth = 0
        topInset = other.topInset
        centerX = other.centerX
        screenFrame = other.screenFrame
    }

    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? NSScreen.screens.first
            ?? NSScreen.main
    }
}
