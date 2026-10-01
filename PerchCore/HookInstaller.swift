import Foundation

public enum HookStatus: Sendable {
    case missing
    case stale
    case installed
}

public struct HookInstaller {
    public enum InstallError: LocalizedError {
        case unreadable(String)
        case malformed
        case unwritable(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let reason): "Couldn't read settings.json: \(reason)"
            case .malformed: "settings.json isn't a JSON object — leaving it untouched."
            case .unwritable(let reason): "Couldn't write settings.json: \(reason)"
            }
        }
    }

    private static let marker = "perch-hook"

    let settingsURL: URL
    let executable: String

    public init(
        settingsURL: URL = Paths.settings,
        executable: String = Paths.hookExecutable.path
    ) {
        self.settingsURL = settingsURL
        self.executable = executable
    }

    public var status: HookStatus {
        guard let hooks = (try? load())?["hooks"] else { return .missing }
        var pointsAtAnotherCopy = false

        for kind in HookKind.allCases {
            let ours = commands(in: hooks[kind.rawValue]).filter { $0.contains(Self.marker) }
            if ours.isEmpty { return .missing }
            if ours.contains(where: { !$0.hasPrefix(executable) }) { pointsAtAnotherCopy = true }
        }
        return pointsAtAnotherCopy ? .stale : .installed
    }

    public func install() throws {
        var settings = try load()
        var hooks = settings["hooks"].flatMap(asObject) ?? [:]

        for kind in HookKind.allCases {
            var groups = withoutPerchEntries(in: hooks[kind.rawValue]?.arrayValue ?? [])

            var hook: [String: JSONValue] = [
                "type": .string("command"),
                "command": .string("\(executable) \(kind.rawValue)"),
                "async": .bool(true),
            ]
            var group: [String: JSONValue] = [:]
            if kind.needsMatcher {
                hook["timeout"] = .number(5)
                group["matcher"] = .string("")
            }
            group["hooks"] = .array([.object(hook)])

            groups.append(.object(group))
            hooks[kind.rawValue] = .array(groups)
        }

        settings["hooks"] = .object(hooks)
        try save(settings)
    }

    public func uninstall() throws {
        var settings = try load()
        guard var hooks = settings["hooks"].flatMap(asObject) else { return }

        for kind in HookKind.allCases {
            guard let groups = hooks[kind.rawValue]?.arrayValue else { continue }
            let remaining = withoutPerchEntries(in: groups)
            if remaining.isEmpty {
                hooks.removeValue(forKey: kind.rawValue)
            } else {
                hooks[kind.rawValue] = .array(remaining)
            }
        }

        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = .object(hooks)
        }
        try save(settings)
    }

    private func asObject(_ value: JSONValue) -> [String: JSONValue]? {
        if case .object(let fields) = value { return fields }
        return nil
    }

    private func commands(in groups: JSONValue?) -> [String] {
        (groups?.arrayValue ?? [])
            .flatMap { $0["hooks"]?.arrayValue ?? [] }
            .compactMap { $0["command"]?.stringValue }
    }

    private func isPerchHook(_ hook: JSONValue) -> Bool {
        hook["command"]?.stringValue?.contains(Self.marker) ?? false
    }

    private func withoutPerchEntries(in groups: [JSONValue]) -> [JSONValue] {
        groups.compactMap { group in
            guard case .object(var fields) = group,
                  let hooks = fields["hooks"]?.arrayValue else { return group }
            let kept = hooks.filter { !isPerchHook($0) }
            if kept.isEmpty { return nil }
            fields["hooks"] = .array(kept)
            return .object(fields)
        }
    }

    private func load() throws -> [String: JSONValue] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data: Data
        do { data = try Data(contentsOf: settingsURL) }
        catch { throw InstallError.unreadable(error.localizedDescription) }

        guard !data.isEmpty else { return [:] }
        guard let settings = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
            throw InstallError.malformed
        }
        return settings
    }

    private func save(_ settings: [String: JSONValue]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(settings) else { throw InstallError.malformed }

        backUpOnce()

        let target = settingsURL.resolvingSymlinksInPath()
        try? FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        do {
            try data.write(to: target, options: .atomic)
        } catch {
            throw InstallError.unwritable(error.localizedDescription)
        }
    }

    private func backUpOnce() {
        let backup = settingsURL.appendingPathExtension("perch-backup")
        guard FileManager.default.fileExists(atPath: settingsURL.path),
              !FileManager.default.fileExists(atPath: backup.path) else { return }
        try? FileManager.default.copyItem(at: settingsURL, to: backup)
    }
}
