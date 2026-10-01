import AppKit
import Observation

@MainActor
@Observable
final class Preferences {
    private enum Key {
        static let island = "showNotchIsland"
        static let notifyNeedsInput = "notifyOnNeedsInput"
        static let notifyFinish = "notifyOnFinish"
    }

    var showNotchIsland: Bool { didSet { persist(Key.island, showNotchIsland) } }
    var notifyOnNeedsInput: Bool { didSet { persist(Key.notifyNeedsInput, notifyOnNeedsInput) } }
    var notifyOnFinish: Bool { didSet { persist(Key.notifyFinish, notifyOnFinish) } }

    private var islandAwaitingFirstRunDefault: Bool

    init() {
        let defaults = UserDefaults.standard
        let storedIsland = defaults.object(forKey: Key.island) as? Bool
        islandAwaitingFirstRunDefault = storedIsland == nil
        showNotchIsland = storedIsland ?? false
        notifyOnNeedsInput = defaults.object(forKey: Key.notifyNeedsInput) as? Bool ?? true
        notifyOnFinish = defaults.object(forKey: Key.notifyFinish) as? Bool ?? true
    }

    func resolveFirstRunDefaults() {
        guard islandAwaitingFirstRunDefault else { return }
        islandAwaitingFirstRunDefault = false
        showNotchIsland = NSScreen.anyScreenHasNotch
    }

    private func persist(_ key: String, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: key)
    }
}

extension NSScreen {
    static var anyScreenHasNotch: Bool {
        screens.contains { $0.safeAreaInsets.top > 0 }
    }
}
