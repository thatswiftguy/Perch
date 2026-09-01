import Foundation

/// Derives token/context numbers by reading the tail of a session's `.jsonl` transcript.
///
/// This is the only local source for these numbers. `~/.claude/telemetry/` looks like the
/// obvious place but is a failed-upload retry spool — it carries no token or cost data at
/// all, and building on it would silently produce nothing.
public enum TranscriptStats {
    public struct Snapshot: Equatable, Sendable {
        public var contextTokens: Int
        public var contextWindow: Int
        public var outputTokens: Int
        public var model: String?
        public var gitBranch: String?

        public init(
            contextTokens: Int, contextWindow: Int, outputTokens: Int,
            model: String?, gitBranch: String?
        ) {
            self.contextTokens = contextTokens
            self.contextWindow = contextWindow
            self.outputTokens = outputTokens
            self.model = model
            self.gitBranch = gitBranch
        }

        public var usedFraction: Double {
            guard contextWindow > 0 else { return 0 }
            return min(1, Double(contextTokens) / Double(contextWindow))
        }
    }

    private static let tailBytes: UInt64 = 512 * 1024
    private static let maxLinesScanned = 60

    /// Reads backwards to the most recent `assistant` line and reports its usage.
    /// Nil when the transcript has no assistant turn yet.
    ///
    /// Call this off the main thread — it touches the filesystem.
    public static func read(path: String) -> Snapshot? {
        guard let handle = try? FileHandle(forReadingFrom: URL(filePath: path)) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }

        let start = size > tailBytes ? size - tailBytes : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }

        var lines: [Data] = data.split(separator: UInt8(0x0A)).map { Data($0) }
        // Slicing mid-file usually cuts the first record in half.
        if start > 0, !lines.isEmpty { lines.removeFirst() }

        let decoder = JSONDecoder()
        for line in lines.suffix(maxLinesScanned).reversed() {
            guard let entry = try? decoder.decode(JSONValue.self, from: line),
                  entry["type"]?.stringValue == "assistant",
                  let message = entry["message"],
                  let usage = message["usage"] else { continue }

            // Cache reads and writes are real context occupancy — a turn resuming from
            // cache reports input_tokens of ~2 and the rest under the cache keys, so
            // summing only input_tokens would show an essentially empty context window.
            // Deliberately ignores `usage.iterations[]`, which double-counts these.
            let fresh: Int = usage["input_tokens"]?.intValue ?? 0
            let written: Int = usage["cache_creation_input_tokens"]?.intValue ?? 0
            let read: Int = usage["cache_read_input_tokens"]?.intValue ?? 0
            let context: Int = fresh + written + read

            let model = message["model"]?.stringValue
            return Snapshot(
                contextTokens: context,
                contextWindow: windowSize(for: model, context: context),
                outputTokens: usage["output_tokens"]?.intValue ?? 0,
                model: model,
                // Carried on every transcript line; neither the registry record nor the
                // hook payloads include it.
                gitBranch: entry["gitBranch"]?.stringValue
            )
        }
        return nil
    }

    /// Which context window this session is running against.
    ///
    /// Transcripts do not record it. `message.model` is the plain id — a verified 1M
    /// session logs `claude-opus-5`, identical to a 200k one — and no `betas` or window
    /// field is written either. So the size is inferred from usage: a session holding
    /// more than 200k tokens is definitionally not on the 200k model.
    ///
    /// The `[1m]` check still runs first because other surfaces (statusline, telemetry)
    /// do tag the id. The inference is only a fallback, and it under-reports a long-context
    /// session until it crosses 200k — at which point it corrects itself.
    private static func windowSize(for model: String?, context: Int) -> Int {
        if model?.contains("[1m]") ?? false { return 1_000_000 }
        return context > 200_000 ? 1_000_000 : 200_000
    }
}
