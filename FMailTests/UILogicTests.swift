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

    // MARK: — Date.listFormat

    func testListFormatRendersTimeForToday() {
        let now = Date()
        let format = now.listFormat(now: now)
        // No good way to compare two FormatStyle instances directly, so
        // compare the rendered string against another rendering. For "today"
        // we expect time-only (no day/month).
        let rendered = now.formatted(format)
        XCTAssertFalse(rendered.contains("Jan"), "Today's format should not contain month name.")
    }

    func testListFormatRendersMonthDayThisYear() {
        // Build a date earlier in the same year (Jan 1).
        var components = Calendar.current.dateComponents([.year], from: Date())
        components.month = 1
        components.day = 1
        components.hour = 12
        guard let date = Calendar.current.date(from: components) else {
            XCTFail("Couldn't build Jan 1 date")
            return
        }
        let now = Date()
        let rendered = date.formatted(date.listFormat(now: now))
        XCTAssertFalse(rendered.contains(":"), "Same-year format should not include time.")
        XCTAssertFalse(rendered.contains(String(components.year ?? 0)),
                       "Same-year format should not include the year.")
    }

    func testListFormatRendersYearMonthDayForOlder() {
        // 5 years ago.
        guard let date = Calendar.current.date(byAdding: .year, value: -5, to: Date()) else {
            XCTFail("Couldn't build older date")
            return
        }
        let now = Date()
        let rendered = date.formatted(date.listFormat(now: now))
        let yearComponent = Calendar.current.component(.year, from: date)
        XCTAssertTrue(rendered.contains(String(yearComponent)),
                      "Old-date format should include the year. Got: \(rendered)")
    }

    // MARK: — ReplyKind.subjectPreview

    func testSubjectPreviewAddsRePrefix() {
        XCTAssertEqual(
            ReplyKind.subjectPreview(forKind: .reply, originalSubject: "Hello"),
            "Re: Hello"
        )
        XCTAssertEqual(
            ReplyKind.subjectPreview(forKind: .replyAll, originalSubject: "Hello"),
            "Re: Hello"
        )
    }

    func testSubjectPreviewAddsFwdPrefix() {
        XCTAssertEqual(
            ReplyKind.subjectPreview(forKind: .forward, originalSubject: "Hello"),
            "Fwd: Hello"
        )
    }

    func testSubjectPreviewKeepsExistingRePrefix() {
        XCTAssertEqual(
            ReplyKind.subjectPreview(forKind: .reply, originalSubject: "Re: Hello"),
            "Re: Hello"
        )
        XCTAssertEqual(
            ReplyKind.subjectPreview(forKind: .reply, originalSubject: "RE: Hello"),
            "RE: Hello",
            "Case-insensitive — don't double-prefix."
        )
    }

    func testSubjectPreviewKeepsExistingFwdPrefix() {
        XCTAssertEqual(
            ReplyKind.subjectPreview(forKind: .forward, originalSubject: "Fwd: Hello"),
            "Fwd: Hello"
        )
        XCTAssertEqual(
            ReplyKind.subjectPreview(forKind: .forward, originalSubject: "fwd: Hello"),
            "fwd: Hello"
        )
    }

    func testSubjectPreviewEmptySubject() {
        XCTAssertEqual(
            ReplyKind.subjectPreview(forKind: .reply, originalSubject: ""),
            "Re: "
        )
        XCTAssertEqual(
            ReplyKind.subjectPreview(forKind: .forward, originalSubject: ""),
            "Fwd: "
        )
    }

    // MARK: — TimeDeltaFormatter

    func testTimeDeltaSeconds() {
        XCTAssertEqual(TimeDeltaFormatter.format(0), "+0s")
        XCTAssertEqual(TimeDeltaFormatter.format(1), "+1s")
        XCTAssertEqual(TimeDeltaFormatter.format(59), "+59s")
    }

    func testTimeDeltaMinutes() {
        XCTAssertEqual(TimeDeltaFormatter.format(60), "+1m")
        XCTAssertEqual(TimeDeltaFormatter.format(3599), "+59m")
    }

    func testTimeDeltaHours() {
        XCTAssertEqual(TimeDeltaFormatter.format(3600), "+1h")
        XCTAssertEqual(TimeDeltaFormatter.format(86_399), "+23h")
    }

    func testTimeDeltaDays() {
        XCTAssertEqual(TimeDeltaFormatter.format(86_400), "+1d")
        XCTAssertEqual(TimeDeltaFormatter.format(86_400 * 29), "+29d")
    }

    func testTimeDeltaMonths() {
        XCTAssertEqual(TimeDeltaFormatter.format(86_400 * 30), "+1mo")
        XCTAssertEqual(TimeDeltaFormatter.format(86_400 * 200), "+6mo")
    }

    func testTimeDeltaYears() {
        XCTAssertEqual(TimeDeltaFormatter.format(86_400 * 365), "+1y")
        XCTAssertEqual(TimeDeltaFormatter.format(86_400 * 365 * 5), "+5y")
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

    func testMailboxesByAccountSortsInboxFirst() {
        let model = MailModel()
        let acct = MailAccount(uuid: "a", displayName: "A", emailAddress: nil)
        let zMailbox = Mailbox(rowId: 1, accountUUID: "a", pathComponents: ["Z"], totalCount: 0, unreadCount: 0, hidden: false, kind: .other)
        let inbox = Mailbox(rowId: 2, accountUUID: "a", pathComponents: ["INBOX"], totalCount: 0, unreadCount: 0, hidden: false, kind: .inbox)
        let aMailbox = Mailbox(rowId: 3, accountUUID: "a", pathComponents: ["Archive"], totalCount: 0, unreadCount: 0, hidden: false, kind: .archive)
        model.accounts = [acct]
        model.mailboxes = [zMailbox, inbox, aMailbox]

        let grouped = model.mailboxesByAccount
        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped[0].1.map(\.displayName), ["INBOX", "Archive", "Z"])
    }

    func testMailboxesByAccountHidesHiddenByDefault() {
        let model = MailModel()
        let acct = MailAccount(uuid: "a", displayName: "A", emailAddress: nil)
        let visible = Mailbox(rowId: 1, accountUUID: "a", pathComponents: ["INBOX"], totalCount: 0, unreadCount: 0, hidden: false, kind: .inbox)
        let hidden = Mailbox(rowId: 2, accountUUID: "a", pathComponents: ["[Gmail]", "All Mail"], totalCount: 0, unreadCount: 0, hidden: true, kind: .all)
        model.accounts = [acct]
        model.mailboxes = [visible, hidden]

        XCTAssertEqual(model.mailboxesByAccount[0].1.map(\.rowId), [1])

        model.showHidden = true
        XCTAssertEqual(Set(model.mailboxesByAccount[0].1.map(\.rowId)), [1, 2])
    }
}
