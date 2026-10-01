import Foundation

public enum Paths {
    public static let home = FileManager.default.homeDirectoryForCurrentUser

    public static var claudeHome: URL {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
           !override.isEmpty {
            return URL(filePath: (override as NSString).expandingTildeInPath)
        }
        return home.appending(path: ".claude")
    }

    public static var sessionsDirectory: URL { claudeHome.appending(path: "sessions") }
    public static var settings: URL { claudeHome.appending(path: "settings.json") }
    public static var projectsDirectory: URL { claudeHome.appending(path: "projects") }

    public static var appSupport: URL {
        home.appending(path: "Library/Application Support/Perch")
    }
    public static var spool: URL { appSupport.appending(path: "events.ndjson") }

    public static var hookExecutable: URL {
        let directory = Bundle.main.executableURL?.deletingLastPathComponent()
            ?? URL(filePath: CommandLine.arguments[0]).deletingLastPathComponent()
        return directory.appending(path: "perch-hook")
    }

    public static func ensureAppSupport() {
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
    }

    public static func findTranscript(sessionId: String) -> String? {
        guard let projects = try? FileManager.default.contentsOfDirectory(
            at: projectsDirectory, includingPropertiesForKeys: nil
        ) else { return nil }
        return projects
            .map { $0.appending(path: "\(sessionId).jsonl") }
            .first { FileManager.default.fileExists(atPath: $0.path) }?
            .path
    }
}
