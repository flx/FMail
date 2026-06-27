import XCTest
@testable import FMail

/// Tests for the runtime schema/ontology work: generic owner-identity
/// derivation, the `from:me` / `to:me` / `cc:me` / `in:sent` DSL expansion,
/// provider/localized mailbox-class classification, and the `fmail://schema`
/// enum builder + cache. Everything here asserts genericity — nothing is keyed
/// to a specific real mailbox.
final class SchemaOntologyTests: XCTestCase {

    // MARK: — Mailbox-class classification (generic, no DB)

    func testMailboxClassificationAcrossProvidersAndLanguages() {
        let sent = ["Sent", "Sent Messages", "Sent Mail", "Sent Items",
                    "Gesendet", "Posta inviata", "Enviados", "送信済み"]
        for name in sent {
            XCTAssertEqual(IndexDB.mailboxKind(displayName: name), .sent, "\(name) should be .sent")
        }
        XCTAssertEqual(IndexDB.mailboxKind(displayName: "INBOX"), .inbox)
        XCTAssertEqual(IndexDB.mailboxKind(displayName: "Posteingang"), .inbox)
        XCTAssertEqual(IndexDB.mailboxKind(displayName: "Deleted Messages"), .trash)
        XCTAssertEqual(IndexDB.mailboxKind(displayName: "Papierkorb"), .trash)
        XCTAssertEqual(IndexDB.mailboxKind(displayName: "All Mail"), .all)
        XCTAssertEqual(IndexDB.mailboxKind(displayName: "Entwürfe"), .drafts)
        // Case/whitespace-insensitive.
        XCTAssertEqual(IndexDB.mailboxKind(displayName: "  sent items "), .sent)
        // An ordinary user folder is not a system class.
        XCTAssertEqual(IndexDB.mailboxKind(displayName: "Receipts 2024"), .other)
    }

    // MARK: — attachment-type curated families (no fragments / noise)

    func testAttachmentFamilyClassification() {
        let cases: [(String, String)] = [
            ("application/pdf", "pdf"),
            ("image/png", "image"),
            ("image/jpeg", "image"),
            ("audio/mpeg", "audio"),
            ("video/mp4", "video"),
            ("application/msword", "word"),
            ("application/vnd.openxmlformats-officedocument.wordprocessingml.document", "word"),
            ("application/vnd.oasis.opendocument.text", "word"),
            ("application/vnd.ms-excel", "excel"),
            ("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "excel"),
            ("application/vnd.ms-excel.sheet.macroEnabled.12", "excel"),   // used to leak "12"
            ("application/vnd.ms-powerpoint", "presentation"),
            ("application/vnd.openxmlformats-officedocument.presentationml.presentation", "presentation"),
            ("application/zip", "archive"),
            ("application/x-7z-compressed", "archive"),
            ("application/gzip", "archive"),
            ("text/calendar", "calendar"),                 // must beat the text/ catch-all
            ("text/plain", "text"),
            ("message/rfc822", "email"),
            ("application/octet-stream", "other"),          // used to leak "octet"
            ("application/x-pkcs7-signature", "other"),     // used to leak "pkcs"
            ("/plain", "other"),                            // malformed; used to leak "/plain"
            ("", "other")
        ]
        for (ct, fam) in cases {
            XCTAssertEqual(AttachmentType.family(for: ct), fam, "family of \(ct)")
        }
    }

    func testAttachmentFamiliesHaveNoFragmentsOrNoise() {
        // The exact junk reported from a live index must never appear as a family.
        let noise: Set<String> = ["12", "/plain", "x", "ms", "octet", "rfc",
                                  "openxmlformats", "parallel", "pkcs", "xliff"]
        let messy = [
            "application/pdf", "image/png", "application/zip",
            "application/vnd.ms-excel.sheet.macroEnabled.12", "text/plain", "/plain",
            "application/octet-stream", "message/rfc822", "application/x-pkcs7-signature",
            "multipart/parallel", "application/xliff+xml",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        ]
        let families = Set(messy.map { AttachmentType.family(for: $0) })
        for f in families {
            XCTAssertFalse(f.contains("/"), "family '\(f)' must not contain '/'")
            XCTAssertFalse(noise.contains(f), "family '\(f)' is tokenized noise")
            XCTAssertTrue(AttachmentType.families.contains(f), "family '\(f)' must be canonical")
        }
        XCTAssertTrue(families.isSuperset(of: ["pdf", "image", "archive", "excel", "text", "email", "word"]))
    }

    func testAttachmentTypeOperatorExpandsFamiliesAndKeepsSubstring() {
        let word = Evaluator.compile(QueryParser.parse("attachment-type:word"))
        let wordBinds = word.bindings.compactMap { if case .text(let s) = $0 { return s } else { return nil } }
        XCTAssertTrue(wordBinds.contains("%msword%"))
        XCTAssertTrue(wordBinds.contains("%wordprocessingml%"))
        XCTAssertTrue(wordBinds.contains("%opendocument.text%"),
                      "family expansion must reach ODT, which no substring of 'word' would")
        // A non-family value stays a single literal substring match (power user).
        let octet = Evaluator.compile(QueryParser.parse("attachment-type:octet"))
        let octetBinds = octet.bindings.compactMap { if case .text(let s) = $0 { return s } else { return nil } }
        XCTAssertEqual(octetBinds, ["%octet%"])
    }

    func testSchemaAttachmentTypesAreCleanFamilies() async throws {
        let fx = try await Fixture.make()
        defer { try? fx.cleanup() }
        try await fx.db.setBodyContent(messageRowId: fx.lunchMessageRowId, bodyText: "x",
            attachments: [Attachment(name: "a.pdf", contentType: "application/pdf", data: Data(count: 10))])
        try await fx.db.setBodyContent(messageRowId: fx.schoolMessageRowId, bodyText: "x",
            attachments: [Attachment(name: "a.xlsm", contentType: "application/vnd.ms-excel.sheet.macroEnabled.12", data: Data(count: 10))])
        try await fx.db.setBodyContent(messageRowId: fx.schoolReplyRowId, bodyText: "x",
            attachments: [Attachment(name: "a.bin", contentType: "application/octet-stream", data: Data(count: 10))])
        let enums = try await fx.db.schemaEnums()
        XCTAssertEqual(enums.attachmentTypes, ["excel", "other", "pdf"], "clean, sorted families only")
        for t in enums.attachmentTypes { XCTAssertFalse(t.contains("/")) }
    }

    // MARK: — DSL: from:me / to:me / cc:me / in:sent expansion (compile-level)

    private func compile(_ query: String, owners: [String]) -> CompiledQuery {
        let ast = QueryParser.parse(query)
        let rewritten = OwnerExpansion.rewrite(ast, owners: owners)
        return Evaluator.compile(rewritten)
    }

    func testReferencesOwnerDetection() {
        XCTAssertTrue(OwnerExpansion.referencesOwner(QueryParser.parse("from:me")))
        XCTAssertTrue(OwnerExpansion.referencesOwner(QueryParser.parse("to:Me invoice")))
        XCTAssertTrue(OwnerExpansion.referencesOwner(QueryParser.parse("in:sent")))
        XCTAssertFalse(OwnerExpansion.referencesOwner(QueryParser.parse("from:alice@example.com")))
        XCTAssertFalse(OwnerExpansion.referencesOwner(QueryParser.parse("in:inbox unread")))
    }

    func testFromMeCompilesToExactSenderMatch() {
        let q = compile("from:me", owners: ["Felix@Example.com", "felix@icloud.com"])
        XCTAssertTrue(q.whereClause.contains("LOWER(m.sender_address) IN"), q.whereClause)
        // Owners are lowercased + sorted + de-duped, bound as text.
        XCTAssertEqual(q.bindings.count, 2)
        if case .text(let a) = q.bindings[0] { XCTAssertEqual(a, "felix@example.com") } else { XCTFail() }
        if case .text(let b) = q.bindings[1] { XCTAssertEqual(b, "felix@icloud.com") } else { XCTFail() }
        XCTAssertFalse(q.whereClause.contains("messages_fts"), "from:me must not use fuzzy FTS matching")
    }

    func testFromMeWithNoIdentitiesMatchesNothing() {
        let q = compile("from:me", owners: [])
        XCTAssertEqual(q.whereClause, "0", "from:me with no owner identities matches nothing, not everything")
        XCTAssertTrue(q.bindings.isEmpty)
    }

    func testToMeAndCcMeUseRecipientRoles() {
        let to = compile("to:me", owners: ["me@x.com"])
        XCTAssertTrue(to.whereClause.contains("FROM recipients r"))
        XCTAssertTrue(to.whereClause.contains("r.kind = 0"), to.whereClause)
        let cc = compile("cc:me", owners: ["me@x.com"])
        XCTAssertTrue(cc.whereClause.contains("r.kind = 1"), cc.whereClause)
    }

    func testInSentUnionsMailboxAndOwnerSender() {
        let q = compile("in:sent", owners: ["me@x.com"])
        XCTAssertTrue(q.whereClause.contains("kind = 'sent'"), q.whereClause)
        XCTAssertTrue(q.whereClause.contains("LOWER(m.sender_address) IN"), q.whereClause)
        XCTAssertTrue(q.whereClause.contains(" OR "), "in:sent must be a union")
    }

    func testInSentWithNoIdentitiesFallsBackToMailboxOnly() {
        let q = compile("in:sent", owners: [])
        XCTAssertTrue(q.whereClause.contains("kind = 'sent'"))
        XCTAssertFalse(q.whereClause.contains("sender_address"), "no owners ⇒ mailbox-only")
    }

    // MARK: — End-to-end regressions (real IndexDB)

    /// Regression 1 — `from:me` returns only owner-authored mail; no inbound.
    func testRegression_fromMeExcludesInbound() async throws {
        let fx = try await Fixture.make()
        defer { try? fx.cleanup() }

        let owners = try await fx.db.ownerIdentities()
        XCTAssertEqual(owners, ["felix@example.com"])

        let ast = OwnerExpansion.rewrite(QueryParser.parse("from:me"), owners: owners)
        let results = try await fx.db.search(Evaluator.compile(ast))
        let senders = Set(results.map { $0.senderAddress.lowercased() })
        XCTAssertEqual(senders, ["felix@example.com"], "from:me must only return owner-authored mail")
        XCTAssertFalse(senders.contains("anna@example.com"))
        XCTAssertFalse(senders.contains("kyoko@example.com"))
    }

    /// Regression 2 — cross-account `in:sent` spans different providers: one via
    /// a \Sent-class mailbox, one via the owner-sender union (mail authored by
    /// the owner sitting in a non-sent folder, e.g. Gmail All Mail).
    func testRegression_inSentSpansProviders() async throws {
        let env = try await TwoProviderEnv.make()
        defer { try? env.cleanup() }

        let owners = try await env.db.ownerIdentities()
        XCTAssertEqual(Set(owners), ["a@gmail.com", "b@icloud.com"])

        let ast = OwnerExpansion.rewrite(QueryParser.parse("in:sent"), owners: owners)
        let results = try await env.db.search(Evaluator.compile(ast))
        let rowids = Set(results.map { $0.rowId })
        XCTAssertTrue(rowids.contains(env.gmailSentRowId),
                      "in:sent must include Gmail-authored mail (owner-sender union, no Sent folder)")
        XCTAssertTrue(rowids.contains(env.icloudSentRowId),
                      "in:sent must include iCloud Sent-folder mail")
        // It must NOT be limited to one provider, and must not pull inbound mail.
        XCTAssertFalse(rowids.contains(env.gmailInboundRowId))
    }

    /// Regression 3 — a contact with two addresses: a display-name search spans
    /// both (the FTS `sender` column includes the display name). Documents the
    /// address-level caveat that the schema exemplars also call out.
    func testRegression_displayNameSpansAliases() async throws {
        let env = try await TwoProviderEnv.make()
        defer { try? env.cleanup() }

        // "lee" appears only in the shared display name "Pat Lee", never in
        // either address — so a hit on both proves the display-name search
        // spans the contact's two addresses.
        let results = try await env.db.search(Evaluator.compile(QueryParser.parse("from:lee")))
        let addrs = Set(results.map { $0.senderAddress.lowercased() })
        XCTAssertTrue(addrs.contains("pat@home.test"), "addresses: \(addrs)")
        XCTAssertTrue(addrs.contains("pat@work.test"), "addresses: \(addrs)")
    }

    // MARK: — Schema enum genericity

    func testSchemaSingleAccount() async throws {
        let fx = try await Fixture.make()
        defer { try? fx.cleanup() }
        let enums = try await fx.db.schemaEnums()
        XCTAssertEqual(enums.accounts.count, 1)
        XCTAssertEqual(enums.accounts[0].email, "felix@example.com")
        XCTAssertTrue(enums.accounts[0].isOwner)
        XCTAssertEqual(enums.ownerIdentities, ["felix@example.com"])
        XCTAssertEqual(enums.mailboxClasses, ["inbox"])      // only the class present
        XCTAssertTrue(enums.attachmentTypes.isEmpty)         // no attachments ⇒ empty
    }

    func testSchemaMultipleAccountsAndPresentOnlyEnums() async throws {
        let env = try await TwoProviderEnv.make()
        defer { try? env.cleanup() }
        let enums = try await env.db.schemaEnums()
        XCTAssertEqual(enums.accounts.count, 2)
        XCTAssertEqual(Set(enums.ownerIdentities), ["a@gmail.com", "b@icloud.com"])
        // Present-only: classes are exactly those that exist, nothing invented.
        XCTAssertEqual(Set(enums.mailboxClasses), ["all", "inbox", "sent"])
    }

    /// An account with a null/blank address must not crash and should still
    /// yield an owner identity via the dominant-sender fallback.
    func testSchemaNullEmailAccountInfersOwnerFromSent() async throws {
        let env = try await NullEmailEnv.make()
        defer { try? env.cleanup() }
        let owners = try await env.db.ownerIdentities()
        XCTAssertEqual(owners, ["owner@blank.test"], "blank-email account infers owner from its Sent mail")
        let enums = try await env.db.schemaEnums()
        XCTAssertEqual(enums.accounts.count, 1)
        XCTAssertNil(enums.accounts[0].email)
        XCTAssertTrue(enums.accounts[0].isOwner)
    }

    func testNonOwnerExclusionDropsAccount() async throws {
        let env = try await TwoProviderEnv.make()
        defer { try? env.cleanup() }
        let enums = try await env.db.schemaEnums(excludingAccounts: ["ACCT-GMAIL"])   // keyed by UUID
        XCTAssertEqual(enums.ownerIdentities, ["b@icloud.com"], "excluded account contributes no identity")
        let gmail = enums.accounts.first { $0.uuid == "ACCT-GMAIL" }
        XCTAssertEqual(gmail?.isOwner, false)
    }

    /// The spec's Part-2 acceptance test: a configured-but-not-me account flagged
    /// non-owner (here keyed by EMAIL, mixed-case, to exercise email matching) is
    /// dropped from `from:me`.
    func testNonOwnerFlaggedAccountReturnsZeroFromMe() async throws {
        let env = try await TwoProviderEnv.make()
        defer { try? env.cleanup() }
        let owners = try await env.db.ownerIdentities(excludingAccounts: ["A@Gmail.com"])
        XCTAssertEqual(owners, ["b@icloud.com"])

        let ast = OwnerExpansion.rewrite(QueryParser.parse("from:me"), owners: owners)
        let addrs = Set(try await env.db.search(Evaluator.compile(ast)).map { $0.senderAddress.lowercased() })
        XCTAssertFalse(addrs.contains("a@gmail.com"), "a flagged non-owner account must not count as me")
        XCTAssertEqual(addrs, ["b@icloud.com"], "only the remaining owner's authored mail")
    }

    /// The cache busts when the index content changes (any write advances the
    /// change-counter that keys the cache).
    func testSchemaCacheInvalidatesOnIndexChange() async throws {
        let env = try await TwoProviderEnv.make()
        defer { try? env.cleanup() }
        let before = try await env.db.schemaEnums()
        XCTAssertEqual(before.accounts.count, 2)

        try await env.db.upsertAccounts([(uuid: "ACCT-NEW", displayName: "New", email: "c@new.test")])
        let after = try await env.db.schemaEnums()
        XCTAssertEqual(after.accounts.count, 3, "schema cache must reflect a newly added account")
        XCTAssertTrue(after.ownerIdentities.contains("c@new.test"))
    }

    // MARK: — Schema document shape

    func testSchemaDocumentBuildsExpectedShape() {
        let enums = SchemaEnums(
            accounts: [.init(uuid: "U", email: "u@x.test", displayName: "U",
                             isOwner: true, messageCount: 3, mailboxClasses: ["inbox", "sent"])],
            ownerIdentities: ["u@x.test"],
            mailboxClasses: ["inbox", "sent"],
            attachmentTypes: ["pdf"]
        )
        guard case .object(let doc) = MCPSchema.build(enums) else { return XCTFail("not an object") }
        XCTAssertEqual(doc["version"]?.stringValue, "1")
        XCTAssertNotNil(doc["entities"])
        XCTAssertNotNil(doc["operators"])
        XCTAssertNotNil(doc["exemplars"])
        guard case .object(let en) = doc["enums"] else { return XCTFail("no enums") }
        XCTAssertNotNil(en["is_tokens"])                 // always present (grammar)
        XCTAssertNotNil(en["owner_identities"])
        XCTAssertNotNil(en["attachment_types"])
    }

    /// End-to-end through the JSON-RPC dispatcher: `initialize` advertises the
    /// resources capability, `resources/list` exposes `fmail://schema`, and
    /// `resources/read` returns the schema document.
    func testResourceWiringThroughDispatcher() async throws {
        let fx = try await Fixture.make()
        defer { try? fx.cleanup() }
        let dispatcher = MCPDispatcher()
        let context = MCPContext(indexDB: fx.db, bodyLoader: fx.bodyLoader)
        await MCPTools.registerReadTools(on: dispatcher, context: context)

        func call(_ method: String, params: String = "{}") async throws -> JSONValue {
            let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"\#(method)","params":\#(params)}"#.utf8)
            guard case .response(let data) = await dispatcher.dispatch(rawBody: body, isLocal: true) else {
                return .null
            }
            return (try JSONDecoder().decode(JSONValue.self, from: data)).objectValue?["result"] ?? .null
        }

        let initResult = try await call("initialize")
        XCTAssertNotNil(initResult.objectValue?["capabilities"]?.objectValue?["resources"],
                        "initialize must advertise the resources capability")

        let list = try await call("resources/list")
        let uris = (list.objectValue?["resources"]?.arrayValue ?? [])
            .compactMap { $0.objectValue?["uri"]?.stringValue }
        XCTAssertTrue(uris.contains(MCPSchema.resourceURI), "uris: \(uris)")

        let read = try await call("resources/read", params: #"{"uri":"\#(MCPSchema.resourceURI)"}"#)
        let text = read.objectValue?["contents"]?.arrayValue?.first?.objectValue?["text"]?.stringValue ?? ""
        let parsed = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        XCTAssertEqual(parsed.objectValue?["version"]?.stringValue, "1")
        XCTAssertNotNil(parsed.objectValue?["operators"])
        XCTAssertNotNil(parsed.objectValue?["enums"]?.objectValue?["owner_identities"])
    }

    func testSchemaDocumentOmitsEmptyEnumCategories() {
        let enums = SchemaEnums(accounts: [], ownerIdentities: [], mailboxClasses: [], attachmentTypes: [])
        guard case .object(let doc) = MCPSchema.build(enums),
              case .object(let en) = doc["enums"] else { return XCTFail() }
        XCTAssertNil(en["accounts"], "empty categories omitted")
        XCTAssertNil(en["owner_identities"])
        XCTAssertNil(en["attachment_types"])
        XCTAssertNotNil(en["is_tokens"], "static grammar tokens always present")
    }
}

// MARK: — Fixtures specific to these tests

/// Two accounts on different providers, exercising the cross-provider `in:sent`
/// union: Gmail (no Sent-class folder — sent mail lives in All Mail, found via
/// the owner-sender union) and iCloud (a real \Sent mailbox). Also seeds a
/// single contact under two addresses for the alias test.
private struct TwoProviderEnv {
    let db: IndexDB
    let dbPath: String
    let gmailSentRowId: Int
    let gmailInboundRowId: Int
    let icloudSentRowId: Int

    static func make() async throws -> TwoProviderEnv {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fmail-schema-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let dbURL = tmp.appendingPathComponent("index.sqlite")
        let db = try IndexDB(path: dbURL.path)

        try await db.upsertAccounts([
            (uuid: "ACCT-GMAIL", displayName: "Gmail", email: "a@gmail.com"),
            (uuid: "ACCT-ICLOUD", displayName: "iCloud", email: "b@icloud.com")
        ])

        // Gmail: only an "All Mail" mailbox (kind .all — NOT sent). iCloud: a
        // real "Sent Messages" mailbox (classified .sent) + an Inbox.
        try await db.upsertMailboxes([
            Mailbox(rowId: 200, accountUUID: "ACCT-GMAIL", pathComponents: ["[Gmail]", "All Mail"],
                    totalCount: 0, unreadCount: 0, hidden: false, kind: .all),
            Mailbox(rowId: 201, accountUUID: "ACCT-GMAIL", pathComponents: ["INBOX"],
                    totalCount: 0, unreadCount: 0, hidden: false, kind: .inbox),
            Mailbox(rowId: 300, accountUUID: "ACCT-ICLOUD", pathComponents: ["Sent Messages"],
                    totalCount: 0, unreadCount: 0, hidden: false, kind: .sent)
        ])

        let now = Int(Date().timeIntervalSince1970)
        func msg(_ rowid: Int, mbox: Int, acct: String, from: String, disp: String, subj: String) -> IndexedMessage {
            IndexedMessage(
                appleRowId: rowid, appleMessageIdHash: Int64(rowid), mailboxRowId: mbox, accountUUID: acct,
                subject: subj, subjectPrefix: "", subjectNormalized: subj.lowercased(),
                senderAddress: from, senderDisplay: disp, dateSent: now, dateReceived: now,
                isRead: true, isFlagged: false, hasAttachment: false,
                rfcMessageId: "<\(rowid)@test>", imapUID: rowid)
        }

        let gmailSent = 1100      // authored by owner a@gmail.com, sitting in All Mail
        let gmailInbound = 1101   // inbound from a stranger
        let icloudSent = 1200     // in the iCloud Sent mailbox
        try await db.upsertMessages([
            msg(gmailSent, mbox: 200, acct: "ACCT-GMAIL", from: "a@gmail.com", disp: "A", subj: "sent via gmail"),
            msg(gmailInbound, mbox: 200, acct: "ACCT-GMAIL", from: "stranger@news.test", disp: "News", subj: "newsletter"),
            msg(icloudSent, mbox: 300, acct: "ACCT-ICLOUD", from: "b@icloud.com", disp: "B", subj: "sent via icloud"),
            // Same contact "Pat Lee" under two addresses (alias test).
            msg(1300, mbox: 201, acct: "ACCT-GMAIL", from: "pat@home.test", disp: "Pat Lee", subj: "hi from home"),
            msg(1301, mbox: 201, acct: "ACCT-GMAIL", from: "pat@work.test", disp: "Pat Lee", subj: "hi from work")
        ])
        try await db.incrementalUpdateFTS()

        return TwoProviderEnv(db: db, dbPath: dbURL.path,
                              gmailSentRowId: gmailSent, gmailInboundRowId: gmailInbound,
                              icloudSentRowId: icloudSent)
    }

    func cleanup() throws {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: dbPath).deletingLastPathComponent())
    }
}

/// One account whose email FMail couldn't derive (nil), with a Sent mailbox so
/// the owner identity must be inferred from the dominant sender there.
private struct NullEmailEnv {
    let db: IndexDB
    let dbPath: String

    static func make() async throws -> NullEmailEnv {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fmail-nullemail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let dbURL = tmp.appendingPathComponent("index.sqlite")
        let db = try IndexDB(path: dbURL.path)

        try await db.upsertAccounts([(uuid: "ACCT-NULL", displayName: "Mystery", email: nil)])
        try await db.upsertMailboxes([
            Mailbox(rowId: 400, accountUUID: "ACCT-NULL", pathComponents: ["Sent Messages"],
                    totalCount: 0, unreadCount: 0, hidden: false, kind: .sent)
        ])
        let now = Int(Date().timeIntervalSince1970)
        func sent(_ rowid: Int) -> IndexedMessage {
            IndexedMessage(appleRowId: rowid, appleMessageIdHash: Int64(rowid), mailboxRowId: 400,
                           accountUUID: "ACCT-NULL", subject: "s", subjectPrefix: "", subjectNormalized: "s",
                           senderAddress: "owner@blank.test", senderDisplay: "Owner", dateSent: now, dateReceived: now,
                           isRead: true, isFlagged: false, hasAttachment: false,
                           rfcMessageId: "<\(rowid)@blank>", imapUID: rowid)
        }
        try await db.upsertMessages([sent(2000), sent(2001)])
        try await db.incrementalUpdateFTS()
        return NullEmailEnv(db: db, dbPath: dbURL.path)
    }

    func cleanup() throws {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: dbPath).deletingLastPathComponent())
    }
}
