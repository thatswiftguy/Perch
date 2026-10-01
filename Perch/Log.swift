import Foundation

enum Log {
    static let isDebug = ProcessInfo.processInfo.environment["PERCH_DEBUG"] == "1"

    static func write(_ message: String) {
        FileHandle.standardError.write(Data("perch: \(message)\n".utf8))
    }

    static func debug(_ message: @autoclosure () -> String) {
        guard isDebug else { return }
        write(message())
    }
}
