import Foundation
import SQLite3

enum EnvelopeIndexError: Error, CustomStringConvertible {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case noRow

    var description: String {
        switch self {
        case .openFailed(let m): return "Could not open Envelope Index: \(m)"
        case .prepareFailed(let m): return "Could not prepare statement: \(m)"
        case .stepFailed(let m): return "Step failed: \(m)"
        case .noRow: return "No row returned"
        }
    }
}

/// Smoke-test reader for Apple Mail's `Envelope Index` SQLite database.
/// Used only by `Phase0Tests` to verify the on-disk schema looks like what
/// FMail expects. Production sync uses `EnvelopeReadOnly` below.
final class EnvelopeIndexReader {
    private var db: OpaquePointer?

    init(path: String) throws {
        // Read-only. Don't use `?immutable=1` — Mail.app is actively writing,
        // and immutable mode would give us a stale snapshot.
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        if rc != SQLITE_OK {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown (rc=\(rc))"
            sqlite3_close(handle)
            throw EnvelopeIndexError.openFailed(msg)
        }
        self.db = handle
    }

    deinit {
        sqlite3_close(db)
    }

    func messageCount() throws -> Int {
        try scalarInt("SELECT count(*) FROM messages")
    }

    func mailboxCount() throws -> Int {
        try scalarInt("SELECT count(*) FROM mailboxes")
    }

    private func scalarInt(_ sql: String) throws -> Int {
        var stmt: OpaquePointer?
        let prep = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        if prep != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            throw EnvelopeIndexError.prepareFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        let step = sqlite3_step(stmt)
        guard step == SQLITE_ROW else {
            if step == SQLITE_DONE { throw EnvelopeIndexError.noRow }
            let msg = String(cString: sqlite3_errmsg(db))
            throw EnvelopeIndexError.stepFailed(msg)
        }
        return Int(sqlite3_column_int64(stmt, 0))
    }
}

/// Production read-only reader for Apple Mail's Envelope Index. Owned by
/// `Indexer.runFullSync` for the duration of one sync pass. Caller closes
/// via `close()` when done — explicit so we can release the SQLite handle
/// before the next sync without waiting for ARC.
final class EnvelopeReadOnly {
    let db: OpaquePointer

    init(path: String) throws {
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        if rc != SQLITE_OK {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "rc=\(rc)"
            sqlite3_close(handle)
            throw EnvelopeIndexError.openFailed(msg)
        }
        self.db = handle!
    }

    func close() { sqlite3_close(db) }

    struct RawMessage {
        let rowId: Int
        let messageIdHash: Int64
        let mailboxRowId: Int
        let accountUUID: String
        let subjectPrefix: String
        let subjectText: String
        let senderAddress: String
        let senderDisplay: String
        let dateSent: Int?
        let dateReceived: Int?
        let isRead: Bool
        let isFlagged: Bool
        let hasAttachment: Bool
        let rfcMessageId: String?
        let imapUID: Int?
    }

    struct RawRecipient {
        let messageRowId: Int
        let kind: Int
        let position: Int
        let address: String
        let display: String
    }

    struct RawReference {
        let fromRowId: Int
        let toHash: Int64
        let isParent: Bool
    }

    func loadMailboxes() throws -> [Mailbox] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT ROWID, url FROM mailboxes ORDER BY ROWID", -1, &stmt, nil) == SQLITE_OK else {
            throw EnvelopeIndexError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var out: [Mailbox] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowid = Int(sqlite3_column_int64(stmt, 0))
            guard let urlCStr = sqlite3_column_text(stmt, 1) else { continue }
            let urlStr = String(cString: urlCStr)
            guard let parsed = MailboxURL.parse(urlStr) else { continue }
            let hidden = MailboxFilter.isHiddenByDefault(pathComponents: parsed.pathComponents)
            // kind field is set by IndexDB.upsertMailboxes from displayName;
            // pass placeholder here since this Mailbox is only used for insert.
            out.append(Mailbox(
                rowId: rowid,
                accountUUID: parsed.accountUUID,
                pathComponents: parsed.pathComponents,
                totalCount: 0,
                unreadCount: 0,
                hidden: hidden,
                kind: "other"
            ))
        }
        return out
    }

    func likelyEmailAddress(forAccountUUID uuid: String, mailboxes: [Mailbox]) throws -> String? {
        if let s = sentHeuristic(uuid: uuid, mailboxes: mailboxes) {
            return s
        }
        return recipientHeuristic(uuid: uuid, mailboxes: mailboxes)
    }

    /// Most-common-sender from this account's Sent mailbox. Best signal
    /// when the user has actually sent mail from the account.
    private func sentHeuristic(uuid: String, mailboxes: [Mailbox]) -> String? {
        let sentRowIds = mailboxes
            .filter { $0.accountUUID == uuid && ($0.displayName == "Sent Messages" || $0.displayName == "Sent Mail") }
            .map(\.rowId)
        guard !sentRowIds.isEmpty else { return nil }
        let placeholders = sentRowIds.map { _ in "?" }.joined(separator: ",")
        // Gmail Sent mailboxes contain messages via labels, not direct
        // mailbox assignment. Query both paths.
        let sql = """
        WITH sent_msgs AS (
            SELECT m.ROWID
            FROM messages m
            WHERE m.mailbox IN (\(placeholders)) AND m.deleted = 0
            UNION
            SELECT l.message_id AS ROWID
            FROM labels l JOIN messages m ON m.ROWID = l.message_id
            WHERE l.mailbox_id IN (\(placeholders)) AND m.deleted = 0
        )
        SELECT a.address, COUNT(*) as c
        FROM messages m JOIN addresses a ON a.ROWID = m.sender
        WHERE m.ROWID IN (SELECT ROWID FROM sent_msgs)
        GROUP BY a.address
        ORDER BY c DESC
        LIMIT 1
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        var idx: Int32 = 1
        for id in sentRowIds {
            sqlite3_bind_int64(stmt, idx, Int64(id))
            idx += 1
        }
        for id in sentRowIds {
            sqlite3_bind_int64(stmt, idx, Int64(id))
            idx += 1
        }
        if sqlite3_step(stmt) == SQLITE_ROW, let cstr = sqlite3_column_text(stmt, 0) {
            return String(cString: cstr)
        }
        return nil
    }

    /// Fallback: most-common To-recipient across this account's incoming
    /// mail. Handles accounts with no Sent mailbox (receive-only, IMAP-only,
    /// secondary "Outbox"-named mailbox) — the user's own email is reliably
    /// the top recipient. Returns nil if the account has no mail at all.
    private func recipientHeuristic(uuid: String, mailboxes: [Mailbox]) -> String? {
        let mboxIds = mailboxes.filter { $0.accountUUID == uuid }.map(\.rowId)
        guard !mboxIds.isEmpty else { return nil }
        let placeholders = mboxIds.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT a.address, COUNT(*) as c
        FROM recipients r
        JOIN addresses a ON a.ROWID = r.address
        JOIN messages m ON m.ROWID = r.message
        WHERE m.mailbox IN (\(placeholders)) AND m.deleted = 0 AND r.type = 0
        GROUP BY a.address
        ORDER BY c DESC
        LIMIT 1
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        for (idx, id) in mboxIds.enumerated() {
            sqlite3_bind_int64(stmt, Int32(idx + 1), Int64(id))
        }
        if sqlite3_step(stmt) == SQLITE_ROW, let cstr = sqlite3_column_text(stmt, 0) {
            return String(cString: cstr)
        }
        return nil
    }

    func fetchAllLabels() throws -> [(messageRowId: Int, mailboxRowId: Int)] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT message_id, mailbox_id FROM labels", -1, &stmt, nil) == SQLITE_OK else {
            throw EnvelopeIndexError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        var out: [(Int, Int)] = []
        out.reserveCapacity(300_000)
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append((Int(sqlite3_column_int64(stmt, 0)), Int(sqlite3_column_int64(stmt, 1))))
        }
        return out.map { (messageRowId: $0.0, mailboxRowId: $0.1) }
    }

    func fetchAllMessages() throws -> [RawMessage] {
        // The RFC 2822 Message-ID header lives in `message_global_data`. The FK
        // is `messages.global_message_id` → `message_global_data.ROWID` (NOT
        // `mgd.message_id`, which is some other internal hash).
        let sql = """
        SELECT m.ROWID, m.message_id, m.mailbox, mb.url, COALESCE(m.subject_prefix, ''),
               COALESCE(s.subject, ''),
               COALESCE(a.address, ''),
               COALESCE(a.comment, ''),
               m.date_sent, m.date_received,
               m.read, m.flagged,
               EXISTS(SELECT 1 FROM attachments at WHERE at.message = m.ROWID),
               mgd.message_id_header,
               m.remote_id
        FROM messages m
        JOIN mailboxes mb ON mb.ROWID = m.mailbox
        LEFT JOIN subjects s ON s.ROWID = m.subject
        LEFT JOIN addresses a ON a.ROWID = m.sender
        LEFT JOIN message_global_data mgd ON mgd.ROWID = m.global_message_id
        WHERE m.deleted = 0
        ORDER BY m.ROWID
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EnvelopeIndexError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var out: [RawMessage] = []
        out.reserveCapacity(160_000)
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowid = Int(sqlite3_column_int64(stmt, 0))
            let hash = sqlite3_column_int64(stmt, 1)
            let mboxId = Int(sqlite3_column_int64(stmt, 2))
            let urlStr = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            let parsed = MailboxURL.parse(urlStr)
            let acct = parsed?.accountUUID ?? ""
            let prefix = String(cString: sqlite3_column_text(stmt, 4))
            let subj = String(cString: sqlite3_column_text(stmt, 5))
            let saddr = String(cString: sqlite3_column_text(stmt, 6))
            let sdisp = String(cString: sqlite3_column_text(stmt, 7))
            let ds = sqlite3_column_int64(stmt, 8)
            let dr = sqlite3_column_int64(stmt, 9)
            let read = sqlite3_column_int(stmt, 10) != 0
            let flagged = sqlite3_column_int(stmt, 11) != 0
            let hasAtt = sqlite3_column_int(stmt, 12) != 0
            let rfcId = sqlite3_column_text(stmt, 13).map { String(cString: $0) }
            let uidVal = sqlite3_column_int64(stmt, 14)
            let uid: Int? = sqlite3_column_type(stmt, 14) == SQLITE_NULL ? nil : Int(uidVal)

            out.append(RawMessage(
                rowId: rowid, messageIdHash: hash, mailboxRowId: mboxId, accountUUID: acct,
                subjectPrefix: prefix, subjectText: subj,
                senderAddress: saddr, senderDisplay: sdisp,
                dateSent: ds > 0 ? Int(ds) : nil,
                dateReceived: dr > 0 ? Int(dr) : nil,
                isRead: read, isFlagged: flagged, hasAttachment: hasAtt,
                rfcMessageId: rfcId,
                imapUID: uid
            ))
        }
        return out
    }

    func fetchAllRecipients() throws -> [RawRecipient] {
        let sql = """
        SELECT r.message, r.type, r.position, a.address, COALESCE(a.comment, '')
        FROM recipients r
        JOIN addresses a ON a.ROWID = r.address
        ORDER BY r.message
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EnvelopeIndexError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var out: [RawRecipient] = []
        out.reserveCapacity(250_000)
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(RawRecipient(
                messageRowId: Int(sqlite3_column_int64(stmt, 0)),
                kind: Int(sqlite3_column_int64(stmt, 1)),
                position: Int(sqlite3_column_int64(stmt, 2)),
                address: String(cString: sqlite3_column_text(stmt, 3)),
                display: String(cString: sqlite3_column_text(stmt, 4))
            ))
        }
        return out
    }

    func fetchAllReferences() throws -> [RawReference] {
        let sql = "SELECT message, reference, is_originator FROM message_references ORDER BY message"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EnvelopeIndexError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var out: [RawReference] = []
        out.reserveCapacity(500_000)
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(RawReference(
                fromRowId: Int(sqlite3_column_int64(stmt, 0)),
                toHash: sqlite3_column_int64(stmt, 1),
                isParent: sqlite3_column_int(stmt, 2) != 0
            ))
        }
        return out
    }
}
