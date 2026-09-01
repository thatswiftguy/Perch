import Foundation
import Testing
@testable import PerchCore

/// `settings.json` belongs to the user and may hold hand-written configuration, so these
/// tests care less about "did we add our hooks" than about "did we leave everything else
/// exactly as we found it".
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
        #expect(installer.isInstalled())
    }

    @Test func toolEventsCarryAMatcherAndOthersDoNot() throws {
        try write("{}")
        try installer.install()
        let hooks = try #require(try read()["hooks"])

        // An empty matcher means "every tool". Events without tools must not carry one.
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

        // An event we don't subscribe to must survive completely untouched.
        #expect(hooks["PreCompact"]?.arrayValue?.count == 1)
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
        #expect(installer.isInstalled())
        try installer.uninstall()

        #expect(try read() == before)
        #expect(!installer.isInstalled())
    }

    @Test func uninstallLeavesNoEmptyScaffolding() throws {
        try write("{}")
        try installer.install()
        try installer.uninstall()

        // No orphaned "hooks": {} — the file should look like we were never here.
        #expect(try read()["hooks"] == nil)
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
        #expect(!installer.isStale())

        // Simulate the user dragging Perch.app somewhere else.
        let moved = HookInstaller(settingsURL: settings, executable: "/Applications/Perch.app/Contents/MacOS/perch-hook")
        #expect(moved.isInstalled())
        #expect(moved.isStale())

        try moved.install()
        #expect(!moved.isStale())
    }

    @Test func refusesToTouchAFileItCannotParse() throws {
        let garbage = "{ this is not json"
        try write(garbage)

        #expect(throws: HookInstaller.InstallError.self) { try installer.install() }
        // The point of throwing: the user's file is still whatever it was.
        #expect(try String(contentsOf: settings, encoding: .utf8) == garbage)
    }

    @Test func writesOneBackupBeforeTheFirstEdit() throws {
        try write(#"{"skipWorkflowUsageWarning": true}"#)
        try installer.install()

        let backup = settings.appendingPathExtension("perch-backup")
        let contents = try String(contentsOf: backup, encoding: .utf8)
        #expect(contents.contains("skipWorkflowUsageWarning"))
        #expect(!contents.contains("perch-hook"), "backup must predate our changes")

        // A second edit must not overwrite the pristine copy with an already-modified one.
        try installer.uninstall()
        try installer.install()
        #expect(try String(contentsOf: backup, encoding: .utf8) == contents)
    }

    @Test func handlesAMissingSettingsFile() throws {
        #expect(!FileManager.default.fileExists(atPath: settings.path))
        try installer.install()
        #expect(installer.isInstalled())
    }
}

/// Installing must survive the shapes a real machine puts `settings.json` in.
@Suite struct HookInstallerEnvironmentTests {
    private func scratch() throws -> URL {
        let dir = URL(filePath: NSTemporaryDirectory())
            .appending(path: "perch-env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func createsTheConfigDirectoryOnAFreshMachine() throws {
        // Claude Code installed but never run: ~/.claude doesn't exist yet, and an
        // unguarded write fails with an error the user can't act on.
        let root = try scratch()
        let settings = root.appending(path: "nested/.claude/settings.json")
        let installer = HookInstaller(settingsURL: settings, executable: "/tmp/perch-hook")

        try installer.install()
        #expect(installer.isInstalled())
        #expect(FileManager.default.fileExists(atPath: settings.path))
    }

    @Test func writesThroughASymlinkInsteadOfReplacingIt() throws {
        // Developers routinely symlink settings.json into a dotfiles repo. An atomic write
        // to the link path would swap the link for a regular file and quietly detach it.
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

        // And the content must have landed on the real file behind it.
        let written = try String(contentsOf: real, encoding: .utf8)
        #expect(written.contains("perch-hook"))
        #expect(written.contains("skipWorkflowUsageWarning"))
    }
}
