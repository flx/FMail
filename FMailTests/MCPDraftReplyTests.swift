import XCTest
@testable import FMail

/// `draft_reply` and the hardening that shipped with it. Mail.app is never
/// driven: the handler gets a recording fake drafter, and `runOsascript`
/// itself refuses to run under XCTest.
final class MCPDraftReplyTests: XCTestCase {

    /// Records requests; returns a canned outcome.
    final class FakeDrafter: ReplyDrafting, @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [ReplyDraftRequest] = []
        var requests: [ReplyDraftRequest] { lock.withLock { _requests } }
        let result: Swift.Result<ReplyDraftOutcome, ReplyDraftError>

        init(result: Swift.Result<ReplyDraftOutcome, ReplyDraftError> = .success(ReplyDraftOutcome(draftId: 7, mode: .pasted, notes: []))) {
            self.result = result
        }

        func draftReply(_ request: ReplyDraftRequest) async -> Swift.Result<ReplyDraftOutcome, ReplyDraftError> {
            lock.withLock { _requests.append(request) }
            return result
        }
    }

    private func call(_ args: [String: JSONValue], fixture: Fixture, drafter: FakeDrafter, local: Bool = true) async throws -> JSONValue {
        let ctx = MCPContext(indexDB: fixture.db, bodyLoader: fixture.bodyLoader, drafter: drafter)
        return try await MCPRequestContext.$isLocal.withValue(local) {
            try await MCPHandlers.draftReply(.object(args), context: ctx)
        }
    }

    private func tmpFile(_ name: String, bytes: Int = 16) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fmail-draft-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(count: bytes).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return url
    }

    // MARK: — Handler

    func testOpensReplyWithBodyAndBuildsEntry() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }
        let drafter = FakeDrafter()
        let result = try await call([
            "rowid": .int(Int64(fixture.schoolMessageRowId)),
            "body": .string("Thanks Anna — sounds good."),
            "reply_all": .bool(true),
        ], fixture: fixture, drafter: drafter)

        let obj = try XCTUnwrap(result.objectValue)
        XCTAssertEqual(obj["opened"]?.boolValue, true)
        XCTAssertEqual(obj["sent"]?.boolValue, false)
        XCTAssertEqual(obj["mode"]?.stringValue, "pasted")

        let req = try XCTUnwrap(drafter.requests.first)
        XCTAssertEqual(req.entry.appleRowId, fixture.schoolMessageRowId)
        XCTAssertEqual(req.entry.mailboxPathComponents, ["INBOX"])
        XCTAssertEqual(req.entry.accountEmail, "felix@example.com")
        XCTAssertTrue(req.replyAll)
        XCTAssertEqual(req.body, "Thanks Anna — sounds good.")
        XCTAssertTrue(req.fallbackQuote.contains("Anna <anna@example.com> wrote:"), req.fallbackQuote)
    }

    func testLocalPathAttachmentIsPassedThrough() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }
        let file = try tmpFile("quote.pdf", bytes: 1234)
        let drafter = FakeDrafter()
        let result = try await call([
            "rowid": .int(Int64(fixture.lunchMessageRowId)),
            "attachments": .array([.object(["path": .string(file.path)])]),
        ], fixture: fixture, drafter: drafter)

        XCTAssertEqual(drafter.requests.first?.attachmentURLs.map(\.lastPathComponent), ["quote.pdf"])
        let att = result.objectValue?["attachments"]?.arrayValue?.first?.objectValue
        XCTAssertEqual(att?["byte_count"]?.intValue, 1234)
        XCTAssertEqual(att?["source"]?.stringValue, "file")
    }

    /// claude.ai connectors always arrive over the tunnel, so draft attachments
    /// are deliberately unconfined for tunnel requests too (drafts never send).
    func testTunnelRequestMayAttachProjectFiles() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }
        let file = try tmpFile("sheet_01.dxf", bytes: 2048)
        let drafter = FakeDrafter()
        _ = try await call([
            "rowid": .int(Int64(fixture.lunchMessageRowId)),
            "attachments": .array([.object(["path": .string(file.path)])]),
        ], fixture: fixture, drafter: drafter, local: false)
        XCTAssertEqual(drafter.requests.first?.attachmentURLs.map(\.lastPathComponent), ["sheet_01.dxf"])
    }

    /// Writes from the tunnel stay confined — only draft *reads* were opened up.
    func testTunnelSavePathsAreStillConfined() throws {
        try MCPRequestContext.$isLocal.withValue(false) {
            XCTAssertThrowsError(try MCPHandlers.resolveSavePath("/tmp/evil.plist"))
        }
    }

    func testDirectoryAndMissingFilesAreRejected() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }
        let dir = try tmpFile("x").deletingLastPathComponent()
        for path in [dir.path, dir.appendingPathComponent("nope.pdf").path] {
            do {
                _ = try await call([
                    "rowid": .int(Int64(fixture.lunchMessageRowId)),
                    "attachments": .array([.object(["path": .string(path)])]),
                ], fixture: fixture, drafter: FakeDrafter())
                XCTFail("accepted \(path)")
            } catch let e as JSONRPCErrorPayload {
                XCTAssertTrue(e.message.contains("no readable file"), e.message)
            }
        }
    }

    func testEmailAttachmentWithoutBodyOnDiskExplainsFix() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }
        do {
            _ = try await call([
                "rowid": .int(Int64(fixture.lunchMessageRowId)),
                "attachments": .array([.object([
                    "rowid": .int(Int64(fixture.schoolMessageRowId)),
                    "attachment_index": .int(0),
                ])]),
            ], fixture: fixture, drafter: FakeDrafter())
            XCTFail("expected an error")
        } catch let e as JSONRPCErrorPayload {
            XCTAssertTrue(e.message.contains("fetch_from_server"), e.message)
        }
    }

    func testLimitsAndRequiredArgs() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }
        let rowid = JSONValue.int(Int64(fixture.lunchMessageRowId))
        let cases: [([String: JSONValue], String)] = [
            ([:], "`rowid`"),
            (["rowid": .int(999_999)], "no message"),
            (["rowid": rowid, "body": .string(String(repeating: "a", count: MCPHandlers.DraftLimits.maxBodyCharacters + 1))], "longer than"),
            (["rowid": rowid, "attachments": .array(Array(repeating: .object(["path": .string("/x")]), count: MCPHandlers.DraftLimits.maxAttachments + 1))], "at most"),
            (["rowid": rowid, "attachments": .array([.object(["rowid": rowid])])], "give either"),
        ]
        for (args, needle) in cases {
            do {
                _ = try await call(args, fixture: fixture, drafter: FakeDrafter())
                XCTFail("accepted \(args)")
            } catch let e as JSONRPCErrorPayload {
                XCTAssertTrue(e.message.contains(needle), "\(e.message) — expected \(needle)")
            }
        }
    }

    func testDrafterFailureSurfacesAsError() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }
        do {
            _ = try await call(["rowid": .int(Int64(fixture.lunchMessageRowId))], fixture: fixture,
                               drafter: FakeDrafter(result: .failure(.messageNotFound)))
            XCTFail("expected an error")
        } catch let e as JSONRPCErrorPayload {
            XCTAssertTrue(e.message.contains("couldn't find the message"), e.message)
        }
    }

    func testToolOnlyRegisteredWithDrafter() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }
        let plain = MCPDispatcher()
        await MCPTools.registerReadTools(on: plain, context: MCPContext(indexDB: fixture.db, bodyLoader: fixture.bodyLoader))
        let plainNames = await plain.registeredToolNames()
        XCTAssertFalse(plainNames.contains("draft_reply"))

        let withDrafter = MCPDispatcher()
        await MCPTools.registerReadTools(on: withDrafter, context: MCPContext(indexDB: fixture.db, bodyLoader: fixture.bodyLoader, drafter: FakeDrafter()))
        let names = await withDrafter.registeredToolNames()
        XCTAssertTrue(names.contains("draft_reply"))
    }

    // MARK: — Quote + scripts

    func testPlainTextQuote() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let q = ReplyQuote.build(senderDisplay: "Anna", senderAddress: "anna@example.com", date: date, originalText: "Hi\r\n\r\nSee you")
        XCTAssertTrue(q.hasPrefix("On Nov "), q)
        XCTAssertTrue(q.hasSuffix("Anna <anna@example.com> wrote:\n> Hi\n>\n> See you"), q)
        XCTAssertEqual(ReplyQuote.build(senderDisplay: "", senderAddress: "a@b.c", date: nil, originalText: ""), "a@b.c wrote:")
        XCTAssertEqual(ReplyQuote.compose(body: "  Yes.\n", quote: "Q"), "Yes.\n\nQ")
        XCTAssertEqual(ReplyQuote.compose(body: " ", quote: "Q"), "Q")
        let long = ReplyQuote.build(senderDisplay: "", senderAddress: "a@b.c", date: nil,
                                    originalText: String(repeating: "x", count: ReplyQuote.maxQuotedCharacters + 10))
        XCTAssertTrue(long.hasSuffix("[…]"))
    }

    func testOpenReplyScriptReturnsDraftId() throws {
        let entry = MailScripter.BatchEntry(rfcMessageId: "<a@b>", appleRowId: 42, accountEmail: "me@x.com", mailboxPathComponents: ["INBOX"])
        let src = try XCTUnwrap(MailScripter.openReplyScriptSource(entry, replyAll: true))
        XCTAssertTrue(src.contains("set draftId to 0"))
        XCTAssertTrue(src.contains("reply msg with opening window and reply to all"))
        XCTAssertTrue(src.contains("set draftId to id of newDraft"))
        XCTAssertTrue(src.contains("return draftId"))
        XCTAssertFalse(src.contains("send"), "a draft script must never send")
    }

    func testDraftScriptsTakeTextOnlyViaArgv() {
        for src in [MailScripter.fillDraftScript, MailScripter.pasteIntoDraftScript, MailScripter.draftFrontScript] {
            XCTAssertTrue(src.contains("on run argv"))
            XCTAssertFalse(src.contains("send "), "a draft script must never send")
        }
    }

    func testOsascriptRefusesUnderXCTest() async {
        XCTAssertTrue(MailScripter.isRunningUnderXCTest)
        let (_, err, code) = await MailScripter.runOsascript("return 1")
        XCTAssertEqual(code, -1)
        XCTAssertTrue(err.contains("XCTest"))
    }

    // MARK: — Server hardening

    func testNullOriginIsRejected() {
        let server = MCPServer()
        func req(_ origin: String?) -> HTTPRequestLine {
            var headers = ["host": "127.0.0.1:8765"]
            if let origin { headers["origin"] = origin }
            return HTTPRequestLine(method: "POST", path: "/mcp", query: "", headers: headers, body: Data())
        }
        XCTAssertTrue(server.originIsAllowed(req(nil)))
        XCTAssertTrue(server.originIsAllowed(req("http://127.0.0.1:8765")))
        XCTAssertFalse(server.originIsAllowed(req("null")))
        XCTAssertFalse(server.originIsAllowed(req("NULL")))
        XCTAssertFalse(server.originIsAllowed(req("https://evil.example")))
    }

    func testJSONContentTypeCheck() {
        XCTAssertTrue(MCPServer.isJSONContentType("application/json"))
        XCTAssertTrue(MCPServer.isJSONContentType("Application/JSON; charset=utf-8"))
        XCTAssertFalse(MCPServer.isJSONContentType(nil))
        XCTAssertFalse(MCPServer.isJSONContentType("text/plain"))
        XCTAssertFalse(MCPServer.isJSONContentType("application/x-www-form-urlencoded"))
        XCTAssertFalse(MCPServer.isJSONContentType("application/jsonp"))
    }
}
