import AppKit
import PerchCore
import SwiftUI

@MainActor
enum IslandSnapshot {
    static var requestedDirectory: String? {
        ProcessInfo.processInfo.environment["PERCH_SNAPSHOT"]
    }

    private struct Case {
        let name: String
        let sessions: [Session]
        let isHovering: Bool
        let isDetached: Bool
    }

    static func run(into directory: String) {
        let attached = NotchGeometry.preferredScreen().map(NotchGeometry.init)
            ?? NotchGeometry(screen: NSScreen.screens[0])
        let detached = NotchGeometry(detachedLike: attached)

        for testCase in cases {
            let geometry = testCase.isDetached ? detached : attached
            let stage = SnapshotStage(geometry: geometry) {
                NotchIslandView(
                    sessions: testCase.sessions,
                    geometry: geometry,
                    isHovering: testCase.isHovering
                )
            }

            let renderer = ImageRenderer(content: stage)
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            else {
                Log.write("snapshot \(testCase.name) failed to render")
                continue
            }

            let url = URL(filePath: directory).appending(path: "\(testCase.name).png")
            try? png.write(to: url)
            Log.write("wrote \(url.lastPathComponent)")
        }
    }

    private static var cases: [Case] {
        [
            Case(name: "1-idle-hidden", sessions: [idle(minutesAgo: 40)],
                 isHovering: false, isDetached: false),
            Case(name: "2-working",
                 sessions: [working(tool: "Bash", detail: "swift test", secondsAgo: 72)],
                 isHovering: false, isDetached: false),
            Case(name: "3-working-many", sessions: [
                working(tool: "Edit", detail: "SessionStore.swift", secondsAgo: 8),
                working(tool: "Grep", detail: "notch", secondsAgo: 40),
                idle(minutesAgo: 3),
            ], isHovering: false, isDetached: false),
            Case(name: "4-needs-input",
                 sessions: [blocked(reason: .permission, secondsAgo: 14)],
                 isHovering: false, isDetached: false),
            Case(name: "5-finished", sessions: [idle(minutesAgo: 0)],
                 isHovering: false, isDetached: false),
            Case(name: "6-expanded", sessions: [
                blocked(reason: .permission, secondsAgo: 22),
                working(tool: "Bash", detail: "xcodebuild -scheme App", secondsAgo: 96),
                idle(minutesAgo: 4),
            ], isHovering: true, isDetached: false),
            Case(name: "7-expanded-empty", sessions: [], isHovering: true, isDetached: false),
            Case(name: "8-detached-working",
                 sessions: [working(tool: "Bash", detail: "npm run build", secondsAgo: 31)],
                 isHovering: false, isDetached: true),
            Case(name: "9-detached-expanded", sessions: [
                blocked(reason: .agentInput, secondsAgo: 5),
                working(tool: "Read", detail: "Package.swift", secondsAgo: 12),
            ], isHovering: true, isDetached: true),
        ]
    }

    private static func working(tool: String, detail: String, secondsAgo: TimeInterval) -> Session {
        session(
            named: "perch",
            state: .working(
                tool: tool, detail: detail, since: Date().addingTimeInterval(-secondsAgo)
            ),
            contextFraction: 0.42,
            branch: "main"
        )
    }

    private static func blocked(reason: NeedsInputReason, secondsAgo: TimeInterval) -> Session {
        session(
            named: "checkout-service",
            state: .needsInput(reason, since: Date().addingTimeInterval(-secondsAgo)),
            contextFraction: 0.91,
            branch: "feature/retry-policy"
        )
    }

    private static func idle(minutesAgo: Double) -> Session {
        session(
            named: "docs-site",
            state: .idle(
                lastMessage: "Refactored the parser and all tests pass.",
                since: Date().addingTimeInterval(-minutesAgo * 60)
            ),
            contextFraction: 0.17,
            branch: "main"
        )
    }

    private static func session(
        named name: String, state: SessionState, contextFraction: Double, branch: String
    ) -> Session {
        var runtime = SessionRuntime()
        runtime.state = state
        runtime.title = name

        let json = """
        {"pid":1,"sessionId":"\(UUID().uuidString)","cwd":"/Users/dev/\(name)","startedAt":0,
         "version":"2.1.247","kind":"interactive","entrypoint":"claude-desktop","name":"\(name)"}
        """
        let record = try! JSONDecoder().decode(SessionRecord.self, from: Data(json.utf8))

        return Session(
            record: record,
            runtime: runtime,
            stats: TranscriptStats.Snapshot(
                contextTokens: Int(200_000 * contextFraction),
                contextWindow: 200_000,
                model: "claude-opus-5",
                gitBranch: branch
            )
        )
    }
}

private struct SnapshotStage<Content: View>: View {
    let geometry: NotchGeometry
    @ViewBuilder let content: Content

    var body: some View {
        ZStack(alignment: .top) {
            Color(red: 0.18, green: 0.20, blue: 0.24)

            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.34).frame(height: geometry.topInset)
                    if geometry.isAttached {
                        Color.black.frame(width: geometry.notchWidth, height: geometry.topInset)
                    }
                }
                Spacer(minLength: 0)
            }

            content
        }
        .frame(width: NotchGeometry.hostWidth, height: NotchGeometry.hostHeight)
    }
}
