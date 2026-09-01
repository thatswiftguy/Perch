import Foundation

/// Reads Claude Code's live-process registry, `<claude home>/sessions/<pid>.json`.
///
/// This is the authoritative answer to "which sessions exist right now". Hook events can
/// be missed — the app might have been closed, or the hooks not yet installed — but a
/// session cannot be running without a record here, and cannot have exited while one
/// still passes liveness validation.
public enum SessionRegistry {
    /// Every live interactive session, validated against the running process table.
    public static func sweep() -> [SessionRecord] {
        decodeAll().filter { $0.isAlive() }
    }

    /// Every record on disk, live or stale. Exposed for diagnostics, which want to report
    /// what was rejected as well as what survived.
    public static func decodeAll() -> [SessionRecord] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: Paths.sessionsDir, includingPropertiesForKeys: nil
        ) else { return [] }

        let decoder = JSONDecoder()
        return entries
            .filter { $0.pathExtension == "json" }   // skip the sibling 0600 .key files
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(SessionRecord.self, from: data)
            }
            // Only surface sessions a human is driving; daemons and background workers
            // have no progress worth watching.
            .filter { ($0.kind ?? "interactive") == "interactive" }
    }
}
