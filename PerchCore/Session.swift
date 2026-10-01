import Foundation

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

    public var title: String {
        if let title = runtime.title, !title.isEmpty { return title }
        return record.displayName
    }

    public var lastSeen: Date {
        runtime.lastActivity ?? record.startDate ?? .distantPast
    }
}

public extension Collection<Session> {
    var needsInputCount: Int { count(where: { $0.state.isNeedsInput }) }
    var workingCount: Int { count(where: { $0.state.isWorking }) }

    var activitySummary: String {
        var parts: [String] = []
        if needsInputCount > 0 { parts.append("\(needsInputCount) waiting") }
        if workingCount > 0 { parts.append("\(workingCount) working") }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        return isEmpty ? "" : "\(count) idle"
    }
}
