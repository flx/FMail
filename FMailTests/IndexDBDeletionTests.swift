import XCTest
@testable import FMail

/// Coverage for the two delete paths on `IndexDB`:
///
/// - `deleteMessagesByRowid(_:)` — optimistic delete from the local index,
///   called by `ReadStatusController` after a UI / MCP delete dispatch so
///   the UI and follow-up MCP reads reflect the deletion immediately.
/// - `pruneMessagesNotIn(_:)` — orphan cleanup, called by the indexer at
///   the end of a sync to drop rows Apple's Envelope Index no longer
///   exposes (including draft autosaves filtered at fetch time).
final class IndexDBDeletionTests: XCTestCase {

    // MARK: — deleteMessagesByRowid

    func testDeleteMessagesByRowidRemovesFromAllTables() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }

        // Sanity: row exists, body searchable.
        let pre = try await fixture.db.loadMessage(rowid: fixture.schoolMessageRowId)
        XCTAssertNotNil(pre)
        let preSearch = try await fixture.db.search(
            Evaluator.compile(QueryParser.parse("school trip")),
            limit: 10
        )
        XCTAssertTrue(preSearch.contains(where: { $0.rowId == fixture.schoolMessageRowId }))

        try await fixture.db.deleteMessagesByRowid([fixture.schoolMessageRowId])

        // Row gone from messages.
        let post = try await fixture.db.loadMessage(rowid: fixture.schoolMessageRowId)
        XCTAssertNil(post, "messages row must be deleted")

        // FTS no longer matches the deleted row.
        let postSearch = try await fixture.db.search(
            Evaluator.compile(QueryParser.parse("school trip")),
            limit: 10
        )
        XCTAssertFalse(
            postSearch.contains(where: { $0.rowId == fixture.schoolMessageRowId }),
            "messages_fts entry must be deleted alongside the messages row"
        )

        // Other messages untouched.
        let surviving = try await fixture.db.loadMessage(rowid: fixture.lunchMessageRowId)
        XCTAssertNotNil(surviving)
    }

    func testDeleteMessagesByRowidIsNoopForEmptyInput() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }

        try await fixture.db.deleteMessagesByRowid([])
        // Sanity-check nothing was disturbed.
        let school = try await fixture.db.loadMessage(rowid: fixture.schoolMessageRowId)
        let lunch = try await fixture.db.loadMessage(rowid: fixture.lunchMessageRowId)
        XCTAssertNotNil(school)
        XCTAssertNotNil(lunch)
    }

    func testDeleteMessagesByRowidIsIdempotent() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }

        try await fixture.db.deleteMessagesByRowid([fixture.schoolMessageRowId])
        // Second call with the same rowid must not throw.
        try await fixture.db.deleteMessagesByRowid([fixture.schoolMessageRowId])
        let post = try await fixture.db.loadMessage(rowid: fixture.schoolMessageRowId)
        XCTAssertNil(post)
    }

    // MARK: — pruneMessagesNotIn (see below for helpers shared with delete tests)

    func testDeleteThreadMembersDropsEmptyThreadFromQueries() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }

        // Lunch thread has a single member — delete it and confirm thread
        // summaries no longer surface it. Thread aggregates come live from
        // the messages table, so the prior `threads` row becomes invisible.
        try await fixture.db.deleteMessagesByRowid([fixture.lunchMessageRowId])
        let summaries = try await fixture.db.loadAllThreadSummaries(limit: 100)
        XCTAssertFalse(
            summaries.contains(where: { $0.threadId == fixture.lunchThreadId }),
            "thread with no surviving messages must not appear in summaries"
        )
        XCTAssertTrue(summaries.contains(where: { $0.threadId == fixture.schoolThreadId }))
    }

    // MARK: — pruneMessagesNotIn

    func testPruneMessagesNotInDropsRowsAbsentFromKeepSet() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }

        // Keep only the lunch message — simulates Apple's Envelope Index
        // no longer exposing the two school-thread rowids on the next
        // sync (e.g. because they were deleted, or because they're now
        // filtered draft autosaves with type=5).
        try await fixture.db.pruneMessagesNotIn(Set([fixture.lunchMessageRowId]))

        let school = try await fixture.db.loadMessage(rowid: fixture.schoolMessageRowId)
        let reply = try await fixture.db.loadMessage(rowid: fixture.schoolReplyRowId)
        let lunch = try await fixture.db.loadMessage(rowid: fixture.lunchMessageRowId)
        XCTAssertNil(school)
        XCTAssertNil(reply)
        XCTAssertNotNil(lunch)
    }

    func testPruneMessagesNotInDoesNothingWhenAllKept() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }

        let keep: Set<Int> = [
            fixture.schoolMessageRowId,
            fixture.schoolReplyRowId,
            fixture.lunchMessageRowId
        ]
        try await fixture.db.pruneMessagesNotIn(keep)

        for rowid in keep {
            let row = try await fixture.db.loadMessage(rowid: rowid)
            XCTAssertNotNil(row, "rowid \(rowid) was in keep set; must not be deleted")
        }
    }
}
