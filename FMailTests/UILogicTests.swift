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
}
