import Foundation
import Testing
@testable import PerchCore

@Suite struct IslandPresentationTests {
    private func session(_ title: String, _ state: SessionState) -> Session {
        var runtime = SessionRuntime()
        runtime.state = state
        runtime.title = title
        let json = """
        {"pid":1,"sessionId":"\(UUID().uuidString)","cwd":"/tmp/\(title)","kind":"interactive"}
        """
        let record = try! JSONDecoder().decode(SessionRecord.self, from: Data(json.utf8))
        return Session(record: record, runtime: runtime, stats: nil)
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    @Test func nothingRunningMeansNothingShown() {
        let p = IslandPresentation.make(sessions: [], isHovering: false, now: now)
        #expect(p.mode == .hidden)
    }

    @Test func aLongIdleSessionIsNotWorthShowing() {
        let idle = session("api", .idle(lastMessage: "done", since: ago(3600)))
        #expect(IslandPresentation.make(sessions: [idle], isHovering: false, now: now).mode == .hidden)
    }

    @Test func aJustFinishedTurnIsAcknowledgedBriefly() {
        let done = session("api", .idle(lastMessage: "all tests pass", since: ago(2)))
        let p = IslandPresentation.make(sessions: [done], isHovering: false, now: now)
        #expect(p.mode == .compact)
        #expect(p.kind == .finished)
    }

    @Test func theAcknowledgementTimesItselfOut() {
        let justOver = IslandPresentation.finishedLinger + 1
        let done = session("api", .idle(lastMessage: "done", since: ago(justOver)))
        #expect(IslandPresentation.make(sessions: [done], isHovering: false, now: now).mode == .hidden)
    }

    @Test func blockedOutranksWorkingForTheOneVisibleSlot() {
        let sessions = [
            session("blocked", .needsInput(.permission, since: ago(5))),
            session("busy", .working(tool: "Bash", detail: "npm test", since: ago(90))),
        ]
        let p = IslandPresentation.make(sessions: sessions, isHovering: false, now: now)
        #expect(p.kind == .needsInput)
        #expect(p.primary?.title == "blocked")
        #expect(p.extraActive == 1)
    }

    @Test func workingBeatsAFinishedTurn() {
        let sessions = [
            session("busy", .working(tool: "Edit", detail: nil, since: ago(3))),
            session("done", .idle(lastMessage: "ok", since: ago(1))),
        ]
        let p = IslandPresentation.make(sessions: sessions, isHovering: false, now: now)
        #expect(p.kind == .working)
        #expect(p.primary?.title == "busy")
    }

    @Test func otherActiveSessionsAreCountedNotListed() {
        let sessions = (0..<4).map { session("s\($0)", .working(tool: "Bash", detail: nil, since: ago(10))) }
        let p = IslandPresentation.make(sessions: sessions, isHovering: false, now: now)
        #expect(p.extraActive == 3)
    }

    @Test func hoveringAQuietMachineConfirmsItIsQuiet() {
        let p = IslandPresentation.make(sessions: [], isHovering: true, now: now)
        #expect(p.mode == .expanded)
        #expect(p.sessions.isEmpty)
    }

    @Test func hoveringExpandsEvenWhenTheIslandWasHidden() {
        let idle = session("api", .idle(lastMessage: "done", since: ago(3600)))
        #expect(IslandPresentation.make(sessions: [idle], isHovering: true, now: now).mode == .expanded)
    }

    @Test func everySessionSurvivesIntoTheExpandedList() {
        let sessions = [
            session("a", .needsInput(.permission, since: ago(1))),
            session("b", .working(tool: "Bash", detail: nil, since: ago(2))),
            session("c", .idle(lastMessage: nil, since: ago(999))),
        ]
        let p = IslandPresentation.make(sessions: sessions, isHovering: true, now: now)
        #expect(p.sessions.count == 3)
    }
}
