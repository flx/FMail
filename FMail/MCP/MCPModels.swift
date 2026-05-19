import Foundation

/// MCP DTOs — the stable JSON shapes returned to LLM clients. Decoupled from
/// internal types so refactors of `MessageHeader` / `ThreadSummary` don't
/// silently change the contract. Field names are snake_case to match what
/// LLMs typically expect from JSON APIs.

struct EmailRef: Codable, Sendable {
    let rowid: Int
    let subject: String
    let sender_display: String
    let sender_address: String
    let date_sent: String?
    let date_received: String?
    let mailbox_path: String
    let is_read: Bool
    let is_flagged: Bool
    let has_attachment: Bool
    let thread_id: Int
    /// True when the `.emlx` for this message has been parsed by
    /// FMail's body indexer. `get_email` / `get_thread` / `get_attachment`
    /// can return body / attachment content for these rows without
    /// requiring Mail.app to do an IMAP fetch. `false` rows may still
    /// work but can also fail with "body not on disk" — the LLM should
    /// prefer `body_on_disk:true` rows when there's a choice.
    let body_on_disk: Bool
}

struct AttachmentRef: Codable, Sendable {
    let name: String
    let content_type: String
    let byte_count: Int
}

/// Attachment bytes returned by `get_attachment` *without* `save_to_path`.
/// `data_base64` holds the decoded (post-MIME-decode) raw file contents,
/// base64-encoded for safe JSON transport. `truncated` is true when the
/// caller's `max_bytes` was below `byte_count` — re-call with a larger
/// cap (or pass `save_to_path` to skip the size cap entirely).
struct AttachmentContent: Codable, Sendable {
    let rowid: Int
    let attachment_index: Int
    let name: String
    let content_type: String
    let byte_count: Int
    let data_base64: String
    let truncated: Bool
}

/// Attachment metadata returned by `get_attachment` when `save_to_path`
/// was supplied. No `data_base64` — the bytes are on disk at `saved_path`.
/// Lets MCP clients sidestep the per-tool-call result-size cap that
/// would otherwise force them to three-hop (tool → disk → shell decode)
/// for any non-trivial PDF.
struct AttachmentSaved: Codable, Sendable {
    let rowid: Int
    let attachment_index: Int
    let name: String
    let content_type: String
    let byte_count: Int
    let saved_path: String
}

/// One row in the result of `get_attachments_for_rowids`. Either `saved`
/// is set (success) or `error` is (couldn't fetch body, no such index,
/// I/O failure on write, etc.) — never both.
struct BulkAttachmentRow: Codable, Sendable {
    let rowid: Int
    let attachment_index: Int
    let name: String?
    let content_type: String?
    let byte_count: Int?
    let saved_path: String?
    let error: String?
}

struct BulkAttachmentResult: Codable, Sendable {
    let saved: [BulkAttachmentRow]
    let errors: [BulkAttachmentRow]
}

struct EmailFull: Codable, Sendable {
    let rowid: Int
    let thread_id: Int
    let mailbox_path: String
    let subject: String
    let sender_display: String
    let sender_address: String
    let to: [String]
    let cc: [String]
    let bcc: [String]
    let date_sent: String?
    let date_received: String?
    let is_read: Bool
    let is_flagged: Bool
    let rfc_message_id: String?
    /// See `EmailRef.body_on_disk`. Useful when the LLM is fanning out
    /// across thread members and wants to know which ones need a fetch.
    let body_on_disk: Bool
    let plain_text_body: String
    let plain_text_truncated: Bool
    let plain_text_full_chars: Int
    let html_body_present: Bool
    let attachments: [AttachmentRef]
}

struct ThreadRef: Codable, Sendable {
    let thread_id: Int
    let latest_subject: String
    let latest_sender_display: String
    let latest_date_received: String?
    let message_count: Int
    let unread_count: Int
    let flagged_count: Int
    let latest_is_outgoing: Bool
}

struct UnansweredThread: Codable, Sendable {
    let thread_id: Int
    let latest_subject: String
    let latest_outgoing_address: String
    let latest_date_received: String?
    let days_silent: Int
    let recipient_addresses: [String]
}

// MARK: — Result envelopes (one per tool)

struct SearchEmailsResult: Codable, Sendable {
    let results: [EmailRef]
}

struct ListThreadsResult: Codable, Sendable {
    let threads: [ThreadRef]
}

struct GetThreadResult: Codable, Sendable {
    let messages: [EmailFull]
}

struct FindUnansweredThreadsResult: Codable, Sendable {
    let threads: [UnansweredThread]
}

struct MarkReadResult: Codable, Sendable {
    let applied: Int
    let error: String?
}

// MARK: — Date / encoding helpers

private struct ISO8601: Sendable {
    static func format(_ date: Date) -> String { date.formatted(.iso8601) }
}

extension Date {
    /// ISO-8601 string with seconds precision, suitable for JSON DTOs.
    func mcpISO8601() -> String { ISO8601.format(self) }
}

extension Optional where Wrapped == Date {
    func mcpISO8601() -> String? {
        guard let self else { return nil }
        return ISO8601.format(self)
    }
}

extension JSONValue {
    /// Encode any `Encodable` Swift value to a `JSONValue` tree by way of
    /// JSONEncoder/JSONDecoder. Lossless for any Codable value that maps
    /// cleanly onto JSON.
    static func encoding<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
