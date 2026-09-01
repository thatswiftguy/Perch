import Foundation

public enum Format {
    /// Compact elapsed time: 8s, 4m 20s, 1h 03m. Tuned for a menu bar row where the
    /// number is scanned, not read.
    public static func elapsed(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 {
            let m = seconds / 60, s = seconds % 60
            return s == 0 ? "\(m)m" : "\(m)m \(s)s"
        }
        let h = seconds / 3600, m = (seconds % 3600) / 60
        return String(format: "%dh %02dm", h, m)
    }

    public static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 5 { return "just now" }
        return elapsed(since: date, now: now) + " ago"
    }

    public static func tokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            return "\(count / 1000)k"
        }
        return "\(count)"
    }

    /// Trims a command or path to something that fits one line without wrapping.
    public static func truncate(_ s: String, to limit: Int = 52) -> String {
        let flat = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count <= limit ? flat : String(flat.prefix(limit - 1)) + "…"
    }
}
