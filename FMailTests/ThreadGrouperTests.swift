import XCTest
@testable import FMail

/// Pure union-find coverage for `ThreadGrouper.build`. The grouper takes a flat
/// list of messages plus a list of `(from rowid → to message-id hash)` links
/// and produces `IndexedThread` components. Documented rules (from the source):
///
///   - Each message starts in its own component.
///   - A link unions message `from` with the message whose
///     `apple_message_id_hash` equals the link's `toHash` (if such a message
///     exists in the batch). Links to a missing hash are skipped.
///   - `threadId` = the *smallest* member rowid (stable across re-runs).
///   - root (`rootMessageRowId`) = the *earliest-dated* member.
///   - `unreadCount` = members with `isRead == false`; `flaggedCount` = members
///     with `isFlagged == true`; `messageCount` = member count.
///
/// These are pure in-memory assertions — no SQLite, no Mail.app.
final class ThreadGrouperTests: XCTestCase {

    private typealias Msg = (rowid: Int, hash: Int64, date: Int, isRead: Bool, isFlagged: Bool)
    private typealias Link = (from: Int, toHash: Int64)

    // MARK: — Linking

    func testMessagesLinkedViaReferenceGroupIntoOneThread() {
        // Message 10 has hash 100; message 20 references hash 100 (its parent).
        let messages: [Msg] = [
            (rowid: 10, hash: 100, date: 1_000, isRead: true, isFlagged: false),
            (rowid: 20, hash: 200, date: 2_000, isRead: true, isFlagged: false),
        ]
        let links: [Link] = [(from: 20, toHash: 100)]

        let threads = ThreadGrouper.build(messages: messages, links: links)
        XCTAssertEqual(threads.count, 1, "the two messages should fuse into one thread")
        guard let t = threads.first else { return XCTFail("expected one thread") }
        XCTAssertEqual(Set(t.memberRowIds), [10, 20])
        XCTAssertEqual(t.messageCount, 2)
    }

    func testTransitiveLinkingMergesChainIntoOneThread() {
        // 10 ← 20 ← 30 (each references the previous one's hash).
        let messages: [Msg] = [
            (rowid: 10, hash: 100, date: 1_000, isRead: true, isFlagged: false),
            (rowid: 20, hash: 200, date: 2_000, isRead: true, isFlagged: false),
            (rowid: 30, hash: 300, date: 3_000, isRead: true, isFlagged: false),
        ]
        let links: [Link] = [
            (from: 20, toHash: 100),
            (from: 30, toHash: 200),
        ]
        let threads = ThreadGrouper.build(messages: messages, links: links)
        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(Set(threads[0].memberRowIds), [10, 20, 30])
    }

    func testUnlinkedMessagesStayInSeparateThreads() {
        let messages: [Msg] = [
            (rowid: 10, hash: 100, date: 1_000, isRead: true, isFlagged: false),
            (rowid: 20, hash: 200, date: 2_000, isRead: true, isFlagged: false),
        ]
        let threads = ThreadGrouper.build(messages: messages, links: [])
        XCTAssertEqual(threads.count, 2, "no links → two singleton threads")
    }

    // MARK: — thread_id stability

    func testThreadIdIsSmallestMemberRowId() {
        let messages: [Msg] = [
            (rowid: 55, hash: 100, date: 1_000, isRead: true, isFlagged: false),
            (rowid: 12, hash: 200, date: 2_000, isRead: true, isFlagged: false),
            (rowid: 99, hash: 300, date: 3_000, isRead: true, isFlagged: false),
        ]
        let links: [Link] = [
            (from: 12, toHash: 100),
            (from: 99, toHash: 200),
        ]
        let threads = ThreadGrouper.build(messages: messages, links: links)
        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads[0].threadId, 12, "threadId is the minimum member rowid")
    }

    func testThreadIdIsStableRegardlessOfInputOrder() {
        let messages: [Msg] = [
            (rowid: 10, hash: 100, date: 1_000, isRead: true, isFlagged: false),
            (rowid: 20, hash: 200, date: 2_000, isRead: true, isFlagged: false),
            (rowid: 30, hash: 300, date: 3_000, isRead: true, isFlagged: false),
        ]
        let links: [Link] = [(from: 20, toHash: 100), (from: 30, toHash: 100)]

        let a = ThreadGrouper.build(messages: messages, links: links)
        let b = ThreadGrouper.build(messages: messages.reversed(), links: links.reversed())
        // Same single thread, same id (min rowid 10) both times.
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(a[0].threadId, 10)
        XCTAssertEqual(b[0].threadId, 10)
    }

    // MARK: — root = earliest date

    func testRootIsEarliestDatedMessage() {
        // Member 30 is oldest (date 500), so it's the thread root even though
        // 10 has the smaller rowid (and is therefore the threadId).
        let messages: [Msg] = [
            (rowid: 10, hash: 100, date: 1_000, isRead: true, isFlagged: false),
            (rowid: 20, hash: 200, date: 2_000, isRead: true, isFlagged: false),
            (rowid: 30, hash: 300, date: 500, isRead: true, isFlagged: false),
        ]
        let links: [Link] = [(from: 20, toHash: 100), (from: 30, toHash: 100)]
        let threads = ThreadGrouper.build(messages: messages, links: links)
        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads[0].threadId, 10, "smallest rowid")
        XCTAssertEqual(threads[0].rootMessageRowId, 30, "earliest date wins for the root")
        XCTAssertEqual(threads[0].latestDateReceived, 2_000, "latest date is the max member date")
    }

    // MARK: — unread / flagged aggregation

    func testUnreadAndFlaggedAreAggregatedAcrossThread() {
        let messages: [Msg] = [
            (rowid: 10, hash: 100, date: 1_000, isRead: false, isFlagged: true),
            (rowid: 20, hash: 200, date: 2_000, isRead: true,  isFlagged: false),
            (rowid: 30, hash: 300, date: 3_000, isRead: false, isFlagged: true),
        ]
        let links: [Link] = [(from: 20, toHash: 100), (from: 30, toHash: 100)]
        let threads = ThreadGrouper.build(messages: messages, links: links)
        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads[0].messageCount, 3)
        XCTAssertEqual(threads[0].unreadCount, 2, "two members are unread")
        XCTAssertEqual(threads[0].flaggedCount, 2, "two members are flagged")
    }

    // MARK: — robustness

    func testLinkToMissingHashDoesNotCrashAndDoesNotMerge() {
        // The link references hash 999, which no message in the batch carries.
        let messages: [Msg] = [
            (rowid: 10, hash: 100, date: 1_000, isRead: true, isFlagged: false),
            (rowid: 20, hash: 200, date: 2_000, isRead: true, isFlagged: false),
        ]
        let links: [Link] = [(from: 20, toHash: 999)]
        let threads = ThreadGrouper.build(messages: messages, links: links)
        XCTAssertEqual(threads.count, 2, "dangling reference is ignored; no merge happens")
    }

    func testLinkFromUnknownRowIdIsIgnored() {
        let messages: [Msg] = [
            (rowid: 10, hash: 100, date: 1_000, isRead: true, isFlagged: false),
        ]
        // `from: 77` isn't in the batch — must be skipped, not crash.
        let links: [Link] = [(from: 77, toHash: 100)]
        let threads = ThreadGrouper.build(messages: messages, links: links)
        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads[0].memberRowIds, [10])
    }

    func testEmptyInputProducesNoThreads() {
        let threads = ThreadGrouper.build(messages: [], links: [])
        XCTAssertTrue(threads.isEmpty)
    }

    /// A message with hash 0 is never a link target (the grouper only indexes
    /// non-zero hashes into `hashToIdx`), so a link to hash 0 cannot merge it.
    func testZeroHashIsNotAMergeTarget() {
        let messages: [Msg] = [
            (rowid: 10, hash: 0, date: 1_000, isRead: true, isFlagged: false),
            (rowid: 20, hash: 200, date: 2_000, isRead: true, isFlagged: false),
        ]
        let links: [Link] = [(from: 20, toHash: 0)]
        let threads = ThreadGrouper.build(messages: messages, links: links)
        XCTAssertEqual(threads.count, 2, "hash 0 is not indexed, so the link can't union anything")
    }
}
