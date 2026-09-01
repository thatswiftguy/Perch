import Foundation
import Testing
@testable import PerchCore

@Suite struct SessionStateTests {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func event(_ kind: HookKind, _ fields: [String: JSONValue] = [:], at: Date? = nil) -> HookEvent {
        var payload: [String: JSONValue] = ["session_id": .string("s1"), "cwd": .string("/tmp/p")]
        payload.merge(fields) { _, new in new }
        return HookEvent(ts: (at ?? t0).timeIntervalSince1970, event: kind, payload: payload)
    }

    @Test func aPromptStartsATurn() {
        var runtime = SessionRuntime()
        runtime.apply(event(.userPromptSubmit, ["session_title": .string("Fix the parser")]))

        #expect(runtime.state.isWorking)
        #expect(runtime.title == "Fix the parser")
        #expect(runtime.turnStart == t0)
        #expect(runtime.turnToolCount == 0)
    }

    @Test func toolUseNamesWhatIsRunning() {
        var runtime = SessionRuntime()
        runtime.apply(event(.userPromptSubmit))
        runtime.apply(event(.preToolUse, [
            "tool_name": .string("Bash"),
            "tool_input": .object(["command": .string("npm test")]),
        ]))

        guard case .working(let tool, let detail, _) = runtime.state else {
            Issue.record("expected working, got \(runtime.state)"); return
        }
        #expect(tool == "Bash")
        #expect(detail == "npm test")
        #expect(runtime.turnToolCount == 1)
    }

    @Test func betweenToolsTheTurnClockKeepsRunning() {
        var runtime = SessionRuntime()
        runtime.apply(event(.userPromptSubmit))
        let later = t0.addingTimeInterval(30)
        runtime.apply(event(.preToolUse, ["tool_name": .string("Read")], at: later))
        runtime.apply(event(.postToolUse, ["tool_name": .string("Read")], at: later))

        // Elapsed should track the turn, not reset to zero every time a tool returns.
        #expect(runtime.state.since == t0)
        #expect(runtime.state.isWorking)
    }

    @Test func aPermissionPromptMeansBlockedNotBusy() {
        var runtime = SessionRuntime()
        runtime.apply(event(.userPromptSubmit))
        runtime.apply(event(.notification, [
            "notification_type": .string("permission_prompt"),
            "message": .string("Claude needs permission to run rm"),
        ]))

        #expect(runtime.state.isNeedsInput)
        // This is the whole reason hooks exist: nothing in the transcript distinguishes
        // this state from ordinary work.
        #expect(runtime.state.rank < SessionState.working(tool: nil, detail: nil, since: t0).rank)
    }

    @Test func anAgentQuestionAlsoBlocks() {
        var runtime = SessionRuntime()
        runtime.apply(event(.notification, ["notification_type": .string("agent_needs_input")]))
        guard case .needsInput(let reason, _) = runtime.state else {
            Issue.record("expected needsInput"); return
        }
        #expect(reason == .agentInput)
    }

    @Test func stopEndsTheTurnAndKeepsTheLastMessage() {
        var runtime = SessionRuntime()
        runtime.apply(event(.userPromptSubmit))
        runtime.apply(event(.stop, [
            "last_assistant_message": .string("Done — 3 files changed."),
            "background_tasks": .array([.string("a"), .string("b")]),
        ], at: t0.addingTimeInterval(90)))

        guard case .idle(let message, _) = runtime.state else {
            Issue.record("expected idle, got \(runtime.state)"); return
        }
        #expect(message == "Done — 3 files changed.")
        #expect(runtime.lastTurnDuration == 90)
        #expect(runtime.backgroundTasks == 2)
        #expect(runtime.turnStart == nil)
    }

    @Test func subagentActivityDoesNotDisturbTheParent() {
        var runtime = SessionRuntime()
        runtime.apply(event(.preToolUse, ["tool_name": .string("Task")]))
        let before = runtime.state

        // A subagent runs its own tool loop; folding it in would make one Task call look
        // like a storm of unrelated activity, and its Stop would look like the parent
        // finishing.
        runtime.apply(event(.preToolUse, [
            "tool_name": .string("Grep"), "agent_id": .string("agent-1"),
        ]))
        runtime.apply(event(.stop, ["agent_id": .string("agent-1")]))

        #expect(runtime.state == before)
    }

    @Test func aSubagentEventStillCountsAsActivity() {
        var runtime = SessionRuntime()
        let later = t0.addingTimeInterval(10)
        runtime.apply(event(.preToolUse, ["agent_id": .string("a"), "tool_name": .string("Read")], at: later))
        #expect(runtime.lastActivity == later)
    }

    @Test func blockedOutranksWorkingWhichOutranksIdle() {
        let ranks = [
            SessionState.needsInput(.permission, since: t0).rank,
            SessionState.working(tool: nil, detail: nil, since: t0).rank,
            SessionState.unknown.rank,
            SessionState.idle(lastMessage: nil, since: t0).rank,
        ]
        #expect(ranks == ranks.sorted())
    }

    @Test func unknownFieldsInAPayloadAreHarmless() {
        var runtime = SessionRuntime()
        // Claude Code adds hook fields between releases; a strict decoder would throw here
        // and the app would go blind.
        runtime.apply(event(.stop, [
            "some_future_field": .object(["nested": .array([.number(1)])]),
            "last_assistant_message": .string("ok"),
        ]))
        #expect(runtime.state.isIdle)
    }
}
