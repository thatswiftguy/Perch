import Foundation
import Testing
@testable import PerchCore

@Suite struct HookInstallerTests {
    let dir: URL
    let settings: URL
    let installer: HookInstaller

    init() throws {
        dir = URL(filePath: NSTemporaryDirectory())
            .appending(path: "perch-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        settings = dir.appending(path: "settings.json")
        installer = HookInstaller(settingsURL: settings, executable: "/Apps/Perch.app/Contents/MacOS/perch-hook")
    }

    private func write(_ json: String) throws {
        try json.write(to: settings, atomically: true, encoding: .utf8)
    }

    private func read() throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: settings))
    }

    @Test func installsEveryEventWeSubscribeTo() throws {
        try write("{}")
        try installer.install()

        let hooks = try #require(try read()["hooks"])
        for kind in HookKind.allCases {
            let groups = try #require(hooks[kind.rawValue]?.arrayValue, "missing \(kind.rawValue)")
            let commands = groups.flatMap { $0["hooks"]?.arrayValue ?? [] }
                .compactMap { $0["command"]?.stringValue }
            #expect(commands.contains("/Apps/Perch.app/Contents/MacOS/perch-hook \(kind.rawValue)"))
        }
        #expect(installer.status == .installed)
    }

    @Test func toolEventsCarryAMatcherAndOthersDoNot() throws {
        try write("{}")
        try installer.install()
        let hooks = try #require(try read()["hooks"])

        let preToolUse = try #require(hooks["PreToolUse"]?.arrayValue?.first)
        #expect(preToolUse["matcher"]?.stringValue == "")

        let stop = try #require(hooks["Stop"]?.arrayValue?.first)
        #expect(stop["matcher"] == nil)
    }

    @Test func hooksAreAsyncSoTheyNeverStallASession() throws {
        try write("{}")
        try installer.install()
        let hooks = try #require(try read()["hooks"])
        for kind in HookKind.allCases {
            let entries = (hooks[kind.rawValue]?.arrayValue ?? [])
                .flatMap { $0["hooks"]?.arrayValue ?? [] }
            #expect(entries.allSatisfy { $0["async"]?.boolValue == true }, "\(kind.rawValue) not async")
        }
    }

    @Test func preservesUnrelatedSettings() throws {
        try write(#"{"skipWorkflowUsageWarning": true, "model": "opus", "env": {"FOO": "bar"}}"#)
        try installer.install()

        let after = try read()
        #expect(after["skipWorkflowUsageWarning"]?.boolValue == true)
        #expect(after["model"]?.stringValue == "opus")
        #expect(after["env"]?["FOO"]?.stringValue == "bar")
    }

    @Test func preservesTheUsersOwnHooks() throws {
        try write("""
        {"hooks": {
          "PreToolUse": [{"matcher": "Bash",
            "hooks": [{"type": "command", "command": "my-audit-log.sh"}]}],
          "PreCompact": [{"hooks": [{"type": "command", "command": "notify-me.sh"}]}]
        }}
        """)
        try installer.install()

        let hooks = try #require(try read()["hooks"])
        let preToolCommands = (hooks["PreToolUse"]?.arrayValue ?? [])
            .flatMap { $0["hooks"]?.arrayValue ?? [] }
            .compactMap { $0["command"]?.stringValue }
        #expect(preToolCommands.contains("my-audit-log.sh"))
        #expect(preToolCommands.contains { $0.contains("perch-hook") })

        #expect(hooks["PreCompact"]?.arrayValue?.count == 1,
                "an event we do not subscribe to must survive untouched")
    }

    @Test func uninstallRestoresTheOriginalExactly() throws {
        let original = """
        {"hooks": {
          "PreToolUse": [{"matcher": "Bash",
            "hooks": [{"type": "command", "command": "my-audit-log.sh"}]}]
        }, "skipWorkflowUsageWarning": true}
        """
        try write(original)
        let before = try read()

        try installer.install()
        #expect(installer.status == .installed)
        try installer.uninstall()

        #expect(try read() == before)
        #expect(installer.status == .missing)
    }

    @Test func uninstallLeavesNoEmptyScaffolding() throws {
        try write("{}")
        try installer.install()
        try installer.uninstall()

        #expect(try read()["hooks"] == nil, "no orphaned scaffolding may be left behind")
    }

    @Test func installingTwiceDoesNotDuplicateEntries() throws {
        try write("{}")
        try installer.install()
        try installer.install()

        let hooks = try #require(try read()["hooks"])
        for kind in HookKind.allCases {
            let ours = (hooks[kind.rawValue]?.arrayValue ?? [])
                .flatMap { $0["hooks"]?.arrayValue ?? [] }
                .filter { $0["command"]?.stringValue?.contains("perch-hook") ?? false }
            #expect(ours.count == 1, "\(kind.rawValue) has \(ours.count) Perch entries")
        }
    }

    @Test func detectsHooksPointingAtAnOldCopyOfTheApp() throws {
        try write("{}")
        try installer.install()
        #expect(installer.status == .installed)

        let moved = HookInstaller(settingsURL: settings, executable: "/Applications/Perch.app/Contents/MacOS/perch-hook")
        #expect(moved.status == .stale)

        try moved.install()
        #expect(moved.status == .installed)
    }

    @Test func refusesToTouchAFileItCannotParse() throws {
        let garbage = "{ this is not json"
        try write(garbage)

        #expect(throws: HookInstaller.InstallError.self) { try installer.install() }
        #expect(try String(contentsOf: settings, encoding: .utf8) == garbage,
                "the user's file must be left exactly as it was")
    }

    @Test func writesOneBackupBeforeTheFirstEdit() throws {
        try write(#"{"skipWorkflowUsageWarning": true}"#)
        try installer.install()

        let backup = settings.appendingPathExtension("perch-backup")
        let contents = try String(contentsOf: backup, encoding: .utf8)
        #expect(contents.contains("skipWorkflowUsageWarning"))
        #expect(!contents.contains("perch-hook"), "backup must predate our changes")

        try installer.uninstall()
        try installer.install()
        #expect(try String(contentsOf: backup, encoding: .utf8) == contents,
                "a later edit must not overwrite the pristine backup")
    }

    @Test func handlesAMissingSettingsFile() throws {
        #expect(!FileManager.default.fileExists(atPath: settings.path))
        try installer.install()
        #expect(installer.status == .installed)
    }
}

@Suite struct HookInstallerEnvironmentTests {
    private func scratch() throws -> URL {
        let dir = URL(filePath: NSTemporaryDirectory())
            .appending(path: "perch-env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func createsTheConfigDirectoryOnAFreshMachine() throws {
        let root = try scratch()
        let settings = root.appending(path: "nested/.claude/settings.json")
        let installer = HookInstaller(settingsURL: settings, executable: "/tmp/perch-hook")

        try installer.install()
        #expect(installer.status == .installed)
        #expect(FileManager.default.fileExists(atPath: settings.path))
    }

    @Test func writesThroughASymlinkInsteadOfReplacingIt() throws {
        let root = try scratch()
        let real = root.appending(path: "dotfiles-settings.json")
        try #"{"skipWorkflowUsageWarning": true}"#.write(to: real, atomically: true, encoding: .utf8)

        let link = root.appending(path: "settings.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let installer = HookInstaller(settingsURL: link, executable: "/tmp/perch-hook")
        try installer.install()

        let attributes = try FileManager.default.attributesOfItem(atPath: link.path)
        #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink,
                "the symlink must survive the write")

        let written = try String(contentsOf: real, encoding: .utf8)
        #expect(written.contains("perch-hook"))
        #expect(written.contains("skipWorkflowUsageWarning"))
    }
}
