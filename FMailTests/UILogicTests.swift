import XCTest
@testable import FMail

/// Tests for the pure-Swift helpers extracted from the UI layer. These
/// don't touch Mail.app, the file system, or SQLite — they run in any
/// environment, FDA or no FDA.
final class UILogicTests: XCTestCase {

    // MARK: — PriorityListSettings.entriesMatching
    //
    // Backs the per-message "Remove … from Priority Mail" menu commands: which
    // hand-edited entry (or entries) put a given sender into Priority. Saves and
    // restores the real UserDefaults-backed list around each case.

    private func withSupplemental(_ entries: [String], _ body: () -> Void) {
        let saved = PriorityListSettings.supplementalAddresses
        defer { PriorityListSettings.supplementalAddresses = saved }
        PriorityListSettings.supplementalAddresses = entries
        body()
    }

    func testEntriesMatchingExactAddressIsCaseInsensitive() {
        withSupplemental(["Alice@Example.com", "bob@other.com"]) {
            XCTAssertEqual(
                PriorityListSettings.entriesMatching("alice@example.com"),
                ["Alice@Example.com"],
                "Exact match ignores case and returns the entry verbatim."
            )
        }
    }

    func testEntriesMatchingBareDomainActsAsSubstringWildcard() {
        // A bare word/domain classifies as the GLOB `*savills.com*`.
        withSupplemental(["savills.com"]) {
            XCTAssertEqual(PriorityListSettings.entriesMatching("john@savills.com"), ["savills.com"])
            XCTAssertEqual(PriorityListSettings.entriesMatching("a@mail.savills.com"), ["savills.com"])
            XCTAssertTrue(PriorityListSettings.entriesMatching("john@example.com").isEmpty)
        }
    }

    func testEntriesMatchingExplicitWildcard() {
        withSupplemental(["*@vendor.com"]) {
            XCTAssertEqual(PriorityListSettings.entriesMatching("sales@vendor.com"), ["*@vendor.com"])
            // `*@vendor.com` anchors the domain — a subdomain sender shouldn't match.
            XCTAssertTrue(PriorityListSettings.entriesMatching("sales@eu.vendor.com").isEmpty)
            XCTAssertTrue(PriorityListSettings.entriesMatching("sales@notvendor.com").isEmpty)
        }
    }

    func testEntriesMatchingQuestionMarkWildcardIsSingleChar() {
        withSupplemental(["a?@vendor.com"]) {
            XCTAssertEqual(PriorityListSettings.entriesMatching("ab@vendor.com"), ["a?@vendor.com"])
            XCTAssertTrue(PriorityListSettings.entriesMatching("abc@vendor.com").isEmpty,
                          "`?` matches exactly one character, not two.")
        }
    }

    func testEntriesMatchingReturnsEveryMatchingEntryInOrder() {
        // A sender can be put into Priority by more than one entry; the menu
        // offers to remove each, in list order.
        withSupplemental(["*vendor.com", "sales@vendor.com", "*other.com"]) {
            XCTAssertEqual(
                PriorityListSettings.entriesMatching("sales@vendor.com"),
                ["*vendor.com", "sales@vendor.com"]
            )
        }
    }

    func testEntriesMatchingEmptyAddressMatchesNothing() {
        withSupplemental(["*vendor.com"]) {
            XCTAssertTrue(PriorityListSettings.entriesMatching("").isEmpty)
            XCTAssertTrue(PriorityListSettings.entriesMatching("   ").isEmpty)
        }
    }
}
