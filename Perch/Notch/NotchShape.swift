import SwiftUI

/// The island's outline: square against the menu bar, rounded where it hangs free.
///
/// An earlier version cut concave shoulders into the top corners, so the body appeared to
/// bulge out of the cutout. Measuring the rendered pixels killed it: a concave shoulder
/// has to dip below the menu bar's bottom edge, and everything below that line is desktop
/// wallpaper — so the curve revealed a 9pt stripe of wallpaper between the menu bar and
/// the island and read as a rendering gap rather than a flare. The top edge is flush now.
/// The illusion survives anyway, because the cutout is black and so is this: down the
/// centre the two are one continuous shape.
struct NotchShape: Shape {
    /// Zero when there is no cutout to hang from, which switches to a free-floating pill.
    let notchWidth: CGFloat
    var topRadius: CGFloat = 11
    var bottomRadius: CGFloat = 19
    var detachedRadius: CGFloat = 16

    func path(in rect: CGRect) -> Path {
        guard notchWidth > 0 else {
            return RoundedRectangle(cornerRadius: detachedRadius, style: .continuous)
                .path(in: rect)
        }
        // Small radius on top so the corners against the menu bar stay tight; a generous
        // one below, where the body hangs over the desktop.
        return UnevenRoundedRectangle(
            topLeadingRadius: topRadius,
            bottomLeadingRadius: bottomRadius,
            bottomTrailingRadius: bottomRadius,
            topTrailingRadius: topRadius,
            style: .continuous
        ).path(in: rect)
    }
}
