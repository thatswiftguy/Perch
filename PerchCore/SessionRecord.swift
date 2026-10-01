import Foundation

public struct SessionRecord: Codable, Sendable, Identifiable, Equatable {
    public let pid: Int32
    public let sessionId: String
    public let cwd: String
    public let startedAt: Double?
    public let version: String?
    public let kind: String?
    public let entrypoint: String?
    public let name: String?

    public var id: String { sessionId }
    public var isInteractive: Bool { (kind ?? "interactive") == "interactive" }
    public var projectName: String { URL(filePath: cwd).lastPathComponent }
    public var startDate: Date? { startedAt.map { Date(timeIntervalSince1970: $0 / 1000) } }

    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return projectName
    }

    public var isAlive: Bool {
        guard let processStart = processStartTime(pid) else { return false }
        guard let registeredAt = startDate else { return true }
        let registrationDelay = registeredAt.timeIntervalSince(processStart)
        return registrationDelay >= -5 && registrationDelay <= 120
    }
}

private func processStartTime(_ pid: Int32) -> Date? {
    var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&query, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let started = info.kp_proc.p_starttime
    return Date(
        timeIntervalSince1970: Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
    )
}
