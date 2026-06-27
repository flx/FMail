import Foundation

/// Builds the `fmail://schema` ontology document — a machine-readable map of
/// FMail's email data model: the entities and their fields, the relationships
/// between them, the search-DSL operators, and the *live enumerable values*
/// present in this index (accounts, owner identities, mailbox classes,
/// attachment-type families). An LLM reads this to compose precise
/// `search_emails` queries instead of guessing operators or values.
///
/// The structural half (entities / relationships / operators / exemplars) is
/// static and describes FMail's fixed model — that is not "hardcoding a
/// mailbox". The `enums` half is computed per-index by `IndexDB.schemaEnums`
/// and lists ONLY values actually present; empty categories are omitted.
enum MCPSchema {
    static let resourceURI = "fmail://schema"
    static let version = "1"

    static let resourceName = "FMail data-model schema"
    static let resourceDescription = """
    Machine-readable map of FMail's email data model — entities, relationships, \
    the search_emails DSL operators, and the live values present in THIS index \
    (your accounts, what from:me / in:sent resolve to, the mailbox classes and \
    attachment types actually indexed). Read this to ground search_emails \
    queries in real operators and values instead of guessing.
    """

    /// Compute the full schema document from the live index, honouring the
    /// user's configured non-owner accounts.
    static func document(context: MCPContext) async throws -> JSONValue {
        let excluded = MCPSettings.nonOwnerAccounts()
        let enums = try await context.indexDB.schemaEnums(excludingAccounts: excluded)
        return build(enums)
    }

    /// Assemble the document from already-computed enums. Pure / synchronous so
    /// it's trivially unit-testable.
    static func build(_ e: SchemaEnums) -> JSONValue {
        func strings(_ xs: [String]) -> JSONValue { .array(xs.map { .string($0) }) }

        // MARK: entities (static — FMail's fixed model)
        let entities: JSONValue = .object([
            "account":    .object(["fields": strings(["uuid", "email", "display_name", "is_owner", "message_count"])]),
            "mailbox":    .object(["fields": strings(["path", "account", "class"])]),
            "thread":     .object(["fields": strings(["thread_id", "message_count"])]),
            "message":    .object(["fields": strings(["rowid", "subject", "from", "to", "cc", "date_sent", "is_read", "is_flagged", "has_attachment", "mailbox", "thread_id"])]),
            "attachment": .object(["fields": strings(["name", "content_type", "byte_count"])]),
            "contact":    .object(["fields": strings(["address", "display_name", "is_owner"])])
        ])

        let relationships = strings([
            "account 1..* mailbox", "mailbox 1..* message",
            "thread 1..* message", "message 1..* attachment",
            "message *..* contact (roles: from,to,cc)"
        ])

        // MARK: operators (static — the DSL grammar, enumerated not prose)
        func op(_ name: String, _ value: String, appliesTo: String? = nil) -> JSONValue {
            var o: [String: JSONValue] = ["name": .string(name), "value": .string(value)]
            if let appliesTo { o["applies_to"] = .string(appliesTo) }
            return .object(o)
        }
        let operators: JSONValue = .array([
            op("from", "address | display | domain | me", appliesTo: "message"),
            op("to", "address | display | domain | me", appliesTo: "message"),
            op("cc", "address | display | domain | me", appliesTo: "message"),
            op("subject", "text", appliesTo: "message"),
            op("body", "text (aliases: content, text)", appliesTo: "message"),
            op("attachment", "attachment filename", appliesTo: "attachment"),
            op("attachment-type", "<attachment_types> family name (pdf, word, excel, archive, …) or a raw content-type substring", appliesTo: "attachment"),
            op("attachment-size", ">N{b,kb,mb,gb} (also <, >=, <=, =)", appliesTo: "attachment"),
            op("account", "<account email or substring>", appliesTo: "account"),
            op("in", "<mailbox_classes>", appliesTo: "mailbox"),
            op("thread", "numeric thread_id", appliesTo: "thread"),
            op("is", "<is_tokens>", appliesTo: "message"),
            op("has", "<has_tokens>", appliesTo: "message"),
            op("before", "date", appliesTo: "message"),
            op("after", "date (alias: since)", appliesTo: "message"),
            op("on", "date (alias: during)", appliesTo: "message"),
            op("bareword", "free text — matches subject/body/sender/recipients")
        ])

        // MARK: enums (dynamic — ONLY values present; empty categories omitted)
        var enums: [String: JSONValue] = [
            // is/has are grammar tokens, always available regardless of data.
            "is_tokens": strings(["read", "unread", "flagged", "unflagged"]),
            "has_tokens": strings(["attachment"])
        ]
        if !e.accounts.isEmpty {
            enums["accounts"] = .array(e.accounts.map { a in
                .object([
                    "uuid": .string(a.uuid),
                    "email": a.email.map { JSONValue.string($0) } ?? .null,
                    "display_name": .string(a.displayName),
                    "is_owner": .bool(a.isOwner),
                    "message_count": .int(Int64(a.messageCount)),
                    "mailbox_classes": strings(a.mailboxClasses)
                ])
            })
        }
        if !e.ownerIdentities.isEmpty { enums["owner_identities"] = strings(e.ownerIdentities) }
        if !e.mailboxClasses.isEmpty { enums["mailbox_classes"] = strings(e.mailboxClasses) }
        if !e.attachmentTypes.isEmpty { enums["attachment_types"] = strings(e.attachmentTypes) }

        // MARK: exemplars (static — generic intent→query templates)
        func ex(_ intent: String, _ query: String, _ note: String? = nil) -> JSONValue {
            var o: [String: JSONValue] = ["intent": .string(intent), "query": .string(query)]
            if let note { o["note"] = .string(note) }
            return .object(o)
        }
        let exemplars: JSONValue = .array([
            ex("what I sent about X", "from:me subject:X", "or: in:sent X"),
            ex("did PERSON reply about X", "from:\"PERSON\" X", "display name spans a contact's aliases"),
            ex("PERSON across all their addresses", "from:a@x.com OR from:a@y.com",
               "identity caveat: from: matches addresses; a display-name search may miss an alias, an address search misses other addresses"),
            ex("unread invoices with a PDF", "is:unread invoice has:attachment attachment-type:pdf"),
            ex("big attachments I got last month", "has:attachment attachment-size:>5mb after:DATE before:DATE"),
            ex("a draft I started to PERSON", "in:drafts to:PERSON"),
            ex("narrow within one conversation", "thread:ID body:X")
        ])

        return .object([
            "version": .string(version),
            "generated_at": .string(Date().formatted(.iso8601)),
            "entities": entities,
            "relationships": relationships,
            "syntax": .string("Boolean: AND (implicit), OR, NOT or `-`, ( ), \"quoted phrase\". Values match by token PREFIX; quote for an exact match. `me` on from/to/cc and `in:sent` resolve to owner_identities."),
            "operators": operators,
            "enums": .object(enums),
            "exemplars": exemplars
        ])
    }
}
