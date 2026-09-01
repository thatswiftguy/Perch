import Foundation
import PerchCore

/// Read-only diagnostics: prints exactly what Perch sees, so a menu bar showing nothing
/// can be traced to a missing registry entry, missing hooks, or an empty spool.
enum Doctor {
    static func run() {
        print("Perch doctor\n")

        let installer = HookInstaller()
        print("hook helper   \(Paths.hookExecutable.path)")
        print("settings      \(Paths.settings.path)")
        print("hooks         \(installer.isInstalled() ? (installer.isStale() ? "installed (STALE PATH)" : "installed") : "NOT installed")")

        let spoolSize = (try? FileManager.default
            .attributesOfItem(atPath: Paths.spool.path)[.size] as? Int) ?? nil
        print("spool         \(Paths.spool.path) (\(spoolSize.map { "\($0) bytes" } ?? "absent"))")

        let records = SessionRegistry.sweep()
        print("\nlive sessions \(records.count)")
        for record in records {
            print("  • \(record.displayName)  [\(record.sessionId.prefix(8))]  pid \(record.pid)")
            print("    cwd        \(record.cwd)")
            print("    kind       \(record.kind ?? "?")   entrypoint \(record.entrypoint ?? "?")   v\(record.version ?? "?")")
            if let path = Paths.findTranscript(sessionId: record.sessionId) {
                if let s = TranscriptStats.read(path: path) {
                    let pct = Int(s.usedFraction * 100)
                    print("    context    \(s.contextTokens) / \(s.contextWindow) (\(pct)%)  model \(s.model ?? "?")  branch \(s.gitBranch ?? "?")")
                } else {
                    print("    context    no assistant turn yet")
                }
            } else {
                print("    transcript not found")
            }
        }

        let events = HookEvent.readSpool()
        print("\nspool events  \(events.count)")
        for event in events.suffix(8) {
            let stamp = event.date.formatted(date: .omitted, time: .standard)
            let who = event.sessionId.map { String($0.prefix(8)) } ?? "?"
            var line = "  \(stamp)  \(who)  \(event.event.rawValue)"
            if let tool = event.toolName { line += " \(tool)" }
            if let type = event.notificationType { line += " [\(type)]" }
            print(line)
        }

        // Fold the events through the same state machine the app uses, so the reported
        // state is the app's, not a second implementation that could disagree.
        var runtimes: [String: SessionRuntime] = [:]
        for event in events {
            guard let sid = event.sessionId else { continue }
            var runtime = runtimes[sid] ?? SessionRuntime()
            runtime.apply(event)
            runtimes[sid] = runtime
        }
        print("\nderived state")
        if records.isEmpty { print("  (no live sessions)") }
        for record in records {
            let state = runtimes[record.sessionId]?.state ?? .unknown
            print("  \(record.displayName.padding(toLength: 20, withPad: " ", startingAt: 0)) \(describe(state))")
        }
    }

    private static func describe(_ state: SessionState) -> String {
        switch state {
        case .unknown: "unknown (no events)"
        case .working(let tool, let detail, _):
            "working" + (tool.map { " · \($0)" } ?? "") + (detail.map { " · \($0)" } ?? "")
        case .needsInput(let reason, _): "NEEDS INPUT · \(reason.label)"
        case .idle(let message, _): "idle" + (message.map { " · \($0.prefix(50))" } ?? "")
        }
    }
}
