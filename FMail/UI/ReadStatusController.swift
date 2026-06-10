import AppKit
import Foundation

/// Owns the menu's Mark-as-read / Mark-as-unread commands. The single entry
/// point (`setReadStatus(rowids:isRead:)`) applies the change optimistically
/// (DB + every visible counter updates immediately), then awaits one
/// AppleScript at Mail.app. The next FSEvent-driven sync reconciles in case
/// Mail.app couldn't apply the change; failures surface via
/// `MailModel.bulkActionError`.
@MainActor
final class ReadStatusController {
    // `unowned`: the entry point is invoked from the menu while the model is
    // alive, and the model owns this controller — so it cannot outlive the
    // model. (The optimistic-flip DB write uses a `[weak model]` capture; see
    // `persistIsRead`.) Contrast `SyncCoordinator`, which keeps `weak` because
    // it owns periodic/detached tasks that can fire during model teardown.
    private unowned let model: MailModel

    init(model: MailModel) { self.model = model }

    /// How long to suppress FSEvents-triggered syncs around an AppleScript
    /// write-back so the optimistic flip isn't reverted before Mail.app
    /// commits the change to its Envelope Index.
    private enum SkipWindow: TimeInterval {
        case beforeDispatch = 120
        case afterDispatch = 180
    }

    private func suppressSync(_ window: SkipWindow) {
        model.syncCoordinator?.skipSyncsUntil = Date().addingTimeInterval(window.rawValue)
    }

    // MARK: — Public API

    /// Mark a list of messages by rowid; resolves rowids via `IndexDB`,
    /// runs the optimistic-flip pipeline, AWAITS the AppleScript dispatch,
    /// and returns the matched count. This is the single entry point used by
    /// the menu's Mark-as-read/unread commands (see `StatusItemController`).
    @MainActor
    func setReadStatus(rowids: [Int], isRead: Bool) async -> (applied: Int, error: String?) {
        guard let db = model.indexDB else {
            return (0, "Index not loaded")
        }
        var resolved: [MessageHeader] = []
        for rowid in rowids {
            if let m = try? await db.loadMessage(rowid: rowid) {
                resolved.append(m)
            }
        }
        guard !resolved.isEmpty else {
            return (0, "No messages matched the given rowids")
        }

        // Optimistic flip — updates the badge/index immediately so the menu
        // reflects the change before Mail.app commits it.
        await applyOptimisticReadFlip(messages: resolved, isRead: isRead)

        // AppleScript dispatch — awaited, not Task.detached.
        let entries = mailScripterEntries(for: resolved)
        guard !entries.isEmpty else {
            let msg = "Couldn't build AppleScript entries (mailbox/account info missing)"
            model.bulkActionError = msg
            return (0, msg)
        }
        suppressSync(.beforeDispatch)
        let result = await MailScripter.setReadStatusBatch(entries, isRead: isRead)
        suppressSync(.afterDispatch)

        switch result {
        case .ok(let matched):
            return (matched, nil)
        case .notFound:
            let msg = "Mail.app couldn't find any of the selected messages — apple_rowid may be stale."
            model.bulkActionError = msg
            return (0, msg)
        case .failed(let m):
            let msg = "Couldn't update Mail.app: \(m)"
            model.bulkActionError = msg
            return (resolved.count, msg)
        }
    }

    // MARK: — Pipeline

    /// Group `messages` by thread id (via IndexDB) and apply the optimistic
    /// read flip. Falls back to a per-message visible-array flip when the DB
    /// lookup is unavailable, so the reader/search views still update.
    private func applyOptimisticReadFlip(messages: [MessageHeader], isRead: Bool) async {
        let perThread = await groupByThread(messages)
        if !perThread.isEmpty {
            applyOptimisticThreadBulkRead(perThread: perThread, isRead: isRead)
        } else {
            applyOptimisticReadFlags(messageRowIds: messages.map(\.rowId), isRead: isRead)
        }
    }

    /// Bucket `messages` by their thread id. Returns `[]` when the index is
    /// unavailable or the lookup fails (callers treat that as "fall back to a
    /// per-message flip").
    private func groupByThread(
        _ messages: [MessageHeader]
    ) async -> [(threadId: Int, messages: [MessageHeader])] {
        guard let db = model.indexDB,
              let map = try? await db.threadIds(forMessages: messages.map(\.rowId)) else {
            return []
        }
        var byThread: [Int: [MessageHeader]] = [:]
        for msg in messages {
            if let tid = map[msg.rowId] { byThread[tid, default: []].append(msg) }
        }
        return byThread.map { (threadId: $0.key, messages: $0.value) }
    }

    /// Build AppleScript entries from messages, looking up each message's
    /// canonical mailbox + account so MailScripter can use the fast
    /// `whose id is N` path instead of the slow message-id scan.
    private func mailScripterEntries(for messages: [MessageHeader]) -> [MailScripter.BatchEntry] {
        messages.compactMap { msg in
            let mb = model.mailboxes.first { $0.rowId == msg.mailboxRowId }
            let acct = mb.flatMap { mb in
                model.accounts.first { $0.uuid == mb.accountUUID }
            }
            return MailScripter.BatchEntry(
                rfcMessageId: msg.rfcMessageId ?? "",
                appleRowId: msg.rowId,
                accountEmail: acct?.emailAddress,
                mailboxPathComponents: mb?.pathComponents
            )
        }
    }

    // MARK: — Optimistic flips

    /// Thread-aware optimistic flip. Updates every selected thread's
    /// summary by the count of its flipped messages — works even for
    /// threads whose messages aren't loaded into `messagesInSelectedThread`
    /// (i.e., closed threads in a multi-select).
    private func applyOptimisticThreadBulkRead(
        perThread: [(threadId: Int, messages: [MessageHeader])],
        isRead: Bool
    ) {
        let allMessages = perThread.flatMap { $0.messages }

        // Thread summaries — decrement/increment each by its flipped count.
        let flippedCountByThread = Dictionary(
            perThread.map { ($0.threadId, $0.messages.count) }, uniquingKeysWith: +
        )
        model.threadsForSelectedMailbox = OptimisticUpdate.applyingReadFlip(
            to: model.threadsForSelectedMailbox,
            flippedCountByThread: flippedCountByThread,
            isRead: isRead
        )

        // Sidebar mailbox unread counts.
        applyMailboxUnreadDeltas(
            OptimisticUpdate.mailboxUnreadDeltas(forFlipping: allMessages, isRead: isRead)
        )

        // Flip the per-message read dot wherever these messages are visible.
        flipReadInVisibleArrays(rowIds: Set(allMessages.map(\.rowId)), isRead: isRead)

        // Global counter.
        let totalDelta = allMessages.count * OptimisticUpdate.unreadDelta(isRead: isRead)
        model.allUnreadCount = max(0, model.allUnreadCount + totalDelta)

        // Persist to DB.
        if let db = model.indexDB {
            persistIsRead(rowids: allMessages.map(\.rowId), isRead: isRead, db: db)
        }
    }

    /// Per-message fallback when the thread-id lookup failed. Discovers each
    /// message's previous read state and mailbox from the visible arrays
    /// (`messagesInSelectedThread`, `searchResults`) — the only places it can
    /// see them without the DB — and updates counts from there.
    private func applyOptimisticReadFlags(messageRowIds: [Int], isRead: Bool) {
        guard !messageRowIds.isEmpty else { return }

        var newSearchResults = model.searchResults
        var newMessagesInThread = model.messagesInSelectedThread

        var unreadCountDelta = 0
        var mailboxDeltas: [Int: Int] = [:]
        var flippedRowIds: [Int] = []
        let perMessage = OptimisticUpdate.unreadDelta(isRead: isRead)

        for rowId in messageRowIds {
            var prevIsRead: Bool? = nil
            var mailboxRowId: Int? = nil

            if let idx = newMessagesInThread.firstIndex(where: { $0.rowId == rowId }) {
                prevIsRead = newMessagesInThread[idx].isRead
                mailboxRowId = newMessagesInThread[idx].mailboxRowId
                newMessagesInThread[idx] = newMessagesInThread[idx].withIsRead(isRead)
            }
            if let idx = newSearchResults.firstIndex(where: { $0.rowId == rowId }) {
                if prevIsRead == nil { prevIsRead = newSearchResults[idx].isRead }
                if mailboxRowId == nil { mailboxRowId = newSearchResults[idx].mailboxRowId }
                newSearchResults[idx] = newSearchResults[idx].withIsRead(isRead)
            }

            if let prev = prevIsRead, prev != isRead {
                unreadCountDelta += perMessage
                if let mid = mailboxRowId { mailboxDeltas[mid, default: 0] += perMessage }
                flippedRowIds.append(rowId)
            }
        }

        model.searchResults = newSearchResults
        model.messagesInSelectedThread = newMessagesInThread

        applyMailboxUnreadDeltas(mailboxDeltas)

        // Open thread's summary — count how many flipped messages belong
        // to it (may differ when bulk-marking from search results that
        // span multiple threads).
        if !flippedRowIds.isEmpty,
           let tid = model.selectedThreadId,
           let summaryIdx = model.threadsForSelectedMailbox.firstIndex(where: { $0.threadId == tid }) {
            let inThreadCount = flippedRowIds.filter { id in
                newMessagesInThread.contains(where: { $0.rowId == id })
            }.count
            if inThreadCount > 0 {
                let s = model.threadsForSelectedMailbox[summaryIdx]
                model.threadsForSelectedMailbox[summaryIdx] =
                    s.with(unreadCount: max(0, s.unreadCount + inThreadCount * perMessage))
            }
        }

        model.allUnreadCount = max(0, model.allUnreadCount + unreadCountDelta)

        if let db = model.indexDB, !flippedRowIds.isEmpty {
            persistIsRead(rowids: flippedRowIds, isRead: isRead, db: db)
        }
    }

    // MARK: — Shared model mutations

    /// Apply per-mailbox unread deltas to the sidebar, in one assignment.
    private func applyMailboxUnreadDeltas(_ deltas: [Int: Int]) {
        guard !deltas.isEmpty else { return }
        model.mailboxes = model.mailboxes.map { mb in
            guard let delta = deltas[mb.rowId], delta != 0 else { return mb }
            return mb.with(unreadCount: max(0, mb.unreadCount + delta))
        }
    }

    /// Flip the read flag on `rowIds` wherever they appear in the open thread
    /// or the search results, reassigning each array at most once.
    private func flipReadInVisibleArrays(rowIds: Set<Int>, isRead: Bool) {
        if model.messagesInSelectedThread.contains(where: { rowIds.contains($0.rowId) && $0.isRead != isRead }) {
            model.messagesInSelectedThread = model.messagesInSelectedThread.map {
                rowIds.contains($0.rowId) && $0.isRead != isRead ? $0.withIsRead(isRead) : $0
            }
        }
        if model.searchResults.contains(where: { rowIds.contains($0.rowId) && $0.isRead != isRead }) {
            model.searchResults = model.searchResults.map {
                rowIds.contains($0.rowId) && $0.isRead != isRead ? $0.withIsRead(isRead) : $0
            }
        }
    }

    /// One-transaction batch write of `is_read`. Failures show up as a
    /// `bulkActionError` alert — without surfacing, the optimistic in-memory
    /// flip would silently revert on the next sync, leaving the user with
    /// no idea what happened.
    private func persistIsRead(rowids: [Int], isRead: Bool, db: IndexDB) {
        // Inherits MainActor isolation from this @MainActor method, so the
        // catch block runs back on the main actor without an explicit hop.
        Task { [weak model] in
            do {
                try await db.setIsReadBatch(rowids: rowids, isRead: isRead)
            } catch {
                Log.db.error("setIsReadBatch failed for \(rowids.count) rows: \(String(describing: error), privacy: .public)")
                model?.bulkActionError = "Couldn't update read status in the local index — your change may not stick after the next sync. (\(error.localizedDescription))"
            }
        }
    }
}
