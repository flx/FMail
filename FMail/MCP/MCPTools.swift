import Foundation

/// Tool registry — wires tool names + descriptions + JSON Schemas to their
/// handler implementations in `MCPHandlers`. Registration happens once per
/// MCP server start.
///
/// Each tool's `description` is what the LLM sees in `tools/list`. Be
/// pragmatic, not poetic. The `search_emails` description embeds the FMail
/// DSL grammar so the LLM can compose queries without external knowledge.
enum MCPTools {
    /// Register Phase A2 read tools. Phase A3 also calls
    /// `registerUnansweredAndMarkReadTools`.
    static func registerReadTools(on dispatcher: MCPDispatcher, context: MCPContext) async {
        await dispatcher.register(searchEmailsTool(context: context))
        await dispatcher.register(listThreadsTool(context: context))
        await dispatcher.register(getThreadTool(context: context))
        await dispatcher.register(getEmailTool(context: context))
    }

    /// Register `find_unanswered_threads` and `mark_read`. Call this only
    /// after the context has its `markReadHandler` set; otherwise `mark_read`
    /// will return an error to every caller.
    static func registerUnansweredAndMarkReadTools(on dispatcher: MCPDispatcher, context: MCPContext) async {
        await dispatcher.register(findUnansweredTool(context: context))
        await dispatcher.register(markReadTool(context: context))
    }

    // MARK: — search_emails

    private static func searchEmailsTool(context: MCPContext) -> MCPTool {
        MCPTool(
            name: "search_emails",
            description: searchEmailsDescription,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("FMail DSL query — see the tool description for grammar.")
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "minimum": .int(1),
                        "maximum": .int(500),
                        "default": .int(50),
                        "description": .string("Max results to return.")
                    ]),
                    "since": .object([
                        "type": .string("string"),
                        "description": .string("Optional ISO date (YYYY-MM-DD or YYYY-MM or YYYY). Folded into the query as `after:`.")
                    ]),
                    "until": .object([
                        "type": .string("string"),
                        "description": .string("Optional ISO date. Folded into the query as `before:`.")
                    ])
                ]),
                "required": .array([.string("query")])
            ]),
            handler: { args in try await MCPHandlers.searchEmails(args, context: context) }
        )
    }

    // MARK: — list_threads

    private static func listThreadsTool(context: MCPContext) -> MCPTool {
        MCPTool(
            name: "list_threads",
            description: """
            List threads in a mailbox (or "All Mailboxes"), newest first.
            Returns thread summaries — call `get_thread` to read messages.

            Excludes drafts, trash, and junk in the All Mailboxes scope.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "scope": .object([
                        "description": .string("Either the literal string \"all_mailboxes\", or {\"mailbox_rowid\": <int>} to scope to one mailbox. Defaults to \"all_mailboxes\".")
                    ]),
                    "since": .object([
                        "type": .string("string"),
                        "description": .string("Optional ISO date (YYYY-MM-DD); only threads with `latest_date_received >= since` are returned.")
                    ]),
                    "until": .object([
                        "type": .string("string"),
                        "description": .string("Optional ISO date; only threads with `latest_date_received <= until` are returned.")
                    ]),
                    "unread_only": .object([
                        "type": .string("boolean"),
                        "default": .bool(false)
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "minimum": .int(1),
                        "maximum": .int(600),
                        "default": .int(100)
                    ])
                ])
            ]),
            handler: { args in try await MCPHandlers.listThreads(args, context: context) }
        )
    }

    // MARK: — get_thread

    private static func getThreadTool(context: MCPContext) -> MCPTool {
        MCPTool(
            name: "get_thread",
            description: """
            Get all messages in a thread, oldest first. Returns full message
            content including plain-text body and attachment metadata.

            Body text is plain (HTML stripped). Bytes for attachments are not
            shipped — only name / content_type / byte_count.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "thread_id": .object(["type": .string("integer")]),
                    "include_bodies": .object([
                        "type": .string("boolean"),
                        "default": .bool(true)
                    ]),
                    "max_body_chars": .object([
                        "type": .string("integer"),
                        "minimum": .int(0),
                        "maximum": .int(200000),
                        "default": .int(8000),
                        "description": .string("Per-message plain-text truncation cap. 0 disables body content (still returns headers/attachments).")
                    ])
                ]),
                "required": .array([.string("thread_id")])
            ]),
            handler: { args in try await MCPHandlers.getThread(args, context: context) }
        )
    }

    // MARK: — get_email

    private static func getEmailTool(context: MCPContext) -> MCPTool {
        MCPTool(
            name: "get_email",
            description: """
            Fetch one message by rowid. Returns the same shape as items in
            `get_thread.messages`. Use after `search_emails` when you want to
            read a single result in detail.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "rowid": .object(["type": .string("integer")]),
                    "max_body_chars": .object([
                        "type": .string("integer"),
                        "minimum": .int(0),
                        "maximum": .int(200000),
                        "default": .int(8000)
                    ])
                ]),
                "required": .array([.string("rowid")])
            ]),
            handler: { args in try await MCPHandlers.getEmail(args, context: context) }
        )
    }

    // MARK: — find_unanswered_threads

    private static func findUnansweredTool(context: MCPContext) -> MCPTool {
        MCPTool(
            name: "find_unanswered_threads",
            description: """
            Threads where YOU sent the latest message and haven't heard back.
            "You sent" matches the sender against your account email addresses,
            or against `our_address` if supplied.

            Excludes drafts/trash/junk. A reply later than your outgoing message
            removes the thread from the result. `days_silent` is computed from
            the latest outgoing message's `date_received`.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "since": .object([
                        "type": .string("string"),
                        "description": .string("ISO date (YYYY-MM-DD / YYYY-MM / YYYY). Only outgoing messages on/after this date count.")
                    ]),
                    "our_address": .object([
                        "type": .string("string"),
                        "description": .string("Optional: restrict to one specific sender address. Defaults to any account email.")
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "minimum": .int(1),
                        "maximum": .int(500),
                        "default": .int(50)
                    ])
                ]),
                "required": .array([.string("since")])
            ]),
            handler: { args in try await MCPHandlers.findUnansweredThreads(args, context: context) }
        )
    }

    // MARK: — mark_read

    private static func markReadTool(context: MCPContext) -> MCPTool {
        MCPTool(
            name: "mark_read",
            description: """
            Mark messages read or unread by rowid. Routes through the same
            pipeline FMail's UI uses: optimistic flip + DB persist + AppleScript
            dispatch to Mail.app.

            Bound: keep batches ≤ ~50 messages. Mail.app linearly scans
            per-mailbox messages by `whose id is N`; 100+ messages across
            multiple Gmail accounts can take 30s+ and may exceed your client's
            HTTP timeout. The work may still complete on Mail.app's side even
            if the call times out — re-call with the same rowids to confirm.

            Returns `applied` (count Mail.app matched) and `error` (string when
            the AppleScript dispatch failed).
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "rowids": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("integer")]),
                        "description": .string("Apple Mail rowids — get them from search_emails / get_thread results.")
                    ]),
                    "is_read": .object([
                        "type": .string("boolean"),
                        "default": .bool(true),
                        "description": .string("true to mark read, false to mark unread.")
                    ])
                ]),
                "required": .array([.string("rowids")])
            ]),
            handler: { args in try await MCPHandlers.markRead(args, context: context) }
        )
    }

    // MARK: — search_emails description (the LLM-visible DSL grammar)

    private static let searchEmailsDescription: String = """
    Search the FMail index using a query DSL. Returns matching messages
    newest first. Drafts, trash, and junk are excluded.

    DSL GRAMMAR
    ===========
    Operators: AND (implicit), OR, NOT or `-`, parentheses, "quoted phrases".

    Field operators (each takes a single value or a quoted phrase):
      from:       sender address or display name
      to:         recipient address or display name
      cc:         cc recipient
      subject:    subject line
      body:       body text (aliases: content:, text:)
      attachment: attachment filename
      account:    account display name (e.g. "icloud", "gmail")
      in:         mailbox kind ("inbox", "sent", "archive", "all", or any path)
      has:        "attachment" only
      is:         "read", "unread", "flagged"
      before:     date — see DATE FORMS
      after:, since:  date
      on:, during:    date range matching the precision of the date

    Bareword tokens match anywhere (subject + body + sender + recipients).

    No-colon shortcuts: hasattachment, isunread, isread, isflagged.

    DATE FORMS
    ----------
      ISO:         2024-03-15, 2024-03, 2024
      Single word: today, yesterday, tomorrow
      Compact:     7d, 2w, 3m, 1y
      Quoted:      "last 30 days", "last week", "this year"
      Month name:  march, march 2024

    DATE SEMANTICS
    --------------
      before:DATE    < start of period containing DATE
      after:DATE     for partial dates: >= start of NEXT period (so after:2024 is >= 2025-01-01)
                     for full dates: >= DATE (Gmail-style inclusive)
      during:/on:    [start, start of next period) — matches the precision of DATE

    Bareword search and field values match by token PREFIX
    (e.g. `subject:v` matches "vermont"). Quote for exact match: "vermont".

    EXAMPLES
    --------
      from:anna school trip
      from:anna@gmail.com after:2024-01
      to:me from:bank invoice
      (anna OR kyoko) school -homework
      "exact phrase" has:attachment
      isunread last 7d

    INPUTS
    ------
      query     (required) the DSL string above
      limit     1–500, default 50
      since     optional ISO date — folded in as after:
      until     optional ISO date — folded in as before:

    NOTES
    -----
    - Body content is searchable as it gets indexed in the background; a
      very recent message may not match by body text yet, but always matches
      by subject/sender/recipient/attachment-name immediately.
    - Returns subject, sender, dates, mailbox path, thread_id, has_attachment,
      is_read, is_flagged. Call `get_email` to read body content.
    """
}
