import AppKit
import Foundation

/// Owns the menu's Mark-as-read / Mark-as-unread commands. Production code
/// enters through `setReadStatus(rowids:isRead:)`, which applies the change
/// optimistically (badge counter + DB update immediately), then awaits one
/// AppleScript at Mail.app. The next FSEvent-driven sync reconciles in case
/// Mail.app couldn't apply the change; failures surface via
/// `MailModel.bulkActionError`. (`applyOptimisticReadFlip` is `internal`
/// only so tests can drive the optimistic flip directly — see its doc
/// comment — it is never a second production entry point.)
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

    /// Flip the badge/index for the messages that actually change state.
    /// Dedupes by `rowId` first so passing the same message twice can't
    /// double-count the delta, then filters to `isRead != $0.isRead` (D3) so
    /// the delta and the DB write are correct even if a caller passes
    /// messages already in the target state — `setReadStatus`'s `resolved`
    /// (unfiltered) still feeds the AppleScript dispatch and the return
    /// value, so its contract is unchanged.
    ///
    /// `internal`, not `private`, **only** so tests can drive the optimistic
    /// flip directly without going through `setReadStatus` — and therefore
    /// without ever dispatching AppleScript at Mail.app. This method never
    /// talks to Mail.app itself; production code must always go through
    /// `setReadStatus`.
    func applyOptimisticReadFlip(messages: [MessageHeader], isRead: Bool) async {
        var seenRowIds = Set<Int>()
        let deduped = messages.filter { seenRowIds.insert($0.rowId).inserted }
        let toFlip = deduped.filter { $0.isRead != isRead }
        guard !toFlip.isEmpty else { return }

        // Nothing to persist to — bail before mutating the counter so it
        // never drifts from the (unwritten) DB state.
        guard let db = model.indexDB else { return }

        // Global counter.
        let totalDelta = toFlip.count * unreadDelta(isRead: isRead)
        model.allUnreadCount = max(0, model.allUnreadCount + totalDelta)

        // Persist to DB.
        persistIsRead(rowids: toFlip.map(\.rowId), isRead: isRead, db: db)
    }

    /// Signed count change applied per message when flipping to `isRead`:
    /// marking read removes one unread (-1); marking unread adds one (+1).
    private func unreadDelta(isRead: Bool) -> Int { isRead ? -1 : 1 }

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

    /// Tail of the chain of spawned persist `Task`s. Each new write awaits the
    /// previous one, so awaiting this single handle drains *every* outstanding
    /// write, not just the last (same pattern as `MailModel.applyMCPSettings`).
    ///
    /// Exposed **only** so tests can deterministically drain the fire-and-forget
    /// DB write before tearing down their tmp fixture — without the drain, the
    /// write lands after the fixture directory is deleted and fails with a disk
    /// I/O error that no assertion catches. Production callers (`setReadStatus`)
    /// must keep NOT awaiting this: the write intentionally races Mail.app's own
    /// commit and is reconciled by the next sync.
    private(set) var pendingPersist: Task<Void, Never>?

    /// One-transaction batch write of `is_read`. Failures show up as a
    /// `bulkActionError` alert — without surfacing, the optimistic in-memory
    /// flip would silently revert on the next sync, leaving the user with
    /// no idea what happened.
    private func persistIsRead(rowids: [Int], isRead: Bool, db: IndexDB) {
        // Chain after any in-flight write so two rapid mark actions commit in
        // call order rather than racing, and so `pendingPersist` is a handle to
        // all of them. Inherits MainActor isolation from this @MainActor method,
        // so the catch block runs back on the main actor without an explicit hop.
        let previous = pendingPersist
        pendingPersist = Task { [weak model] in
            await previous?.value
            do {
                try await db.setIsReadBatch(rowids: rowids, isRead: isRead)
            } catch {
                Log.db.error("setIsReadBatch failed for \(rowids.count) rows: \(String(describing: error), privacy: .public)")
                model?.bulkActionError = "Couldn't update read status in the local index — your change may not stick after the next sync. (\(error.localizedDescription))"
            }
        }
    }
}
