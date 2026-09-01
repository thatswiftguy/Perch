import AppKit
import PerchCore
import SwiftUI

extension NSScreen {
    /// Stable identifier for a physical display, used to keep one island per screen.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }
}

/// Owns one borderless island window per display.
///
/// Every screen gets one, the way macOS puts a menu bar on every screen: status you have
/// to go and look for on another display isn't status. The notched panel gets the attached
/// design; everything else gets the detached pill.
@MainActor
final class NotchWindowController {
    /// One display's island. A class so hover and its pending collapse can be mutated in
    /// place while the dictionary holds it.
    @MainActor
    private final class Island {
        let panel: NSPanel
        let geometry: NotchGeometry
        let hover: HoverState
        var collapse: Task<Void, Never>?

        init(panel: NSPanel, geometry: NotchGeometry) {
            self.panel = panel
            self.geometry = geometry
            self.hover = HoverState()
        }
    }

    private let store: SessionStore
    private var islands: [CGDirectDisplayID: Island] = [:]
    private var hoverTimer: Timer?

    /// How far outside the cutout the pointer counts as reaching for the island.
    private let triggerPadding: CGFloat = 42
    /// Generous bounds kept while expanded, so the pointer can move onto the island
    /// itself without falling straight out of the zone that opened it.
    private let expandedReach = CGSize(width: 210, height: 250)

    init(store: SessionStore) {
        self.store = store
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    var isVisible: Bool { !islands.isEmpty }

    // MARK: - Lifecycle

    func show() {
        for screen in NSScreen.screens {
            guard let id = screen.displayID, islands[id] == nil else { continue }
            islands[id] = makeIsland(on: screen)
        }
        guard !islands.isEmpty else {
            Log.write("no screens available for the notch island")
            return
        }
        startHoverTracking()
    }

    func hide() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        for island in islands.values {
            island.collapse?.cancel()
            island.panel.orderOut(nil)
            island.panel.close()
        }
        islands.removeAll()
    }

    func setVisible(_ visible: Bool) {
        visible ? show() : hide()
    }

    private func makeIsland(on screen: NSScreen) -> Island {
        let geometry = NotchGeometry(screen: screen)

        let panel = NSPanel(
            contentRect: geometry.hostFrame,
            // .nonactivatingPanel keeps the app from coming forward just because the
            // island appeared.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // A window shadow would outline the island against the cutout and destroy the
        // blend. The detached fallback draws its own shadow in SwiftUI instead.
        panel.hasShadow = false
        // Fully click-through. The island is a display, not a control: swallowing clicks
        // in its large transparent host window would break whatever is underneath, and
        // actions already live in the menu bar popover. Hover is tracked by polling the
        // pointer instead, which needs no event delivery at all.
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
        ]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let island = Island(panel: panel, geometry: geometry)
        panel.contentView = NSHostingView(
            rootView: NotchIslandHost(store: store, geometry: geometry, hover: island.hover)
        )
        panel.setFrame(geometry.hostFrame, display: false)
        panel.orderFrontRegardless()

        Log.debug(
            "island on \(screen.localizedName): \(geometry.isAttached ? "attached" : "detached"), "
                + "notch \(Int(geometry.notchWidth))x\(Int(geometry.topInset)) "
                + "at x=\(Int(geometry.centerX)), host \(geometry.hostFrame)"
        )
        return island
    }

    // MARK: - Hover

    /// Polls the pointer rather than installing event monitors.
    ///
    /// The windows ignore mouse events entirely, so tracking areas and mouse-moved
    /// monitors would never fire for them. Reading `NSEvent.mouseLocation` on a timer is
    /// one cheap call plus a rect test per display, needs no accessibility permission, and
    /// can't interfere with any other application's input.
    private func startHoverTracking() {
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in self.updateHover() }
        }
    }

    private func updateHover() {
        guard !islands.isEmpty else { return }
        let pointer = NSEvent.mouseLocation

        // The pointer is only ever on one display, so at most one island expands. The
        // rest are evaluated too, so an island on a screen the pointer just left collapses
        // instead of staying stuck open.
        for island in islands.values {
            let geo = island.geometry
            // Asymmetric zones: a small target opens the island, a large one keeps it
            // open. One zone for both makes it flicker along the boundary.
            let zone = island.hover.isHovering ? expandedZone(geo) : triggerZone(geo)

            if zone.contains(pointer) {
                island.collapse?.cancel()
                island.collapse = nil
                island.hover.isHovering = true
            } else if island.hover.isHovering, island.collapse == nil {
                // Brief delay so crossing a corner doesn't slam it shut mid-read.
                island.collapse = Task { @MainActor [weak island] in
                    try? await Task.sleep(for: .milliseconds(180))
                    guard !Task.isCancelled, let island else { return }
                    if !self.expandedZone(island.geometry).contains(NSEvent.mouseLocation) {
                        island.hover.isHovering = false
                    }
                    island.collapse = nil
                }
            }
        }
    }

    private func triggerZone(_ geo: NotchGeometry) -> CGRect {
        // On a screen with no cutout the pill sits a little lower, so the trigger has to
        // reach further down to cover it.
        let width = max(geo.notchWidth, 150) + triggerPadding * 2
        let height = geo.topInset + triggerPadding + (geo.isAttached ? 0 : 12)
        return CGRect(
            x: geo.centerX - width / 2,
            y: geo.screenFrame.maxY - height,
            width: width, height: height
        )
    }

    private func expandedZone(_ geo: NotchGeometry) -> CGRect {
        CGRect(
            x: geo.centerX - expandedReach.width,
            y: geo.screenFrame.maxY - expandedReach.height,
            width: expandedReach.width * 2, height: expandedReach.height
        )
    }

    // MARK: - Displays

    @objc private func screensChanged() {
        // Displays connected or removed, resolution or arrangement changed: geometry and
        // the set of screens can both have moved. Rebuild rather than patch.
        guard isVisible else { return }
        hide()
        show()
    }
}
