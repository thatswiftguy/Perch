import AppKit
import PerchCore
import SwiftUI

/// Renders the island against a simulated notch and menu bar, off-screen, to PNG.
///
/// The island can't be screenshotted from outside the app without screen-recording
/// permission, and its states depend on live sessions that are awkward to stage on demand.
/// Rendering it directly makes the design reviewable — and catches things like text
/// colliding with the concave shoulders, which no unit test would.
///
/// Run with `PERCH_SNAPSHOT=<directory> /Applications/Perch.app/Contents/MacOS/Perch`.
@MainActor
enum IslandSnapshot {
    static var requestedDirectory: String? {
        ProcessInfo.processInfo.environment["PERCH_SNAPSHOT"]
    }

    static func run(into directory: String) {
        let geometry = NotchGeometry.preferredScreen().map(NotchGeometry.init)
            ?? NotchGeometry(screen: NSScreen.screens[0])
        let detached = NotchGeometry(detachedLike: geometry)

        let cases: [(String, [Session], Bool, NotchGeometry)] = [
            ("1-idle-hidden", [idle(minutesAgo: 40)], false, geometry),
            ("2-working", [working(tool: "Bash", detail: "swift test", seconds: 72)], false, geometry),
            ("3-working-many", [
                working(tool: "Edit", detail: "SessionStore.swift", seconds: 8),
                working(tool: "Grep", detail: "notch", seconds: 40),
                idle(minutesAgo: 3),
            ], false, geometry),
            ("4-needs-input", [blocked(reason: .permission, seconds: 14)], false, geometry),
            ("5-finished", [idle(minutesAgo: 0)], false, geometry),
            ("6-expanded", [
                blocked(reason: .permission, seconds: 22),
                working(tool: "Bash", detail: "xcodebuild -scheme App", seconds: 96),
                idle(minutesAgo: 4),
            ], true, geometry),
            ("7-expanded-empty", [], true, geometry),
            ("8-detached-working", [working(tool: "Bash", detail: "npm run build", seconds: 31)], false, detached),
            ("9-detached-expanded", [
                blocked(reason: .agentInput, seconds: 5),
                working(tool: "Read", detail: "Package.swift", seconds: 12),
            ], true, detached),
        ]

        Log.write("snapshot geometry: notch=\(geometry.notchWidth) inset=\(geometry.topInset) attached=\(geometry.isAttached) screens=\(NSScreen.screens.count) insets=\(NSScreen.screens.map(\.safeAreaInsets.top))")

        for (name, sessions, hovering, geo) in cases {
            let p = IslandPresentation.make(sessions: sessions, isHovering: hovering)
            Log.write("  \(name): mode=\(p.mode) kind=\(p.kind) primary=\(p.primary?.title ?? "nil")")
            let stage = SnapshotStage(geometry: geo) {
                NotchIslandView(sessions: sessions, geometry: geo, isHovering: hovering)
            }
            let renderer = ImageRenderer(content: stage)
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?
                    .representation(using: .png, properties: [:])
            else {
                Log.write("snapshot \(name) failed to render")
                continue
            }
            let url = URL(filePath: directory).appending(path: "\(name).png")
            try? png.write(to: url)
            Log.write("wrote \(url.lastPathComponent)")
        }
    }

    // MARK: - Synthetic sessions

    /// `SessionRecord`'s memberwise initialiser is internal to PerchCore, and it is only
    /// ever produced by decoding the registry, so staging one means decoding too.
    private static func record(_ name: String, _ path: String) -> SessionRecord {
        let json = """
        {"pid":1,"sessionId":"\(UUID().uuidString)","cwd":"\(path)","startedAt":0,
         "version":"2.1.247","kind":"interactive","entrypoint":"claude-desktop","name":"\(name)"}
        """
        return try! JSONDecoder().decode(SessionRecord.self, from: Data(json.utf8))
    }

    private static func stats(_ fraction: Double, branch: String) -> TranscriptStats.Snapshot {
        TranscriptStats.Snapshot(
            contextTokens: Int(200_000 * fraction), contextWindow: 200_000,
            outputTokens: 2_400, model: "claude-opus-5", gitBranch: branch
        )
    }

    private static func working(tool: String, detail: String, seconds: TimeInterval) -> Session {
        var runtime = SessionRuntime()
        runtime.state = .working(tool: tool, detail: detail, since: Date().addingTimeInterval(-seconds))
        runtime.title = "perch"
        return Session(record: record("perch", "/Users/dev/perch"), runtime: runtime,
                       stats: stats(0.42, branch: "main"))
    }

    private static func blocked(reason: NeedsInputReason, seconds: TimeInterval) -> Session {
        var runtime = SessionRuntime()
        runtime.state = .needsInput(reason, since: Date().addingTimeInterval(-seconds))
        runtime.title = "checkout-service"
        return Session(record: record("checkout-service", "/Users/dev/checkout-service"), runtime: runtime,
                       stats: stats(0.91, branch: "feature/retry-policy"))
    }

    private static func idle(minutesAgo: Double) -> Session {
        var runtime = SessionRuntime()
        runtime.state = .idle(
            lastMessage: "Refactored the parser and all tests pass.",
            since: Date().addingTimeInterval(-minutesAgo * 60)
        )
        runtime.title = "docs-site"
        return Session(record: record("docs-site", "/Users/dev/docs-site"), runtime: runtime,
                       stats: stats(0.17, branch: "main"))
    }
}

/// A fake desktop: wallpaper, menu bar, and the black cutout, so the blend can be judged.
private struct SnapshotStage<Content: View>: View {
    let geometry: NotchGeometry
    @ViewBuilder let content: Content

    var body: some View {
        ZStack(alignment: .top) {
            Color(red: 0.18, green: 0.20, blue: 0.24)

            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    // Translucent menu bar strip.
                    Color.black.opacity(0.34)
                        .frame(height: geometry.topInset)
                    if geometry.isAttached {
                        // The physical cutout: no pixels here on a real Mac.
                        Color.black
                            .frame(width: geometry.notchWidth, height: geometry.topInset)
                    }
                }
                Spacer(minLength: 0)
            }

            content
        }
        // Must match the island's own frame exactly. A shorter stage makes SwiftUI
        // centre the taller child and clip its top — which silently hides the compact
        // island altogether.
        .frame(width: NotchGeometry.hostWidth, height: NotchGeometry.hostHeight)
    }
}
