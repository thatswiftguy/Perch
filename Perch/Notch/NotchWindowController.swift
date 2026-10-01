import AppKit
import PerchCore
import SwiftUI

@MainActor
final class NotchWindowController {
    @MainActor
    private final class Island {
        let panel: NSPanel
        let geometry: NotchGeometry
        let hover = HoverState()
        var pendingCollapse: Task<Void, Never>?

        init(panel: NSPanel, geometry: NotchGeometry) {
            self.panel = panel
            self.geometry = geometry
        }
    }

    private let store: SessionStore
    private var islands: [CGDirectDisplayID: Island] = [:]
    private var hoverTimer: Timer?

    private let hoverPollInterval = 0.1
    private let collapseDelay = Duration.milliseconds(180)
    private let triggerPadding: CGFloat = 42
    private let expandedReach = CGSize(width: 210, height: 250)

    init(store: SessionStore) {
        self.store = store
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(rebuildForScreenChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    var isVisible: Bool { !islands.isEmpty }

    func setVisible(_ visible: Bool) {
        visible ? show() : hide()
    }

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
            island.pendingCollapse?.cancel()
            island.panel.orderOut(nil)
            island.panel.close()
        }
        islands.removeAll()
    }

    private func makeIsland(on screen: NSScreen) -> Island {
        let geometry = NotchGeometry(screen: screen)

        let panel = NSPanel(
            contentRect: geometry.hostFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
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
            "island on \(screen.localizedName): "
                + "\(geometry.isAttached ? "attached" : "detached"), host \(geometry.hostFrame)"
        )
        return island
    }

    private func startHoverTracking() {
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: hoverPollInterval, repeats: true) { _ in
            Task { @MainActor in self.updateHover() }
        }
    }

    private func updateHover() {
        let pointer = NSEvent.mouseLocation

        for island in islands.values {
            let zone = island.hover.isHovering
                ? expandedZone(island.geometry)
                : triggerZone(island.geometry)

            if zone.contains(pointer) {
                island.pendingCollapse?.cancel()
                island.pendingCollapse = nil
                island.hover.isHovering = true
            } else if island.hover.isHovering, island.pendingCollapse == nil {
                island.pendingCollapse = collapseTask(for: island)
            }
        }
    }

    private func collapseTask(for island: Island) -> Task<Void, Never> {
        Task { @MainActor [weak island] in
            try? await Task.sleep(for: collapseDelay)
            guard !Task.isCancelled, let island else { return }
            if !expandedZone(island.geometry).contains(NSEvent.mouseLocation) {
                island.hover.isHovering = false
            }
            island.pendingCollapse = nil
        }
    }

    private func triggerZone(_ geometry: NotchGeometry) -> CGRect {
        let width = max(geometry.notchWidth, 150) + triggerPadding * 2
        let height = geometry.topInset + triggerPadding + (geometry.isAttached ? 0 : 12)
        return CGRect(
            x: geometry.centerX - width / 2,
            y: geometry.screenFrame.maxY - height,
            width: width,
            height: height
        )
    }

    private func expandedZone(_ geometry: NotchGeometry) -> CGRect {
        CGRect(
            x: geometry.centerX - expandedReach.width,
            y: geometry.screenFrame.maxY - expandedReach.height,
            width: expandedReach.width * 2,
            height: expandedReach.height
        )
    }

    @objc private func rebuildForScreenChange() {
        guard isVisible else { return }
        hide()
        show()
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }
}
