import Foundation
import PerchCore

/// Incremental reader over the NDJSON spool that `perch-hook` appends to.
///
/// Polled rather than watched with a vnode source: the helper rotates the file in place,
/// so a watch would have to handle truncation, replacement and recreation anyway. A stat
/// plus a read of the delta, four times a second, costs less than that machinery.
final class EventSpool {
    private var offset: UInt64 = 0
    private var partial = Data()

    /// Events appended since the last call. Empty when nothing changed.
    func drain() -> [HookEvent] {
        let path = Paths.spool.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64 else { return [] }

        if size < offset {
            // The helper rotated the file. What remains is the recent tail, so re-reading
            // it from the top is correct — the last event per session is still the newest.
            offset = 0
            partial = Data()
        }
        guard size > offset else { return [] }

        guard let handle = try? FileHandle(forReadingFrom: Paths.spool) else { return [] }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        guard let chunk = try? handle.readToEnd(), !chunk.isEmpty else { return [] }
        offset = size

        var buffer = partial + chunk
        partial = Data()

        // A read can land mid-line; hold the remainder back until its newline arrives.
        if buffer.last != 0x0A, let lastNewline = buffer.lastIndex(of: 0x0A) {
            partial = buffer[buffer.index(after: lastNewline)...]
            buffer = buffer[..<buffer.index(after: lastNewline)]
        } else if buffer.last != 0x0A {
            partial = buffer
            return []
        }

        // Hooks are registered async so they never stall a session, which means the
        // helper processes can finish in a different order than Claude fired them — a
        // PostToolUse landing after the next PreToolUse would rewind the state machine.
        // Each event carries the time its hook ran, so sort by that.
        return HookEvent.decodeAll(from: buffer).sorted { $0.ts < $1.ts }
    }
}
