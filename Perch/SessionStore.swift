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
    private var statsLoading: Set<String> = []
    private let spool = EventSpool()
    private var timer: Timer?
    private var tick = 0

    private let pollInterval = 0.25
    private let ticksPerRegistrySweep = 4
    private let replayGracePeriod: TimeInterval = 30

    func start() {
        Paths.ensureAppSupport()
        ingest(spool.drain(), notify: false)
        sweepRegistry()

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
        if tick % ticksPerRegistrySweep == 0 { sweepRegistry() } else { rebuild() }
    }

    private func ingest(_ events: [HookEvent], notify: Bool) {
        guard !events.isEmpty else { return }

        for event in events {
            guard let id = event.sessionId else { continue }
            var runtime = runtimes[id] ?? SessionRuntime()
            let previousState = runtime.state
            runtime.apply(event)
            runtimes[id] = runtime
            Log.debug("\(event.event.rawValue) \(id.prefix(8)) -> \(runtime.state)")

            let isReplay = event.date.timeIntervalSinceNow < -replayGracePeriod
            if notify, !isReplay {
                announce(id, from: previousState, to: runtime.state, runtime: runtime)
            }
            if event.event == .stop || event.event == .postToolUse { loadStats(for: id) }
        }
        rebuild()
    }

    private func announce(
        _ id: String, from previous: SessionState, to current: SessionState,
        runtime: SessionRuntime
    ) {
        let name = runtime.title ?? records.first { $0.sessionId == id }?.displayName ?? "Claude"

        switch (previous, current) {
        case (_, .needsInput(let reason, _)) where !previous.isNeedsInput:
            notifier.needsInput(session: name, reason: reason.label)
        case (.working, .idle(let message, _)):
            notifier.finished(
                session: name, message: message, backgroundTasks: runtime.backgroundTasks
            )
        default:
            break
        }
    }

    private func sweepRegistry() {
        records = SessionRegistry.liveSessions()
        let live = Set(records.map(\.sessionId))

        runtimes = runtimes.filter { live.contains($0.key) }
        stats = stats.filter { live.contains($0.key) }

        for record in records where runtimes[record.sessionId]?.transcriptPath == nil {
            loadStats(for: record.sessionId)
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
            .sorted(by: Self.isOrderedBefore)

        if rebuilt != sessions { sessions = rebuilt }
    }

    private static func isOrderedBefore(_ lhs: Session, _ rhs: Session) -> Bool {
        if lhs.state.rank != rhs.state.rank { return lhs.state.rank < rhs.state.rank }
        if lhs.lastSeen != rhs.lastSeen { return lhs.lastSeen > rhs.lastSeen }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }

    private func loadStats(for id: String) {
        guard !statsLoading.contains(id) else { return }
        statsLoading.insert(id)
        let knownPath = runtimes[id]?.transcriptPath

        Task.detached(priority: .utility) {
            let path = knownPath ?? Paths.findTranscript(sessionId: id)
            let snapshot = path.flatMap { TranscriptStats.read(path: $0) }
            await MainActor.run { self.applyStats(for: id, path: path, snapshot: snapshot) }
        }
    }

    private func applyStats(
        for id: String, path: String?, snapshot: TranscriptStats.Snapshot?
    ) {
        statsLoading.remove(id)
        if let path { runtimes[id, default: SessionRuntime()].transcriptPath = path }
        if let snapshot { stats[id] = snapshot }
        rebuild()
    }
}
