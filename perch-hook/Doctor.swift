import Foundation
import PerchCore

enum Doctor {
    static func run() {
        let installer = HookInstaller()
        print("Perch doctor\n")
        print("hook helper   \(Paths.hookExecutable.path)")
        print("settings      \(Paths.settings.path)")
        print("hooks         \(describe(installer.status))")
        print("spool         \(Paths.spool.path) (\(spoolSize()))")

        let records = SessionRegistry.liveSessions()
        print("\nlive sessions \(records.count)")
        for record in records { describe(record) }

        let events = HookEvent.readSpool()
        print("\nspool events  \(events.count)")
        for event in events.suffix(8) { describe(event) }

        print("\nderived state")
        let runtimes = replay(events)
        if records.isEmpty { print("  (no live sessions)") }
        for record in records {
            let name = record.displayName.padding(toLength: 20, withPad: " ", startingAt: 0)
            print("  \(name) \(runtimes[record.sessionId]?.state ?? .unknown)")
        }
    }

    private static func replay(_ events: [HookEvent]) -> [String: SessionRuntime] {
        var runtimes: [String: SessionRuntime] = [:]
        for event in events {
            guard let id = event.sessionId else { continue }
            runtimes[id, default: SessionRuntime()].apply(event)
        }
        return runtimes
    }

    private static func describe(_ status: HookStatus) -> String {
        switch status {
        case .installed: "installed"
        case .stale: "installed (STALE PATH)"
        case .missing: "NOT installed"
        }
    }

    private static func spoolSize() -> String {
        let size = try? FileManager.default.attributesOfItem(atPath: Paths.spool.path)[.size] as? Int
        return size.map { "\($0) bytes" } ?? "absent"
    }

    private static func describe(_ record: SessionRecord) {
        print("  • \(record.displayName)  [\(record.sessionId.prefix(8))]  pid \(record.pid)")
        print("    cwd        \(record.cwd)")
        print("    kind       \(record.kind ?? "?")   "
              + "entrypoint \(record.entrypoint ?? "?")   v\(record.version ?? "?")")

        guard let path = Paths.findTranscript(sessionId: record.sessionId) else {
            print("    transcript not found")
            return
        }
        guard let stats = TranscriptStats.read(path: path) else {
            print("    context    no assistant turn yet")
            return
        }
        print("    context    \(stats.contextTokens) / \(stats.contextWindow) "
              + "(\(Int(stats.usedFraction * 100))%)  "
              + "model \(stats.model ?? "?")  branch \(stats.gitBranch ?? "?")")
    }

    private static func describe(_ event: HookEvent) {
        let stamp = event.date.formatted(date: .omitted, time: .standard)
        let id = event.sessionId.map { String($0.prefix(8)) } ?? "?"
        var line = "  \(stamp)  \(id)  \(event.event.rawValue)"
        if let tool = event.toolName { line += " \(tool)" }
        if let type = event.notificationType { line += " [\(type)]" }
        print(line)
    }
}
