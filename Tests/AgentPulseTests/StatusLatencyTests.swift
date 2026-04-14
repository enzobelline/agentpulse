/// Tests for status update latency scenarios.
///
/// When a session transitions from "waiting" → "running", several things must happen:
///   1. Hook fires (PreToolUse/PostToolUse) and writes JSON (~23ms)
///   2. DispatchSource or 1s timer detects the file change
///   3. Swift reads JSON, detects status transition, updates UI
///
/// These tests simulate the edge cases that cause visible latency:
///   - Rapid writes within same mtime (second write missed)
///   - Status transitions that get coalesced (waiting→running never seen)
///   - Lock contention delaying writes
///   - Multiple hooks firing in quick succession

import Foundation
import Testing
@testable import AgentPulseLib

struct StatusLatencyTests {

    // MARK: - Helpers

    private func session(status: String, updatedAt: TimeInterval = 1000) -> Session {
        Session(directory: "/test", name: "test", status: status, updatedAt: updatedAt)
    }

    // MARK: - Status transition detection

    @Test("waiting → running detected as single transition")
    func waitingToRunning() {
        let old = ["s1": session(status: "waiting")]
        let new = ["s1": session(status: "running")]
        let transitions = detectStatusTransitions(old: old, new: new)
        #expect(transitions.count == 1)
        #expect(transitions[0].oldStatus == "waiting")
        #expect(transitions[0].newStatus == "running")
    }

    @Test("No change → no transitions")
    func noChange() {
        let old = ["s1": session(status: "running")]
        let new = ["s1": session(status: "running")]
        let transitions = detectStatusTransitions(old: old, new: new)
        #expect(transitions.isEmpty)
    }

    @Test("New session appearing → transition with nil oldStatus")
    func newSession() {
        let old: [String: Session] = [:]
        let new = ["s1": session(status: "running")]
        let transitions = detectStatusTransitions(old: old, new: new)
        #expect(transitions.count == 1)
        #expect(transitions[0].oldStatus == nil)
        #expect(transitions[0].newStatus == "running")
    }

    @Test("Session removed → no transition (removal is not in new snapshot)")
    func removedSession() {
        let old = ["s1": session(status: "running")]
        let new: [String: Session] = [:]
        let transitions = detectStatusTransitions(old: old, new: new)
        #expect(transitions.isEmpty)
    }

    @Test("Multiple simultaneous transitions detected independently")
    func multipleTransitions() {
        let old = [
            "s1": session(status: "waiting"),
            "s2": session(status: "running"),
            "s3": session(status: "running"),
        ]
        let new = [
            "s1": session(status: "running"),
            "s2": session(status: "done"),
            "s3": session(status: "running"),  // unchanged
        ]
        let transitions = detectStatusTransitions(old: old, new: new)
        #expect(transitions.count == 2)
        let keys = Set(transitions.map { $0.key })
        #expect(keys == ["s1", "s2"])
    }

    // MARK: - Coalesced transitions (the core latency problem)
    //
    // If the app reads the file only on timer ticks (1s interval), and
    // two hooks fire within one tick, intermediate states are lost.
    // Example: waiting→running→waiting happens between ticks — app only
    // sees waiting→waiting (no transition detected, no UI update).

    @Test("Coalesced: waiting→running→waiting between polls — transition invisible")
    func coalescedWaitingRunningWaiting() {
        // Poll 1: sees "waiting"
        let poll1 = ["s1": session(status: "waiting")]
        // Between polls: hook sets "running", then another PermissionRequest sets "waiting"
        // Poll 2: sees "waiting" again
        let poll2 = ["s1": session(status: "waiting", updatedAt: 1001)]
        let transitions = detectStatusTransitions(old: poll1, new: poll2)
        // The running→waiting→running round-trip was invisible
        #expect(transitions.isEmpty)
    }

    @Test("Coalesced: running→waiting→running between polls — waiting never shown")
    func coalescedRunningWaitingRunning() {
        let poll1 = ["s1": session(status: "running")]
        // PermissionRequest→waiting, then PostToolUse→running, all within 1s
        let poll2 = ["s1": session(status: "running", updatedAt: 1001)]
        let transitions = detectStatusTransitions(old: poll1, new: poll2)
        // User never saw "waiting" — this is actually GOOD (no false alarm)
        #expect(transitions.isEmpty)
    }

    @Test("Coalesced: running→done→closed between polls — done notification missed")
    func coalescedRunningDoneClosed() {
        let poll1 = ["s1": session(status: "running")]
        // Stop hook→done, then SessionEnd→closed, session removed
        let poll2: [String: Session] = [:]
        let transitions = detectStatusTransitions(old: poll1, new: poll2)
        // Session vanished — "done" notification was never fired
        #expect(transitions.isEmpty)
    }

    // MARK: - mtime-based change detection
    //
    // The app compares file mtime to decide whether to re-read.
    // Two writes within the same filesystem timestamp granularity
    // (1 second on HFS+, 1ns on APFS) cause the second to be missed.

    @Test("Different mtime → change detected")
    func differentMtime() {
        #expect(wouldDetectChange(lastSeenMtime: 1000.0, currentMtime: 1000.023))
    }

    @Test("Same mtime → change NOT detected (rapid write within same timestamp)")
    func sameMtime() {
        #expect(!wouldDetectChange(lastSeenMtime: 1000.0, currentMtime: 1000.0))
    }

    @Test("mtime goes backward (clock skew or restore) → change detected")
    func mtimeBackward() {
        #expect(wouldDetectChange(lastSeenMtime: 1000.0, currentMtime: 999.0))
    }

    // MARK: - Rapid hook sequences
    //
    // When Claude uses multiple tools quickly, hooks fire in rapid succession.
    // Each hook does: lock → read → modify → write → unlock (~23ms each).
    // If the app polls between two hooks, it sees the intermediate state.
    // If it polls after both, it only sees the final state.

    @Test("Two hooks within one poll: only final state visible")
    func twoHooksOnePoll() {
        // State before any hooks
        let beforePoll = ["s1": session(status: "waiting")]
        // Hook 1 (PreToolUse): waiting → running at t=1000.010
        // Hook 2 (PostToolUse): running → running at t=1000.033 (with activity)
        // App polls at t=1001.0 — only sees final state
        let afterPoll = ["s1": session(status: "running", updatedAt: 1000.033)]
        let transitions = detectStatusTransitions(old: beforePoll, new: afterPoll)
        #expect(transitions.count == 1)
        #expect(transitions[0].oldStatus == "waiting")
        #expect(transitions[0].newStatus == "running")
    }

    @Test("Three hooks within one poll: intermediate 'waiting' invisible")
    func threeHooksOnePoll() {
        // App sees "running"
        let poll1 = ["s1": session(status: "running")]
        // Hook 1 (PermissionRequest): running → waiting  t+10ms
        // Hook 2 (PreToolUse): waiting → running          t+30ms  (user approved fast)
        // Hook 3 (PostToolUse): running → running          t+80ms
        // App polls — only sees running→running
        let poll2 = ["s1": session(status: "running", updatedAt: 1000.080)]
        let transitions = detectStatusTransitions(old: poll1, new: poll2)
        // The "waiting" state was never visible to the user — no false notification
        #expect(transitions.isEmpty)
    }

    @Test("Permission approved slowly: waiting persists across multiple polls")
    func slowPermission() {
        let poll1 = ["s1": session(status: "running")]
        // PermissionRequest fires
        let poll2 = ["s1": session(status: "waiting", updatedAt: 1001)]
        let t1 = detectStatusTransitions(old: poll1, new: poll2)
        #expect(t1.count == 1)
        #expect(t1[0].newStatus == "waiting")

        // 3 seconds later, still waiting (user hasn't approved yet)
        let poll3 = ["s1": session(status: "waiting", updatedAt: 1001)]
        let t2 = detectStatusTransitions(old: poll2, new: poll3)
        #expect(t2.isEmpty) // no new transition

        // User finally approves, PreToolUse fires
        let poll4 = ["s1": session(status: "running", updatedAt: 1004)]
        let t3 = detectStatusTransitions(old: poll3, new: poll4)
        #expect(t3.count == 1)
        #expect(t3[0].oldStatus == "waiting")
        #expect(t3[0].newStatus == "running")
    }

    // MARK: - Lock contention simulation
    //
    // If the Swift reaper holds the file lock while a hook is trying to write,
    // the hook blocks on flock(). The "running" status write is delayed by
    // however long the reaper takes (typically <10ms, but could spike).

    @Test("Lock delay: status write arrives late but transition still detected on next poll")
    func lockDelayedWrite() {
        // Poll 1: waiting (hook hasn't written yet due to lock)
        let poll1 = ["s1": session(status: "waiting", updatedAt: 1000)]
        // Poll 2: still waiting (hook still blocked on lock)
        let poll2 = ["s1": session(status: "waiting", updatedAt: 1000)]
        let t1 = detectStatusTransitions(old: poll1, new: poll2)
        #expect(t1.isEmpty) // no change yet

        // Poll 3: lock released, hook wrote "running"
        let poll3 = ["s1": session(status: "running", updatedAt: 1002.5)]
        let t2 = detectStatusTransitions(old: poll2, new: poll3)
        #expect(t2.count == 1)
        #expect(t2[0].newStatus == "running")
    }
}
