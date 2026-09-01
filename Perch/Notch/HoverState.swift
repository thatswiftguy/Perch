import Observation

/// Hover lives in its own observable object so the controller can flip it without
/// rebuilding the hosting view — SwiftUI then animates the expansion itself.
@MainActor
@Observable
final class HoverState {
    var isHovering = false
}
