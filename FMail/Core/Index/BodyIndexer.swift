import Foundation

/// Walks `.emlx` files for messages whose body has not yet been indexed,
/// extracts plain-text body, and adds it to FTS. Designed to run in the
/// background as a long sweep that the user can interrupt by quitting.
///
/// The metadata sync in `Indexer.runFullSync` populates FTS with subject +
/// sender + recipients, so search works immediately for those fields. Body
/// content becomes searchable as this sweep progresses.
actor BodyIndexer {
    private let indexDB: IndexDB
    private let bodyLoader: BodyLoader
    private(set) var isRunning = false
    private var cancelled = false

    init(indexDB: IndexDB, bodyLoader: BodyLoader) {
        self.indexDB = indexDB
        self.bodyLoader = bodyLoader
    }

    func cancel() { cancelled = true }

    /// Runs until the unindexed-body queue is empty or `cancel()` is called.
    /// Reports progress via the `progress` closure (called on the MainActor).
    func runUntilDone(
        mailboxes: [Mailbox],
        progress: @MainActor @escaping (BodyIndexProgress) -> Void
    ) async {
        if isRunning { return }
        isRunning = true
        cancelled = false
        defer { isRunning = false }

        let mailboxByRowId = Dictionary(uniqueKeysWithValues: mailboxes.map { ($0.rowId, $0) })

        let total = (try? await indexDB.countUnindexedBody()) ?? 0
        var done = 0
        await reportProgress(progress, stage: "Indexing bodies", done: 0, total: total)

        let batchSize = 200
        while !cancelled {
            let batch: [(rowid: Int, mailboxRowId: Int)]
            do {
                batch = try await indexDB.fetchUnindexedBodyMessages(limit: batchSize)
            } catch {
                break
            }
            if batch.isEmpty { break }

            for entry in batch {
                if cancelled { break }
                guard let mb = mailboxByRowId[entry.mailboxRowId] else {
                    // Orphan reference; mark as indexed-with-empty so we don't loop.
                    try? await indexDB.setBodyText(messageRowId: entry.rowid, bodyText: "")
                    done += 1
                    continue
                }
                do {
                    if let body = try await bodyLoader.loadBody(messageRowId: entry.rowid, mailbox: mb) {
                        // Split into the rankable body (body_clean) and the
                        // stripped reply-chain/signature tail (body_quoted), and
                        // classify list/newsletter mail from the headers — both
                        // feed the relevance ranker. setBodyContent also replaces
                        // the message's attachment rows (content-type/size for
                        // the DSL filters).
                        let split = BodyCleaner.split(body.displayText)
                        try await indexDB.setBodyContent(
                            messageRowId: entry.rowid,
                            bodyClean: split.clean,
                            bodyQuoted: split.quoted,
                            isBulk: BulkHeuristic.isBulk(body.headers),
                            attachments: body.attachments
                        )
                    } else {
                        // No .emlx on disk yet (e.g. Mail.app is still
                        // downloading it). Mark it missing, not indexed, so
                        // `retryMissingBodies` picks it up once it lands.
                        try await indexDB.markBodyMissing(messageRowId: entry.rowid)
                    }
                } catch {
                    // Skip; mark as done so we don't loop on a corrupt file.
                    try? await indexDB.setBodyText(messageRowId: entry.rowid, bodyText: "")
                }
                done += 1
                if done % 50 == 0 {
                    await reportProgress(progress, stage: "Indexing bodies", done: done, total: total)
                    // Yield so other actor work can run.
                    await Task.yield()
                }
            }
        }
        if !cancelled {
            await retryMissingBodies(mailboxByRowId: mailboxByRowId)
        }
        await reportProgress(progress, stage: cancelled ? "Paused" : "Idle", done: done, total: total)
    }

    /// Set once this process has retried *every* missing body; after that
    /// each sweep only retries recent/unread ones.
    private var retriedAllMissing = false
    /// Window for the per-sweep retry (unread mail is always included).
    static let missingRetryWindow: TimeInterval = 14 * 86_400

    /// Re-check messages whose `.emlx` was missing. Each sweep follows a sync,
    /// which drops BodyLoader's file-map cache, so newly downloaded files are
    /// visible here. Only rows whose file has now appeared are written; a
    /// still-missing row costs a map lookup. Every missing row is retried
    /// once per launch; afterwards only unread or recent ones, so huge
    /// mailboxes aren't re-listed on every 60-second sync.
    func retryMissingBodies(mailboxByRowId: [Int: Mailbox]) async {
        let since: Date? = retriedAllMissing ? Date().addingTimeInterval(-Self.missingRetryWindow) : nil
        guard let rows = try? await indexDB.fetchBodyMissingMessages(recentSince: since) else { return }
        for (i, entry) in rows.enumerated() {
            if cancelled { return }
            guard let mb = mailboxByRowId[entry.mailboxRowId] else { continue }
            do {
                guard let body = try await bodyLoader.loadBody(messageRowId: entry.rowid, mailbox: mb) else { continue }
                let split = BodyCleaner.split(body.displayText)
                try await indexDB.setBodyContent(
                    messageRowId: entry.rowid,
                    bodyClean: split.clean,
                    bodyQuoted: split.quoted,
                    isBulk: BulkHeuristic.isBulk(body.headers),
                    attachments: body.attachments
                )
            } catch {
                // Present but unparseable: stop retrying it.
                try? await indexDB.setBodyText(messageRowId: entry.rowid, bodyText: "")
            }
            if i % 200 == 199 { await Task.yield() }
        }
        retriedAllMissing = true
    }

    private func reportProgress(_ closure: @MainActor @escaping (BodyIndexProgress) -> Void, stage: String, done: Int, total: Int) async {
        await MainActor.run {
            closure(BodyIndexProgress(stage: stage, done: done, total: total))
        }
    }
}

struct BodyIndexProgress: Sendable, Equatable {
    var stage: String
    var done: Int
    var total: Int

    static let idle = BodyIndexProgress(stage: "Idle", done: 0, total: 0)
}
