import XCTest
@testable import FMail

/// Eval harness for `search_emails(sort: "relevance")` ranking quality.
///
/// Reproduces the real-world failure (an eBay listing + an FT newsletter that
/// quote an old conveyancing signature outranking the genuine Tredegar thread)
/// in a deterministic in-memory index, then measures MRR and nDCG@5 over the
/// query set in `relevance_fixtures.json`. It compares four ranking stages so
/// each change in the overhaul can be shown to move the metric up (or at least
/// not regress):
///
///   1. `.uniform`  — equal column weights, no bulk discount / recency /
///                    proximity. The pre-overhaul "rank the raw blob, all text
///                    equal" baseline.
///   2. `.textOnly` — per-column BM25 weights (#1) over the clean/quoted split
///                    (#2). Subject/sender high, quoted text near-zero.
///   3. bulkStage   — `.textOnly` + the bulk-mail discount (#3).
///   4. `.default`  — full ranking: + proximity boost (#4) + hybrid recency
///                    (#5).
final class RelevanceEvalTests: XCTestCase {

    // MARK: — Fixture

    /// One labelled query from `relevance_fixtures.json`.
    private struct RelevanceCase: Decodable {
        let query: String
        let relevant_rowids: [Int]
    }

    /// rowids of the bulk distractors that must NOT dominate the Tredegar query.
    private let ebayRowid = 9001
    private let ftRowid = 9002

    private func loadCases() throws -> [RelevanceCase] {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = dir.appendingPathComponent("relevance_fixtures.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([RelevanceCase].self, from: data)
    }

    /// Seed message: rowid, subject, sender display, the (already-split) clean
    /// and quoted body halves, whether it's bulk, and how many days back it was
    /// received. The genuine Tredegar thread is old; the bulk distractors are
    /// fresh (so the harness also proves recency doesn't let fresh newsletters
    /// beat strong older matches).
    private struct Seed {
        let rowid: Int
        let subject: String
        let prefix: String
        let senderDisplay: String
        let clean: String
        let quoted: String
        let isBulk: Bool
        let daysAgo: Int
    }

    private static let filler = """
    Thank you for your patience throughout this matter. As discussed, the lender has now issued the mortgage \
    paperwork and we are working through the final searches and enquiries raised by the other side. Please review \
    the enclosed report on title at your convenience and let us know if anything is unclear. We will keep you \
    updated at each stage and remain available should you wish to discuss anything by telephone during business \
    hours this week or the next.
    """

    private func seeds() -> [Seed] {
        let f = Self.filler
        return [
            // — Genuine Tredegar conveyancing thread (the relevant set) —
            Seed(rowid: 4723, subject: "Tredegar House — completion of your purchase", prefix: "",
                 senderDisplay: "Helena Price",
                 clean: "Dear Felix, an update on Flat 6, Tredegar House. Our solicitor will confirm completion of the Tredegar House purchase once funds clear. \(f)",
                 quoted: "", isBulk: false, daysAgo: 230),
            Seed(rowid: 121398, subject: "Re: Tredegar House — completion of your purchase", prefix: "Re: ",
                 senderDisplay: "Felix",
                 clean: "Thank you Helena. \(f) Please confirm the completion date for the Tredegar House purchase and whether the solicitor needs anything further before completion.",
                 quoted: "On Tue Helena Price wrote: Our solicitor will confirm completion of the Tredegar House purchase once the lender releases funds and contracts are exchanged.",
                 isBulk: false, daysAgo: 228),
            Seed(rowid: 120914, subject: "Conveyancing quote for Flat 6, Tredegar House", prefix: "",
                 senderDisplay: "Property Legal",
                 clean: "Thanks for your enquiry about the conveyancing for Flat 6 at Tredegar House. Our solicitor has prepared a completion quote. \(f)",
                 quoted: "", isBulk: false, daysAgo: 235),
            Seed(rowid: 120915, subject: "Tredegar House searches and completion timeline", prefix: "",
                 senderDisplay: "Helena Price",
                 clean: "\(f) The local authority searches for Tredegar House are back and raise no issues, so our solicitor expects completion to proceed on schedule.",
                 quoted: "", isBulk: false, daysAgo: 224),
            Seed(rowid: 120916, subject: "Re: Tredegar House — completion statement", prefix: "Re: ",
                 senderDisplay: "Helena Price",
                 clean: "Please find the completion statement for the Tredegar House purchase. \(f) \(f) Our solicitor will send final figures before completion.",
                 quoted: "", isBulk: false, daysAgo: 220),

            // — Bulk distractors: short, high-density, terms live in the QUOTED
            //   signature only. Fresh, so they'd win a naive recency tie too. —
            Seed(rowid: 9001, subject: "Your item sold: Vintage brass desk lamp", prefix: "",
                 senderDisplay: "eBay",
                 clean: "Your item sold. Post within three days.",
                 quoted: "Flat 6 Tredegar House. Completion confirmed by your solicitor.",
                 isBulk: true, daysAgo: 4),
            Seed(rowid: 9002, subject: "FT Weekend: the week in markets", prefix: "",
                 senderDisplay: "Financial Times",
                 clean: "This week most read from the FT.",
                 quoted: "Flat 6 Tredegar House completion. Best, your solicitor.",
                 isBulk: true, daysAgo: 3),

            // — Unique-target genuine messages (each query below hits exactly one) —
            Seed(rowid: 6001, subject: "Dinner reservation at Luca on Friday", prefix: "",
                 senderDisplay: "Marco",
                 clean: "I booked a table at Luca for Friday at 8pm. Let me know if that reservation works.",
                 quoted: "", isBulk: false, daysAgo: 12),
            Seed(rowid: 6002, subject: "Q3 budget review", prefix: "",
                 senderDisplay: "Dana",
                 clean: "Please review the Q3 budget spreadsheet before the meeting; I flagged the marketing line for discussion.",
                 quoted: "", isBulk: false, daysAgo: 20),
            Seed(rowid: 6003, subject: "Flight confirmation BA2490 to Edinburgh", prefix: "",
                 senderDisplay: "British Airways",
                 clean: "Your flight BA2490 to Edinburgh is confirmed, departing Heathrow at 0915.",
                 quoted: "", isBulk: false, daysAgo: 30),
            Seed(rowid: 6004, subject: "Quote for the bathroom leak repair", prefix: "",
                 senderDisplay: "Tom the Plumber",
                 clean: "Following my visit, my quote to fix the bathroom leak and replace the seal is four hundred and fifty pounds.",
                 quoted: "", isBulk: false, daysAgo: 45),
            Seed(rowid: 6005, subject: "School trip permission slip due Friday", prefix: "",
                 senderDisplay: "School Office",
                 clean: "Please return the signed permission slip for the school trip by Friday.",
                 quoted: "", isBulk: false, daysAgo: 60),
            Seed(rowid: 6006, subject: "Your prescription is ready for collection", prefix: "",
                 senderDisplay: "Boots Pharmacy",
                 clean: "Your repeat prescription is ready to collect from the pharmacy counter.",
                 quoted: "", isBulk: false, daysAgo: 8),
            Seed(rowid: 6007, subject: "Tax return deadline reminder", prefix: "",
                 senderDisplay: "Grant and Co",
                 clean: "A reminder that your self assessment tax return deadline is the end of January.",
                 quoted: "", isBulk: false, daysAgo: 90),
            Seed(rowid: 6008, subject: "Your wedding photos are ready", prefix: "",
                 senderDisplay: "Aperture Studio",
                 clean: "The edited wedding photos from the ceremony are ready to download from your gallery.",
                 quoted: "", isBulk: false, daysAgo: 75),

            // — Bulk noise (never a target) —
            Seed(rowid: 7001, subject: "Deals of the week — up to 20% off", prefix: "",
                 senderDisplay: "The Store",
                 clean: "Do not miss this week deals across the store.",
                 quoted: "", isBulk: true, daysAgo: 1),
            Seed(rowid: 7002, subject: "Your weekly news digest", prefix: "",
                 senderDisplay: "News Digest",
                 clean: "The top stories you might have missed this week.",
                 quoted: "", isBulk: true, daysAgo: 2),
            Seed(rowid: 7003, subject: "Amazon: your order has shipped", prefix: "",
                 senderDisplay: "Amazon",
                 clean: "Your recent order has shipped and is on its way.",
                 quoted: "", isBulk: true, daysAgo: 1),
        ]
    }

    /// Build an in-memory index seeded with `seedList` (defaults to the full
    /// fixture). Mirrors the production path: upsert metadata → incremental FTS
    /// (subject/sender/recipients) → `setBodyContent` per message to fill
    /// body_clean / body_quoted / is_bulk.
    private func makeIndex(_ customSeeds: [Seed]? = nil) async throws -> (db: IndexDB, cleanup: () -> Void) {
        let seedList = customSeeds ?? seeds()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fmail-relevance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let dbURL = tmp.appendingPathComponent("index.sqlite")
        let db = try IndexDB(path: dbURL.path)

        try await db.upsertAccounts([(uuid: "ACCT", displayName: "Felix", email: "felix@example.com")])
        let inboxRowId = 100
        try await db.upsertMailboxes([Mailbox(
            rowId: inboxRowId, accountUUID: "ACCT", pathComponents: ["INBOX"],
            totalCount: 0, unreadCount: 0, hidden: false, kind: .inbox
        )])

        let now = Int(Date().timeIntervalSince1970)
        let messages: [IndexedMessage] = seedList.map { s in
            let ts: Int = now - s.daysAgo * 86_400
            return IndexedMessage(
                appleRowId: s.rowid, appleMessageIdHash: Int64(s.rowid),
                mailboxRowId: inboxRowId, accountUUID: "ACCT",
                subject: s.subject, subjectPrefix: s.prefix,
                subjectNormalized: s.subject.lowercased(),
                senderAddress: "\(s.rowid)@sender.example.com", senderDisplay: s.senderDisplay,
                dateSent: ts, dateReceived: ts,
                isRead: true, isFlagged: false, hasAttachment: false,
                rfcMessageId: "<\(s.rowid)@example.com>", imapUID: s.rowid
            )
        }
        try await db.upsertMessages(messages)
        try await db.incrementalUpdateFTS()
        for s in seedList {
            try await db.setBodyContent(
                messageRowId: s.rowid, bodyClean: s.clean, bodyQuoted: s.quoted,
                isBulk: s.isBulk, attachments: []
            )
        }
        return (db, { try? FileManager.default.removeItem(at: tmp) })
    }

    // MARK: — Ranking + metrics

    private func rankedRowids(_ query: String, db: IndexDB, tuning: RelevanceTuning) async throws -> [Int] {
        guard let plan = Evaluator.compile(QueryParser.parse(query)).relevancePlan else {
            XCTFail("query \"\(query)\" produced no relevance plan"); return []
        }
        let hits = try await db.searchRanked(
            plan: plan, limit: 50, offset: 0, sort: .relevance,
            includeSnippet: false, snippetTokens: 18, tuning: tuning
        )
        return hits.map(\.header.rowId)
    }

    /// Mean reciprocal rank: 1/(rank of first relevant hit), 0 if none.
    private func reciprocalRank(_ ranked: [Int], relevant: Set<Int>) -> Double {
        for (i, rowid) in ranked.enumerated() where relevant.contains(rowid) {
            return 1.0 / Double(i + 1)
        }
        return 0
    }

    /// nDCG@k with binary relevance.
    private func ndcg(_ ranked: [Int], relevant: Set<Int>, k: Int = 5) -> Double {
        func dcg(_ rels: [Double]) -> Double {
            rels.enumerated().reduce(0) { $0 + $1.element / log2(Double($1.offset + 2)) }
        }
        let gains = ranked.prefix(k).map { relevant.contains($0) ? 1.0 : 0.0 }
        let ideal = Array(repeating: 1.0, count: min(k, relevant.count))
        let idcg = dcg(ideal)
        guard idcg > 0 else { return 0 }
        return dcg(gains) / idcg
    }

    /// Aggregate (mean MRR, mean nDCG@5) over the whole query set for one tuning.
    private func evaluate(_ tuning: RelevanceTuning, cases: [RelevanceCase], db: IndexDB) async throws -> (mrr: Double, ndcg: Double) {
        var mrr = 0.0, nd = 0.0
        for c in cases {
            let ranked = try await rankedRowids(c.query, db: db, tuning: tuning)
            let relevant = Set(c.relevant_rowids)
            mrr += reciprocalRank(ranked, relevant: relevant)
            nd += ndcg(ranked, relevant: relevant)
        }
        let n = Double(cases.count)
        return (mrr / n, nd / n)
    }

    // MARK: — Tests

    /// The headline acceptance check: for "Tredegar completion solicitor" the
    /// bulk eBay/FT rows top the un-weighted baseline, and the improved ranking
    /// drops them out of the top 5 with a genuine thread message at rank 1.
    func testTredegarFailureModeFixed() async throws {
        let (db, cleanup) = try await makeIndex()
        defer { cleanup() }
        let query = "Tredegar completion solicitor"
        let threadRowids: Set<Int> = [4723, 121398, 120914, 120915, 120916]

        let baseline = try await rankedRowids(query, db: db, tuning: .uniform)
        let baselineTop5 = Set(baseline.prefix(5))
        XCTAssertTrue(
            baselineTop5.contains(ebayRowid) || baselineTop5.contains(ftRowid),
            "baseline should exhibit the failure: a bulk quote in the top 5 (got \(baseline.prefix(5)))"
        )

        let improved = try await rankedRowids(query, db: db, tuning: .default)
        let improvedTop5 = Set(improved.prefix(5))
        XCTAssertFalse(improvedTop5.contains(ebayRowid), "eBay must drop out of the top 5")
        XCTAssertFalse(improvedTop5.contains(ftRowid), "FT must drop out of the top 5")
        XCTAssertTrue(threadRowids.contains(improved.first ?? -1),
                      "rank 1 should be a genuine Tredegar thread message (got \(improved.first ?? -1))")
        XCTAssertTrue(improvedTop5.isSubset(of: threadRowids),
                      "the whole top 5 should be the genuine thread (got \(improved.prefix(5)))")
    }

    /// Stage the overhaul and assert each change moves the aggregate metrics up
    /// or at least doesn't regress, and that the full ranking beats the
    /// baseline outright. Records the per-stage numbers in the test log.
    func testRelevanceMetricsImproveAcrossStages() async throws {
        let (db, cleanup) = try await makeIndex()
        defer { cleanup() }
        let cases = try loadCases()

        var bulkStage = RelevanceTuning.textOnly      // weights (#1,#2) + bulk discount (#3)
        bulkStage.bulkMultiplier = 0.3

        let stages: [(String, RelevanceTuning)] = [
            ("baseline (uniform)", .uniform),
            ("+ column weights + clean/quoted split", .textOnly),
            ("+ bulk discount", bulkStage),
            ("+ proximity + recency (default)", .default),
        ]

        var scores: [(name: String, mrr: Double, ndcg: Double)] = []
        for (name, tuning) in stages {
            let (mrr, nd) = try await evaluate(tuning, cases: cases, db: db)
            scores.append((name, mrr, nd))
            print(String(format: "  %-42@  MRR=%.4f  nDCG@5=%.4f", name as NSString, mrr, nd))
        }

        let eps = 1e-9
        for i in 1..<scores.count {
            XCTAssertGreaterThanOrEqual(scores[i].mrr, scores[i - 1].mrr - eps,
                "MRR regressed at stage \"\(scores[i].name)\" (\(scores[i].mrr) < \(scores[i - 1].mrr))")
            XCTAssertGreaterThanOrEqual(scores[i].ndcg, scores[i - 1].ndcg - eps,
                "nDCG@5 regressed at stage \"\(scores[i].name)\" (\(scores[i].ndcg) < \(scores[i - 1].ndcg))")
        }

        // Full ranking beats the baseline outright.
        XCTAssertGreaterThan(scores.last!.mrr, scores.first!.mrr,
                             "default MRR should beat the uniform baseline")
        XCTAssertGreaterThan(scores.last!.ndcg, scores.first!.ndcg,
                             "default nDCG@5 should beat the uniform baseline")
        // Sanity floor: the improved ranking should be strong in absolute terms.
        XCTAssertGreaterThan(scores.last!.mrr, 0.9)
        XCTAssertGreaterThan(scores.last!.ndcg, 0.9)
    }

    /// `include_bulk: false` hard-filters newsletter/list mail out of results.
    func testIncludeBulkFalseHardFiltersBulk() async throws {
        let (db, cleanup) = try await makeIndex()
        defer { cleanup() }
        var noBulk = RelevanceTuning.default
        noBulk.includeBulk = false
        let ranked = try await rankedRowids("Tredegar completion solicitor", db: db, tuning: noBulk)
        XCTAssertFalse(ranked.contains(ebayRowid))
        XCTAssertFalse(ranked.contains(ftRowid))
        XCTAssertTrue(ranked.contains(4723), "genuine results stay")
    }

    /// Recency (#5) in isolation: two messages with identical text but
    /// different dates tie on BM25, so the recency blend must break the tie
    /// toward the newer one. With `lambda: 0` the tie-break disappears.
    func testRecencyBreaksTies() async throws {
        let body = "alpha beta gamma delta epsilon"
        let older = Seed(rowid: 100, subject: "Status note", prefix: "", senderDisplay: "A",
                         clean: body, quoted: "", isBulk: false, daysAgo: 300)
        let newer = Seed(rowid: 200, subject: "Status note", prefix: "", senderDisplay: "A",
                         clean: body, quoted: "", isBulk: false, daysAgo: 1)
        let (db, cleanup) = try await makeIndex([older, newer])
        defer { cleanup() }

        // Single token → no proximity term, so recency is the only tie-breaker.
        let withRecency = try await rankedRowids("alpha", db: db, tuning: .default)
        XCTAssertEqual(withRecency.first, 200, "recency should rank the newer message first")

        var noRecency = RelevanceTuning.default
        noRecency.lambda = 0
        let ranked0 = try await rankedRowids("alpha", db: db, tuning: noRecency)
        XCTAssertEqual(Set(ranked0), [100, 200], "both still returned with recency off")
    }

    /// Proximity (#4) in isolation: two messages of equal length and term
    /// frequency tie on BM25; the one whose query terms are adjacent (so it
    /// matches `NEAR()`) must outrank the one whose terms are far apart.
    func testProximityBoostPrefersClusteredTerms() async throws {
        let filler = (1...11).map { "w\($0)" }.joined(separator: " ")
        let clustered = Seed(rowid: 300, subject: "Report", prefix: "", senderDisplay: "A",
                             clean: "alpha beta \(filler)", quoted: "", isBulk: false, daysAgo: 10)
        let scattered = Seed(rowid: 301, subject: "Report", prefix: "", senderDisplay: "A",
                             clean: "alpha \(filler) beta", quoted: "", isBulk: false, daysAgo: 10)
        let (db, cleanup) = try await makeIndex([clustered, scattered])
        defer { cleanup() }

        let withProximity = try await rankedRowids("alpha beta", db: db, tuning: .default)
        XCTAssertEqual(withProximity.first, 300,
                       "the message with adjacent terms should rank first under the proximity boost")
    }
}
