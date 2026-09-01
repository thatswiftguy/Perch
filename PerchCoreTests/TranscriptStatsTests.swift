import Foundation
import Testing
@testable import PerchCore

@Suite struct TranscriptStatsTests {
    private func fixture(_ lines: [String]) throws -> String {
        let url = URL(filePath: NSTemporaryDirectory())
            .appending(path: "perch-transcript-\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func assistant(
        input: Int, cacheWrite: Int, cacheRead: Int, output: Int = 100,
        model: String = "claude-opus-5", branch: String = "main"
    ) -> String {
        """
        {"type":"assistant","gitBranch":"\(branch)","message":{"model":"\(model)","role":"assistant",\
        "usage":{"input_tokens":\(input),"cache_creation_input_tokens":\(cacheWrite),\
        "cache_read_input_tokens":\(cacheRead),"output_tokens":\(output),\
        "iterations":[{"input_tokens":999999}]}}}
        """
    }

    @Test func contextCountsCachedTokensNotJustFreshInput() throws {
        // A turn resuming from cache reports input_tokens of ~2 and puts everything else
        // under the cache keys. Summing only input_tokens would show an empty context
        // window on a session that is actually nearly full.
        let path = try fixture([assistant(input: 2, cacheWrite: 13_481, cacheRead: 38_256)])
        let snapshot = try #require(TranscriptStats.read(path: path))

        #expect(snapshot.contextTokens == 51_739)
        #expect(snapshot.outputTokens == 100)
    }

    @Test func ignoresPerIterationUsage() throws {
        // `usage.iterations[]` repeats the same tokens per internal iteration; adding it
        // would multiply the count.
        let path = try fixture([assistant(input: 10, cacheWrite: 20, cacheRead: 30)])
        let snapshot = try #require(TranscriptStats.read(path: path))
        #expect(snapshot.contextTokens == 60)
    }

    @Test func readsTheMostRecentAssistantTurn() throws {
        let path = try fixture([
            assistant(input: 1, cacheWrite: 0, cacheRead: 999),
            #"{"type":"user","message":{"role":"user","content":"next"}}"#,
            assistant(input: 5, cacheWrite: 10, cacheRead: 20),
            #"{"type":"attachment","attachment":{"type":"total_tokens_reminder"}}"#,
        ])
        let snapshot = try #require(TranscriptStats.read(path: path))
        #expect(snapshot.contextTokens == 35)
    }

    @Test func longContextModelsGetTheLargerWindow() throws {
        let normal = try #require(TranscriptStats.read(
            path: try fixture([assistant(input: 100, cacheWrite: 0, cacheRead: 0)])))
        #expect(normal.contextWindow == 200_000)

        let long = try #require(TranscriptStats.read(
            path: try fixture([assistant(input: 100, cacheWrite: 0, cacheRead: 0, model: "claude-opus-5[1m]")])))
        #expect(long.contextWindow == 1_000_000)
        #expect(long.usedFraction == 0.0001)
    }

    @Test func picksUpTheGitBranch() throws {
        // Neither the registry record nor the hook payloads carry this.
        let path = try fixture([assistant(input: 1, cacheWrite: 0, cacheRead: 0, branch: "feature/parser")])
        #expect(try #require(TranscriptStats.read(path: path)).gitBranch == "feature/parser")
    }

    @Test func returnsNothingWhenThereIsNoAssistantTurnYet() throws {
        let path = try fixture([#"{"type":"user","message":{"role":"user","content":"hi"}}"#])
        #expect(TranscriptStats.read(path: path) == nil)
    }

    @Test func missingFileIsNotAnError() {
        #expect(TranscriptStats.read(path: "/nope/missing.jsonl") == nil)
    }

    @Test func usedFractionIsClamped() {
        let over = TranscriptStats.Snapshot(
            contextTokens: 500_000, contextWindow: 200_000, outputTokens: 0, model: nil, gitBranch: nil)
        #expect(over.usedFraction == 1)
    }
}

@Suite struct ContextWindowInferenceTests {
    private func transcript(context: Int, model: String) throws -> String {
        let url = URL(filePath: NSTemporaryDirectory())
            .appending(path: "perch-window-\(UUID().uuidString).jsonl")
        let line = """
        {"type":"assistant","message":{"model":"\(model)","role":"assistant",\
        "usage":{"input_tokens":2,"cache_creation_input_tokens":0,\
        "cache_read_input_tokens":\(context - 2),"output_tokens":1}}}
        """
        try (line + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    @Test func aSessionOverTwoHundredKMustBeOnTheLongContextModel() throws {
        // Observed on a real 1M session: message.model is the plain id, with nothing in
        // the transcript marking the larger window. Usage is the only available signal.
        let snapshot = try #require(TranscriptStats.read(
            path: try transcript(context: 339_318, model: "claude-opus-5")))
        #expect(snapshot.contextWindow == 1_000_000)
        #expect(snapshot.contextTokens == 339_318)
        #expect(snapshot.usedFraction < 1)
    }

    @Test func ordinarySessionsKeepTheStandardWindow() throws {
        let snapshot = try #require(try TranscriptStats.read(
            path: transcript(context: 151_360, model: "claude-opus-5")))
        #expect(snapshot.contextWindow == 200_000)
    }

    @Test func aTaggedModelIdIsTrustedBeforeTheInference() throws {
        let snapshot = try #require(try TranscriptStats.read(
            path: transcript(context: 50_000, model: "claude-opus-5[1m]")))
        #expect(snapshot.contextWindow == 1_000_000)
    }
}
