import Foundation
import PerchCore

final class EventSpool {
    private var offset: UInt64 = 0
    private var partialLine = Data()

    func drain() -> [HookEvent] {
        guard let size = spoolSize() else { return [] }

        if size < offset {
            offset = 0
            partialLine = Data()
        }
        guard size > offset else { return [] }

        guard let handle = try? FileHandle(forReadingFrom: Paths.spool) else { return [] }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        guard let chunk = try? handle.readToEnd(), !chunk.isEmpty else { return [] }
        offset = size

        var buffer = partialLine + chunk
        partialLine = Data()

        if buffer.last != 0x0A {
            guard let lastNewline = buffer.lastIndex(of: 0x0A) else {
                partialLine = buffer
                return []
            }
            partialLine = buffer[buffer.index(after: lastNewline)...]
            buffer = buffer[..<buffer.index(after: lastNewline)]
        }

        return HookEvent.decodeAll(from: buffer).sorted { $0.ts < $1.ts }
    }

    private func spoolSize() -> UInt64? {
        try? FileManager.default.attributesOfItem(atPath: Paths.spool.path)[.size] as? UInt64
    }
}
