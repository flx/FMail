import XCTest
@testable import FMail

/// Tests for the search query DSL — lexer + parser + evaluator. Two layers:
/// 1. Structural assertions on the compiled `CompiledQuery` (where-clause
///    shape, FTS-expression bindings, interpretation reconstruction).
/// 2. End-to-end search against an in-memory `IndexDB` fixture, so the
///    compiled SQL is actually `sqlite3_prepare`-able and returns the
///    expected rows. The AND-fusion regression lives here — its symptom
///    was a silent FTS5 syntax error that turned into zero results, not a
///    string-level mismatch.
final class QueryDSLTests: XCTestCase {

    // MARK: — Structural

    func testEmptyQueryHasNoConstraint() {
        let q = compile("")
        XCTAssertFalse(q.hasAnyConstraint)
        XCTAssertEqual(q.interpretation, "")
    }

    func testBagOfWordsCompilesToFTSSubquery() {
        let q = compile("school trip")
        XCTAssertTrue(q.hasAnyConstraint)
        XCTAssertTrue(q.whereClause.contains("messages_fts MATCH"))
        let expr = ftsExpression(q)
        // FTS5 implicit-AND between phrases is fine when both operands
        // are bare phrases (the AND-fusion rule only kicks in for fused
        // text branches inside a paren).
        XCTAssertTrue(expr.contains("school*"))
        XCTAssertTrue(expr.contains("trip*"))
    }

    func testFromFieldEmitsColumnFilter() {
        let q = compile("from:anna")
        let expr = ftsExpression(q)
        XCTAssertTrue(expr.contains("{sender}"))
        XCTAssertTrue(expr.contains("anna*"))
        XCTAssertEqual(q.interpretation, "from:anna")
    }

    func testOrFusionAcrossSameType() {
        let q = compile("from:kyoko OR to:kyoko")
        let expr = ftsExpression(q)
        // OR with parens, two column filters.
        XCTAssertTrue(expr.contains("{sender}"))
        XCTAssertTrue(expr.contains("{recipients}"))
        XCTAssertTrue(expr.contains(" OR "))
        XCTAssertEqual(q.interpretation, "(from:kyoko OR to:kyoko)")
    }

    /// Regression: prior to the fix, the all-text AND fast path joined
    /// branches with a space, which FTS5 parses as implicit AND — but
    /// implicit AND breaks when one operand is a parenthesised
    /// subexpression. The compiled MATCH expression became unparseable
    /// and `sqlite3_step` returned no rows. Now: join with explicit AND.
    func testAndFusionWithParenthesisedSubexprUsesExplicitAND() {
        let q = compile("(from:kyoko OR to:kyoko) subject:flat")
        let expr = ftsExpression(q)
        XCTAssertTrue(expr.contains(" AND "), "fused text AND must be explicit, got: \(expr)")
        XCTAssertTrue(expr.contains("{subject}"))
        XCTAssertTrue(expr.contains("{sender}"))
        XCTAssertTrue(expr.contains("{recipients}"))
    }

    func testQuotedPhraseEmitsExactMatch() {
        let q = compile("\"school trip\"")
        let expr = ftsExpression(q)
        XCTAssertTrue(expr.contains("\"school trip\""))
        XCTAssertEqual(q.interpretation, "\"school trip\"")
    }

    func testNegationFlipsToNotInSubquery() {
        let q = compile("school -trip")
        XCTAssertTrue(q.hasAnyConstraint)
        // The NOT branch becomes `NOT IN (SELECT ... FROM messages_fts MATCH ?)`.
        XCTAssertTrue(q.whereClause.contains("NOT IN"))
    }

    func testDatePredicateProducesSQLFragment() {
        let q = compile("before:2024-01-01")
        // Date predicates produce direct SQL on m.date_received — not an
        // FTS subquery — so a plain date-only query has no MATCH at all.
        XCTAssertFalse(q.whereClause.contains("messages_fts"))
        XCTAssertTrue(q.whereClause.contains("date_received"))
        XCTAssertEqual(q.bindings.count, 1)
        if case .int = q.bindings.first! {} else {
            XCTFail("date predicate must bind as integer epoch seconds")
        }
    }

    func testMixedTextAndDateCompose() {
        let q = compile("from:anna after:2024-01-01")
        XCTAssertTrue(q.whereClause.contains("messages_fts MATCH"))
        XCTAssertTrue(q.whereClause.contains("date_received"))
        XCTAssertEqual(q.bindings.count, 2)
    }

    func testFlagAndScopePredicatesAreSQLOnly() {
        let q = compile("is:unread in:inbox")
        XCTAssertFalse(q.whereClause.contains("messages_fts"))
        XCTAssertTrue(q.whereClause.contains("is_read = 0"))
        XCTAssertTrue(q.whereClause.contains("mailboxes"))
    }

    func testUnknownFieldFallsBackToBagOfWords() {
        let q = compile("custom:value")
        // Unknown field surfaces as bag-of-words so the user still gets results.
        let expr = ftsExpression(q)
        XCTAssertTrue(expr.contains("value*"))
        XCTAssertEqual(q.interpretation, "custom?:value")
    }

    func testInterpretationRoundtripsNestedExpression() {
        let q = compile("(from:anna OR from:kyoko) school -homework")
        // Interpretation is canonicalised; assert the major pieces are present.
        XCTAssertTrue(q.interpretation.contains("from:anna"))
        XCTAssertTrue(q.interpretation.contains("from:kyoko"))
        XCTAssertTrue(q.interpretation.contains(" OR "))
        XCTAssertTrue(q.interpretation.contains("school"))
        XCTAssertTrue(q.interpretation.contains("-homework"))
    }

    // MARK: — `after:` semantics (inclusive of period start)

    /// All three flavors should bind the epoch corresponding to the
    /// *start* of the named period (in the user's local timezone — the
    /// parser uses `Calendar.current`). Expected values are computed
    /// dynamically so the tests work in any tz.
    func testAfterFullDateIsInclusive() {
        let q = compile("after:2024-03-15")
        assertDateBinding(q, expected: makeLocalDate(2024, 3, 15))
    }

    func testAfterPartialYearIsInclusive() {
        // Previously: `after:2024` meant `>= 2025-01-01`. Now: `>= 2024-01-01`.
        let q = compile("after:2024")
        assertDateBinding(q, expected: makeLocalDate(2024, 1, 1))
    }

    func testAfterPartialMonthIsInclusive() {
        let q = compile("after:2024-03")
        assertDateBinding(q, expected: makeLocalDate(2024, 3, 1))
    }

    private func makeLocalDate(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d
        return Calendar.current.date(from: c)!
    }

    private func assertDateBinding(_ q: CompiledQuery, expected: Date) {
        XCTAssertEqual(q.bindings.count, 1)
        guard case .int(let epoch) = q.bindings[0] else {
            XCTFail("date predicate must bind as int epoch seconds")
            return
        }
        XCTAssertEqual(epoch, Int64(expected.timeIntervalSince1970))
    }

    // MARK: — `thread:` field operator

    func testThreadFieldCompilesToSQLPredicate() {
        let q = compile("thread:42")
        XCTAssertTrue(q.whereClause.contains("thread_id"))
        // Two bindings: the synthetic-vs-real match emits the rowid twice.
        XCTAssertEqual(q.bindings.count, 2)
        for b in q.bindings {
            guard case .int(let v) = b else {
                XCTFail()
                return
            }
            XCTAssertEqual(v, 42)
        }
    }

    func testThreadCombinesWithBodySearch() {
        // The whole point of the operator: "find the message in this
        // thread where N is mentioned." Compiles to a mixed SQL/FTS shape.
        let q = compile("thread:42 body:invoice")
        XCTAssertTrue(q.whereClause.contains("thread_id"))
        XCTAssertTrue(q.whereClause.contains("messages_fts MATCH"))
    }

    // MARK: — Address / domain tokenisation

    func testFromDomainStyleSplitsOnDot() {
        // `from:savills.com` should AND tokens [savills, com] against the
        // sender column so it hits any @savills.com address.
        let q = compile("from:savills.com")
        let expr = ftsExpression(q)
        XCTAssertTrue(expr.contains("{sender}"))
        XCTAssertTrue(expr.contains("savills*"))
        XCTAssertTrue(expr.contains("com*"))
        XCTAssertTrue(expr.contains(" AND "))
    }

    func testFromFullAddressSplitsOnAt() {
        let q = compile("from:james@savills.com")
        let expr = ftsExpression(q)
        XCTAssertTrue(expr.contains("james*"))
        XCTAssertTrue(expr.contains("savills*"))
        XCTAssertTrue(expr.contains("com*"))
    }

    func testFromSingleWordKeepsPrefixForm() {
        // Single-token values stay as the pre-fix `{col}: token*` shape
        // (no parens, no AND) — matches the documented "prefix match" behaviour.
        let q = compile("from:james")
        let expr = ftsExpression(q)
        XCTAssertTrue(expr.contains("{sender}: james*"))
        XCTAssertFalse(expr.contains(" AND "))
    }

    // MARK: — Integration: compiled query actually runs

    /// Same shape as the regression query but executed against a real
    /// in-memory `IndexDB`. Confirms the produced SQL parses AND returns
    /// the expected rows — the FTS5 syntax error would silently return
    /// zero rows here, not throw.
    func testAndFusionRegressionReturnsRowsAgainstLiveIndex() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }

        // School thread: anna sent "School trip update" to felix. Search
        // should find it via either branch of the OR + the subject filter.
        let q = compile("(from:anna OR to:anna) subject:school")
        let rows = try await fixture.db.search(q, limit: 10)
        let rowids = Set(rows.map(\.rowId))
        XCTAssertTrue(
            rowids.contains(fixture.schoolMessageRowId) || rowids.contains(fixture.schoolReplyRowId),
            "AND-fused query should match at least one of the school-thread messages"
        )
    }

    func testPureTextQueryReturnsRowsAgainstLiveIndex() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }
        let q = compile("from:anna school")
        let rows = try await fixture.db.search(q, limit: 10)
        XCTAssertTrue(rows.contains(where: { $0.rowId == fixture.schoolMessageRowId }))
    }

    // MARK: — Helpers

    private func compile(_ input: String) -> CompiledQuery {
        let ast = QueryParser.parse(input)
        return Evaluator.compile(ast)
    }

    /// Extracts the single text-binding payload (the FTS5 MATCH expression).
    /// XCTFails when the query has no text bindings.
    private func ftsExpression(_ q: CompiledQuery, file: StaticString = #file, line: UInt = #line) -> String {
        for b in q.bindings {
            if case .text(let s) = b { return s }
        }
        XCTFail("expected at least one text binding (an FTS5 MATCH expression)", file: file, line: line)
        return ""
    }
}
