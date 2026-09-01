import Foundation

/// Installs and removes Perch's entries in `~/.claude/settings.json`.
///
/// That file belongs to the user and may already contain unrelated settings and their own
/// hooks, so every operation here is a read-modify-write that preserves anything it does
/// not recognise. Perch's own entries are identified by `perch-hook` appearing in the
/// command, which makes uninstall exact rather than best-effort.
public struct HookInstaller {
    public enum InstallError: LocalizedError {
        case unreadable(String)
        case malformed
        case unwritable(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let s): "Couldn't read settings.json: \(s)"
            case .malformed: "settings.json isn't a JSON object — leaving it untouched."
            case .unwritable(let s): "Couldn't write settings.json: \(s)"
            }
        }
    }

    public static let marker = "perch-hook"

    /// The settings file to edit and the helper path to bake into it. Both are injected
    /// so the merge logic can be tested against a scratch file instead of the user's own
    /// settings.
    let settingsURL: URL
    let executable: String

    public init(
        settingsURL: URL = Paths.settings,
        executable: String = Paths.hookExecutable.path
    ) {
        self.settingsURL = settingsURL
        self.executable = executable
    }

    // MARK: - Status

    public func isInstalled() -> Bool {
        guard let settings = try? load(), let hooks = settings["hooks"] else { return false }
        return HookKind.allCases.allSatisfy { kind in
            (hooks[kind.rawValue]?.arrayValue ?? []).contains { group in
                (group["hooks"]?.arrayValue ?? []).contains {
                    $0["command"]?.stringValue?.contains(Self.marker) ?? false
                }
            }
        }
    }

    /// True when hooks are installed but point at a different copy of the app — after
    /// moving Perch to /Applications, say. The stale path silently stops reporting, so
    /// the UI needs to be able to offer a re-install.
    public func isStale() -> Bool {
        guard isInstalled(), let settings = try? load(), let hooks = settings["hooks"] else {
            return false
        }
        let expected = executable
        for kind in HookKind.allCases {
            for group in hooks[kind.rawValue]?.arrayValue ?? [] {
                for hook in group["hooks"]?.arrayValue ?? [] {
                    guard let command = hook["command"]?.stringValue,
                          command.contains(Self.marker) else { continue }
                    if !command.hasPrefix(expected) { return true }
                }
            }
        }
        return false
    }

    // MARK: - Mutation

    public func install() throws {
        var settings = try load()

        var hooks: [String: JSONValue] = {
            if case .object(let existing)? = settings["hooks"] { return existing }
            return [:]
        }()

        for kind in HookKind.allCases {
            // Drop any previous Perch entry first so re-installing after a move replaces
            // the stale path instead of stacking a second copy on top of it.
            var groups = stripPerch(from: hooks[kind.rawValue]?.arrayValue ?? [])

            var hook: [String: JSONValue] = [
                "type": .string("command"),
                "command": .string("\(executable) \(kind.rawValue)"),
                // Fire-and-forget: Perch only observes, and a monitor must never add
                // latency to the session it is monitoring.
                "async": .bool(true),
            ]
            if kind.needsMatcher { hook["timeout"] = .number(5) }

            var group: [String: JSONValue] = ["hooks": .array([.object(hook)])]
            // An empty matcher matches every tool. Events without tools take no matcher.
            if kind.needsMatcher { group["matcher"] = .string("") }

            groups.append(.object(group))
            hooks[kind.rawValue] = .array(groups)
        }

        settings["hooks"] = .object(hooks)
        try save(settings)
    }

    public func uninstall() throws {
        var settings = try load()
        guard case .object(var hooks)? = settings["hooks"] else { return }

        for kind in HookKind.allCases {
            guard let groups = hooks[kind.rawValue]?.arrayValue else { continue }
            let cleaned = stripPerch(from: groups)
            // Leave no empty scaffolding behind: the file should end up byte-comparable
            // to how we found it.
            if cleaned.isEmpty {
                hooks.removeValue(forKey: kind.rawValue)
            } else {
                hooks[kind.rawValue] = .array(cleaned)
            }
        }

        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = .object(hooks)
        }
        try save(settings)
    }

    /// Removes Perch's hook entries from a matcher-group list, dropping any group whose
    /// hooks all belonged to us while preserving the user's own entries in shared groups.
    private func stripPerch(from groups: [JSONValue]) -> [JSONValue] {
        groups.compactMap { group -> JSONValue? in
            guard case .object(var fields) = group,
                  let hooks = fields["hooks"]?.arrayValue else { return group }
            let kept = hooks.filter { !($0["command"]?.stringValue?.contains(Self.marker) ?? false) }
            if kept.isEmpty { return nil }
            fields["hooks"] = .array(kept)
            return .object(fields)
        }
    }

    // MARK: - File IO

    private func load() throws -> [String: JSONValue] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data: Data
        do { data = try Data(contentsOf: settingsURL) }
        catch { throw InstallError.unreadable(error.localizedDescription) }
        guard !data.isEmpty else { return [:] }
        guard let object = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
            throw InstallError.malformed
        }
        return object
    }

    private func save(_ settings: [String: JSONValue]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(settings) else { throw InstallError.malformed }

        // Keep one backup beside the original before the first modification, so there is
        // always a way back to the user's hand-written file.
        let backup = settingsURL.appendingPathExtension("perch-backup")
        if FileManager.default.fileExists(atPath: settingsURL.path),
           !FileManager.default.fileExists(atPath: backup.path) {
            try? FileManager.default.copyItem(at: settingsURL, to: backup)
        }

        // An atomic write replaces the path with a fresh file, which would silently
        // destroy a symlink — and developers routinely symlink settings.json into a
        // dotfiles repo. Resolve first so the write lands on the real file.
        let target = settingsURL.resolvingSymlinksInPath()

        // A machine where Claude Code has never run has no config directory yet, and the
        // write would fail with an error the user can do nothing about.
        try? FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        do {
            // Atomic: a half-written settings.json would break every future session.
            try data.write(to: target, options: .atomic)
        } catch {
            throw InstallError.unwritable(error.localizedDescription)
        }
    }
}
