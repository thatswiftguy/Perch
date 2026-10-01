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
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let preferences = Preferences()
    let store: SessionStore
    private let island: NotchWindowController

    override init() {
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
        preferences.resolveFirstRunDefaults()
        applyIslandPreference()
    }

    func applyIslandPreference() {
        island.setVisible(preferences.showNotchIsland)
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
        island.hide()
    }

    private func terminateIfAlreadyRunning() -> Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { $0.processIdentifier != NSRunningApplication.current.processIdentifier }
        guard let other = others.first else { return false }

        Log.write("another Perch is running (pid \(other.processIdentifier)); exiting")
        NSApp.terminate(nil)
        return true
    }
}
