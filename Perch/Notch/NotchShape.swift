import SwiftUI

struct NotchShape: Shape {
    let notchWidth: CGFloat

    private let attachedTopRadius: CGFloat = 11
    private let attachedBottomRadius: CGFloat = 19
    private let detachedRadius: CGFloat = 16

    func path(in rect: CGRect) -> Path {
        guard notchWidth > 0 else {
            return RoundedRectangle(cornerRadius: detachedRadius, style: .continuous)
                .path(in: rect)
        }
        return UnevenRoundedRectangle(
            topLeadingRadius: attachedTopRadius,
            bottomLeadingRadius: attachedBottomRadius,
            bottomTrailingRadius: attachedBottomRadius,
            topTrailingRadius: attachedTopRadius,
            style: .continuous
        ).path(in: rect)
    }
}
