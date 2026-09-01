import Foundation
import Testing
@testable import PerchCore

@Suite struct FormatTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test(arguments: [
        (0.0, "0s"), (8.0, "8s"), (59.0, "59s"),
        (60.0, "1m"), (75.0, "1m 15s"), (3599.0, "59m 59s"),
        (3600.0, "1h 00m"), (7830.0, "2h 10m"),
    ])
    func elapsedReadsAsAGlance(seconds: Double, expected: String) {
        #expect(Format.elapsed(since: now.addingTimeInterval(-seconds), now: now) == expected)
    }

    @Test func elapsedNeverGoesNegative() {
        // Hook timestamps come from another process, so a little clock skew is possible
        // and "-3s" in the menu bar would look broken.
        #expect(Format.elapsed(since: now.addingTimeInterval(5), now: now) == "0s")
    }

    @Test func tokensAreRoundedForWidth() {
        #expect(Format.tokens(842) == "842")
        #expect(Format.tokens(151_360) == "151k")
        #expect(Format.tokens(1_000_000) == "1.0M")
    }

    @Test func truncateKeepsWithinBudget() {
        #expect(Format.truncate("short", to: 10) == "short")
        let long = Format.truncate(String(repeating: "x", count: 40), to: 10)
        #expect(long.count == 10)
        #expect(long.hasSuffix("…"))
    }

    @Test func truncateFlattensWhitespace() {
        #expect(Format.truncate("  spaced  ", to: 20) == "spaced")
    }
}
