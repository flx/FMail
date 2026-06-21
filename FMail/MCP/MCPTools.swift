import Foundation

/// Tool registry — wires tool names + descriptions + JSON Schemas to their
/// handler implementations in `MCPHandlers`. Registration happens once per
/// MCP server start.
///
/// Each tool's `description` is what the LLM sees in `tools/list`. Be
/// pragmatic, not poetic. The `search_emails` description embeds the FMail
/// DSL grammar so the LLM can compose queries without external knowledge.
enum MCPTools {
    /// Register the read-only MCP tools. By design the surface is
    /// non-destructive — Mail state changes happen through FMail's UI
    /// (or Mail.app directly), never through MCP. That makes it safe to
    /// expose the connector over a public tunnel: the worst an attacker
    /// who got past the bearer token could do is read mail.
    static func registerReadTools(on dispatcher: MCPDispatcher, context: MCPContext) async {
        await dispatcher.register(searchEmailsTool(context: context))
        await dispatcher.register(listThreadsTool(context: context))
        await dispatcher.register(listAccountsTool(context: context))
        await dispatcher.register(getThreadTool(context: context))
        await dispatcher.register(getEmailTool(context: context))
        await dispatcher.register(exportThreadTool(context: context))
        await dispatcher.register(senderStatsTool(context: context))
        await dispatcher.register(getAttachmentTool(context: context))
        await dispatcher.register(getAttachmentsForRowidsTool(context: context))
        await dispatcher.register(fetchFromServerTool(context: context))
        await dispatcher.register(findUnansweredTool(context: context))
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
                    "offset": .object([
                        "type": .string("integer"),
                        "minimum": .int(0),
                        "default": .int(0),
                        "description": .string("Skip this many results before returning — page past the `limit` cap on a large mailbox. Pair with a stable `sort` (newest_first/oldest_first); paging under `relevance` is best-effort since scores shift as the index updates.")
                    ]),
                    "since": .object([
                        "type": .string("string"),
                        "description": .string("Optional ISO date (YYYY-MM-DD or YYYY-MM or YYYY). Folded into the query as `after:`.")
                    ]),
                    "until": .object([
                        "type": .string("string"),
                        "description": .string("Optional ISO date. Folded into the query as `before:`.")
                    ]),
                    "sort": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("newest_first"),
                            .string("oldest_first"),
                            .string("relevance")
                        ]),
                        "default": .string("newest_first"),
                        "description": .string("Result ordering. newest_first is the default. `relevance` ranks by column-weighted FTS5 BM25 (best match first) when the query has text to match — natural for targeted lookups (\"the email where X sent the contract\"). Subject and sender outweigh body text; quoted reply chains / signatures are near-zero weight (so a quoted block can't hijack the ranking); newsletter/list mail is down-ranked; and a small recency tie-breaker is blended in (see recency_lambda / include_bulk). A relevance sort on a metadata-only query (e.g. just `is:unread after:2024`), or one whose text is negated / OR-ed with a date, falls back to newest_first.")
                    ]),
                    "include_snippets": .object([
                        "type": .string("boolean"),
                        "default": .bool(false),
                        "description": .string("When true, each result row includes a `snippet`: a short excerpt of the best-matching column with matched terms wrapped in «…». Lets you triage/rank without a get_email round-trip. Only produced for queries with text to match (same restriction as relevance sort).")
                    ]),
                    "snippet_max_tokens": .object([
                        "type": .string("integer"),
                        "minimum": .int(Int64(SearchSnippet.minTokens)),
                        "maximum": .int(Int64(SearchSnippet.maxTokens)),
                        "default": .int(Int64(SearchSnippet.defaultTokens)),
                        "description": .string("Approximate width (in tokens) of each `snippet`. Only used when include_snippets is true.")
                    ]),
                    "include_attachment_metadata": .object([
                        "type": .string("boolean"),
                        "default": .bool(false),
                        "description": .string("When true, each result row includes `attachments: [{name, content_type, byte_count}]`. Costs one body load per result, so only enable when needed (e.g. 'find the email where Anita sent the contract PDF' workflows).")
                    ]),
                    "dedupe": .object([
                        "type": .string("boolean"),
                        "default": .bool(false),
                        "description": .string("Collapse the same message indexed under multiple accounts into one result, keyed by RFC Message-ID (keeps the copy whose body is on disk). Messages without a Message-ID stay distinct.")
                    ]),
                    "include_bulk": .object([
                        "type": .string("boolean"),
                        "default": .bool(true),
                        "description": .string("When true (default), newsletter / mailing-list mail (List-Unsubscribe or Precedence: bulk/list) stays in results but is down-ranked under `sort: relevance`. Set false to hard-filter it out entirely — useful when you only want personal correspondence.")
                    ]),
                    "recency_lambda": .object([
                        "type": .string("number"),
                        "minimum": .int(0),
                        "default": .double(0.2),
                        "description": .string("Only for `sort: relevance`. Weight of the recency tie-breaker blended into the BM25 score (BM25 is normalised to 0…1 first, so this is on a comparable scale). 0 = pure textual relevance; ~0.2 nudges ties toward recent mail without letting fresh newsletters beat strong older matches.")
                    ]),
                    "recency_tau_days": .object([
                        "type": .string("number"),
                        "minimum": .int(1),
                        "default": .int(180),
                        "description": .string("Only for `sort: relevance`. Time constant (days) of the recency decay exp(-age/tau). Larger = recency stays relevant for older mail. Ignored when recency_lambda is 0.")
                    ])
                ]),
                "required": .array([.string("query")])
            ]),
            handler: { args in try await MCPHandlers.searchEmails(args, context: context) }
        )
    }

    // MARK: — list_accounts

    private static func listAccountsTool(context: MCPContext) -> MCPTool {
        MCPTool(
            name: "list_accounts",
            description: """
            Introspection: list the mail accounts FMail has indexed.
            Returns `{uuid, display_name, email_address}` per account.

            Use the email_address (or any substring of it) on the DSL
            `account:` operator to filter `search_emails`. Most useful
            when you're seeing two similar-looking results across
            different mailboxes and want to know whether they're the
            same message indexed under multiple accounts or actually
            different.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:])
            ]),
            handler: { args in try await MCPHandlers.listAccounts(args, context: context) }
        )
    }

    // MARK: — export_thread

    private static func exportThreadTool(context: MCPContext) -> MCPTool {
        MCPTool(
            name: "export_thread",
            description: """
            Render a whole conversation to Markdown — title, then one section
            per message (headers, cleaned body, attachment list), oldest first.
            Good for archiving or sharing a thread outside mail.

            With `save_to_path`, the Markdown is written to that file and the
            response returns `{thread_id, message_count, saved_path,
            byte_count}` (same local-vs-tunnel path rules as get_attachment:
            local connections write anywhere, tunnel connections are confined
            to ~/Downloads/FMail). Without it, the Markdown comes back inline
            in `markdown`.

            `body_format` defaults to `clean` (strip quoted reply chains /
            signatures / tracking URLs) — pass `plain` to keep them.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "thread_id": .object(["type": .string("integer")]),
                    "save_to_path": .object([
                        "type": .string("string"),
                        "description": .string("Optional. Write the Markdown here instead of returning it inline. Tilde-expanded; absolute honoured verbatim (local) / confined to ~/Downloads/FMail (tunnel); relative resolved against $HOME. Parent dirs created.")
                    ]),
                    "body_format": .object([
                        "type": .string("string"),
                        "enum": .array([.string("plain"), .string("clean"), .string("raw")]),
                        "default": .string("clean")
                    ]),
                    "max_body_chars": .object([
                        "type": .string("integer"),
                        "minimum": .int(0),
                        "maximum": .int(200000),
                        "default": .int(50000),
                        "description": .string("Per-message body truncation cap. 0 = headers/attachments only.")
                    ])
                ]),
                "required": .array([.string("thread_id")])
            ]),
            handler: { args in try await MCPHandlers.exportThread(args, context: context) }
        )
    }

    // MARK: — sender_stats

    private static func senderStatsTool(context: MCPContext) -> MCPTool {
        MCPTool(
            name: "sender_stats",
            description: """
            Correspondent analytics: count messages grouped by sender over an
            optional date range, newest-volume first. Answers "who emails me
            most", powers unsubscribe sweeps, and gives relationship summaries.

            Each row: `{address, display_name, message_count, unread_count,
            latest_date_received}`. Drafts/trash/junk are excluded.

            `direction`:
              - `incoming` (default): senders that are NOT your own account
                addresses — people writing to you.
              - `outgoing`: messages you sent (grouped by your own address).
              - `all`: no sender filter.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "direction": .object([
                        "type": .string("string"),
                        "enum": .array([.string("incoming"), .string("outgoing"), .string("all")]),
                        "default": .string("incoming")
                    ]),
                    "since": .object([
                        "type": .string("string"),
                        "description": .string("Optional ISO date (YYYY / YYYY-MM / YYYY-MM-DD). Only messages on/after this date count.")
                    ]),
                    "until": .object([
                        "type": .string("string"),
                        "description": .string("Optional ISO date. Only messages on/before this date count.")
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "minimum": .int(1),
                        "maximum": .int(200),
                        "default": .int(20),
                        "description": .string("Max senders to return.")
                    ])
                ])
            ]),
            handler: { args in try await MCPHandlers.senderStats(args, context: context) }
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
                    ]),
                    "offset": .object([
                        "type": .string("integer"),
                        "minimum": .int(0),
                        "default": .int(0),
                        "description": .string("Skip this many threads before returning — page past the `limit` cap. Deep paging is bounded (offset + limit ≤ 1200).")
                    ]),
                    "dedupe": .object([
                        "type": .string("boolean"),
                        "default": .bool(false),
                        "description": .string("Collapse threads whose latest message shares a Message-ID — the same conversation mirrored across accounts. Threads whose latest message has no Message-ID stay distinct.")
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
            Get all messages in a thread. Returns full message content
            including plain-text body and attachment metadata. Bytes for
            attachments are not shipped — only name / content_type /
            byte_count.

            **body_format** controls how aggressively the body is
            cleaned before truncation:
              - `plain` (default): HTML stripped, otherwise verbatim.
                Preserves quoted reply chains and signatures.
              - `clean`: same as plain plus — strip everything below the
                first reply-chain marker (`On <date> ... wrote:`,
                `-----Original Message-----`, Outlook quoted-header
                block); strip below the first signature delimiter
                (`-- ` line, `Sent from my iPhone/iPad`, Outlook iOS
                signature); collapse known tracking URLs (Mimecast
                cybergraph, Outlook safelinks, Google AMP); collapse
                blank lines. Designed for context-window-sensitive
                callers pulling long threads — typically 5–10× smaller
                payload on threads with quoted-reply chains and legal
                disclaimer footers.
              - `raw`: same as `plain` today; reserved for future use.

            **max_total_chars**: cap on the SUM of plain-text bodies
            across the whole thread (0 = no cap). When the cap would be
            exceeded, messages are dropped from the tail of whatever
            order is in effect — so with `direction: newest_first` the
            oldest messages drop first. Response includes
            `omitted_message_count` when truncation kicked in.

            **direction**: `oldest_first` (default) or `newest_first`.
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
                    ]),
                    "body_format": .object([
                        "type": .string("string"),
                        "enum": .array([.string("plain"), .string("clean"), .string("raw")]),
                        "default": .string("plain")
                    ]),
                    "max_total_chars": .object([
                        "type": .string("integer"),
                        "minimum": .int(0),
                        "maximum": .int(1_000_000),
                        "default": .int(0),
                        "description": .string("Cap on the SUM of plain_text_body across all returned messages. 0 = no cap.")
                    ]),
                    "direction": .object([
                        "type": .string("string"),
                        "enum": .array([.string("oldest_first"), .string("newest_first")]),
                        "default": .string("oldest_first")
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

            `body_format` works the same as on `get_thread` — pass
            `clean` to strip quoted reply chains, signatures, and
            tracking URLs before truncation.
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
                    ]),
                    "body_format": .object([
                        "type": .string("string"),
                        "enum": .array([.string("plain"), .string("clean"), .string("raw")]),
                        "default": .string("plain")
                    ])
                ]),
                "required": .array([.string("rowid")])
            ]),
            handler: { args in try await MCPHandlers.getEmail(args, context: context) }
        )
    }

    // MARK: — get_attachment

    private static func getAttachmentTool(context: MCPContext) -> MCPTool {
        MCPTool(
            name: "get_attachment",
            description: """
            Fetch one attachment's bytes by message rowid + 0-based index.
            Two output modes:

            **`save_to_path` (recommended for binary)** — the server writes
            the decoded bytes directly to that filesystem path and the
            response contains only `{rowid, attachment_index, name,
            content_type, byte_count, saved_path}`. No base64 round-trip,
            no per-call size cap, no truncation. Use this for any PDF /
            image / archive — base64-in-JSON tends to push anything
            above ~150 KB past MCP-client result-size caps. The path may
            start with `~` (expanded to your home), be absolute, or be
            relative (resolved against your home). Missing parent
            directories are created. When you're connected locally the
            destination is unrestricted; over the tunnel, writes are
            confined to `~/Downloads/FMail`.

            **No `save_to_path`** — bytes returned in `data_base64`, capped
            by `max_bytes` (default 10 MB). Convenient for small text /
            JSON attachments; awkward for binaries.

            Get the attachment index from `get_email` / `get_thread`'s
            `attachments` array (same order).

            **Offloaded attachments:** Apple Mail's "Optimise Mac Storage"
            keeps the body on disk while evicting attachment binaries — so
            `body_on_disk: true` does NOT guarantee attachment bytes are
            local. Check `locally_available` per attachment (surfaced by
            `search_emails include_attachment_metadata: true` and by
            `get_email` / `get_thread`). When false, either:
              - pass `download_if_missing: true` here (synchronous: this
                call drives Mail.app to refetch from the IMAP/Gmail
                server and waits up to `timeout_seconds`), or
              - call `fetch_from_server` first, then re-call this tool.

            Without the flag, a call against an offloaded attachment
            returns a structured `attachment_not_downloaded_locally`
            error rather than silently writing a 0-byte file.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "rowid": .object(["type": .string("integer")]),
                    "attachment_index": .object([
                        "type": .string("integer"),
                        "minimum": .int(0),
                        "description": .string("0-based index into the attachments array returned by get_email / get_thread.")
                    ]),
                    "save_to_path": .object([
                        "type": .string("string"),
                        "description": .string("Filesystem path to write the decoded bytes to. Tilde-expanded; absolute paths honoured verbatim; relative paths resolved against $HOME. Local connections can write anywhere; tunnel connections are confined to ~/Downloads/FMail. When set, the response omits data_base64 and includes saved_path. Recommended for any non-trivial binary.")
                    ]),
                    "max_bytes": .object([
                        "type": .string("integer"),
                        "minimum": .int(0),
                        "default": .int(Int64(AttachmentDefaults.maxBase64Bytes)),
                        "description": .string("Only used when save_to_path is unset. Cap on raw (pre-base64) bytes returned. Larger attachments come back with truncated=true.")
                    ]),
                    "download_if_missing": .object([
                        "type": .string("boolean"),
                        "default": .bool(false),
                        "description": .string("When the attachment bytes are offloaded by Apple Mail, ask Mail.app to refetch from the server and wait up to `timeout_seconds`. Requires Mail.app to be running and the account online. Default false (errors fast with a structured reason instead).")
                    ]),
                    "timeout_seconds": .object([
                        "type": .string("integer"),
                        "minimum": .int(1),
                        "maximum": .int(Int64(AttachmentDefaults.maxFetchTimeoutSeconds)),
                        "default": .int(Int64(AttachmentDefaults.fetchTimeoutSeconds)),
                        "description": .string("Only used with download_if_missing. Max seconds to wait for Mail.app to deliver the bytes.")
                    ])
                ]),
                "required": .array([.string("rowid"), .string("attachment_index")])
            ]),
            handler: { args in try await MCPHandlers.getAttachment(args, context: context) }
        )
    }

    // MARK: — fetch_from_server

    private static func fetchFromServerTool(context: MCPContext) -> MCPTool {
        MCPTool(
            name: "fetch_from_server",
            description: """
            Ask Mail.app to pull a message back from its IMAP/Gmail server
            (body + attachments), then return refreshed attachment
            metadata. Use this when `search_emails` /  `get_email` shows
            `locally_available: false` on an attachment, or after a
            `get_attachment` returned `attachment_not_downloaded_locally`.

            With `attachment_index` + `save_to_path`, the same call also
            writes that one attachment to disk and returns `saved`. With
            `attachment_index` alone, the call just refreshes the metadata
            (now-correct `byte_count`, `locally_available`). Without an
            index, every attachment of the message is refreshed.

            Synchronous: this tool waits up to `timeout_seconds` for the
            bytes to materialise. On timeout the response carries
            `materialised: false` and an `error` describing why
            (Mail.app not running, account offline, server slow). Requires
            Apple Mail's Automation permission (the same permission Mark
            as Read uses).
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "rowid": .object(["type": .string("integer")]),
                    "attachment_index": .object([
                        "type": .string("integer"),
                        "minimum": .int(0),
                        "description": .string("Optional. When set, the call confirms this specific attachment materialised; combine with `save_to_path` to also write it in the same call.")
                    ]),
                    "save_to_path": .object([
                        "type": .string("string"),
                        "description": .string("Optional. Requires `attachment_index`. Filesystem path to write the decoded bytes to; tilde-expanded, absolute honoured verbatim, relative resolved against $HOME. Local connections unrestricted; tunnel connections confined to ~/Downloads/FMail.")
                    ]),
                    "timeout_seconds": .object([
                        "type": .string("integer"),
                        "minimum": .int(1),
                        "maximum": .int(Int64(AttachmentDefaults.maxFetchTimeoutSeconds)),
                        "default": .int(Int64(AttachmentDefaults.fetchTimeoutSeconds)),
                        "description": .string("Max seconds to wait for Mail.app to deliver the bytes.")
                    ])
                ]),
                "required": .array([.string("rowid")])
            ]),
            handler: { args in try await MCPHandlers.fetchFromServer(args, context: context) }
        )
    }

    // MARK: — get_attachments_for_rowids (bulk)

    private static func getAttachmentsForRowidsTool(context: MCPContext) -> MCPTool {
        MCPTool(
            name: "get_attachments_for_rowids",
            description: """
            Bulk variant of `get_attachment` for fan-out workflows
            (e.g. "pull every invoice attachment from these 8 messages").
            Writes every attachment of every supplied rowid into
            `save_dir`, one subdirectory per rowid:

              <save_dir>/<rowid>/<original_filename>

            Returns `{saved: [...], errors: [...]}`. Each `saved` row has
            `{rowid, attachment_index, name, content_type, byte_count,
            saved_path}`. Each `errors` row has `{rowid, attachment_index,
            error}` and means *that message* (or that one attachment)
            couldn't be fetched — the rest of the batch keeps going.

            `save_dir` may start with `~` (expanded to your home), be
            absolute, or be relative (resolved against $HOME). Created if
            missing. Local connections can write anywhere; tunnel
            connections are confined to `~/Downloads/FMail`.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "rowids": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("integer")]),
                        "description": .string("Apple Mail rowids — usually the output of `search_emails`. Messages without attachments contribute nothing to the result.")
                    ]),
                    "save_dir": .object([
                        "type": .string("string"),
                        "description": .string("Directory under which the per-rowid subdirectories will be created.")
                    ])
                ]),
                "required": .array([.string("rowids"), .string("save_dir")])
            ]),
            handler: { args in try await MCPHandlers.getAttachmentsForRowids(args, context: context) }
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

    // MARK: — search_emails description (the LLM-visible DSL grammar)

    private static let searchEmailsDescription: String = """
    **Full-text search across every indexed email** — subject, sender,
    recipients, attachment filenames, and body content — newest first.
    Drafts, trash, and junk are excluded by default; use `in:drafts` (etc.)
    to scope to those explicitly. The DSL below supports boolean operators,
    quoted phrases, and per-field operators so you can compose narrow
    queries like "invoices from a vendor in March 2025 with a PDF attached"
    in one call: `from:vendor.com subject:invoice after:2025-03
    before:2025-04 attachment:pdf`.

    Use this when the user wants to find email by any combination of
    topic / person / time / mailbox / flag / attachment name. Use
    `list_threads` instead when they want a chronological overview of
    recent conversations rather than a targeted search.

    DSL GRAMMAR
    ===========
    Operators: AND (implicit), OR, NOT or `-`, parentheses, "quoted phrases".

    Field operators (each takes a single value or a quoted phrase):
      from:       sender address or display name (supports domain match)
      to:         recipient address or display name
      cc:         cc recipient
      subject:    subject line
      body:       body text (aliases: content:, text:)
      attachment: attachment filename
      attachment-type: attachment content-type substring (pdf, image, zip)
      attachment-size: attachment byte size with a comparator (>1mb, <500kb,
                  >=2m, =0). Units b/kb/mb/gb (1024-based), default bytes,
                  default comparator >=. Offloaded attachments use their
                  declared size where Apple Mail recorded one.
                  NOTE: attachment-type and attachment-size each match a
                  message that HAS such an attachment, independently — so
                  `attachment-type:pdf attachment-size:>1mb` means "has a PDF
                  and has a >1MB file", not necessarily the same file.
      account:    account display name (e.g. "icloud", "gmail")
      in:         mailbox kind ("inbox", "sent", "archive", "all", or any path)
      thread:     numeric thread_id (from previous search/get_thread results) —
                  narrows to one conversation. Combine with body:/from:/etc. to
                  grep within a thread.
      has:        "attachment" only
      is:         "read", "unread", "flagged"
      before:     date — see DATE FORMS
      after:, since:  date
      on:, during:    date range matching the precision of the date

    Bareword tokens match anywhere (subject + body + sender + recipients).

    No-colon shortcuts: hasattachment, isunread, isread, isflagged.

    ADDRESS / DOMAIN MATCHING
    -------------------------
    Values for `from:`/`to:`/`cc:`/`attachment:` are split on non-alphanumeric
    chars before searching, so `from:vendor.com` matches any sender with
    "vendor" AND "com" in their address column (i.e. all @vendor.com
    addresses). `from:jdoe@vendor.com` ANDs four tokens. This catches
    senders even though FTS5 tokenises email addresses by `@` and `.`.

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
                     (so `before:2025` is `< 2025-01-01`)
      after:DATE     >= start of period containing DATE — INCLUSIVE
      since:DATE     synonym for after:
                     (so `after:2024` is `>= 2024-01-01`,
                      `after:2024-03` is `>= 2024-03-01`,
                      `after:2024-03-15` is `>= 2024-03-15`)
      during:/on:    [start, start of next period) — matches the precision of DATE
                     (so `during:2024-03` is all of March 2024)

    Bareword search and field values match by token PREFIX
    (e.g. `subject:v` matches "vermont"). Quote for exact match: "vermont".

    EXAMPLES
    --------
      from:alice school trip
      from:vendor.com (matches any vendor.com sender)
      from:alice@gmail.com after:2024-01
      to:me from:bank invoice
      thread:1234 body:"550k"            (grep within a conversation)
      (alice OR bob) school -homework
      "exact phrase" has:attachment
      from:bank attachment-type:pdf attachment-size:>1mb
      isunread last 7d

    INPUTS
    ------
      query            (required) the DSL string above
      limit            1–500, default 50
      offset           skip N results before returning (pagination), default 0
      sort             newest_first (default) / oldest_first / relevance
      include_snippets attach a matched-text excerpt per row, default false
      include_bulk     keep newsletter/list mail (default true; false hard-filters)
      recency_lambda   relevance recency tie-breaker weight (default 0.2; 0 = off)
      recency_tau_days relevance recency decay constant in days (default 180)
      since            optional ISO date — folded in as after:
      until            optional ISO date — folded in as before:

    NOTES
    -----
    - Body content is searchable as it gets indexed in the background; a
      very recent message may not match by body text yet, but always matches
      by subject/sender/recipient/attachment-name immediately.
    - Each result row has `body_on_disk:true|false`. False means the .emlx
      hasn't been fetched yet — `get_email` / `get_attachment` may fail
      until the user opens the message in Mail.app once. Prefer rows with
      body_on_disk:true when there's a choice.
    """
}
