import XCTest
@testable import FMail

/// SQLite-side coverage for the menu's "Priority Messages" / "Other Messages"
/// split (`IndexDB+Priority`). The Swift glob classifier
/// (`PriorityListSettings.entriesMatching`) is already unit-tested in
/// `UILogicTests`; this file pins down the *SQLite GLOB* side so the two can't
/// silently diverge — a sender that the Swift side calls "priority" must land
/// in the SQL priority block too.
///
/// Drives the public API over a real `IndexDB` on a temp file (same pattern as
/// `IndexDBDedupTests` / `IndexDBDeletionTests`).
final class IndexDBPriorityTests: XCTestCase {

    private let ourEmail = "felix@example.com"

    private struct Env {
        let db: IndexDB
        let cleanup: () -> Void
        let inbox: Int
    }

    private func makeDB() async throws -> Env {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fmail-priority-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let db = try IndexDB(path: tmpDir.appendingPathComponent("index.sqlite").path)
        let cleanup = { _ = try? FileManager.default.removeItem(at: tmpDir) }
        try await db.upsertAccounts([(uuid: "ACCT", displayName: "Felix", email: ourEmail)])
        let inbox = 100
        try await db.upsertMailboxes([
            Mailbox(rowId: inbox, accountUUID: "ACCT", pathComponents: ["INBOX"],
                    totalCount: 0, unreadCount: 0, hidden: false, kind: .inbox)
        ])
        return Env(db: db, cleanup: cleanup, inbox: inbox)
    }

    /// One indexed message. `sender == nil` exercises the NULL-sender path.
    private func message(rowid: Int, mailbox: Int, sender: String?, date: Int,
                         isRead: Bool = true) -> IndexedMessage {
        IndexedMessage(
            appleRowId: rowid, appleMessageIdHash: Int64(rowid), mailboxRowId: mailbox,
            accountUUID: "ACCT", subject: "Subject \(rowid)", subjectPrefix: "",
            subjectNormalized: "subject \(rowid)",
            senderAddress: sender, senderDisplay: sender.map { "Display \($0)" },
            dateSent: date, dateReceived: date, isRead: isRead, isFlagged: false,
            hasAttachment: false, rfcMessageId: "<\(rowid)@example.com>", imapUID: rowid
        )
    }

    /// A `CompiledQuery` that matches every message (read or unread), so the
    /// only partitioning at play is the priority membership predicate.
    private func matchAllQuery() -> CompiledQuery {
        Evaluator.compile(QueryParser.parse("is:read OR is:unread"))
    }

    // MARK: — searchSplitByPriority

    func testSplitPartitionsByExactAndPatternMembership() async throws {
        let env = try await makeDB(); defer { env.cleanup() }
        let base = 1_700_000_000
        try await env.db.upsertMessages([
            message(rowid: 1, mailbox: env.inbox, sender: "boss@work.com", date: base),       // exact priority
            message(rowid: 2, mailbox: env.inbox, sender: "sales@vendor.com", date: base - 1),// pattern priority
            message(rowid: 3, mailbox: env.inbox, sender: "stranger@nowhere.io", date: base - 2), // other
        ])
        try await env.db.incrementalUpdateFTS()

        try await env.db.updatePrioritySet(exact: ["boss@work.com"], patterns: ["*vendor*"])

        let split = try await env.db.searchSplitByPriority(matchAllQuery(), limitPerBlock: 100)
        let priorityIds = Set(split.priority.map(\.rowId))
        let otherIds = Set(split.other.map(\.rowId))

        XCTAssertEqual(priorityIds, [1, 2], "exact-match and pattern-match senders are priority")
        XCTAssertEqual(otherIds, [3], "non-matching sender lands in the other block")
        XCTAssertTrue(priorityIds.isDisjoint(with: otherIds), "a message is in exactly one block")
    }

    /// The SQLite GLOB must agree with the Swift glob the UI uses. A bare-domain
    /// supplemental entry classifies (Swift side) as `*savills.com*`; stored as
    /// that pattern, the SQL side must catch sub-addresses too.
    func testPatternMatchesSubstringLikeSwiftSide() async throws {
        let env = try await makeDB(); defer { env.cleanup() }
        let base = 1_700_000_000
        try await env.db.upsertMessages([
            message(rowid: 10, mailbox: env.inbox, sender: "john@savills.com", date: base),
            message(rowid: 11, mailbox: env.inbox, sender: "a@mail.savills.com", date: base - 1),
            message(rowid: 12, mailbox: env.inbox, sender: "x@example.com", date: base - 2),
        ])
        try await env.db.incrementalUpdateFTS()

        // Mirrors PriorityListSettings classifying "savills.com" → *savills.com*.
        try await env.db.updatePrioritySet(exact: [], patterns: ["*savills.com*"])

        let split = try await env.db.searchSplitByPriority(matchAllQuery(), limitPerBlock: 100)
        XCTAssertEqual(Set(split.priority.map(\.rowId)), [10, 11],
                       "both savills.com senders match the substring GLOB, just like the Swift side")
        XCTAssertEqual(Set(split.other.map(\.rowId)), [12])
    }

    /// NULL sender → COALESCE to '' → never priority, always "other" (never
    /// dropped from both blocks by NULL comparison semantics).
    func testNullSenderLandsInOtherBlock() async throws {
        let env = try await makeDB(); defer { env.cleanup() }
        let base = 1_700_000_000
        try await env.db.upsertMessages([
            message(rowid: 20, mailbox: env.inbox, sender: nil, date: base),
            message(rowid: 21, mailbox: env.inbox, sender: "vip@work.com", date: base - 1),
        ])
        try await env.db.incrementalUpdateFTS()
        // Use a pattern that can't match the empty string a NULL sender
        // COALESCEs to, so the test proves the NULL row lands in "other"
        // rather than vanishing from both blocks.
        try await env.db.updatePrioritySet(exact: ["vip@work.com"], patterns: ["*@work.com"])

        let split = try await env.db.searchSplitByPriority(matchAllQuery(), limitPerBlock: 100)
        XCTAssertEqual(Set(split.priority.map(\.rowId)), [21])
        XCTAssertEqual(Set(split.other.map(\.rowId)), [20],
                       "NULL-sender message must appear in 'other', not disappear")
    }

    func testEmptyPrioritySetPutsEverythingInOther() async throws {
        let env = try await makeDB(); defer { env.cleanup() }
        let base = 1_700_000_000
        try await env.db.upsertMessages([
            message(rowid: 30, mailbox: env.inbox, sender: "a@x.com", date: base),
            message(rowid: 31, mailbox: env.inbox, sender: "b@y.com", date: base - 1),
        ])
        try await env.db.incrementalUpdateFTS()
        try await env.db.updatePrioritySet(exact: [], patterns: [])

        let split = try await env.db.searchSplitByPriority(matchAllQuery(), limitPerBlock: 100)
        XCTAssertTrue(split.priority.isEmpty, "no priority senders configured")
        XCTAssertEqual(Set(split.other.map(\.rowId)), [30, 31])
    }

    func testUpdatePrioritySetReplacesPriorSet() async throws {
        let env = try await makeDB(); defer { env.cleanup() }
        let base = 1_700_000_000
        try await env.db.upsertMessages([
            message(rowid: 40, mailbox: env.inbox, sender: "first@x.com", date: base),
            message(rowid: 41, mailbox: env.inbox, sender: "second@y.com", date: base - 1),
        ])
        try await env.db.incrementalUpdateFTS()

        try await env.db.updatePrioritySet(exact: ["first@x.com"], patterns: [])
        var split = try await env.db.searchSplitByPriority(matchAllQuery(), limitPerBlock: 100)
        XCTAssertEqual(Set(split.priority.map(\.rowId)), [40])

        // Replace the set entirely — the old exact entry must be gone.
        try await env.db.updatePrioritySet(exact: ["second@y.com"], patterns: [])
        split = try await env.db.searchSplitByPriority(matchAllQuery(), limitPerBlock: 100)
        XCTAssertEqual(Set(split.priority.map(\.rowId)), [41],
                       "updatePrioritySet replaces, not appends")
    }

    // MARK: — rowidsMatching

    func testRowidsMatchingFiltersByPriorityBlockAndReadState() async throws {
        let env = try await makeDB(); defer { env.cleanup() }
        let base = 1_700_000_000
        try await env.db.upsertMessages([
            message(rowid: 50, mailbox: env.inbox, sender: "boss@work.com", date: base, isRead: false),     // priority, unread
            message(rowid: 51, mailbox: env.inbox, sender: "boss@work.com", date: base - 1, isRead: true),  // priority, read
            message(rowid: 52, mailbox: env.inbox, sender: "other@x.com", date: base - 2, isRead: false),   // other, unread
        ])
        try await env.db.incrementalUpdateFTS()
        try await env.db.updatePrioritySet(exact: ["boss@work.com"], patterns: [])

        let q = matchAllQuery()
        let priorityUnread = try await env.db.rowidsMatching(q, priority: true, isRead: false)
        XCTAssertEqual(Set(priorityUnread), [50], "priority + unread only")

        let priorityRead = try await env.db.rowidsMatching(q, priority: true, isRead: true)
        XCTAssertEqual(Set(priorityRead), [51], "priority + read only")

        let otherUnread = try await env.db.rowidsMatching(q, priority: false, isRead: false)
        XCTAssertEqual(Set(otherUnread), [52], "other + unread only")
    }

    func testRowidsMatchingEmptyQueryReturnsNothing() async throws {
        let env = try await makeDB(); defer { env.cleanup() }
        try await env.db.upsertMessages([
            message(rowid: 60, mailbox: env.inbox, sender: "a@x.com", date: 1_700_000_000)
        ])
        try await env.db.incrementalUpdateFTS()
        // An unconstrained query (hasAnyConstraint == false) is a guard no-op.
        let empty = Evaluator.compile(QueryParser.parse(""))
        XCTAssertFalse(empty.hasAnyConstraint)
        let rows = try await env.db.rowidsMatching(empty, priority: true, isRead: false)
        XCTAssertTrue(rows.isEmpty)
    }

    // MARK: — sentToAddresses

    /// `sentToAddresses` returns the To/Cc/Bcc addresses of messages whose
    /// sender is one of *our* accounts (i.e. mail you sent) — the auto-prefill
    /// for the priority set.
    func testSentToAddressesReturnsRecipientsOfOurOutgoingMail() async throws {
        let env = try await makeDB(); defer { env.cleanup() }
        let base = 1_700_000_000
        // Message 70: outgoing (sender == our account email).
        // Message 71: incoming (sender is a stranger) — its recipients must NOT
        // be returned.
        try await env.db.upsertMessages([
            message(rowid: 70, mailbox: env.inbox, sender: ourEmail, date: base),
            message(rowid: 71, mailbox: env.inbox, sender: "stranger@x.com", date: base - 1),
        ])
        try await env.db.upsertRecipients([
            // Outgoing recipients (kinds 0/1/2 are To/Cc/Bcc — all counted).
            IndexedRecipient(messageRowId: 70, kind: RecipientKind.to.rawValue, position: 0, address: "Alice@Example.com", display: "Alice"),
            IndexedRecipient(messageRowId: 70, kind: RecipientKind.cc.rawValue, position: 1, address: "bob@example.com", display: "Bob"),
            // Incoming recipient — should be excluded.
            IndexedRecipient(messageRowId: 71, kind: RecipientKind.to.rawValue, position: 0, address: ourEmail, display: "Felix"),
        ])
        try await env.db.incrementalUpdateFTS()

        let sent = try await env.db.sentToAddresses()
        XCTAssertTrue(sent.contains("alice@example.com"), "addresses are lowercased")
        XCTAssertTrue(sent.contains("bob@example.com"), "Cc recipients are counted too")
        XCTAssertFalse(sent.contains(ourEmail),
                       "recipients of *incoming* mail are not part of sentTo")
    }

    /// End-to-end convergence check: feed `sentToAddresses` straight into
    /// `updatePrioritySet` (the real auto-prefill flow) and confirm a message
    /// from one of those addresses is then classified priority by the SQL side.
    func testSentToAddressesFeedsPrioritySetEndToEnd() async throws {
        let env = try await makeDB(); defer { env.cleanup() }
        let base = 1_700_000_000
        try await env.db.upsertMessages([
            message(rowid: 80, mailbox: env.inbox, sender: ourEmail, date: base),          // outgoing to alice
            message(rowid: 81, mailbox: env.inbox, sender: "alice@example.com", date: base - 1), // alice writes back
            message(rowid: 82, mailbox: env.inbox, sender: "spam@x.com", date: base - 2),   // unrelated
        ])
        try await env.db.upsertRecipients([
            IndexedRecipient(messageRowId: 80, kind: RecipientKind.to.rawValue, position: 0, address: "alice@example.com", display: "Alice"),
        ])
        try await env.db.incrementalUpdateFTS()

        let auto = try await env.db.sentToAddresses()
        try await env.db.updatePrioritySet(exact: Array(auto), patterns: [])

        let split = try await env.db.searchSplitByPriority(matchAllQuery(), limitPerBlock: 100)
        XCTAssertTrue(split.priority.map(\.rowId).contains(81),
                      "alice (whom we've emailed) is auto-prioritised when she writes back")
        XCTAssertFalse(split.priority.map(\.rowId).contains(82),
                       "unrelated sender stays in other")
    }
}
