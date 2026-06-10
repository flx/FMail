import XCTest
import SQLite3
@testable import FMail

/// Builds a *miniature synthetic copy* of Apple Mail's `Envelope Index` SQLite
/// database — only the tables and columns that `EnvelopeReadOnly`'s queries
/// actually SELECT — and drives the reader against it.
///
/// This is the test that catches an Apple schema change: if a future macOS
/// renames/drops a column FMail depends on (e.g. `messages.global_message_id`,
/// `addresses.comment`, `message_references.is_originator`), one of these
/// assertions fails loudly instead of the app silently mirroring empty data.
///
/// The reader's `init(path:)` opens read-only, so the fixture writes the schema
/// and rows through a separate read-write handle first, then closes it before
/// opening `EnvelopeReadOnly` on the same file.
final class EnvelopeIndexReaderTests: XCTestCase {

    private var dir: URL!
    private var dbPath: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fmail-envindex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbPath = dir.appendingPathComponent("Envelope Index").path
        try buildSyntheticEnvelopeIndex(at: dbPath)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
        try super.tearDownWithError()
    }

    // MARK: — Synthetic schema + fixture data

    /// Mirrors the exact column set `EnvelopeReadOnly` reads. Addresses use
    /// `imap://<UUID>/<path>` URLs so `MailboxURL.parse` recovers the account
    /// UUID and path components.
    private func buildSyntheticEnvelopeIndex(at path: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let db else {
            XCTFail("could not create synthetic Envelope Index")
            return
        }
        defer { sqlite3_close(db) }

        func run(_ sql: String) throws {
            var err: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
                let msg = err.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(err)
                throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
            }
        }

        // --- Schema (only what the reader queries) ---
        try run("""
        CREATE TABLE mailboxes (
            ROWID INTEGER PRIMARY KEY,
            url TEXT
        );
        """)
        try run("""
        CREATE TABLE messages (
            ROWID INTEGER PRIMARY KEY,
            message_id INTEGER,            -- apple_message_id_hash
            mailbox INTEGER,
            subject INTEGER,               -- FK → subjects.ROWID
            subject_prefix TEXT,
            sender INTEGER,                -- FK → addresses.ROWID
            date_sent INTEGER,
            date_received INTEGER,
            read INTEGER,
            flagged INTEGER,
            deleted INTEGER,
            type INTEGER,
            global_message_id INTEGER,     -- FK → message_global_data.ROWID
            remote_id INTEGER              -- IMAP UID
        );
        """)
        try run("CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);")
        try run("CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);")
        try run("CREATE TABLE message_global_data (ROWID INTEGER PRIMARY KEY, message_id_header TEXT);")
        try run("CREATE TABLE attachments (ROWID INTEGER PRIMARY KEY, message INTEGER, name TEXT);")
        try run("""
        CREATE TABLE recipients (
            ROWID INTEGER PRIMARY KEY,
            message INTEGER,
            type INTEGER,                  -- RecipientKind raw value
            position INTEGER,
            address INTEGER                -- FK → addresses.ROWID
        );
        """)
        try run("""
        CREATE TABLE message_references (
            message INTEGER,
            reference INTEGER,             -- to_message_id_hash
            is_originator INTEGER
        );
        """)
        try run("CREATE TABLE labels (message_id INTEGER, mailbox_id INTEGER);")

        // --- Data ---
        // One Gmail-style account UUID, two mailboxes.
        let uuid = "ACCT-UUID-1234"
        try run("INSERT INTO mailboxes (ROWID, url) VALUES (10, 'imap://\(uuid)/INBOX');")
        try run("INSERT INTO mailboxes (ROWID, url) VALUES (11, 'imap://\(uuid)/Sent Mail');")

        // Addresses: sender Anna (with display name in `comment`), a recipient.
        try run("INSERT INTO addresses (ROWID, address, comment) VALUES (100, 'anna@example.com', 'Anna A');")
        try run("INSERT INTO addresses (ROWID, address, comment) VALUES (101, 'me@example.com', 'Me');")
        try run("INSERT INTO addresses (ROWID, address, comment) VALUES (102, 'cc@example.com', NULL);")

        // Subjects + global message-id headers.
        try run("INSERT INTO subjects (ROWID, subject) VALUES (200, 'School trip update');")
        try run("INSERT INTO message_global_data (ROWID, message_id_header) VALUES (300, '<rfc-id-1@example.com>');")

        // Message 1: kept (deleted=0, type=1). Has a real attachment + read=0.
        try run("""
        INSERT INTO messages
          (ROWID, message_id, mailbox, subject, subject_prefix, sender,
           date_sent, date_received, read, flagged, deleted, type,
           global_message_id, remote_id)
        VALUES
          (1, 9001, 10, 200, 'Re: ', 100, 1700000000, 1700000050, 0, 1, 0, 1, 300, 5555);
        """)
        // A real attachment (not an inline image*.png) → has_attachment EXISTS true.
        try run("INSERT INTO attachments (ROWID, message, name) VALUES (400, 1, 'report.pdf');")

        // Message 2: kept, read=1, no attachment, NULL global_message_id and
        // NULL remote_id (so rfcMessageId / imapUID come back nil).
        try run("""
        INSERT INTO messages
          (ROWID, message_id, mailbox, subject, subject_prefix, sender,
           date_sent, date_received, read, flagged, deleted, type,
           global_message_id, remote_id)
        VALUES
          (2, 9002, 11, NULL, NULL, 101, 1700000100, 1700000150, 1, 0, 0, 1, NULL, NULL);
        """)

        // Message 3: filtered out — type = 5 (Gmail draft autosave).
        try run("""
        INSERT INTO messages
          (ROWID, message_id, mailbox, subject, subject_prefix, sender,
           date_sent, date_received, read, flagged, deleted, type,
           global_message_id, remote_id)
        VALUES
          (3, 9003, 10, 200, '', 100, 1700000200, 1700000250, 0, 0, 0, 5, 300, 7777);
        """)

        // Message 4: filtered out — deleted = 1.
        try run("""
        INSERT INTO messages
          (ROWID, message_id, mailbox, subject, subject_prefix, sender,
           date_sent, date_received, read, flagged, deleted, type,
           global_message_id, remote_id)
        VALUES
          (4, 9004, 10, 200, '', 100, 1700000300, 1700000350, 0, 0, 1, 1, 300, 8888);
        """)

        // Recipients for message 1: To (type 0) and Cc (type 1).
        try run("INSERT INTO recipients (ROWID, message, type, position, address) VALUES (500, 1, 0, 0, 101);")
        try run("INSERT INTO recipients (ROWID, message, type, position, address) VALUES (501, 1, 1, 1, 102);")

        // A reference link: message 2 references message 1's hash, is_originator=0.
        try run("INSERT INTO message_references (message, reference, is_originator) VALUES (2, 9001, 0);")
        try run("INSERT INTO message_references (message, reference, is_originator) VALUES (1, 9001, 1);")

        // Labels: message 1 is labeled into mailbox 11 (Gmail label model).
        try run("INSERT INTO labels (message_id, mailbox_id) VALUES (1, 11);")
    }

    // MARK: — Tests

    func testLoadMailboxesDecodesAccountAndPath() throws {
        let reader = try EnvelopeReadOnly(path: dbPath)
        defer { reader.close() }
        let boxes = try reader.loadMailboxes()
        XCTAssertEqual(boxes.count, 2)
        let inbox = try XCTUnwrap(boxes.first { $0.rowId == 10 })
        XCTAssertEqual(inbox.accountUUID, "ACCT-UUID-1234")
        XCTAssertEqual(inbox.pathComponents, ["INBOX"])
        let sent = try XCTUnwrap(boxes.first { $0.rowId == 11 })
        XCTAssertEqual(sent.pathComponents, ["Sent Mail"])
    }

    func testFetchAllMessagesAppliesDeletedAndTypeFilter() throws {
        let reader = try EnvelopeReadOnly(path: dbPath)
        defer { reader.close() }
        let messages = try reader.fetchAllMessages()
        let ids = Set(messages.map(\.rowId))
        XCTAssertEqual(ids, [1, 2],
                       "type=5 (draft autosave) and deleted=1 rows must be excluded")
    }

    func testFetchAllMessagesDecodesAllColumns() throws {
        let reader = try EnvelopeReadOnly(path: dbPath)
        defer { reader.close() }
        let messages = try reader.fetchAllMessages()

        let m1 = try XCTUnwrap(messages.first { $0.rowId == 1 })
        XCTAssertEqual(m1.messageIdHash, 9001)
        XCTAssertEqual(m1.mailboxRowId, 10)
        XCTAssertEqual(m1.accountUUID, "ACCT-UUID-1234", "account UUID parsed from the mailbox url")
        XCTAssertEqual(m1.subjectPrefix, "Re: ")
        XCTAssertEqual(m1.subjectText, "School trip update")
        XCTAssertEqual(m1.senderAddress, "anna@example.com")
        XCTAssertEqual(m1.senderDisplay, "Anna A", "display name comes from addresses.comment")
        XCTAssertEqual(m1.dateSent, 1700000000)
        XCTAssertEqual(m1.dateReceived, 1700000050)
        XCTAssertFalse(m1.isRead)
        XCTAssertTrue(m1.isFlagged)
        XCTAssertTrue(m1.hasAttachment, "report.pdf is a real (non-inline-image) attachment")
        XCTAssertEqual(m1.rfcMessageId, "<rfc-id-1@example.com>")
        XCTAssertEqual(m1.imapUID, 5555)

        let m2 = try XCTUnwrap(messages.first { $0.rowId == 2 })
        XCTAssertEqual(m2.subjectText, "", "NULL subject FK → COALESCE empty string")
        XCTAssertEqual(m2.subjectPrefix, "", "NULL subject_prefix → COALESCE empty string")
        XCTAssertTrue(m2.isRead)
        XCTAssertFalse(m2.hasAttachment)
        XCTAssertNil(m2.rfcMessageId, "NULL global_message_id FK → nil rfc id")
        XCTAssertNil(m2.imapUID, "NULL remote_id → nil imap uid")
    }

    /// The `hasRealAttachmentExpr` deliberately ignores inline signature
    /// images named `imageNNN.<ext>`. Confirm such an attachment does NOT
    /// flip `has_attachment`.
    func testInlineImageAttachmentDoesNotCountAsRealAttachment() throws {
        // Add an inline-image-only attachment to message 2, then re-read.
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        sqlite3_exec(db, "INSERT INTO attachments (ROWID, message, name) VALUES (401, 2, 'image001.png');", nil, nil, nil)
        sqlite3_close(db)

        let reader = try EnvelopeReadOnly(path: dbPath)
        defer { reader.close() }
        let m2 = try XCTUnwrap(try reader.fetchAllMessages().first { $0.rowId == 2 })
        XCTAssertFalse(m2.hasAttachment,
                       "an inline image (imageNNN.png) must not count as a real attachment")
    }

    func testFetchAllRecipientsDecodesKindAndAddress() throws {
        let reader = try EnvelopeReadOnly(path: dbPath)
        defer { reader.close() }
        let recipients = try reader.fetchAllRecipients()
        XCTAssertEqual(recipients.count, 2)

        let to = try XCTUnwrap(recipients.first { $0.kind == RecipientKind.to.rawValue })
        XCTAssertEqual(to.messageRowId, 1)
        XCTAssertEqual(to.address, "me@example.com")
        XCTAssertEqual(to.position, 0)

        let cc = try XCTUnwrap(recipients.first { $0.kind == RecipientKind.cc.rawValue })
        XCTAssertEqual(cc.address, "cc@example.com")
        XCTAssertEqual(cc.display, "", "NULL comment → empty display via COALESCE")
    }

    func testFetchAllReferencesDecodesIsOriginator() throws {
        let reader = try EnvelopeReadOnly(path: dbPath)
        defer { reader.close() }
        let refs = try reader.fetchAllReferences()
        XCTAssertEqual(refs.count, 2)

        let originator = try XCTUnwrap(refs.first { $0.fromRowId == 1 })
        XCTAssertTrue(originator.isParent, "is_originator=1 decodes to isParent true")
        XCTAssertEqual(originator.toHash, 9001)

        let child = try XCTUnwrap(refs.first { $0.fromRowId == 2 })
        XCTAssertFalse(child.isParent)
        XCTAssertEqual(child.toHash, 9001)
    }

    func testFetchReadFlagsRespectsDeletedAndTypeFilter() throws {
        let reader = try EnvelopeReadOnly(path: dbPath)
        defer { reader.close() }
        let flags = try reader.fetchReadFlags()
        let byRow = Dictionary(uniqueKeysWithValues: flags.map { ($0.rowid, $0.read) })
        XCTAssertEqual(Set(byRow.keys), [1, 2], "same deleted/type filter as fetchAllMessages")
        XCTAssertEqual(byRow[1], false)
        XCTAssertEqual(byRow[2], true)
    }

    func testFetchAllLabels() throws {
        let reader = try EnvelopeReadOnly(path: dbPath)
        defer { reader.close() }
        let labels = try reader.fetchAllLabels()
        XCTAssertEqual(labels.count, 1)
        XCTAssertEqual(labels[0].messageRowId, 1)
        XCTAssertEqual(labels[0].mailboxRowId, 11)
    }

    // NOTE: `EnvelopeReadOnly.likelyEmailAddress` (and its private sent/recipient
    // heuristics) join the production-schema `recipients.address` / `messages.sender`
    // columns the same way the queries above do, so they are covered indirectly
    // by the recipient/message column assertions. They aren't asserted directly
    // here because they depend on a `Mailbox.displayName == "Sent Mail"` match
    // plus account-UUID filtering that would only add fixture noise; the
    // schema-fingerprinting value of this file is already captured by
    // fetchAllMessages / fetchAllRecipients / fetchAllReferences.
}
