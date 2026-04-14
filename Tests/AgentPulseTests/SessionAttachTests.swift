/// Tests for session-attach decision logic (resolveAttachAction + isValidTTY).
///
/// When a user clicks a session row, AgentPulse must decide:
///   1. activateWindow(tty:) — find the Terminal tab by TTY, then activate via Cocoa API
///   2. openTerminal(directory:) — fall back to opening a new Terminal window
///
/// Edge cases that cause incorrect behavior in the wild:
///   - Session reaped before click (session is nil)
///   - TTY field never written (old session, hook failure)
///   - TTY contains garbage from failed ps/tty capture ("??", "not a tty")
///   - TTY is bare device name without /dev/ prefix
///   - Terminal tab closed after session started (TTY stale — handled at AppleScript layer)
///   - Window on different macOS Space (handled by Cocoa activation, not testable here)

import Testing
@testable import AgentPulseLib

struct SessionAttachTests {

    // MARK: - Helpers

    private func session(
        directory: String? = "/Users/test/project",
        tty: String? = "/dev/ttys003",
        status: String = "running"
    ) -> Session {
        Session(directory: directory, name: "test", status: status, updatedAt: 1000, tty: tty)
    }

    // MARK: - resolveAttachAction: happy path

    @Test("Valid TTY → activateWindow")
    func validTTYActivates() {
        let s = session(tty: "/dev/ttys003")
        let action = resolveAttachAction(session: s, sessionKey: "key1")
        #expect(action == .activateWindow(tty: "/dev/ttys003"))
    }

    @Test("High-numbered TTY → activateWindow")
    func highNumberedTTY() {
        let s = session(tty: "/dev/ttys042")
        let action = resolveAttachAction(session: s, sessionKey: "key1")
        #expect(action == .activateWindow(tty: "/dev/ttys042"))
    }

    @Test("TTY with many digits → activateWindow")
    func manyDigitTTY() {
        let s = session(tty: "/dev/ttys12345")
        let action = resolveAttachAction(session: s, sessionKey: "key1")
        #expect(action == .activateWindow(tty: "/dev/ttys12345"))
    }

    // MARK: - resolveAttachAction: missing/nil session

    @Test("Nil session → openTerminal with sessionKey as fallback directory")
    func nilSession() {
        let action = resolveAttachAction(session: nil, sessionKey: "/Users/test/project")
        #expect(action == .openTerminal(directory: "/Users/test/project"))
    }

    @Test("Nil session with UUID key → openTerminal with UUID as directory")
    func nilSessionUUIDKey() {
        let action = resolveAttachAction(session: nil, sessionKey: "abc-123-def")
        #expect(action == .openTerminal(directory: "abc-123-def"))
    }

    // MARK: - resolveAttachAction: nil/empty TTY

    @Test("Nil TTY → openTerminal at session directory")
    func nilTTY() {
        let s = session(directory: "/Users/test/myapp", tty: nil)
        let action = resolveAttachAction(session: s, sessionKey: "key1")
        #expect(action == .openTerminal(directory: "/Users/test/myapp"))
    }

    @Test("Empty TTY string → openTerminal")
    func emptyTTY() {
        let s = session(tty: "")
        let action = resolveAttachAction(session: s, sessionKey: "key1")
        #expect(action == .openTerminal(directory: "/Users/test/project"))
    }

    @Test("Whitespace-only TTY → openTerminal")
    func whitespaceTTY() {
        let s = session(tty: "   ")
        let action = resolveAttachAction(session: s, sessionKey: "key1")
        #expect(action == .openTerminal(directory: "/Users/test/project"))
    }

    // MARK: - resolveAttachAction: garbage TTY values from hook failures

    @Test("TTY is '??' (backgrounded hook) → openTerminal")
    func questionMarkTTY() {
        let s = session(tty: "??")
        let action = resolveAttachAction(session: s, sessionKey: "key1")
        #expect(action == .openTerminal(directory: "/Users/test/project"))
    }

    @Test("TTY is '/dev/??' → openTerminal")
    func devQuestionMarkTTY() {
        let s = session(tty: "/dev/??")
        let action = resolveAttachAction(session: s, sessionKey: "key1")
        #expect(action == .openTerminal(directory: "/Users/test/project"))
    }

    @Test("TTY is 'not a tty' → openTerminal")
    func notATTY() {
        let s = session(tty: "not a tty")
        let action = resolveAttachAction(session: s, sessionKey: "key1")
        #expect(action == .openTerminal(directory: "/Users/test/project"))
    }

    // MARK: - resolveAttachAction: bare device name (missing /dev/ prefix)

    @Test("Bare 'ttys003' without /dev/ prefix → openTerminal")
    func bareTTYNoPrefix() {
        let s = session(tty: "ttys003")
        let action = resolveAttachAction(session: s, sessionKey: "key1")
        #expect(action == .openTerminal(directory: "/Users/test/project"))
    }

    // MARK: - resolveAttachAction: malformed TTY paths

    @Test("Double-prefixed '/dev/tty/ttys003' → openTerminal")
    func doublePrefixedTTY() {
        let s = session(tty: "/dev/tty/ttys003")
        let action = resolveAttachAction(session: s, sessionKey: "key1")
        #expect(action == .openTerminal(directory: "/Users/test/project"))
    }

    @Test("Wrong prefix '/dev/pts/0' (Linux-style) → openTerminal")
    func linuxStylePTY() {
        let s = session(tty: "/dev/pts/0")
        let action = resolveAttachAction(session: s, sessionKey: "key1")
        #expect(action == .openTerminal(directory: "/Users/test/project"))
    }

    @Test("TTY with trailing garbage '/dev/ttys003abc' → openTerminal")
    func ttyTrailingGarbage() {
        let s = session(tty: "/dev/ttys003abc")
        let action = resolveAttachAction(session: s, sessionKey: "key1")
        #expect(action == .openTerminal(directory: "/Users/test/project"))
    }

    @Test("Just '/dev/ttys' with no number → openTerminal")
    func ttyNoNumber() {
        let s = session(tty: "/dev/ttys")
        let action = resolveAttachAction(session: s, sessionKey: "key1")
        #expect(action == .openTerminal(directory: "/Users/test/project"))
    }

    // MARK: - resolveAttachAction: directory fallback chain

    @Test("Session with directory → uses session directory for fallback")
    func directoryFallback() {
        let s = session(directory: "/Users/test/specific-project", tty: nil)
        let action = resolveAttachAction(session: s, sessionKey: "key1")
        #expect(action == .openTerminal(directory: "/Users/test/specific-project"))
    }

    @Test("Session with nil directory → falls back to session key")
    func nilDirectoryFallback() {
        let s = session(directory: nil, tty: nil)
        let action = resolveAttachAction(session: s, sessionKey: "/fallback/path")
        #expect(action == .openTerminal(directory: "/fallback/path"))
    }

    // MARK: - resolveAttachAction: session status doesn't affect routing

    @Test(
        "All statuses with valid TTY → activateWindow",
        arguments: ["running", "waiting", "done", "closed"]
    )
    func allStatusesWithTTY(status: String) {
        let s = session(tty: "/dev/ttys007", status: status)
        let action = resolveAttachAction(session: s, sessionKey: "key1")
        #expect(action == .activateWindow(tty: "/dev/ttys007"))
    }

    @Test(
        "All statuses without TTY → openTerminal",
        arguments: ["running", "waiting", "done", "closed"]
    )
    func allStatusesWithoutTTY(status: String) {
        let s = session(tty: nil, status: status)
        let action = resolveAttachAction(session: s, sessionKey: "key1")
        #expect(action == .openTerminal(directory: "/Users/test/project"))
    }

    // MARK: - isValidTTY: comprehensive validation

    @Test("Valid TTY paths", arguments: [
        "/dev/ttys000",
        "/dev/ttys003",
        "/dev/ttys042",
        "/dev/ttys999",
        "/dev/ttys12345",
    ])
    func validTTYPaths(tty: String) {
        #expect(isValidTTY(tty))
    }

    @Test("Invalid TTY paths", arguments: [
        "",
        " ",
        "??",
        "/dev/??",
        "not a tty",
        "ttys003",
        "/dev/ttys",
        "/dev/ttys003abc",
        "/dev/tty/ttys003",
        "/dev/pts/0",
        "/dev/ttyp0",
        "/dev/ttysABC",
    ])
    func invalidTTYPaths(tty: String) {
        #expect(!isValidTTY(tty))
    }

    @Test("TTY with leading/trailing whitespace → trimmed and validated")
    func ttyWithWhitespace() {
        #expect(isValidTTY(" /dev/ttys003 "))
        #expect(!isValidTTY(" ?? "))
    }

    @Test("Whitespace-padded TTY → activateWindow with trimmed value")
    func whitespacePaddedTTYTrimmed() {
        let s = session(tty: " /dev/ttys003 ")
        let action = resolveAttachAction(session: s, sessionKey: "key1")
        // Must be trimmed — AppleScript compares exact string against Terminal's tty property
        #expect(action == .activateWindow(tty: "/dev/ttys003"))
    }
}
