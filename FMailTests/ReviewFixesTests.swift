import SQLite3
import XCTest
@testable import FMail

/// Regression tests for the 2026-11-19 review findings `mcp-int-overflow-trap`
/// and `body-sweep-marks-missing-done`. (The MIME crash is covered in
/// `EmlxParsingTests`, the OAuth pairing code in `OAuthFlowTests`.)
final class ReviewFixesTests: XCTestCase {

    // MARK: — mcp-int-overflow-trap

    func testIntValueRejectsOutOfRangeNumbersInsteadOfTrapping() {
        XCTAssertNil(JSONValue.double(1e300).intValue)
        XCTAssertNil(JSONValue.double(9_223_372_036_854_775_808).intValue)  // 2^63
        XCTAssertNil(JSONValue.double(-1e300).intValue)
        XCTAssertNil(JSONValue.double(.nan).intValue)
        XCTAssertNil(JSONValue.double(.infinity).intValue)
        XCTAssertEqual(JSONValue.double(42.9).intValue, 42)
        XCTAssertEqual(JSONValue.double(-3.5).intValue, -3)
        XCTAssertEqual(JSONValue.int(7).intValue, 7)
    }

    func testHugeOffsetsDoNotOverflow() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }
        let ctx = MCPContext(indexDB: fixture.db, bodyLoader: fixture.bodyLoader)
        let big = JSONValue.int(Int64.max)
        // Both used to compute `offset + limit` unchecked.
        _ = try await MCPHandlers.listThreads(.object(["offset": big, "limit": .int(600)]), context: ctx)
        _ = try await MCPHandlers.listThreads(.object(["offset": big, "dedupe": .bool(true)]), context: ctx)
        _ = try await MCPHandlers.searchEmails(.object(["query": .string("lunch"), "offset": big]), context: ctx)
        // Out-of-range doubles fall back to the default instead of trapping.
        _ = try await MCPHandlers.listThreads(.object(["limit": .double(1e300)]), context: ctx)
    }

    // MARK: — body-sweep-marks-missing-done

    private func sql(_ path: String, _ statement: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw XCTSkip("open failed") }
        defer { sqlite3_close(db) }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, statement, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "?"
            sqlite3_free(err)
            XCTFail("SQL failed: \(msg)")
        }
    }

    private func bodyState(_ path: String, rowid: Int) -> Int {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { return -1 }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT body_indexed FROM messages WHERE apple_rowid = \(rowid)", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : -1
    }

    /// Write `<rowid>.emlx` where BodyLoader looks for the fixture's INBOX.
    private func writeEmlx(_ fixture: Fixture, rowid: Int, body: String) throws {
        let dir = fixture.mailVersionDir
            .appendingPathComponent("ACCT-FELIX/INBOX.mbox/MAILBOX-UUID/Data/0/0/0/Messages")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rfc = Data("From: anna@example.com\nSubject: s\nContent-Type: text/plain\n\n\(body)\n".utf8)
        try (Data("\(rfc.count)\n".utf8) + rfc).write(to: dir.appendingPathComponent("\(rowid).emlx"))
    }

    func testMissingBodyIsRetriedOnceTheFileAppears() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }
        let rowid = fixture.schoolReplyRowId  // unread in the fixture
        try sql(fixture.dbPath, "UPDATE messages SET body_indexed = 0 WHERE apple_rowid = \(rowid)")
        let loaded = try await fixture.db.loadMailbox(rowid: fixture.inboxRowId)
        let inbox = try XCTUnwrap(loaded)
        let indexer = BodyIndexer(indexDB: fixture.db, bodyLoader: fixture.bodyLoader)

        // 1. No .emlx yet: marked missing (2), not indexed (1).
        await indexer.runUntilDone(mailboxes: [inbox]) { _ in }
        XCTAssertEqual(bodyState(fixture.dbPath, rowid: rowid), Schema.bodyMissing)
        // Still queued for a Mail.app fetch, and not reported as on disk.
        let missing = try await fixture.db.fetchUnreadMissingBody(limit: nil).map(\.rowid)
        XCTAssertTrue(missing.contains(rowid))
        let onDisk = try await fixture.db.enrichForMCP(rowids: [rowid])[rowid]?.bodyOnDisk
        XCTAssertEqual(onDisk, false)

        // 2. Mail.app delivers the file; the next sweep (after a sync drops the
        //    loader cache) indexes it.
        try writeEmlx(fixture, rowid: rowid, body: "zebrafish budget approved")
        await fixture.bodyLoader.invalidateAll()
        await indexer.runUntilDone(mailboxes: [inbox]) { _ in }
        XCTAssertEqual(bodyState(fixture.dbPath, rowid: rowid), Schema.bodyIndexed)
        let hits = try await fixture.db.search(compile("body:zebrafish"), limit: 10).map(\.rowId)
        XCTAssertEqual(hits, [rowid])
    }

    func testMigrationRequeuesEmptyBodiesMarkedIndexed() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }
        // Simulate the pre-v10 bug: a missing file recorded as indexed + empty.
        try await fixture.db.setBodyText(messageRowId: fixture.lunchMessageRowId, bodyText: "")
        try sql(fixture.dbPath, "DELETE FROM schema_version WHERE version = 10")

        _ = try IndexDB(path: fixture.dbPath)  // re-runs migrateTo10

        XCTAssertEqual(bodyState(fixture.dbPath, rowid: fixture.lunchMessageRowId), Schema.bodyNotSwept)
        XCTAssertEqual(bodyState(fixture.dbPath, rowid: fixture.schoolMessageRowId), Schema.bodyIndexed,
                       "rows with real body text are left alone")
    }

    private func compile(_ s: String) -> CompiledQuery {
        Evaluator.compile(QueryParser.parse(s))
    }
}
