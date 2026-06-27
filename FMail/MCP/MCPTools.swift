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
        await dispatcher.register(describeSchemaTool(context: context))

        // The same ontology, exposed as an on-demand resource (the primary
        // surface) so it doesn't ride in any tool description on every call.
        await dispatcher.register(resource: MCPResource(
            uri: MCPSchema.resourceURI,
            name: MCPSchema.resourceName,
            description: MCPSchema.resourceDescription,
            mimeType: "application/json",
            read: {
                let doc = try await MCPSchema.document(context: context)
                let data = try JSONEncoder().encode(doc)
                return String(data: data, encoding: .utf8) ?? "{}"
            }
        ))
    }

    // MARK: — describe_schema

    /// Tool mirror of the `fmail://schema` resource, for MCP clients that don't
    /// surface resources. Returns the identical JSON document.
    private static func describeSchemaTool(context: MCPContext) -> MCPTool {
        MCPTool(
            name: "describe_schema",
            description: """
            Return FMail's data-model schema — the same JSON as the
            `fmail://schema` resource, for clients that don't surface MCP
            resources. Covers the entities and their fields, how they relate,
            every `search_emails` DSL operator, and the LIVE values present in
            THIS index: your accounts, the owner identities that `from:me` /
            `in:sent` resolve to, the mailbox classes, and the attachment-type
            families. Call this once to ground queries in real operators and
            values rather than guessing. Takes no arguments.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:])
            ]),
            handler: { _ in try await MCPSchema.document(context: context) }
        )
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
                        "description": .string("FMail DSL query — see the tool description for grammar, or the `fmail://schema` resource / `describe_schema` for the operator list plus the live filterable values.")
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
            in `markdown`. To hand the user a file, prefer `save_to_path`
            (request access to this connector / ~/Downloads/FMail if needed)
            over computer use / GUI automation.

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
            confined to `~/Downloads/FMail`. This direct write is the
            supported way to land the file on the user's disk over a
            remote connection — prefer it (and, if needed, request access
            to this connector / `~/Downloads/FMail`) over computer use or
            GUI automation to fetch the attachment.

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
            connections are confined to `~/Downloads/FMail`. This is the
            way to bulk-land attachments on the user's disk — prefer it
            (requesting access to this connector / `~/Downloads/FMail` if
            needed) over computer use / GUI automation.
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
    recipients, attachment filenames, and body — newest first. Drafts, trash,
    and junk are excluded unless you scope to them with `in:`.

    Compose narrow queries in one call, e.g. invoices from a vendor in March
    2025 with a PDF: `from:vendor.com subject:invoice after:2025-03
    before:2025-04 attachment-type:pdf`. Use `list_threads` instead for a
    chronological overview rather than a targeted search.

    For the full operator list AND the live values you can filter on — your
    accounts, what `from:me` / `in:sent` resolve to, the mailbox classes and
    attachment-type families actually present in this index — read the
    `fmail://schema` resource (or call `describe_schema`). Grounding a query
    in those real values beats guessing.

    DSL ESSENTIALS
      Boolean: AND (implicit), OR, NOT or `-`, ( ), "quoted phrase".
      Values match by token PREFIX; quote for an exact match.

      Field operators:
        from: / to: / cc:   address, display name, or domain. `me` = you
                            (your own account identities); `in:sent` likewise
                            means mail you authored — both provider-agnostic.
        subject:            subject line
        body:               body text (aliases content:, text:)
        attachment:         attachment filename
        attachment-type:    content-type substring (e.g. pdf, image)
        attachment-size:    comparator + size, e.g. >1mb, <=500kb, =0
                            (units b/kb/mb/gb, default comparator >=)
        in:                 mailbox class (inbox, sent, drafts, archive, all, …)
        account:            account email or substring
        thread:             numeric thread_id — grep within one conversation
        is:                 read | unread | flagged
        has:                attachment
        before: / after: (since:) / on: (during:)   dates

      Dates: ISO (2024-03, 2024-03-15), relative (today, 7d, 2w, 3m), quoted
      ("last 30 days"), or a month name. `after:`/`since:` are inclusive of the
      period start; `during:`/`on:` match the typed precision (`during:2024-03`
      = all of March 2024).

      Bareword tokens match anywhere (subject/body/sender/recipients).
      No-colon shortcuts: hasattachment, isunread, isread, isflagged.

    EXAMPLES
      from:me invoice                  (mail you sent mentioning "invoice")
      to:me from:bank statement
      from:vendor.com after:2024-01    (any vendor.com sender)
      (alice OR bob) school -homework
      thread:1234 body:"550k"
      from:bank attachment-type:pdf attachment-size:>1mb
      isunread last 7d

    NOTES
    - Body text is indexed in the background; a brand-new message matches by
      subject/sender/recipient/attachment-name immediately, by body slightly
      later.
    - Each result has `body_on_disk:true|false`. False = the .emlx isn't
      fetched yet; `get_email` / `get_attachment` may fail until the message is
      opened in Mail.app once. Prefer body_on_disk:true when there's a choice.
    - Other inputs: `limit` (1–500, default 50), `offset`, `sort`
      (newest_first | oldest_first | relevance), `include_snippets`, `dedupe`,
      `include_bulk`, `since`/`until`. See the input schema for the rest.
    """
}
