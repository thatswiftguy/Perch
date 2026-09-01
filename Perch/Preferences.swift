import AppKit
import Observation

/// User-facing toggles, persisted. Nothing here affects correctness — it's all about how
/// loudly Perch announces itself.
@MainActor
@Observable
final class Preferences {
    private enum Key {
        static let island = "showNotchIsland"
        static let notifyNeedsInput = "notifyOnNeedsInput"
        static let notifyFinish = "notifyOnFinish"
    }

    var showNotchIsland: Bool { didSet { store(Key.island, showNotchIsland) } }
    var notifyOnNeedsInput: Bool { didSet { store(Key.notifyNeedsInput, notifyOnNeedsInput) } }
    var notifyOnFinish: Bool { didSet { store(Key.notifyFinish, notifyOnFinish) } }

    /// True until `resolveDefaults()` has picked a first-run value for the island.
    private var islandNeedsDefault: Bool

    init() {
        let defaults = UserDefaults.standard
        let stored = defaults.object(forKey: Key.island) as? Bool
        islandNeedsDefault = stored == nil
        showNotchIsland = stored ?? false
        notifyOnNeedsInput = defaults.object(forKey: Key.notifyNeedsInput) as? Bool ?? true
        notifyOnFinish = defaults.object(forKey: Key.notifyFinish) as? Bool ?? true
    }

    /// Chooses the first-run island default. Must run after the app has finished
    /// launching: `Preferences` is built while the delegate is constructed, which is
    /// early enough that `NSScreen.screens` is still empty — reading it there silently
    /// concludes the Mac has no notch and leaves the island switched off.
    func resolveDefaults() {
        guard islandNeedsDefault else { return }
        islandNeedsDefault = false
        // Default on only where there's a real cutout to grow out of; the detached
        // fallback is a compromise, not something to opt someone into unasked.
        showNotchIsland = NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
    }

    private func store(_ key: String, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
