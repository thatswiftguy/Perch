import PerchCore
import SwiftUI

struct PopoverView: View {
    let store: SessionStore
    @State private var showingSettings = false
    @State private var hookState = HookState.unknown

    enum HookState { case unknown, installed, stale, missing }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if hookState == .missing || hookState == .stale {
                setupBanner
                Divider()
            }

            if showingSettings {
                SettingsView(store: store, hookState: $hookState)
            } else if store.sessions.isEmpty {
                emptyState
            } else {
                sessionList
            }

            Divider()
            footer
        }
        .frame(width: 380)
        .onAppear(perform: refreshHookState)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bird.fill").foregroundStyle(.tint)
            Text("Perch").font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(summary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button {
                showingSettings.toggle()
            } label: {
                Image(systemName: showingSettings ? "xmark" : "gearshape")
            }
            .buttonStyle(.borderless)
            .help(showingSettings ? "Close settings" : "Settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var summary: String {
        if store.sessions.isEmpty { return "No sessions" }
        var parts: [String] = []
        if store.needsInputCount > 0 { parts.append("\(store.needsInputCount) waiting") }
        if store.workingCount > 0 { parts.append("\(store.workingCount) working") }
        if parts.isEmpty { return "\(store.sessions.count) idle" }
        return parts.joined(separator: " · ")
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(store.sessions.enumerated()), id: \.element.id) { index, session in
                    if index > 0 { Divider().padding(.leading, 12) }
                    SessionRow(session: session)
                }
            }
        }
        .frame(maxHeight: 420)
    }

    private var emptyState: some View {
        VStack(spacing: 5) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text("No Claude sessions running")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("Start one and it'll show up here.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    /// Without hooks the app can still list sessions, but every one of them sits at
    /// "no activity seen yet" — so the banner explains the gap rather than leaving the
    /// user staring at a list that never changes.
    private var setupBanner: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(hookState == .stale ? "Hooks point at an old copy of Perch"
                                         : "Hooks aren't installed")
                    .font(.system(size: 12, weight: .medium))
                Text(hookState == .stale
                     ? "Re-install them so status keeps updating."
                     : "Perch can list sessions, but can't tell working from waiting without them.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button(hookState == .stale ? "Re-install" : "Install") {
                showingSettings = true
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var footer: some View {
        HStack {
            if !store.notifier.isAuthorized {
                Text("Notifications off").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Quit Perch") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func refreshHookState() {
        if !HookInstaller().isInstalled() { hookState = .missing }
        else if HookInstaller().isStale() { hookState = .stale }
        else { hookState = .installed }
    }
}
