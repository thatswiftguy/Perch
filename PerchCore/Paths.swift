import Foundation

public enum Paths {
    public static let home = FileManager.default.homeDirectoryForCurrentUser

    /// Claude Code's configuration directory.
    ///
    /// Honours `CLAUDE_CONFIG_DIR`, which Claude Code itself supports for relocating this
    /// tree. Assuming `~/.claude` would leave Perch reading an empty directory — and
    /// silently showing no sessions — for anyone who sets it.
    public static var claudeHome: URL {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
           !override.isEmpty {
            return URL(filePath: (override as NSString).expandingTildeInPath)
        }
        return home.appending(path: ".claude")
    }

    /// Live-process registry: one `<pid>.json` per running session.
    public static var sessionsDir: URL { claudeHome.appending(path: "sessions") }
    /// User settings. The only file Perch ever writes to inside Claude's tree.
    public static var settings: URL { claudeHome.appending(path: "settings.json") }
    /// Per-project transcript directories.
    public static var projectsDir: URL { claudeHome.appending(path: "projects") }

    /// Perch's own state, kept outside Claude's tree so uninstalling never touches it.
    public static var appSupport: URL {
        home.appending(path: "Library/Application Support/Perch")
    }
    public static var spool: URL { appSupport.appending(path: "events.ndjson") }

    /// Absolute path to the hook helper. Hooks run without our environment, so the path
    /// written into settings.json has to be fully resolved.
    ///
    /// Derived from our own executable rather than from the bundle root, so it resolves
    /// correctly whether we're the app inside `Perch.app/Contents/MacOS/`, the helper
    /// itself, or a bare binary in `.build/release` during development.
    public static var hookExecutable: URL {
        let dir = Bundle.main.executableURL?.deletingLastPathComponent()
            ?? URL(filePath: CommandLine.arguments[0]).deletingLastPathComponent()
        return dir.appending(path: "perch-hook")
    }

    @discardableResult
    public static func ensureAppSupport() -> Bool {
        (try? FileManager.default.createDirectory(
            at: appSupport, withIntermediateDirectories: true)) != nil
    }

    /// Locate a session's transcript without waiting for a hook to report its path.
    ///
    /// Project directories are named after the cwd with `/` replaced by `-`, which is
    /// lossy — a directory whose own name contains `-` is ambiguous — so we search for the
    /// session-id filename rather than trying to reconstruct the folder name.
    public static func findTranscript(sessionId: String) -> String? {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: nil
        ) else { return nil }
        for dir in dirs {
            let candidate = dir.appending(path: "\(sessionId).jsonl")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate.path }
        }
        return nil
    }
}
