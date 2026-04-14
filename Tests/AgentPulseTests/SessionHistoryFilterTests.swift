import Testing
@testable import AgentPulseLib

struct SessionHistoryFilterTests {
    // MARK: - Helpers

    private func session(
        status: String = "done",
        summary: String? = nil,
        pid: Int? = nil,
        lastMessage: String? = nil
    ) -> Session {
        Session(name: "test", status: status, updatedAt: 1000, summary: summary, pid: pid, lastMessage: lastMessage)
    }

    private func entry(id: String, summary: String = "test") -> HistoryEntry {
        HistoryEntry(symbol: "●", directory: "/test", summary: summary, sessionId: id, startedAt: 900, endedAt: 1000)
    }

    // MARK: - Group A: shouldRecordToHistory core

    @Test("Normal exit: real summary, dead PID → recorded")
    func normalExit() {
        let s = session(summary: "Fix auth bug")
        #expect(shouldRecordToHistory(session: s, sessionId: "s1", existingIds: [], pidAlive: false))
    }

    @Test("/clear: PID still alive → NOT recorded")
    func clearPidAlive() {
        let s = session(summary: "Fix auth bug")
        #expect(!shouldRecordToHistory(session: s, sessionId: "s1", existingIds: [], pidAlive: true))
    }

    @Test("Nil summary → NOT recorded")
    func nilSummary() {
        let s = session(summary: nil)
        #expect(!shouldRecordToHistory(session: s, sessionId: "s1", existingIds: [], pidAlive: false))
    }

    @Test(
        "Placeholder summaries are NOT recorded",
        arguments: ["Session started", "Process ended", "Processing...", "Needs permission", "Finished"]
    )
    func placeholderSummary(summary: String) {
        let s = session(summary: summary)
        #expect(!shouldRecordToHistory(session: s, sessionId: "s1", existingIds: [], pidAlive: false))
    }

    @Test("Ghost session: placeholder + dead PID → NOT recorded")
    func ghostSessionDeadPid() {
        let s = session(summary: "Process ended", pid: 999999)
        #expect(!shouldRecordToHistory(session: s, sessionId: "s1", existingIds: [], pidAlive: false))
    }

    @Test("No PID field → treated as dead → recorded if real summary")
    func noPidField() {
        let s = session(summary: "Implement OAuth", pid: nil)
        #expect(shouldRecordToHistory(session: s, sessionId: "s1", existingIds: [], pidAlive: false))
    }

    @Test("Real summary with lastMessage → recorded")
    func realSummaryWithLastMessage() {
        let s = session(summary: "Fix auth bug", lastMessage: "I've fixed the authentication...")
        #expect(shouldRecordToHistory(session: s, sessionId: "s1", existingIds: [], pidAlive: false))
    }

    // MARK: - Group B: Dedup via existingIds

    @Test("Fresh session not yet in history → recorded")
    func freshSession() {
        let s = session(summary: "real work")
        #expect(shouldRecordToHistory(session: s, sessionId: "abc", existingIds: [], pidAlive: false))
    }

    @Test("Same sessionId already recorded → blocked")
    func sameIdBlocked() {
        let s = session(summary: "real work")
        #expect(!shouldRecordToHistory(session: s, sessionId: "abc", existingIds: ["abc"], pidAlive: false))
    }

    @Test("Different sessionId in history → allowed")
    func differentIdAllowed() {
        let s = session(summary: "real work")
        #expect(shouldRecordToHistory(session: s, sessionId: "abc", existingIds: ["xyz"], pidAlive: false))
    }

    @Test("Both paths fire: first recorded, second blocked by dedup")
    func bothPathsFireDedup() {
        let s = session(summary: "real work")
        let first = shouldRecordToHistory(session: s, sessionId: "abc", existingIds: [], pidAlive: false)
        let second = shouldRecordToHistory(session: s, sessionId: "abc", existingIds: ["abc"], pidAlive: false)
        #expect(first == true)
        #expect(second == false)
    }

    // MARK: - Group C: Reaper path composition

    @Test("Reaper: running + dead PID → preserves real summary → recorded")
    func reaperRunningDeadPid() {
        let input: [String: Session] = ["s1": session(status: "running", summary: "real work", pid: 999999)]
        let reaped = reapStaleSessions(input)
        // Reaper marks it done but preserves the real summary
        #expect(reaped["s1"]?.status == "done")
        #expect(reaped["s1"]?.summary == "real work")
        // Real summary → recorded to history
        let record = shouldRecordToHistory(session: reaped["s1"]!, sessionId: "s1", existingIds: [], pidAlive: false)
        #expect(record)
    }

    @Test("Reaper: running + dead PID + placeholder summary → 'Process ended'")
    func reaperRunningDeadPidPlaceholder() {
        let input: [String: Session] = ["s1": session(status: "running", summary: "Session started", pid: 999999)]
        let reaped = reapStaleSessions(input)
        #expect(reaped["s1"]?.status == "done")
        #expect(reaped["s1"]?.summary == "Process ended")
        let record = shouldRecordToHistory(session: reaped["s1"]!, sessionId: "s1", existingIds: [], pidAlive: false)
        #expect(!record)
    }

    @Test("Reaper: done + real summary + dead PID → removed → recorded")
    func reaperDoneRealSummaryDeadPid() {
        let input: [String: Session] = ["s1": session(status: "done", summary: "Implemented OAuth", pid: 999999)]
        let reaped = reapStaleSessions(input)
        // Reaper removes done sessions with dead PIDs
        #expect(reaped["s1"] == nil)
        // Using original session data for history recording
        let record = shouldRecordToHistory(session: input["s1"]!, sessionId: "s1", existingIds: [], pidAlive: false)
        #expect(record)
    }

    @Test("Reaper: waiting + dead PID → 'Process ended' → NOT recorded")
    func reaperWaitingDeadPid() {
        let input: [String: Session] = ["s1": session(status: "waiting", summary: "Needs permission", pid: 999999)]
        let reaped = reapStaleSessions(input)
        #expect(reaped["s1"]?.status == "done")
        #expect(reaped["s1"]?.summary == "Process ended")
        let record = shouldRecordToHistory(session: reaped["s1"]!, sessionId: "s1", existingIds: [], pidAlive: false)
        #expect(!record)
    }

    // MARK: - Group D: placeholderSummaries constant

    @Test("placeholderSummaries contains exactly 5 expected strings")
    func placeholderConstant() {
        let expected: Set<String> = ["Session started", "Process ended", "Processing...", "Needs permission", "Finished"]
        #expect(placeholderSummaries == expected)
    }

    @Test("Case-sensitive: lowercase not matched")
    func caseSensitive() {
        #expect(!placeholderSummaries.contains("process ended"))
        #expect(!placeholderSummaries.contains("FINISHED"))
    }

    @Test("Whitespace variants not matched")
    func whitespaceNotMatched() {
        #expect(!placeholderSummaries.contains(" Finished"))
        #expect(!placeholderSummaries.contains("Finished "))
    }

    // MARK: - Group E: applyHistoryEntry array logic

    @Test("First entry to empty list")
    func firstEntryEmpty() {
        let e = entry(id: "s1")
        let result = applyHistoryEntry(e, to: [])
        #expect(result.count == 1)
        #expect(result[0].sessionId == "s1")
    }

    @Test("New entry prepended before existing")
    func prependedBeforeExisting() {
        let e1 = entry(id: "s1")
        let e2 = entry(id: "s2")
        let result = applyHistoryEntry(e2, to: [e1])
        #expect(result[0].sessionId == "s2")
        #expect(result[1].sessionId == "s1")
    }

    @Test("Dedup: same sessionId → unchanged")
    func dedupSameId() {
        let e = entry(id: "s1")
        let result = applyHistoryEntry(e, to: [e])
        #expect(result.count == 1)
    }

    @Test("Dedup: same sessionId at different position → unchanged")
    func dedupDifferentPosition() {
        let e1 = entry(id: "s1")
        let e2 = entry(id: "s2")
        let e3 = entry(id: "s3")
        let existing = [e2, e1, e3]
        let result = applyHistoryEntry(e1, to: existing)
        #expect(result.count == 3)
    }

    @Test("50th entry fits within max")
    func fiftiethEntryFits() {
        let existing = (0..<49).map { entry(id: "s\($0)") }
        let result = applyHistoryEntry(entry(id: "s49"), to: existing)
        #expect(result.count == 50)
    }

    @Test("51st entry drops the oldest")
    func fiftyFirstDropsOldest() {
        let existing = (0..<50).map { entry(id: "s\($0)") }
        let result = applyHistoryEntry(entry(id: "s50"), to: existing)
        #expect(result.count == 50)
        #expect(result[0].sessionId == "s50")
        #expect(result.last?.sessionId == "s48")
    }

    @Test("Custom maxEntries respected")
    func customMaxEntries() {
        let existing = (0..<5).map { entry(id: "s\($0)") }
        let result = applyHistoryEntry(entry(id: "s5"), to: existing, maxEntries: 5)
        #expect(result.count == 5)
        #expect(result[0].sessionId == "s5")
        #expect(result.last?.sessionId == "s3")
    }
}
