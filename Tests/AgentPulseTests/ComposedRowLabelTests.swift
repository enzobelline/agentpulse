import XCTest
@testable import AgentPulseLib

/// Covers the budgeting logic that composes a session row's label from a
/// display name + summary. Guarantees both get to show, with predictable
/// truncation when space is tight.
final class ComposedRowLabelTests: XCTestCase {

    // MARK: - Name absent

    func testNoName_returnsSummaryUnchanged() {
        XCTAssertEqual(
            composedRowLabel(displayName: nil, summary: "working on auth"),
            "working on auth"
        )
    }

    func testEmptyName_returnsSummaryUnchanged() {
        XCTAssertEqual(
            composedRowLabel(displayName: "", summary: "working on auth"),
            "working on auth"
        )
    }

    // MARK: - Name only

    func testName_emptySummary_returnsJustName() {
        XCTAssertEqual(
            composedRowLabel(displayName: "auth refactor", summary: ""),
            "auth refactor"
        )
    }

    func testLongName_emptySummary_truncatesName() {
        let longName = String(repeating: "x", count: 50)
        let result = composedRowLabel(displayName: longName, summary: "")
        XCTAssertEqual(result.count, 25)
        XCTAssertTrue(result.hasSuffix("…"))
    }

    // MARK: - Name + summary, within budget

    func testShortNameShortSummary_bothShownFull() {
        XCTAssertEqual(
            composedRowLabel(displayName: "auth", summary: "/gsd:plan-phase 4"),
            "auth | /gsd:plan-phase 4"
        )
    }

    // MARK: - Long name forces truncation

    func testLongNameShortSummary_nameTruncatedSummaryFull() {
        let longName = String(repeating: "a", count: 40)
        let summary = "do the thing"
        let result = composedRowLabel(displayName: longName, summary: summary)
        XCTAssertTrue(result.contains(" | do the thing"))
        XCTAssertTrue(result.hasPrefix(String(repeating: "a", count: 24)))
        // Name portion = maxName (25), so total = 25 + 3 + 12 = 40
        XCTAssertEqual(result.count, 40)
    }

    // MARK: - Long summary truncated

    func testShortNameLongSummary_summaryTruncated() {
        let longSummary = String(repeating: "q", count: 200)
        let result = composedRowLabel(displayName: "x", summary: longSummary)
        // name (1) + " | " (3) + summary (up to 65-4=61) = 65
        XCTAssertLessThanOrEqual(result.count, 65)
        XCTAssertTrue(result.hasSuffix("…"))
        XCTAssertTrue(result.hasPrefix("x | "))
    }

    // MARK: - Both long

    func testLongNameLongSummary_bothTruncated() {
        let longName = String(repeating: "n", count: 100)
        let longSummary = String(repeating: "s", count: 200)
        let result = composedRowLabel(displayName: longName, summary: longSummary)
        XCTAssertLessThanOrEqual(result.count, 65)
        XCTAssertTrue(result.contains(" | "))
        XCTAssertTrue(result.hasSuffix("…"))
    }

    // MARK: - Degenerate: name so long there's no room for summary

    func testNameEatsWholeBudget_returnsJustName() {
        // maxName (25) leaves 65-25-3 = 37 summary chars, well above minSummary (9)
        // To force "just name", shrink the total budget so summary budget < minSummary
        let result = composedRowLabel(
            displayName: "twenty-five-char-name-here",
            summary: "important prompt",
            maxName: 25,
            totalBudget: 30,    // 30 - 25 - 3 = 2 → below minSummary
            minSummary: 9
        )
        // Result should drop the summary entirely
        XCTAssertFalse(result.contains(" | "))
    }
}
