/// Tests for session sort-key logic.
///
/// Sessions sort into three tiers: pinned (0) > attention (1) > running (2).
/// Within each tier, sessions sort by timestamp — but WHICH timestamp depends
/// on the tier: attention uses updatedAt, running uses startedAt.

import Foundation
import Testing
@testable import AgentPulseLib

struct SortOrderTests {

    // MARK: - Helpers

    private func session(status: String, startedAt: TimeInterval = 1000, updatedAt: TimeInterval = 1000) -> Session {
        Session(name: "test", status: status, updatedAt: updatedAt, startedAt: startedAt)
    }

    private func pair(_ key: String, status: String, startedAt: TimeInterval = 1000, updatedAt: TimeInterval = 1000) -> (key: String, value: Session) {
        (key: key, value: session(status: status, startedAt: startedAt, updatedAt: updatedAt))
    }

    // MARK: - Tier membership

    @Test("Pinned sorts before unpinned")
    func pinnedBeforeUnpinned() {
        let now = Date().timeIntervalSince1970
        var items = [
            pair("unpinned", status: "running", startedAt: now),
            pair("pinned", status: "running", startedAt: now),
        ]
        items = sortedByPriority(items, pinnedSessions: ["pinned"])
        #expect(items[0].key == "pinned")
        #expect(items[1].key == "unpinned")
    }

    @Test("Waiting is attention tier, sorts before running")
    func waitingIsAttentionTier() {
        let now = Date().timeIntervalSince1970
        var items = [
            pair("running1", status: "running", startedAt: now),
            pair("waiting1", status: "waiting", updatedAt: now),
        ]
        items = sortedByPriority(items, pinnedSessions: [])
        #expect(items[0].key == "waiting1")
        #expect(items[1].key == "running1")
    }

    @Test("Done is attention tier, sorts before running")
    func doneIsAttentionTier() {
        let now = Date().timeIntervalSince1970
        var items = [
            pair("running1", status: "running", startedAt: now),
            pair("done1", status: "done", updatedAt: now),
        ]
        items = sortedByPriority(items, pinnedSessions: [])
        #expect(items[0].key == "done1")
        #expect(items[1].key == "running1")
    }

    @Test("Pinned trumps attention tier")
    func pinnedTrumpsAttention() {
        let now = Date().timeIntervalSince1970
        var items = [
            pair("unpinned_waiting", status: "waiting", updatedAt: now),
            pair("pinned_done", status: "done", updatedAt: now),
        ]
        items = sortedByPriority(items, pinnedSessions: ["pinned_done"])
        #expect(items[0].key == "pinned_done")
    }

    // MARK: - Timestamp selection

    @Test("Running tier sorts by startedAt, not updatedAt")
    func runningTierSortsByStartedAt() {
        var items = [
            pair("run_later", status: "running", startedAt: 2000, updatedAt: 100),
            pair("run_earlier", status: "running", startedAt: 1000, updatedAt: 9000),
        ]
        items = sortedByPriority(items, pinnedSessions: [])
        #expect(items[0].key == "run_earlier")
        #expect(items[1].key == "run_later")
    }

    @Test("Attention tier sorts by updatedAt, not startedAt")
    func attentionTierSortsByUpdatedAt() {
        var items = [
            pair("wait_later", status: "waiting", startedAt: 100, updatedAt: 2000),
            pair("wait_earlier", status: "waiting", startedAt: 9000, updatedAt: 1000),
        ]
        items = sortedByPriority(items, pinnedSessions: [])
        #expect(items[0].key == "wait_earlier")
        #expect(items[1].key == "wait_later")
    }

    @Test("Ascending timestamp order within tier")
    func ascendingTimestampOrder() {
        var items = [
            pair("later", status: "running", startedAt: 2000),
            pair("earlier", status: "running", startedAt: 1000),
        ]
        items = sortedByPriority(items, pinnedSessions: [])
        #expect(items[0].key == "earlier")
        #expect(items[1].key == "later")
    }

    // MARK: - Integration

    @Test("All tiers ordered correctly: pinned < attention < running")
    func allTiersOrderedCorrectly() {
        let now = Date().timeIntervalSince1970
        var items = [
            pair("running1", status: "running", startedAt: now),
            pair("pinned_running", status: "running", startedAt: now),
            pair("waiting1", status: "waiting", updatedAt: now),
            pair("done1", status: "done", updatedAt: now),
            pair("pinned_waiting", status: "waiting", updatedAt: now),
        ]
        items = sortedByPriority(items, pinnedSessions: ["pinned_running", "pinned_waiting"])

        let keys = items.map(\.key)
        let pinnedRunningIdx = keys.firstIndex(of: "pinned_running")!
        let pinnedWaitingIdx = keys.firstIndex(of: "pinned_waiting")!
        let waiting1Idx = keys.firstIndex(of: "waiting1")!
        let done1Idx = keys.firstIndex(of: "done1")!
        let running1Idx = keys.firstIndex(of: "running1")!

        #expect(pinnedRunningIdx < waiting1Idx)
        #expect(pinnedWaitingIdx < waiting1Idx)
        #expect(waiting1Idx < running1Idx)
        #expect(done1Idx < running1Idx)
    }

    // MARK: - Direct sort key API

    @Test("Sort key tier values: pinned=0, attention=1, running=2")
    func sortKeyTierValues() {
        let s = session(status: "running")
        let pinned = sessionSortKey(key: "k", session: s, pinnedSessions: ["k"])
        let attention = sessionSortKey(key: "k", session: session(status: "waiting"), pinnedSessions: [])
        let running = sessionSortKey(key: "k", session: s, pinnedSessions: [])

        #expect(pinned.0 == 0)
        #expect(attention.0 == 1)
        #expect(running.0 == 2)
    }
}
