/// Tests for `displaySymbol(for:)` and `displaySummary(for:maxLength:)`.

import Testing
@testable import AgentPulseLib

struct DisplayLabelsTests {

    // MARK: - Helpers

    private func session(
        name: String = "test",
        directory: String = "/d/test",
        summary: String? = nil,
        symbol: String? = nil
    ) -> Session {
        Session(directory: directory, name: name, status: "running", updatedAt: 1000, summary: summary, symbol: symbol)
    }

    // MARK: - displaySymbol

    @Test("Symbol present → returns it")
    func symbolPresent() {
        let s = session(symbol: "◆")
        #expect(displaySymbol(for: s) == "◆")
    }

    @Test("Symbol nil → returns ?")
    func symbolNil() {
        let s = session(symbol: nil)
        #expect(displaySymbol(for: s) == "?")
    }

    @Test("Each default symbol is a single character")
    func defaultSymbolsSingleChar() {
        for sym in SymbolPool.defaultSymbols {
            #expect(sym.count == 1, "Symbol \(sym) should be a single character")
        }
    }

    @Test("Default pool has 18 unique symbols")
    func defaultPoolSize() {
        let symbols = SymbolPool.defaultSymbols
        #expect(symbols.count == 16)
        #expect(Set(symbols).count == 16, "All symbols should be unique")
    }

    @Test("All default symbols render (not replacement char U+FFFD)")
    func defaultSymbolsRenderable() {
        for sym in SymbolPool.defaultSymbols {
            #expect(sym != "\u{FFFD}", "Symbol \(sym) should not be replacement character")
            #expect(!sym.unicodeScalars.contains(Unicode.Scalar(0xFFFD)!))
        }
    }

    @Test("Every default symbol returns correctly from displaySymbol")
    func allDefaultSymbolsRoundTrip() {
        for sym in SymbolPool.defaultSymbols {
            let s = session(symbol: sym)
            #expect(displaySymbol(for: s) == sym)
        }
    }

    // MARK: - displaySummary

    @Test("Short summary returned as-is")
    func summaryShort() {
        let s = session(summary: "fix the bug")
        #expect(displaySummary(for: s) == "fix the bug")
    }

    @Test("Long summary truncated on word boundary with ellipsis")
    func summaryTruncated() {
        let s = session(summary: "fix the authentication bug in the login flow and make it work correctly")
        let result = displaySummary(for: s)
        #expect(result.hasSuffix("…"))
        // The truncated text (before …) should be ≤ 40 chars
        let withoutEllipsis = String(result.dropLast())
        #expect(withoutEllipsis.count <= 40)
    }

    @Test("Nil summary → falls back to directory basename")
    func summaryNilFallback() {
        let s = session(name: "myproject", directory: "/Users/dev/myproject", summary: nil)
        #expect(displaySummary(for: s) == "myproject")
    }

    @Test("Empty summary → falls back to directory basename")
    func summaryEmptyFallback() {
        let s = session(name: "myproject", directory: "/Users/dev/myproject", summary: "")
        #expect(displaySummary(for: s) == "myproject")
    }

    @Test("Summary exactly at max length → no truncation")
    func summaryExactLength() {
        let s = session(summary: "1234567890123456789012345678901234567890") // 40 chars
        #expect(displaySummary(for: s) == "1234567890123456789012345678901234567890")
    }

    @Test("Summary one char over max → truncated")
    func summaryOneOverMax() {
        let s = session(summary: "12345678901234567890123456789012345678901") // 41 chars
        let result = displaySummary(for: s)
        #expect(result.hasSuffix("…"))
    }

    @Test("Custom maxLength respected")
    func summaryCustomMaxLength() {
        let s = session(summary: "a longer summary that should be cut")
        let result = displaySummary(for: s, maxLength: 15)
        let withoutEllipsis = String(result.dropLast())
        #expect(withoutEllipsis.count <= 15)
    }

    @Test("No directory falls back to name")
    func summaryNoDirectoryFallsBackToName() {
        let s = Session(directory: nil, name: "fallback-name", status: "running", updatedAt: 1000, summary: nil)
        #expect(displaySummary(for: s) == "fallback-name")
    }

    @Test("Single long word truncated without word boundary")
    func summarySingleLongWord() {
        let s = session(summary: "abcdefghijklmnopqrstuvwxyz12345678901234567890")
        let result = displaySummary(for: s)
        #expect(result.hasSuffix("…"))
        #expect(result.count <= 41)
    }

    // MARK: - Placeholder summaries fall back to basename

    @Test("Generic placeholder summaries fall back to directory basename",
          arguments: ["Processing...", "Needs permission", "Session started", "Process ended", "Finished"])
    func placeholderFallsBack(placeholder: String) {
        let s = session(name: "myproject", directory: "/Users/dev/myproject", summary: placeholder)
        #expect(displaySummary(for: s) == "myproject")
    }

    @Test("Non-placeholder summary is kept")
    func nonPlaceholderKept() {
        let s = session(name: "myproject", directory: "/Users/dev/myproject", summary: "fix the auth bug")
        #expect(displaySummary(for: s) == "fix the auth bug")
    }

    // MARK: - autoClearLabel

    @Test("0 minutes → Off")
    func autoClearOff() {
        #expect(autoClearLabel(0) == "Off")
    }

    @Test("Minutes under 60 → Xm",
          arguments: [(5, "5m"), (15, "15m"), (30, "30m")])
    func autoClearMinutes(minutes: Int, expected: String) {
        #expect(autoClearLabel(minutes) == expected)
    }

    @Test("60+ minutes → Xh",
          arguments: [(60, "1h"), (180, "3h"), (120, "2h")])
    func autoClearHours(minutes: Int, expected: String) {
        #expect(autoClearLabel(minutes) == expected)
    }

    @Test("1440+ minutes → Xd",
          arguments: [(1440, "1d"), (2880, "2d")])
    func autoClearDays(minutes: Int, expected: String) {
        #expect(autoClearLabel(minutes) == expected)
    }
}
