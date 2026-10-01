import Darwin
import Foundation
import PerchCore

let maxSpoolBytes = 8 * 1024 * 1024
let bytesKeptOnRotate = 2 * 1024 * 1024

func exitQuietly() -> Never { exit(0) }

func runMaintenance(_ command: String) {
    switch command {
    case "--doctor":
        Doctor.run()
        exit(0)
    case "--install", "--uninstall":
        let installer = HookInstaller()
        let installing = command == "--install"
        do {
            try installing ? installer.install() : installer.uninstall()
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
        print("\(installing ? "Installed" : "Removed") Perch hooks in \(Paths.settings.path)")
        if installing { print("Helper: \(Paths.hookExecutable.path)") }
        exit(0)
    default:
        return
    }
}

func rotateIfOversized(_ fileDescriptor: Int32) {
    guard let size = try? FileManager.default
        .attributesOfItem(atPath: Paths.spool.path)[.size] as? Int,
        size > maxSpoolBytes,
        let handle = try? FileHandle(forReadingFrom: Paths.spool)
    else { return }

    try? handle.seek(toOffset: UInt64(size - bytesKeptOnRotate))
    var tail = (try? handle.readToEnd()) ?? Data()
    try? handle.close()

    if let firstNewline = tail.firstIndex(of: 0x0A) {
        tail = tail[tail.index(after: firstNewline)...]
    }
    _ = tail.withUnsafeBytes { pwrite(fileDescriptor, $0.baseAddress, tail.count, 0) }
    ftruncate(fileDescriptor, off_t(tail.count))
    lseek(fileDescriptor, 0, SEEK_END)
}

func append(_ line: Data) {
    Paths.ensureAppSupport()

    let fileDescriptor = open(Paths.spool.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    guard fileDescriptor >= 0 else { exitQuietly() }
    defer { close(fileDescriptor) }

    guard flock(fileDescriptor, LOCK_EX) == 0 else { exitQuietly() }
    defer { flock(fileDescriptor, LOCK_UN) }

    rotateIfOversized(fileDescriptor)
    _ = line.withUnsafeBytes { write(fileDescriptor, $0.baseAddress, line.count) }
}

guard CommandLine.arguments.count > 1 else { exitQuietly() }
runMaintenance(CommandLine.arguments[1])

guard let kind = HookKind(rawValue: CommandLine.arguments[1]) else { exitQuietly() }

let stdinData = FileHandle.standardInput.readDataToEndOfFile()
guard !stdinData.isEmpty,
      let payload = try? JSONDecoder().decode([String: JSONValue].self, from: stdinData)
else { exitQuietly() }

let encoder = JSONEncoder()
encoder.outputFormatting = [.withoutEscapingSlashes]
let event = HookEvent(ts: Date().timeIntervalSince1970, event: kind, payload: payload)
guard var line = try? encoder.encode(event) else { exitQuietly() }
line.append(0x0A)

append(line)
exitQuietly()
