import Foundation

/// A user account, identified by the UUID directory under `~/Library/Mail/V*`.
struct MailAccount: Identifiable, Hashable {
    let uuid: String
    let displayName: String
    let emailAddress: String?
    var id: String { uuid }
    var rootURL: URL {
        MailStoreEnumerator.currentMailVersionDirectory()!.appendingPathComponent(uuid)
    }
}

/// A mailbox (= folder, in old-Apple-Mail terms). Each mailbox lives under one
/// account directory; the path components map directly to nested `*.mbox`
/// directories on disk.
struct Mailbox: Identifiable, Hashable {
    let rowId: Int                // mailboxes.ROWID in Envelope Index
    let accountUUID: String
    let pathComponents: [String]  // e.g. ["[Gmail]", "All Mail"] or ["INBOX"]
    let totalCount: Int
    let unreadCount: Int          // computed by FMail, not Apple's drift-prone field
    let hidden: Bool
    let kind: String              // "inbox" / "sent" / "drafts" / "trash" / "junk" / "archive" / "all" / "other"
    var id: Int { rowId }

    var displayName: String { pathComponents.last ?? "(unnamed)" }

    /// Filesystem path to the .mbox directory tree for this mailbox.
    func diskURL(under accountRoot: URL) -> URL {
        var url = accountRoot
        for component in pathComponents {
            url.appendPathComponent("\(component).mbox")
        }
        return url
    }
}

/// Lightweight header-only message info, suitable for showing in a list.
struct MessageHeader: Identifiable, Hashable {
    let rowId: Int                // messages.ROWID — also the .emlx filename
    let mailboxRowId: Int
    let subject: String           // RFC 2047 decoded
    let senderAddress: String
    let senderDisplay: String     // "Display Name" or address if no name
    let dateSent: Date?
    let dateReceived: Date?
    let isRead: Bool
    let isFlagged: Bool
    let rfcMessageId: String?     // RFC 2822 Message-ID header (with angle brackets)
    let imapUID: Int?             // Apple Mail's per-mailbox IMAP UID; lets
                                  // AppleScript do O(1) `whose id is N` lookups
    var id: Int { rowId }
}

/// One attachment extracted from an `.emlx`. `data` holds the decoded bytes
/// (after Content-Transfer-Encoding decode), so saving via `NSSavePanel`
/// is just a `data.write(to:)`.
struct Attachment {
    let name: String
    let contentType: String
    let data: Data
}

/// Fully-parsed message body for display in the reader.
struct MessageBody: Equatable {
    let headers: ParsedHeaders
    let plainText: String?
    let html: String?
    let attachments: [Attachment]

    /// Names of attachments, in order. Convenience for code that only
    /// cares about display (FTS indexing, header line "paperclip + names").
    var attachmentNames: [String] { attachments.map(\.name) }

    /// Best text for rendering: plain if available, otherwise HTML stripped.
    var displayText: String {
        if let plainText, !plainText.isEmpty { return plainText }
        if let html, !html.isEmpty { return HTMLStripper.toPlainText(html) }
        return ""
    }

    static func == (lhs: MessageBody, rhs: MessageBody) -> Bool {
        // Only the textual content + attachment list matters for SwiftUI
        // change detection. Compare attachments by (name, byte count) — full
        // byte-equality on potentially-multi-MB blobs would be wasteful.
        guard lhs.plainText == rhs.plainText, lhs.html == rhs.html else { return false }
        guard lhs.attachments.count == rhs.attachments.count else { return false }
        for (a, b) in zip(lhs.attachments, rhs.attachments) {
            if a.name != b.name || a.data.count != b.data.count { return false }
        }
        return true
    }
}
