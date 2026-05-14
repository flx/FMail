import XCTest
@testable import FMail

/// Phase B0 tests for the writeback router. Uses recording mock services
/// so we can verify which messages got dispatched to which backend without
/// actually invoking Mail.app / Gmail API / IMAP.
final class WritebackRouterTests: XCTestCase {

    // MARK: — Default routing (no account_writeback rows)

    func testDefaultRoutingSendsEverythingToAppleScript() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }

        let recorder = RecordingService(kind: .applescript)
        let router = WritebackRouter(
            indexDB: fixture.db,
            services: [
                .applescript: recorder,
                .gmailApi: FailingService(kind: .gmailApi),
                .imap: FailingService(kind: .imap)
            ]
        )

        let result = await router.moveToJunk(rowids: [
            fixture.schoolMessageRowId,
            fixture.lunchMessageRowId
        ])
        XCTAssertEqual(result.applied, 2)
        let captured = await recorder.allCalls()
        XCTAssertEqual(captured.count, 1, "should batch into one call to the AppleScript service")
        XCTAssertEqual(captured.first?.operation, "moveToJunk")
        XCTAssertEqual(Set(captured.first?.rowids ?? []), [fixture.schoolMessageRowId, fixture.lunchMessageRowId])
    }

    // MARK: — Configured account routes elsewhere

    func testConfiguredAccountRoutesToGmailAPI() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }

        // Mark the fixture's only account as gmail_api.
        try await fixture.db.setWritebackPreference(
            accountUUID: "ACCT-FELIX",
            service: .gmailApi,
            keychainLabel: "test.label",
            settingsJSON: "{}"
        )

        let appleRecorder = RecordingService(kind: .applescript)
        let gmailRecorder = RecordingService(kind: .gmailApi)
        let router = WritebackRouter(
            indexDB: fixture.db,
            services: [
                .applescript: appleRecorder,
                .gmailApi: gmailRecorder,
                .imap: FailingService(kind: .imap)
            ]
        )

        _ = await router.delete(rowids: [fixture.lunchMessageRowId])

        let appleCalls = await appleRecorder.allCalls()
        let gmailCalls = await gmailRecorder.allCalls()
        XCTAssertEqual(appleCalls.count, 0, "no calls should land on AppleScript when account is configured for gmail_api")
        XCTAssertEqual(gmailCalls.count, 1)
        XCTAssertEqual(gmailCalls.first?.rowids, [fixture.lunchMessageRowId])
        XCTAssertEqual(gmailCalls.first?.operation, "delete")
    }

    // MARK: — Result shape: missing rowids

    func testUnknownRowidsAreReportedAsNotFound() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }

        let recorder = RecordingService(kind: .applescript)
        let router = WritebackRouter(
            indexDB: fixture.db,
            services: [
                .applescript: recorder,
                .gmailApi: FailingService(kind: .gmailApi),
                .imap: FailingService(kind: .imap)
            ]
        )

        let bogusRowid = 9_999_999
        let result = await router.moveToJunk(rowids: [
            fixture.lunchMessageRowId,
            bogusRowid
        ])
        // The real one got applied; the bogus one is `.notFound`.
        XCTAssertEqual(result.perMessage[fixture.lunchMessageRowId], .ok)
        XCTAssertEqual(result.perMessage[bogusRowid], .notFound)
        let captured = await recorder.allCalls()
        // Only the real rowid was dispatched.
        XCTAssertEqual(captured.first?.rowids, [fixture.lunchMessageRowId])
    }

    // MARK: — mark_read goes through router too (so it benefits from B1+ later)

    func testMarkReadRoutesToConfiguredService() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }
        let recorder = RecordingService(kind: .applescript)
        let router = WritebackRouter(
            indexDB: fixture.db,
            services: [
                .applescript: recorder,
                .gmailApi: FailingService(kind: .gmailApi),
                .imap: FailingService(kind: .imap)
            ]
        )
        _ = await router.setReadStatus(rowids: [fixture.schoolReplyRowId], isRead: true)
        let calls = await recorder.allCalls()
        XCTAssertEqual(calls.first?.operation, "setReadStatus(isRead=true)")
    }

    // MARK: — Schema migration

    func testSchemaV7CreatesAccountWritebackTable() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }
        // If migration ran, this should round-trip cleanly.
        try await fixture.db.setWritebackPreference(
            accountUUID: "TEST-UUID",
            service: .imap,
            keychainLabel: "test.imap.label",
            settingsJSON: "{\"host\":\"imap.example.com\"}"
        )
        let pref = try await fixture.db.writebackPreference(accountUUID: "TEST-UUID")
        XCTAssertEqual(pref?.service, .imap)
        XCTAssertEqual(pref?.keychainLabel, "test.imap.label")
        XCTAssertTrue(pref?.settingsJSON.contains("imap.example.com") ?? false)
    }

    func testWritebackPreferenceNilWhenNoRow() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }
        let pref = try await fixture.db.writebackPreference(accountUUID: "NEVER-SET")
        XCTAssertNil(pref)
    }
}

// MARK: — Recording mock service

/// Mock WritebackService that records every call. Returns success uniformly
/// so the router's result-merging path is exercised.
private actor RecordingService: WritebackService {
    nonisolated let kind: WritebackKind
    private var calls: [Call] = []

    struct Call: Sendable, Equatable {
        let operation: String
        let rowids: [Int]
    }

    init(kind: WritebackKind) { self.kind = kind }

    func setReadStatus(_ messages: [MessageRef], isRead: Bool) async -> WritebackResult {
        await record(operation: "setReadStatus(isRead=\(isRead))", refs: messages)
        return Self.successResult(for: messages)
    }
    func moveToJunk(_ messages: [MessageRef]) async -> WritebackResult {
        await record(operation: "moveToJunk", refs: messages)
        return Self.successResult(for: messages)
    }
    func delete(_ messages: [MessageRef]) async -> WritebackResult {
        await record(operation: "delete", refs: messages)
        return Self.successResult(for: messages)
    }

    func allCalls() -> [Call] { calls }

    private func record(operation: String, refs: [MessageRef]) {
        calls.append(Call(operation: operation, rowids: refs.map(\.appleRowId).sorted()))
    }

    private static func successResult(for messages: [MessageRef]) -> WritebackResult {
        var out = WritebackResult.empty()
        out.applied = messages.count
        for ref in messages { out.perMessage[ref.appleRowId] = .ok }
        return out
    }
}

/// Mock that fails any call — used to ensure unconfigured services are
/// NEVER invoked under the default routing.
private struct FailingService: WritebackService, Sendable {
    let kind: WritebackKind
    func setReadStatus(_ messages: [MessageRef], isRead: Bool) async -> WritebackResult {
        XCTFail("FailingService.setReadStatus(\(kind.rawValue)) should not be called")
        return WritebackResult.empty()
    }
    func moveToJunk(_ messages: [MessageRef]) async -> WritebackResult {
        XCTFail("FailingService.moveToJunk(\(kind.rawValue)) should not be called")
        return WritebackResult.empty()
    }
    func delete(_ messages: [MessageRef]) async -> WritebackResult {
        XCTFail("FailingService.delete(\(kind.rawValue)) should not be called")
        return WritebackResult.empty()
    }
}
