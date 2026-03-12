/// Tests for session reaping (dead PID detection) and pin cleanup.
///
/// Reaping: the app calls `kill(pid, 0)` to detect dead processes.
///   - ESRCH (no such process) → process is dead → mark session as "done"
///   - EPERM (permission denied) → process exists but owned by another user → leave alone
///   - Success → process is alive → leave alone
///   - Sessions without a PID or already "done" are skipped entirely.
///
/// Pin cleanup: on load, stale pinnedSessions entries (referencing
/// non-existent session keys) are pruned.

import Foundation
import Testing
@testable import AgentPulseLib

struct SessionLifecycleTests {

    // MARK: - Helpers

    private func session(status: String, pid: Int? = nil, summary: String? = nil, updatedAt: TimeInterval = 1000) -> Session {
        Session(name: "test", status: status, updatedAt: updatedAt, summary: summary, pid: pid)
    }

    // MARK: - Reaping stale sessions — Core PID states

    @Test("Dead PID → status becomes done, summary becomes Process ended")
    func deadPidMarkedDone() {
        let sessions: [String: Session] = [
            "s1": session(status: "running", pid: 999999),
        ]
        let result = reapStaleSessions(sessions)
        #expect(result["s1"]?.status == "done")
        #expect(result["s1"]?.summary == "Process ended")
    }

    @Test("Alive PID → session unchanged")
    func alivePidUntouched() {
        let sessions: [String: Session] = [
            "s1": session(status: "running", pid: Int(getpid())),
        ]
        let result = reapStaleSessions(sessions)
        #expect(result["s1"]?.status == "running")
        #expect(result["s1"]?.summary == nil)
    }

    // MARK: - Reaping stale sessions — Skip conditions

    @Test("No PID field → session skipped")
    func noPidUntouched() {
        let sessions: [String: Session] = [
            "s1": session(status: "running", pid: nil),
        ]
        let result = reapStaleSessions(sessions)
        #expect(result["s1"]?.status == "running")
    }

    @Test("Already done with dead PID → removed entirely")
    func alreadyDoneDeadPidRemoved() {
        let sessions: [String: Session] = [
            "s1": session(status: "done", pid: 999999, summary: "Finished"),
        ]
        let result = reapStaleSessions(sessions)
        #expect(result["s1"] == nil)
    }

    @Test("Already done with live PID → kept")
    func alreadyDoneLivePidKept() {
        let sessions: [String: Session] = [
            "s1": session(status: "done", pid: Int(getpid()), summary: "Finished"),
        ]
        let result = reapStaleSessions(sessions)
        #expect(result["s1"]?.status == "done")
        #expect(result["s1"]?.summary == "Finished")
    }

    @Test("Waiting session with dead PID → reaped")
    func waitingSessionDeadPid() {
        let sessions: [String: Session] = [
            "s1": session(status: "waiting", pid: 999999),
        ]
        let result = reapStaleSessions(sessions)
        #expect(result["s1"]?.status == "done")
        #expect(result["s1"]?.summary == "Process ended")
    }

    // MARK: - Reaping stale sessions — Integration

    @Test("Mixed sessions: only dead PID reaped")
    func multipleSessionsMixed() {
        let sessions: [String: Session] = [
            "alive": session(status: "running", pid: Int(getpid())),
            "dead": session(status: "running", pid: 999999),
            "nopid": session(status: "running", pid: nil),
            "done_already": session(status: "done", pid: 999998, summary: "Finished"),
        ]
        let result = reapStaleSessions(sessions)

        #expect(result["alive"]?.status == "running")
        #expect(result["dead"]?.status == "done")
        #expect(result["dead"]?.summary == "Process ended")
        #expect(result["nopid"]?.status == "running")
        #expect(result["done_already"] == nil) // dead PID + done → removed
    }

    @Test("Reap returns new dict without mutating original")
    func reapReturnsNewDict() {
        let sessions: [String: Session] = [
            "s1": session(status: "running", pid: 999999),
        ]
        let result = reapStaleSessions(sessions)
        #expect(sessions["s1"]?.status == "running")
        #expect(result["s1"]?.status == "done")
    }

    // MARK: - Auto-clear TTL expiry

    @Test("TTL 0 (disabled) → no sessions expired")
    func ttlDisabledNoExpiry() {
        let now: TimeInterval = 100_000
        let sessions: [String: Session] = [
            "s1": session(status: "done", updatedAt: 0),
        ]
        let expired = expiredSessionKeys(sessions, ttlMinutes: 0, now: now)
        #expect(expired.isEmpty)
    }

    @Test("Done session exactly at TTL boundary → expired")
    func ttlExactBoundary() {
        let now: TimeInterval = 100_000
        let updatedAt = now - TimeInterval(1440 * 60) // exactly 1 day ago
        let sessions: [String: Session] = [
            "s1": Session(name: "test", status: "done", updatedAt: updatedAt),
        ]
        let expired = expiredSessionKeys(sessions, ttlMinutes: 1440, now: now)
        #expect(expired == ["s1"])
    }

    @Test("Done session 1 second before TTL → not expired")
    func ttlOneSecondBefore() {
        let now: TimeInterval = 100_000
        let updatedAt = now - TimeInterval(1440 * 60) + 1 // 1 second short of 1 day
        let sessions: [String: Session] = [
            "s1": Session(name: "test", status: "done", updatedAt: updatedAt),
        ]
        let expired = expiredSessionKeys(sessions, ttlMinutes: 1440, now: now)
        #expect(expired.isEmpty)
    }

    @Test("Running session past TTL → not expired (only done sessions)")
    func ttlRunningNotExpired() {
        let now: TimeInterval = 100_000
        let sessions: [String: Session] = [
            "s1": Session(name: "test", status: "running", updatedAt: 0),
        ]
        let expired = expiredSessionKeys(sessions, ttlMinutes: 5, now: now)
        #expect(expired.isEmpty)
    }

    @Test("Waiting session past TTL → not expired")
    func ttlWaitingNotExpired() {
        let now: TimeInterval = 100_000
        let sessions: [String: Session] = [
            "s1": Session(name: "test", status: "waiting", updatedAt: 0),
        ]
        let expired = expiredSessionKeys(sessions, ttlMinutes: 5, now: now)
        #expect(expired.isEmpty)
    }

    @Test("Mixed sessions: only done past TTL expired")
    func ttlMixedSessions() {
        let now: TimeInterval = 100_000
        let sessions: [String: Session] = [
            "done_old": Session(name: "a", status: "done", updatedAt: now - 600),    // 10m ago
            "done_new": Session(name: "b", status: "done", updatedAt: now - 60),     // 1m ago
            "running":  Session(name: "c", status: "running", updatedAt: now - 600),
        ]
        let expired = Set(expiredSessionKeys(sessions, ttlMinutes: 5, now: now))
        #expect(expired == ["done_old"])
    }

    // MARK: - Pin cleanup

    @Test("Valid pin kept")
    func validPinKept() {
        var settings = Settings(pinnedSessions: ["s1"])
        let sessionKeys = Set(["s1", "s2"])
        settings.pinnedSessions.removeAll { !sessionKeys.contains($0) }
        #expect(settings.pinnedSessions == ["s1"])
    }

    @Test("Stale pin pruned, valid kept")
    func stalePinPruned() {
        var settings = Settings(pinnedSessions: ["s1", "gone"])
        let sessionKeys = Set(["s1"])
        settings.pinnedSessions.removeAll { !sessionKeys.contains($0) }
        #expect(settings.pinnedSessions == ["s1"])
    }

    @Test("All pins stale → empty list")
    func allPinsStale() {
        var settings = Settings(pinnedSessions: ["x", "y", "z"])
        let sessionKeys = Set(["s1"])
        settings.pinnedSessions.removeAll { !sessionKeys.contains($0) }
        #expect(settings.pinnedSessions == [])
    }

    @Test("Mixed pins: valid ones keep original order")
    func mixedPins() {
        var settings = Settings(pinnedSessions: ["s1", "gone1", "s3", "gone2"])
        let sessionKeys = Set(["s1", "s2", "s3"])
        settings.pinnedSessions.removeAll { !sessionKeys.contains($0) }
        #expect(settings.pinnedSessions == ["s1", "s3"])
    }

    // MARK: - Notification settings

    @Test("Default settings: both notifications and sound enabled")
    func defaultNotificationSettings() {
        let settings = Settings()
        #expect(settings.notificationsEnabled == true)
        #expect(settings.soundEnabled == true)
    }

    @Test("Settings without notifications_enabled field → defaults to true")
    func notificationsEnabledMissing() throws {
        let json = """
        {"sound_enabled":true,"first_run_complete":false,"pinned_sessions":[],"max_visible_sessions":5}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Settings.self, from: json)
        #expect(decoded.notificationsEnabled == true)
    }

    @Test("Settings with notifications_enabled false → decoded correctly")
    func notificationsEnabledFalse() throws {
        let json = """
        {"sound_enabled":true,"notifications_enabled":false,"first_run_complete":false,"pinned_sessions":[],"max_visible_sessions":5}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Settings.self, from: json)
        #expect(decoded.notificationsEnabled == false)
    }

    @Test("Settings round-trip preserves notifications_enabled")
    func notificationsEnabledRoundTrip() throws {
        let original = Settings(soundEnabled: false, notificationsEnabled: false)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        #expect(decoded.notificationsEnabled == false)
        #expect(decoded.soundEnabled == false)
    }

    // MARK: - Codable round-trip for Session.symbol

    @Test("Session with symbol encodes and decodes correctly")
    func symbolCodableRoundTrip() throws {
        let original = Session(name: "test", status: "running", updatedAt: 1000, symbol: "◆")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Session.self, from: data)
        #expect(decoded.symbol == "◆")
    }

    @Test("Session without symbol decodes symbol as nil")
    func symbolNilCodableRoundTrip() throws {
        let json = """
        {"name":"test","status":"running","updated_at":1000}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Session.self, from: json)
        #expect(decoded.symbol == nil)
    }

    @Test("All 18 default symbols survive JSON encode/decode")
    func allSymbolsCodableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for sym in SymbolPool.defaultSymbols {
            let original = Session(name: "test", status: "running", updatedAt: 1000, symbol: sym)
            let data = try encoder.encode(original)
            let decoded = try decoder.decode(Session.self, from: data)
            #expect(decoded.symbol == sym, "Symbol \(sym) should survive round-trip")
        }
    }

    // MARK: - SymbolPool Codable

    @Test("SymbolPool encodes and decodes correctly")
    func symbolPoolCodableRoundTrip() throws {
        var pool = SymbolPool()
        let assigned = pool.available.removeFirst()
        pool.assigned["session-1"] = assigned
        let data = try JSONEncoder().encode(pool)
        let decoded = try JSONDecoder().decode(SymbolPool.self, from: data)
        #expect(decoded.available.count == 15)
        #expect(decoded.assigned["session-1"] == assigned)
    }

    @Test("Fresh SymbolPool has all 16 symbols available, none assigned")
    func freshSymbolPool() {
        let pool = SymbolPool()
        #expect(pool.available.count == 16)
        #expect(pool.assigned.isEmpty)
    }

    // MARK: - StatusFile migration (no symbol_pool field)

    @Test("StatusFile decodes without symbol_pool → fresh pool")
    func statusFileMissingPool() throws {
        let json = """
        {"sessions":{},"settings":{"sound_enabled":true,"first_run_complete":false,"pinned_sessions":[],"max_visible_sessions":5}}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(StatusFile.self, from: json)
        #expect(decoded.symbolPool.available.count == 16)
        #expect(decoded.symbolPool.assigned.isEmpty)
    }

    @Test("StatusFile decodes with symbol_pool → preserves it")
    func statusFileWithPool() throws {
        let json = """
        {"sessions":{},"settings":{"sound_enabled":true,"first_run_complete":false,"pinned_sessions":[],"max_visible_sessions":5},"symbol_pool":{"available":["▲","■"],"assigned":{"s1":"◆"}}}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(StatusFile.self, from: json)
        #expect(decoded.symbolPool.available == ["▲", "■"])
        #expect(decoded.symbolPool.assigned == ["s1": "◆"])
    }
}
