import XCTest
@testable import FMail

/// Coverage for `ReadStatusController.applyOptimisticReadFlip` — the surviving
/// half of the old view-model machinery after the `dead-viewmodel-state`
/// cleanup (the badge delta + the DB write-back).
///
/// These tests drive the `internal` `applyOptimisticReadFlip` directly and
/// **never** `setReadStatus`: `setReadStatus` dispatches AppleScript at
/// Mail.app, and with a tmp-fixture `indexDB` but no `model.mailboxes`,
/// `mailScripterEntries` would build `BatchEntry`s with `accountEmail: nil` /
/// `mailboxPathComponents: nil`, which take `MailScripter`'s cross-account
/// fallback — a real `osascript` walk over every mailbox of every account,
/// matching on `apple_rowid`. Fixture rowids collide trivially with real
/// ones, so such a test could flip the read state of a real message in the
/// developer's own Mail.app.
@MainActor
final class ReadStatusControllerTests: XCTestCase {

    /// Polls until `rowid`'s persisted `is_read` equals `expected`, or the
    /// timeout elapses. Returning `true` therefore proves the write committed.
    ///
    /// Needed because `persistIsRead`'s DB write is a fire-and-forget `Task`
    /// that `applyOptimisticReadFlip` does not await. Every test here must let
    /// that write land — either by calling this helper, or (when it doesn't
    /// check the persisted value) by awaiting `controller.pendingPersist?.value`
    /// — *before* its tmp fixture is torn down in `defer`. Skip that and the
    /// write fires against a deleted directory, failing with a disk I/O error
    /// that surfaces inside an unrelated later test, or after the suite ends.
    private func waitForPersistedIsRead(
        _ db: IndexDB, rowid: Int, expected: Bool, timeout: TimeInterval = 2
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let msg = try await db.loadMessage(rowid: rowid), msg.isRead == expected {
                return true
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    // MARK: — (a) flipping to read persists is_read to the index

    func testFlipToReadPersistsIsReadToIndex() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }

        let model = MailModel()
        model.indexDB = fixture.db
        let controller = ReadStatusController(model: model)

        let before = try await fixture.db.loadMessage(rowid: fixture.schoolReplyRowId)
        XCTAssertEqual(before?.isRead, false, "fixture's reply starts unread")

        await controller.applyOptimisticReadFlip(messages: [before!], isRead: true)

        let persisted = try await waitForPersistedIsRead(
            fixture.db, rowid: fixture.schoolReplyRowId, expected: true
        )
        XCTAssertTrue(persisted, "is_read should be written to the index")
    }

    // MARK: — (b) allUnreadCount decrements by the actually-flipped count

    func testFlipToReadDecrementsAllUnreadCountByFlippedCount() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }

        let model = MailModel()
        model.indexDB = fixture.db
        model.allUnreadCount = 5
        let controller = ReadStatusController(model: model)

        let reply = try await fixture.db.loadMessage(rowid: fixture.schoolReplyRowId)
        XCTAssertEqual(reply?.isRead, false)

        await controller.applyOptimisticReadFlip(messages: [reply!], isRead: true)
        await controller.pendingPersist?.value

        XCTAssertEqual(model.allUnreadCount, 4, "one message flipped to read: -1")
    }

    // MARK: — (c) already-in-target-state rowids don't move the counter (D3 hardening)

    func testFlipAlreadyReadMessagesLeavesCounterUnchanged() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }

        let model = MailModel()
        model.indexDB = fixture.db
        model.allUnreadCount = 5
        let controller = ReadStatusController(model: model)

        // schoolMessageRowId starts read in the fixture.
        let alreadyRead = try await fixture.db.loadMessage(rowid: fixture.schoolMessageRowId)
        XCTAssertEqual(alreadyRead?.isRead, true)

        await controller.applyOptimisticReadFlip(messages: [alreadyRead!], isRead: true)

        XCTAssertEqual(model.allUnreadCount, 5, "already-read message contributes no delta")
    }

    // MARK: — (d) sign convention: read is -1, unread is +1

    func testFlipToUnreadIncrementsAllUnreadCount() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }

        let model = MailModel()
        model.indexDB = fixture.db
        model.allUnreadCount = 5
        let controller = ReadStatusController(model: model)

        // schoolMessageRowId starts read — flip it unread.
        let msg = try await fixture.db.loadMessage(rowid: fixture.schoolMessageRowId)
        XCTAssertEqual(msg?.isRead, true)

        await controller.applyOptimisticReadFlip(messages: [msg!], isRead: false)
        await controller.pendingPersist?.value

        XCTAssertEqual(model.allUnreadCount, 6, "marking a read message unread: +1")

        let persisted = try await fixture.db.loadMessage(rowid: fixture.schoolMessageRowId)
        XCTAssertEqual(persisted?.isRead, false, "is_read should be persisted as false for the unread direction too")
    }

    // MARK: — (e) mixed batch: only the message that actually changes state
    // moves the counter and gets persisted — this is the case the D3
    // hardening (filtering to `isRead != $0.isRead`) exists for; a batch
    // with nothing already in the target state can't exercise it.

    func testFlipMixedBatchOnlyCountsAndPersistsTheChangedMessage() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }

        let model = MailModel()
        model.indexDB = fixture.db
        model.allUnreadCount = 5
        let controller = ReadStatusController(model: model)

        let alreadyRead = try await fixture.db.loadMessage(rowid: fixture.schoolMessageRowId)
        let unread = try await fixture.db.loadMessage(rowid: fixture.schoolReplyRowId)
        XCTAssertEqual(alreadyRead?.isRead, true)
        XCTAssertEqual(unread?.isRead, false)

        await controller.applyOptimisticReadFlip(messages: [alreadyRead!, unread!], isRead: true)
        await controller.pendingPersist?.value

        XCTAssertEqual(model.allUnreadCount, 4, "only the actually-unread message should move the counter, not both")

        let unreadNow = try await fixture.db.loadMessage(rowid: fixture.schoolReplyRowId)
        XCTAssertEqual(unreadNow?.isRead, true, "the previously-unread message should be persisted as read")

        let alreadyReadNow = try await fixture.db.loadMessage(rowid: fixture.schoolMessageRowId)
        XCTAssertEqual(alreadyReadNow?.isRead, true, "the already-read message must not be clobbered by the batch write")
    }

    // MARK: — (f) duplicate rowids in the input don't double-count the counter

    func testFlipDuplicateMessagesCountsOnce() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }

        let model = MailModel()
        model.indexDB = fixture.db
        model.allUnreadCount = 5
        let controller = ReadStatusController(model: model)

        let reply = try await fixture.db.loadMessage(rowid: fixture.schoolReplyRowId)
        XCTAssertEqual(reply?.isRead, false)

        await controller.applyOptimisticReadFlip(messages: [reply!, reply!], isRead: true)
        await controller.pendingPersist?.value

        XCTAssertEqual(model.allUnreadCount, 4, "the same message passed twice must only count once")
    }

    // MARK: — (g) no indexDB: the counter must not move (nothing to persist to)

    func testFlipWithNoIndexDBDoesNotMoveCounter() async {
        let model = MailModel()
        model.indexDB = nil
        model.allUnreadCount = 5
        let controller = ReadStatusController(model: model)

        let unread = MessageHeader(
            rowId: 999,
            mailboxRowId: 100,
            subject: "Test",
            senderAddress: "someone@example.com",
            senderDisplay: "Someone",
            dateSent: nil,
            dateReceived: nil,
            isRead: false,
            isFlagged: false,
            hasAttachment: false,
            rfcMessageId: nil,
            imapUID: nil
        )

        await controller.applyOptimisticReadFlip(messages: [unread], isRead: true)

        XCTAssertEqual(model.allUnreadCount, 5, "with no indexDB there's nowhere to persist to, so the counter must not drift from it")
    }
}
