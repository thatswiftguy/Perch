import Foundation

/// One entry in Claude Code's live-process registry: `~/.claude/sessions/<pid>.json`.
///
/// Claude Code writes this at startup and rewrites it if `sessionId` or `cwd` change.
/// It is not a heartbeat — the mtime is registration time, so liveness must come from
/// `isAlive(startTimes:)` rather than from the file's age.
public struct SessionRecord: Codable, Sendable, Identifiable, Equatable {
    public let pid: Int32
    public let sessionId: String
    public let cwd: String
    public let startedAt: Double?      // epoch milliseconds
    public let procStart: String?      // verbatim `ps -o lstart=` output at registration
    public let version: String?
    public let kind: String?           // interactive | bg | daemon | daemon-worker
    public let entrypoint: String?
    public let name: String?

    public var id: String { sessionId }

    public var startDate: Date? {
        startedAt.map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    /// Human label for the session: its assigned name, else the project folder.
    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return projectName
    }

    public var projectName: String { URL(filePath: cwd).lastPathComponent }

    /// True if `pid` is still running *and* is still the same process we registered.
    ///
    /// The start-time check is what makes this safe: PIDs get recycled, and a bare
    /// `kill -0` would happily report a brand-new unrelated process as a live session.
    ///
    /// Note this deliberately ignores the record's `procStart` string. That field is the
    /// output of `ps -o lstart=` as captured by the Claude Code process, so it is rendered
    /// in *that* process's timezone — observed as UTC for desktop-launched sessions while
    /// a `ps` run from here renders local time. Comparing the strings marks every session
    /// dead. `startedAt` is an unambiguous epoch, so we compare against that instead.
    public func isAlive() -> Bool {
        guard let started = Proc.startTime(pid) else { return false }
        guard let registeredAt = startDate else { return true }

        // Registration happens moments after the process starts — measured at 0.5–0.9s.
        // A recycled PID would have to have launched inside this window to be mistaken
        // for the original.
        let delay = registeredAt.timeIntervalSince(started)
        return delay >= -5 && delay <= 120
    }
}

public enum Proc {
    /// Exact start time of a process, or nil if no such process is running.
    ///
    /// Asks the kernel directly rather than shelling out to `ps`: the answer is an
    /// absolute epoch with no timezone or locale in the path, and it costs one syscall,
    /// which matters when this runs for every session on every poll.
    public static func startTime(_ pid: Int32) -> Date? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride

        // For a dead PID sysctl still succeeds but writes nothing, so the size check —
        // not the return code — is what actually detects absence.
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }

        let started = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000)
    }
}
