import PerchCore
import SwiftUI

@main
struct PerchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            PopoverView(store: delegate.store)
        } label: {
            MenuBarLabel(store: delegate.store)
        }
        // .window rather than .menu: the popover shows progress bars and multi-line rows,
        // which a menu can't lay out.
        .menuBarExtraStyle(.window)
    }
}

/// Startup lives in a delegate rather than in `App.init` because
/// `UNUserNotificationCenter` needs a fully launched application — asking for
/// authorization any earlier is silently dropped and the app never appears in
/// System Settings › Notifications.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let preferences = Preferences()
    let store: SessionStore
    private let island: NotchWindowController
    private var islandObservation: (any NSObjectProtocol)?

    override init() {
        let preferences = self.preferences
        store = SessionStore(preferences: preferences)
        island = NotchWindowController(store: store)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let directory = IslandSnapshot.requestedDirectory {
            IslandSnapshot.run(into: directory)
            NSApp.terminate(nil)
            return
        }
        guard !terminateIfAlreadyRunning() else { return }
        store.notifier.requestAuthorization()
        store.start()
        preferences.resolveDefaults()
        island.setVisible(preferences.showNotchIsland)
    }

    /// Called by the settings toggle. Kept here rather than observed, so showing and
    /// hiding a window is an explicit action rather than a side effect of a property.
    func applyIslandPreference() {
        island.setVisible(preferences.showNotchIsland)
    }

    /// Exits if another copy of Perch is already running.
    ///
    /// Launch Services stops you double-clicking the app twice, but nothing stops a second
    /// copy started from the command line or from a stale build in DerivedData — and two
    /// instances means two islands on every display and two notifications per event. The
    /// older process keeps running; this one steps aside.
    private func terminateIfAlreadyRunning() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let mine = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != mine.processIdentifier }
        guard !others.isEmpty else { return false }

        Log.write("another Perch is already running (pid \(others[0].processIdentifier)); exiting")
        NSApp.terminate(nil)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
        island.hide()
    }
}
