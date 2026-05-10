import Foundation
@testable import FMail

/// In-process fixture for the MCP tests. Builds a real `IndexDB` on a tmp
/// file path, populates it with two accounts and a small set of messages,
/// and returns the handles tests need (`db`, `bodyLoader`).
///
/// Shape:
///   - account "felix-icloud" (felix@example.com)
///   - mailbox "INBOX" (rowid 100)
///   - message #1: from anna@example.com, subject "School trip update", read
///   - message #2: reply from felix@example.com to anna@example.com, unread
///     (so this is an outgoing message in the "school" thread)
///   - message #3: from kyoko@example.com, subject "Lunch?", read
///   - thread A: messages #1 + #2 (the "school" thread)
///   - thread B: message #3 (the "lunch" thread)
struct Fixture {
    let db: IndexDB
    let bodyLoader: BodyLoader
    let dbPath: String
    let mailVersionDir: URL

    let inboxRowId: Int
    let schoolMessageRowId: Int   // anna's "School trip update"
    let schoolReplyRowId: Int     // felix's reply
    let lunchMessageRowId: Int
    let schoolThreadId: Int
    let lunchThreadId: Int

    static func make() async throws -> Fixture {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fmail-mcp-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dbURL = tmpDir.appendingPathComponent("index.sqlite")
        let mailVersionDir = tmpDir.appendingPathComponent("MailV10")
        try FileManager.default.createDirectory(at: mailVersionDir, withIntermediateDirectories: true)

        let db = try IndexDB(path: dbURL.path)
        let bodyLoader = BodyLoader(mailVersionDir: mailVersionDir)

        // Accounts
        try await db.upsertAccounts([
            (uuid: "ACCT-FELIX", displayName: "Felix iCloud", email: "felix@example.com")
        ])

        // Mailboxes
        let inboxRowId = 100
        let inbox = Mailbox(
            rowId: inboxRowId,
            accountUUID: "ACCT-FELIX",
            pathComponents: ["INBOX"],
            totalCount: 0,
            unreadCount: 0,
            hidden: false,
            kind: .inbox
        )
        try await db.upsertMailboxes([inbox])

        // Messages
        let schoolMsgRowId = 1001
        let schoolReplyRowId = 1002
        let lunchMsgRowId = 1003
        let schoolThreadId = schoolMsgRowId  // root rowid as thread id
        let lunchThreadId = lunchMsgRowId

        let now = Int(Date().timeIntervalSince1970)
        let yesterday = now - 86_400
        let twoDaysAgo = now - 86_400 * 2

        try await db.upsertMessages([
            IndexedMessage(
                appleRowId: schoolMsgRowId,
                appleMessageIdHash: 11,
                mailboxRowId: inboxRowId,
                accountUUID: "ACCT-FELIX",
                subject: "School trip update",
                subjectPrefix: "",
                subjectNormalized: "school trip update",
                senderAddress: "anna@example.com",
                senderDisplay: "Anna",
                dateSent: twoDaysAgo,
                dateReceived: twoDaysAgo,
                isRead: true,
                isFlagged: false,
                hasAttachment: false,
                rfcMessageId: "<school-1@example.com>",
                imapUID: 1
            ),
            IndexedMessage(
                appleRowId: schoolReplyRowId,
                appleMessageIdHash: 12,
                mailboxRowId: inboxRowId,
                accountUUID: "ACCT-FELIX",
                subject: "Re: School trip update",
                subjectPrefix: "Re: ",
                subjectNormalized: "school trip update",
                senderAddress: "felix@example.com",
                senderDisplay: "Felix",
                dateSent: yesterday,
                dateReceived: yesterday,
                isRead: false,
                isFlagged: false,
                hasAttachment: false,
                rfcMessageId: "<school-2@example.com>",
                imapUID: 2
            ),
            IndexedMessage(
                appleRowId: lunchMsgRowId,
                appleMessageIdHash: 13,
                mailboxRowId: inboxRowId,
                accountUUID: "ACCT-FELIX",
                subject: "Lunch?",
                subjectPrefix: "",
                subjectNormalized: "lunch",
                senderAddress: "kyoko@example.com",
                senderDisplay: "Kyoko",
                dateSent: now,
                dateReceived: now,
                isRead: true,
                isFlagged: false,
                hasAttachment: false,
                rfcMessageId: "<lunch-1@example.com>",
                imapUID: 3
            )
        ])

        // Recipients (every message has felix as TO except the outgoing reply,
        // which has anna as TO).
        try await db.upsertRecipients([
            IndexedRecipient(messageRowId: schoolMsgRowId, kind: 0, position: 0, address: "felix@example.com", display: "Felix"),
            IndexedRecipient(messageRowId: schoolReplyRowId, kind: 0, position: 0, address: "anna@example.com", display: "Anna"),
            IndexedRecipient(messageRowId: lunchMsgRowId, kind: 0, position: 0, address: "felix@example.com", display: "Felix")
        ])

        // Threads
        try await db.replaceThreads([
            IndexedThread(
                threadId: schoolThreadId,
                rootMessageRowId: schoolMsgRowId,
                latestDateReceived: yesterday,
                messageCount: 2,
                unreadCount: 1,
                flaggedCount: 0,
                memberRowIds: [schoolMsgRowId, schoolReplyRowId]
            ),
            IndexedThread(
                threadId: lunchThreadId,
                rootMessageRowId: lunchMsgRowId,
                latestDateReceived: now,
                messageCount: 1,
                unreadCount: 0,
                flaggedCount: 0,
                memberRowIds: [lunchMsgRowId]
            )
        ])

        // FTS update: the indexer normally calls this; mirror that here so
        // search returns sensible results.
        try await db.incrementalUpdateFTS()
        // Manually backfill body_text for FTS so searching for body words
        // works even without on-disk .emlx files.
        try await db.setBodyText(messageRowId: schoolMsgRowId, bodyText: "Hi Felix — quick update on the school trip plans for next month.")
        try await db.setBodyText(messageRowId: schoolReplyRowId, bodyText: "Thanks Anna, that works for us. Felix")
        try await db.setBodyText(messageRowId: lunchMsgRowId, bodyText: "Want to grab lunch tomorrow?")

        return Fixture(
            db: db,
            bodyLoader: bodyLoader,
            dbPath: dbURL.path,
            mailVersionDir: mailVersionDir,
            inboxRowId: inboxRowId,
            schoolMessageRowId: schoolMsgRowId,
            schoolReplyRowId: schoolReplyRowId,
            lunchMessageRowId: lunchMsgRowId,
            schoolThreadId: schoolThreadId,
            lunchThreadId: lunchThreadId
        )
    }

    func cleanup() throws {
        let parent = URL(fileURLWithPath: dbPath).deletingLastPathComponent()
        try? FileManager.default.removeItem(at: parent)
    }
}
