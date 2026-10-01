import Foundation

public enum TranscriptStats {
    public struct Snapshot: Equatable, Sendable {
        public var contextTokens: Int
        public var contextWindow: Int
        public var model: String?
        public var gitBranch: String?

        public init(contextTokens: Int, contextWindow: Int, model: String?, gitBranch: String?) {
            self.contextTokens = contextTokens
            self.contextWindow = contextWindow
            self.model = model
            self.gitBranch = gitBranch
        }

        public var usedFraction: Double {
            guard contextWindow > 0 else { return 0 }
            return min(1, Double(contextTokens) / Double(contextWindow))
        }

        public var isNearlyFull: Bool { usedFraction > 0.85 }
    }

    private static let tailBytes: UInt64 = 512 * 1024
    private static let maxLinesScanned = 60
    private static let standardWindow = 200_000
    private static let longWindow = 1_000_000

    public static func read(path: String) -> Snapshot? {
        guard let lines = tailLines(of: path) else { return nil }
        let decoder = JSONDecoder()

        for line in lines.suffix(maxLinesScanned).reversed() {
            guard let entry = try? decoder.decode(JSONValue.self, from: line),
                  entry["type"]?.stringValue == "assistant",
                  let message = entry["message"],
                  let usage = message["usage"] else { continue }

            let contextTokens = (usage["input_tokens"]?.intValue ?? 0)
                + (usage["cache_creation_input_tokens"]?.intValue ?? 0)
                + (usage["cache_read_input_tokens"]?.intValue ?? 0)
            let model = message["model"]?.stringValue

            return Snapshot(
                contextTokens: contextTokens,
                contextWindow: contextWindow(for: model, holding: contextTokens),
                model: model,
                gitBranch: entry["gitBranch"]?.stringValue
            )
        }
        return nil
    }

    private static func tailLines(of path: String) -> [Data]? {
        guard let handle = try? FileHandle(forReadingFrom: URL(filePath: path)) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }

        let start = size > tailBytes ? size - tailBytes : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }

        var lines = data.split(separator: UInt8(0x0A)).map { Data($0) }
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    private static func contextWindow(for model: String?, holding tokens: Int) -> Int {
        if model?.contains("[1m]") ?? false { return longWindow }
        return tokens > standardWindow ? longWindow : standardWindow
    }
}
