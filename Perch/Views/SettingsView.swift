import PerchCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let store: SessionStore
    @Binding var hookState: PopoverView.HookState

    @State private var error: String?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            hooksSection
            Divider()
            notificationsSection
            Divider()
            islandSection
            Divider()
            startupSection

            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
    }

    private var hooksSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Claude Code Hooks").font(.system(size: 12, weight: .semibold))
            Text("Perch adds seven entries to ~/.claude/settings.json so it can tell a working session from one waiting on you. Your existing settings are preserved, and a backup is written the first time.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Label(statusText, systemImage: statusIcon)
                    .font(.system(size: 11))
                    .foregroundStyle(hookState == .installed ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                Spacer()
                if hookState == .installed || hookState == .stale {
                    Button("Uninstall") { run(HookInstaller().uninstall) }
                        .controlSize(.small)
                }
                Button(hookState == .stale ? "Re-install" : "Install") { run(HookInstaller().install) }
                    .controlSize(.small)
                    .disabled(hookState == .installed)
            }

            Text("Changes apply to sessions started after installing.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notifications").font(.system(size: 12, weight: .semibold))
            Toggle("When a session needs input", isOn: Binding(
                get: { store.preferences.notifyOnNeedsInput },
                set: { store.preferences.notifyOnNeedsInput = $0 }
            ))
            Toggle("When a session finishes", isOn: Binding(
                get: { store.preferences.notifyOnFinish },
                set: { store.preferences.notifyOnFinish = $0 }
            ))
            if let problem = store.notifier.authorizationError {
                Text(problem).font(.system(size: 10)).foregroundStyle(.orange)
            } else if !store.notifier.isAuthorized {
                Text("Not authorised yet — allow Perch in System Settings › Notifications.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 11))
    }

    private var islandSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notch island").font(.system(size: 12, weight: .semibold))
            Toggle("Show status below the notch", isOn: Binding(
                get: { store.preferences.showNotchIsland },
                set: {
                    store.preferences.showNotchIsland = $0
                    // Ask the delegate to open or close the window; the preference alone
                    // shouldn't have window side effects.
                    (NSApp.delegate as? AppDelegate)?.applyIslandPreference()
                }
            ))
            .toggleStyle(.checkbox)
            .font(.system(size: 11))
            Text(hasNotch
                 ? "Grows out of the notch. Hover it for the full list."
                 : "This display has no notch, so the island floats just below the menu bar.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hasNotch: Bool {
        NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
    }

    private var startupSection: some View {
        Toggle("Launch Perch at login", isOn: Binding(
            get: { launchAtLogin },
            set: { setLaunchAtLogin($0) }
        ))
        .toggleStyle(.checkbox)
        .font(.system(size: 11))
    }

    private var statusText: String {
        switch hookState {
        case .installed: "Installed"
        case .stale: "Installed, but pointing at an old path"
        case .missing: "Not installed"
        case .unknown: "Checking…"
        }
    }

    private var statusIcon: String {
        switch hookState {
        case .installed: "checkmark.circle.fill"
        case .stale: "exclamationmark.triangle.fill"
        case .missing, .unknown: "circle"
        }
    }

    private func run(_ action: () throws -> Void) {
        error = nil
        do {
            try action()
        } catch {
            self.error = error.localizedDescription
        }
        if !HookInstaller().isInstalled() { hookState = .missing }
        else if HookInstaller().isStale() { hookState = .stale }
        else { hookState = .installed }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        error = nil
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            self.error = "Login item: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
