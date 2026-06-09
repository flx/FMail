import XCTest
@testable import FMail

/// Tests for the pure-Swift helpers extracted from the UI layer. These
/// don't touch Mail.app, the file system, or SQLite — they run in any
/// environment, FDA or no FDA.
final class UILogicTests: XCTestCase {

    // MARK: — MailboxKind.viewScope

    func testViewScopeAllMailboxesAlwaysExcludesSystem() {
        XCTAssertEqual(
            MailboxKind.viewScope(forSelectedKind: nil, allMailboxesScope: true),
            .excludeAllSystem
        )
        XCTAssertEqual(
            MailboxKind.viewScope(forSelectedKind: .drafts, allMailboxesScope: true),
            .excludeAllSystem,
            "All-Mailboxes scope wins over selectedKind."
        )
    }

    func testViewScopeIncludesAllInsideSystemMailbox() {
        for kind: MailboxKind in [.drafts, .trash, .junk] {
            XCTAssertEqual(
                MailboxKind.viewScope(forSelectedKind: kind, allMailboxesScope: false),
                .includeAll,
                "Browsing \(kind) directly should include the system messages."
            )
        }
    }

    func testViewScopeDefaultExcludesDrafts() {
        for kind: MailboxKind in [.inbox, .sent, .archive, .all, .other] {
            XCTAssertEqual(
                MailboxKind.viewScope(forSelectedKind: kind, allMailboxesScope: false),
                .excludeDrafts,
                "Non-system mailbox \(kind) should default to excludeDrafts."
            )
        }
    }

    func testViewScopeNoSelectionDefaultsToExcludeDrafts() {
        XCTAssertEqual(
            MailboxKind.viewScope(forSelectedKind: nil, allMailboxesScope: false),
            .excludeDrafts
        )
    }

    func testIsSystemIsolated() {
        XCTAssertTrue(MailboxKind.drafts.isSystemIsolated)
        XCTAssertTrue(MailboxKind.trash.isSystemIsolated)
        XCTAssertTrue(MailboxKind.junk.isSystemIsolated)
        XCTAssertFalse(MailboxKind.inbox.isSystemIsolated)
        XCTAssertFalse(MailboxKind.sent.isSystemIsolated)
        XCTAssertFalse(MailboxKind.archive.isSystemIsolated)
        XCTAssertFalse(MailboxKind.all.isSystemIsolated)
        XCTAssertFalse(MailboxKind.other.isSystemIsolated)
    }
}

// MARK: — MailModel selection / sort tests

@MainActor
final class MailModelLogicTests: XCTestCase {

    func testSelectIgnoresStaleMailboxId() {
        let model = MailModel()
        // No mailboxes loaded — selecting an arbitrary id should be a no-op
        // (silently rejected, not crashed).
        model.select(.mailbox(99_999))
        XCTAssertNil(model.selection,
                     "Stale mailbox id should not become the active selection.")
    }

    func testSelectAllMailboxesAlwaysSucceeds() {
        let model = MailModel()
        model.selectAllMailboxes()
        XCTAssertEqual(model.selection, .allMailboxes)
    }

    func testSelectResolvesKnownMailbox() {
        let model = MailModel()
        let mb = Mailbox(
            rowId: 7,
            accountUUID: "acct-1",
            pathComponents: ["INBOX"],
            totalCount: 0,
            unreadCount: 0,
            hidden: false,
            kind: .inbox
        )
        model.mailboxes = [mb]
        model.select(.mailbox(7))
        XCTAssertEqual(model.selection, .mailbox(7))
    }

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
