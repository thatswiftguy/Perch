import PerchCore
import SwiftUI

struct PopoverView: View {
    let store: SessionStore

    @State private var showingSettings = false
    @State private var hookStatus = HookInstaller().status

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if hookStatus != .installed {
                setupBanner
                Divider()
            }

            if showingSettings {
                SettingsView(store: store, hookStatus: $hookStatus)
            } else if store.sessions.isEmpty {
                emptyState
            } else {
                sessionList
            }

            Divider()
            footer
        }
        .frame(width: 380)
        .onAppear { hookStatus = HookInstaller().status }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bird.fill").foregroundStyle(.tint)
            Text("Perch").font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(store.sessions.activitySummary)
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

    private var setupBanner: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(hookStatus == .stale
                     ? "Hooks point at an old copy of Perch"
                     : "Hooks aren't installed")
                    .font(.system(size: 12, weight: .medium))
                Text(hookStatus == .stale
                     ? "Re-install them so status keeps updating."
                     : "Perch can list sessions, but can't tell working from waiting without them.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button(hookStatus == .stale ? "Re-install" : "Install") { showingSettings = true }
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
}
