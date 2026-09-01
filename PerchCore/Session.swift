import Foundation

/// One session as the UI sees it: identity from the registry, behavior from hooks,
/// numbers from the transcript.
public struct Session: Identifiable, Equatable, Sendable {
    public let record: SessionRecord
    public let runtime: SessionRuntime
    public let stats: TranscriptStats.Snapshot?

    public init(
        record: SessionRecord, runtime: SessionRuntime, stats: TranscriptStats.Snapshot?
    ) {
        self.record = record
        self.runtime = runtime
        self.stats = stats
    }

    public var id: String { record.sessionId }
    public var state: SessionState { runtime.state }

    /// Prefer the title Claude assigned to the work over the folder name.
    public var title: String {
        if let t = runtime.title, !t.isEmpty { return t }
        return record.displayName
    }
}
