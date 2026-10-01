import Foundation

public enum Format {
    public static func elapsed(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 {
            let minutes = seconds / 60, trailing = seconds % 60
            return trailing == 0 ? "\(minutes)m" : "\(minutes)m \(trailing)s"
        }
        return String(format: "%dh %02dm", seconds / 3600, (seconds % 3600) / 60)
    }

    public static func ago(_ date: Date, now: Date = Date()) -> String {
        now.timeIntervalSince(date) < 5 ? "just now" : elapsed(since: date, now: now) + " ago"
    }

    public static func tokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return "\(count / 1000)k" }
        return "\(count)"
    }

    public static func firstLine(_ text: String) -> String {
        text.split(separator: "\n").first.map(String.init) ?? text
    }

    public static func truncate(_ text: String, to limit: Int = 52) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= limit ? trimmed : String(trimmed.prefix(limit - 1)) + "…"
    }
}
