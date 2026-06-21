import XCTest
@testable import FMail

/// Tests for the MCP backlog features: BM25/snippets (#4/#5), pagination (#6),
/// attachment-type/size filters (#7), dedupe (#8), sender_stats (#9), thread
/// export (#10), and the tunnel-aware save path (#1). Pure-unit assertions
/// where possible; integration against the shared `Fixture` where a live
/// `IndexDB` is needed.
final class MCPNewFeaturesTests: XCTestCase {

    private func compile(_ s: String) -> CompiledQuery { Evaluator.compile(QueryParser.parse(s)) }

    // MARK: — Relevance plan extraction (#4/#5)

    func testRelevancePlanForPureText() {
        let plan = compile("school trip").relevancePlan
        XCTAssertNotNil(plan)
        XCTAssertNil(plan?.residualSQL)
        XCTAssertTrue(plan?.ftsMatch.contains("school*") ?? false)
    }

    func testRelevancePlanForTextAndDateHasResidual() {
        let plan = compile("from:anna after:2024-01-01").relevancePlan
        XCTAssertNotNil(plan)
        XCTAssertTrue(plan?.residualSQL?.contains("date_received") ?? false)
        XCTAssertEqual(plan?.residualBindings.count, 1)
        XCTAssertTrue(plan?.ftsMatch.contains("anna*") ?? false)
    }

    func testRelevancePlanNilForMetadataOnly() {
        // No text to rank → no plan (caller falls back to date order).
        XCTAssertNil(compile("is:unread in:inbox").relevancePlan)
    }

    func testRelevancePlanNilForNegatedText() {
        // A negated FTS branch can't be the positive MATCH.
        XCTAssertNil(compile("from:anna -from:bob").relevancePlan)
    }

    func testRelevancePlanNilForTextOrDate() {
        // OR straddling the MATCH/SQL boundary is unsupported.
        XCTAssertNil(compile("from:anna OR after:2024").relevancePlan)
    }

    // MARK: — attachment-size value parsing (#7)

    func testParseSizeWithComparatorAndUnit() {
        let r = AttachmentSizeValue.parse(">1mb")
        XCTAssertEqual(r?.0, .gt)
        XCTAssertEqual(r?.1, 1024 * 1024)
    }

    func testParseSizeDefaultsToGTE() {
        let r = AttachmentSizeValue.parse("500kb")
        XCTAssertEqual(r?.0, .gte)
        XCTAssertEqual(r?.1, 500 * 1024)
    }

    func testParseSizeEqualsZeroBytes() {
        let r = AttachmentSizeValue.parse("=0")
        XCTAssertEqual(r?.0, .eq)
        XCTAssertEqual(r?.1, 0)
    }

    func testParseSizeDecimal() {
        XCTAssertEqual(AttachmentSizeValue.parse(">=1.5mb")?.1, Int(1.5 * 1024 * 1024))
    }

    func testParseSizeRejectsGarbage() {
        XCTAssertNil(AttachmentSizeValue.parse("big"))
        XCTAssertNil(AttachmentSizeValue.parse(">"))
        XCTAssertNil(AttachmentSizeValue.parse(""))
    }

    // MARK: — attachment term compilation (#7)

    func testAttachmentTypeCompilesToExists() {
        let q = compile("attachment-type:pdf")
        XCTAssertTrue(q.whereClause.contains("FROM attachments a"))
        XCTAssertTrue(q.whereClause.contains("content_type"))
        if case .text(let s)? = q.bindings.first { XCTAssertEqual(s, "%pdf%") } else { XCTFail("expected LIKE binding") }
    }

    func testAttachmentSizeCompilesToExists() {
        let q = compile("attachment-size:>1mb")
        XCTAssertTrue(q.whereClause.contains("byte_count >"))
        if case .int(let n)? = q.bindings.first { XCTAssertEqual(n, Int64(1024 * 1024)) } else { XCTFail("expected int binding") }
    }

    func testAttachmentSizeInterpretationRoundtrips() {
        XCTAssertEqual(compile("attachment-size:>=2mb").interpretation, "attachment-size:>=\(2 * 1024 * 1024)")
    }

    // MARK: — dedupe helper (#8)

    func testDedupedByMessageIDKeepsBodyOnDiskCopy() {
        let a = header(rowId: 1, rfc: "<same@x>")
        let b = header(rowId: 2, rfc: "<same@x>")
        let c = header(rowId: 3, rfc: "<other@x>")
        let enr: [Int: MCPMessageEnrichment] = [
            1: enrich(bodyOnDisk: false),
            2: enrich(bodyOnDisk: true),
            3: enrich(bodyOnDisk: false)
        ]
        let out = MCPHandlers.dedupedByMessageID([a, b, c], enrichments: enr)
        XCTAssertEqual(out.count, 2)
        // The <same@x> slot is held by the first occurrence but upgraded to the
        // body-on-disk copy (rowid 2).
        XCTAssertEqual(out[0].rowId, 2)
        XCTAssertEqual(out[1].rowId, 3)
    }

    func testDedupedKeepsRowsWithoutMessageIDDistinct() {
        let out = MCPHandlers.dedupedByMessageID(
            [header(rowId: 1, rfc: nil), header(rowId: 2, rfc: nil)],
            enrichments: [:]
        )
        XCTAssertEqual(out.count, 2)
    }

    func testNormalizedMessageIDStripsBracketsAndCase() {
        XCTAssertEqual(MCPHandlers.normalizedMessageID("  <Abc@X>  "), "abc@x")
        XCTAssertNil(MCPHandlers.normalizedMessageID(nil))
        XCTAssertNil(MCPHandlers.normalizedMessageID("  "))
    }

    // MARK: — tunnel-aware save path (#1)

    func testUnconfinedHonoursAbsolutePathVerbatim() throws {
        XCTAssertEqual(try MCPHandlers.unconfinedAbsolutePath("/tmp/fmail-test/out.pdf"), "/tmp/fmail-test/out.pdf")
    }

    func testUnconfinedResolvesRelativeAgainstHome() throws {
        let p = try MCPHandlers.unconfinedAbsolutePath("foo/bar.pdf")
        XCTAssertEqual(p, (NSHomeDirectory() as NSString).appendingPathComponent("foo/bar.pdf"))
    }

    func testUnconfinedRejectsEmpty() {
        XCTAssertThrowsError(try MCPHandlers.unconfinedAbsolutePath("   "))
    }

    func testConfinedPathStillRejectsEscape() {
        // safeAbsolutePath (the tunnel path) is unchanged — still confines.
        XCTAssertThrowsError(try MCPHandlers.safeAbsolutePath("/etc/passwd"))
    }

    // MARK: — Integration: ranked search + snippet (#4/#5)

    func testSearchRankedReturnsSnippet() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }
        let plan = try XCTUnwrap(compile("school").relevancePlan)
        let hits = try await fixture.db.searchRanked(
            plan: plan, limit: 10, offset: 0, sort: .relevance, includeSnippet: true, snippetTokens: 18
        )
        XCTAssertFalse(hits.isEmpty)
        XCTAssertTrue(hits.contains { $0.header.rowId == fixture.schoolMessageRowId })
        XCTAssertTrue(hits.contains { ($0.snippet ?? "").contains(SearchSnippet.open) },
                      "at least one hit should carry a marked snippet")
    }

    // MARK: — Integration: pagination (#6)

    func testSearchOffsetPaginates() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }
        let q = compile("example")  // every message's address is @example.com
        let page1 = try await fixture.db.search(q, limit: 1, offset: 0, sort: .newestFirst)
        let page2 = try await fixture.db.search(q, limit: 1, offset: 1, sort: .newestFirst)
        XCTAssertEqual(page1.count, 1)
        XCTAssertEqual(page2.count, 1)
        XCTAssertNotEqual(page1.first?.rowId, page2.first?.rowId)
    }

    // MARK: — Integration: attachment filters (#7)

    func testAttachmentTypeAndSizeFilters() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }
        try await fixture.db.setBodyContent(messageRowId: fixture.lunchMessageRowId, bodyText: "lunch",
            attachments: [Attachment(name: "invoice.pdf", contentType: "application/pdf", data: Data(count: 2_000_000))])
        try await fixture.db.setBodyContent(messageRowId: fixture.schoolMessageRowId, bodyText: "school",
            attachments: [Attachment(name: "note.txt", contentType: "text/plain", data: Data(count: 100))])
        // Offloaded: no bytes on disk, but a declared X-Apple-Content-Length.
        try await fixture.db.setBodyContent(messageRowId: fixture.schoolReplyRowId, bodyText: "reply",
            attachments: [Attachment(name: "big.zip", contentType: "application/zip", data: Data(), declaredByteCount: 5_000_000)])

        func rowids(_ s: String) async throws -> Set<Int> {
            Set(try await fixture.db.search(compile(s), limit: 50).map(\.rowId))
        }
        let pdf = try await rowids("attachment-type:pdf")
        XCTAssertEqual(pdf, [fixture.lunchMessageRowId])
        let zip = try await rowids("attachment-type:zip")
        XCTAssertEqual(zip, [fixture.schoolReplyRowId])

        let big = try await rowids("attachment-size:>1mb")
        XCTAssertTrue(big.contains(fixture.lunchMessageRowId))    // 2MB local pdf
        XCTAssertTrue(big.contains(fixture.schoolReplyRowId))     // 5MB declared (offloaded)
        XCTAssertFalse(big.contains(fixture.schoolMessageRowId))  // 100-byte txt

        let small = try await rowids("attachment-size:<1kb")
        XCTAssertEqual(small, [fixture.schoolMessageRowId])
    }

    // MARK: — Integration: sender_stats (#9)

    func testSenderStatsIncomingExcludesOurAddress() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }
        let addrs = try await fixture.db.senderStats(since: nil, until: nil, direction: .incoming, limit: 20).map(\.address)
        XCTAssertTrue(addrs.contains("anna@example.com"))
        XCTAssertTrue(addrs.contains("kyoko@example.com"))
        XCTAssertFalse(addrs.contains("felix@example.com"))  // our own account
    }

    func testSenderStatsOutgoingIsOurAddress() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }
        let rows = try await fixture.db.senderStats(since: nil, until: nil, direction: .outgoing, limit: 20)
        XCTAssertEqual(rows.map(\.address), ["felix@example.com"])
    }

    // MARK: — Integration: export_thread (#10)

    func testExportThreadRendersMarkdown() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }
        let ctx = MCPContext(indexDB: fixture.db, bodyLoader: fixture.bodyLoader)
        let result = try await MCPHandlers.exportThread(
            .object(["thread_id": .int(Int64(fixture.schoolThreadId))]), context: ctx
        )
        let obj = result.objectValue
        XCTAssertEqual(obj?["message_count"]?.intValue, 2)
        let md = obj?["markdown"]?.stringValue ?? ""
        XCTAssertTrue(md.contains("School trip update"))
        XCTAssertTrue(md.contains("**From:**"))
    }

    // MARK: — BodyCleaner clean/quoted split

    func testSplitSeparatesReplyChainIntoQuoted() {
        let body = """
        Thanks, that works for me.

        On Mon, 1 Jan 2024, Bob <bob@x.com> wrote:
        > here is the original message
        > with several quoted lines
        """
        let (clean, quoted) = BodyCleaner.split(body)
        XCTAssertEqual(clean, "Thanks, that works for me.")
        XCTAssertTrue(quoted.contains("On Mon"))
        XCTAssertTrue(quoted.contains("original message"))
    }

    func testSplitSeparatesSignatureIntoQuoted() {
        let body = "The real content here.\n-- \nFelix\nSent from my iPhone"
        let (clean, quoted) = BodyCleaner.split(body)
        XCTAssertEqual(clean, "The real content here.")
        XCTAssertTrue(quoted.contains("Felix"))
    }

    func testSplitCleanMatchesLegacyClean() {
        // split(text).clean must reproduce the old clean(text) output exactly.
        let body = "Hello\n\n\nworld\n\nOn Tue, A <a@x> wrote:\n> quoted"
        XCTAssertEqual(BodyCleaner.split(body).clean, BodyCleaner.clean(body))
    }

    func testSplitNoMarkerLeavesQuotedEmpty() {
        let (clean, quoted) = BodyCleaner.split("Just a plain note with no quoting.")
        XCTAssertEqual(clean, "Just a plain note with no quoting.")
        XCTAssertEqual(quoted, "")
    }

    // MARK: — Bulk-mail heuristic

    func testBulkDetectedFromListUnsubscribe() {
        let h = ParsedHeaders([("list-unsubscribe", "<https://x.com/unsub>")])
        XCTAssertTrue(BulkHeuristic.isBulk(h))
    }

    func testBulkDetectedFromPrecedence() {
        XCTAssertTrue(BulkHeuristic.isBulk(ParsedHeaders([("precedence", "bulk")])))
        XCTAssertTrue(BulkHeuristic.isBulk(ParsedHeaders([("precedence", "list")])))
    }

    func testNonBulkPersonalMail() {
        let h = ParsedHeaders([("from", "anna@example.com"), ("subject", "lunch?")])
        XCTAssertFalse(BulkHeuristic.isBulk(h))
    }

    // MARK: — Helpers

    private func header(rowId: Int, rfc: String?) -> MessageHeader {
        MessageHeader(
            rowId: rowId, mailboxRowId: 100, subject: "s",
            senderAddress: "a@x", senderDisplay: "A",
            dateSent: nil, dateReceived: nil, isRead: false, isFlagged: false,
            hasAttachment: false, rfcMessageId: rfc, imapUID: nil
        )
    }

    private func enrich(bodyOnDisk: Bool) -> MCPMessageEnrichment {
        MCPMessageEnrichment(
            mailboxPath: "INBOX", threadId: 1, hasAttachment: false,
            bodyOnDisk: bodyOnDisk, accountEmail: "felix@example.com"
        )
    }
}
