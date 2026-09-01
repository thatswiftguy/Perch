import Darwin
import Foundation
import PerchCore

// perch-hook <EventName>
//
// Claude Code pipes the hook payload in on stdin. We stamp it, append one NDJSON line
// to the spool, and get out. This runs inside the user's session on every tool call, so
// two rules govern everything below:
//
//   1. Be fast. No network, no parsing beyond the payload itself.
//   2. Never fail loudly. Every path exits 0 — a broken monitor must not break the
//      session it is monitoring.

let maxSpoolBytes = 8 * 1024 * 1024
let keepOnRotate = 2 * 1024 * 1024

func finish() -> Never { exit(0) }

guard CommandLine.arguments.count > 1 else { finish() }

// Maintenance subcommands. `--doctor` is read-only; the other two are the same
// settings.json edit the Settings panel performs, exposed for headless setup.
switch CommandLine.arguments[1] {
case "--doctor":
    Doctor.run()
    exit(0)
case "--install", "--uninstall":
    let installing = CommandLine.arguments[1] == "--install"
    do {
        let installer = HookInstaller()
        try installing ? installer.install() : installer.uninstall()
        print("\(installing ? "Installed" : "Removed") Perch hooks in \(Paths.settings.path)")
        if installing { print("Helper: \(Paths.hookExecutable.path)") }
        print("Restart any running Claude Code sessions to pick this up.")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(1)
    }
default:
    break
}

guard let kind = HookKind(rawValue: CommandLine.arguments[1]) else { finish() }

let stdinData = FileHandle.standardInput.readDataToEndOfFile()
guard !stdinData.isEmpty,
      let payload = try? JSONDecoder().decode([String: JSONValue].self, from: stdinData)
else { finish() }

let event = HookEvent(ts: Date().timeIntervalSince1970, event: kind, payload: payload)

let encoder = JSONEncoder()
encoder.outputFormatting = [.withoutEscapingSlashes]
guard var line = try? encoder.encode(event) else { finish() }
line.append(0x0A)  // JSONEncoder emits no newlines of its own, so one line per event.

Paths.ensureAppSupport()

let fd = open(Paths.spool.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
guard fd >= 0 else { finish() }
defer { close(fd) }

// A hook payload can exceed PIPE_BUF, so O_APPEND alone does not guarantee an atomic
// write and concurrent sessions could interleave halves of two lines. The lock is what
// makes "one event per line" actually true.
guard flock(fd, LOCK_EX) == 0 else { finish() }
defer { flock(fd, LOCK_UN) }

// Rotate under the same lock, keeping the tail: the app rebuilds state by replaying the
// spool at launch, so recent history is worth more than a simple truncate-to-zero.
if let size = (try? FileManager.default.attributesOfItem(atPath: Paths.spool.path)[.size]) as? Int,
   size > maxSpoolBytes,
   let handle = try? FileHandle(forReadingFrom: Paths.spool) {
    let start = size - keepOnRotate
    try? handle.seek(toOffset: UInt64(start))
    var tail = (try? handle.readToEnd()) ?? Data()
    try? handle.close()
    // Drop the partial first line left by slicing mid-record.
    if let nl = tail.firstIndex(of: 0x0A) { tail = tail[tail.index(after: nl)...] }
    _ = tail.withUnsafeBytes { pwrite(fd, $0.baseAddress, tail.count, 0) }
    ftruncate(fd, off_t(tail.count))
    lseek(fd, 0, SEEK_END)
}

_ = line.withUnsafeBytes { write(fd, $0.baseAddress, line.count) }
finish()
