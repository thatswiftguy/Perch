import Foundation
import Observation
import PerchCore

@MainActor
@Observable
final class SessionStore {
    private(set) var sessions: [Session] = []

    let preferences: Preferences
    let notifier: Notifier

    init(preferences: Preferences) {
        self.preferences = preferences
        self.notifier = Notifier(preferences: preferences)
    }

    private var records: [SessionRecord] = []
    private var runtimes: [String: SessionRuntime] = [:]
    private var stats: [String: TranscriptStats.Snapshot] = [:]
    private var statsInFlight = Set<String>()
    private let spool = EventSpool()
    private var timer: Timer?
    private var tick = 0

    // Cadence: the spool is a stat plus a short read, so it can run often. The registry
    // sweep shells out to `ps`, so it runs once a second.
    private let pollInterval = 0.25
    private let sweepEveryNTicks = 4

    var needsInputCount: Int { sessions.count(where: { $0.state.isNeedsInput }) }
    var workingCount: Int { sessions.count(where: { $0.state.isWorking }) }

    func start() {
        Paths.ensureAppSupport()

        // Replay whatever accumulated while Perch was closed, silently: these events are
        // history, and firing a burst of "finished" notifications for turns that ended
        // hours ago is exactly the wrong first impression.
        ingest(spool.drain(), notify: false)
        refresh()

        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { _ in
            Task { @MainActor in self.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        ingest(spool.drain(), notify: true)
        tick += 1
        if tick % sweepEveryNTicks == 0 {
            refresh()
        } else {
            rebuild()
        }
    }

    private func ingest(_ events: [HookEvent], notify: Bool) {
        guard !events.isEmpty else { return }

        for event in events {
            guard let sid = event.sessionId else { continue }
            var runtime = runtimes[sid] ?? SessionRuntime()
            let before = runtime.state
            runtime.apply(event)
            runtimes[sid] = runtime
            Log.debug("\(event.event.rawValue) \(sid.prefix(8)) -> \(runtime.state)")

            // Rotation makes us re-read the spool tail, so an old event can arrive twice.
            // Requiring freshness keeps that replay silent.
            let isFresh = event.date.timeIntervalSinceNow > -30
            if notify && isFresh {
                announce(sid, from: before, to: runtime.state, runtime: runtime)
            }

            if event.event == .stop || event.event == .postToolUse {
                refreshStats(sid, path: runtime.transcriptPath)
            }
        }
        rebuild()
    }

    /// Fire only on the two transitions a human actually cares about while away from the
    /// screen. In particular, `.idle` is announced only when arriving from `.working`, so
    /// a session that was already sitting idle at launch stays quiet.
    private func announce(
        _ sid: String, from before: SessionState, to after: SessionState, runtime: SessionRuntime
    ) {
        let name = runtimes[sid]?.title
            ?? records.first { $0.sessionId == sid }?.displayName
            ?? "Claude"

        switch (before, after) {
        case (_, .needsInput(let reason, _)) where !before.isNeedsInput:
            notifier.needsInput(session: name, reason: reason.label)
        case (.working, .idle(let message, _)):
            notifier.finished(
                session: name, message: message, backgroundTasks: runtime.backgroundTasks
            )
        default:
            break
        }
    }

    private func refresh() {
        records = SessionRegistry.sweep()
        let live = Set(records.map(\.sessionId))

        // The registry has the final say on existence. A session whose record is gone —
        // or whose PID was recycled — is dropped even if we never saw its SessionEnd.
        runtimes = runtimes.filter { live.contains($0.key) }
        stats = stats.filter { live.contains($0.key) }

        // Sessions that started before Perch did have no hook events yet, so nothing has
        // told us where their transcript is. Find it so their stats still fill in.
        for record in records where runtimes[record.sessionId]?.transcriptPath == nil {
            locateTranscript(record.sessionId)
        }
        rebuild()
    }

    private func rebuild() {
        let rebuilt = records
            .map {
                Session(
                    record: $0,
                    runtime: runtimes[$0.sessionId] ?? SessionRuntime(),
                    stats: stats[$0.sessionId]
                )
            }
            .sorted {
                if $0.state.rank != $1.state.rank { return $0.state.rank < $1.state.rank }
                let l = $0.runtime.lastActivity ?? $0.record.startDate ?? .distantPast
                let r = $1.runtime.lastActivity ?? $1.record.startDate ?? .distantPast
                if l != r { return l > r }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }

        // Assign only on real change. This runs four times a second; without the guard
        // every tick would invalidate the views and redraw the popover for nothing.
        if rebuilt != sessions { sessions = rebuilt }
    }

    private func locateTranscript(_ sid: String) {
        guard !statsInFlight.contains(sid) else { return }
        statsInFlight.insert(sid)
        Task.detached(priority: .utility) {
            let path = Paths.findTranscript(sessionId: sid)
            let snapshot = path.flatMap { TranscriptStats.read(path: $0) }
            await MainActor.run {
                self.statsInFlight.remove(sid)
                if let path {
                    var runtime = self.runtimes[sid] ?? SessionRuntime()
                    runtime.transcriptPath = path
                    self.runtimes[sid] = runtime
                }
                if let snapshot { self.stats[sid] = snapshot }
                self.rebuild()
            }
        }
    }

    private func refreshStats(_ sid: String, path: String?) {
        guard let path, !statsInFlight.contains(sid) else { return }
        statsInFlight.insert(sid)
        Task.detached(priority: .utility) {
            let snapshot = TranscriptStats.read(path: path)
            await MainActor.run {
                self.statsInFlight.remove(sid)
                if let snapshot {
                    self.stats[sid] = snapshot
                    self.rebuild()
                }
            }
        }
    }
}
