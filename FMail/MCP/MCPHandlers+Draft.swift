import Foundation

/// `draft_reply` — open a reply to an indexed message in Mail.app, optionally
/// pre-filled with draft text and attachments. The draft is left open for the
/// user to review; nothing here can send mail.
extension MCPHandlers {

    enum DraftLimits {
        static let maxBodyCharacters = 100_000
        static let maxAttachments = 10
        /// Gmail's own per-message cap; larger drafts couldn't be sent anyway.
        static let maxTotalAttachmentBytes = 25 * 1024 * 1024
        /// Email attachments are copied here before being attached.
        static var stagingRoot: URL {
            FileManager.default.temporaryDirectory.appendingPathComponent("FMailDrafts", isDirectory: true)
        }
        /// Staged copies older than this are swept on the next draft.
        static let stagingMaxAge: TimeInterval = 24 * 3600
    }

    struct DraftReplyAttachment: Codable, Sendable {
        let name: String
        let byte_count: Int
        /// "file" (a path the caller gave) or "email" (copied from an indexed message).
        let source: String
    }

    struct DraftReplyResult: Codable, Sendable {
        let opened: Bool
        let rowid: Int
        let reply_all: Bool
        /// `pasted` (Mail's native quote kept), `applescript` (plain-text
        /// quote) or `opened_only` (nothing to add).
        let mode: String
        let attachments: [DraftReplyAttachment]
        let notes: [String]
        let sent: Bool
    }

    static func draftReply(_ args: JSONValue, context: MCPContext) async throws -> JSONValue {
        func invalid(_ message: String) -> JSONRPCErrorPayload {
            JSONRPCErrorPayload(code: JSONRPCErrorCode.invalidParams, message: "draft_reply: \(message)")
        }
        guard let drafter = context.drafter else {
            throw JSONRPCErrorPayload(code: JSONRPCErrorCode.internalError, message: "draft_reply: drafting is not available in this FMail instance")
        }
        guard let obj = args.objectValue, let rowid = obj["rowid"]?.intValue else {
            throw invalid("`rowid` (integer) is required")
        }
        let body = obj["body"]?.stringValue ?? ""
        guard body.count <= DraftLimits.maxBodyCharacters else {
            throw invalid("`body` is longer than \(DraftLimits.maxBodyCharacters) characters")
        }
        let replyAll = obj["reply_all"]?.boolValue ?? false
        let attachmentSpecs = obj["attachments"]?.arrayValue ?? []
        guard attachmentSpecs.count <= DraftLimits.maxAttachments else {
            throw invalid("at most \(DraftLimits.maxAttachments) attachments")
        }

        guard let msg = try await context.indexDB.loadMessage(rowid: rowid) else {
            throw invalid("no message with rowid \(rowid)")
        }
        guard let mailbox = try await context.indexDB.loadMailbox(rowid: msg.mailboxRowId) else {
            throw JSONRPCErrorPayload(code: JSONRPCErrorCode.internalError, message: "draft_reply: rowid \(rowid) has no resolvable mailbox")
        }

        sweepStagingRoot()
        let staging = DraftLimits.stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var urls: [URL] = []
        var described: [DraftReplyAttachment] = []
        var totalBytes = 0
        for (i, spec) in attachmentSpecs.enumerated() {
            let resolved = try await resolveDraftAttachment(spec, index: i, staging: staging, context: context)
            totalBytes += resolved.info.byte_count
            guard totalBytes <= DraftLimits.maxTotalAttachmentBytes else {
                throw invalid("attachments exceed \(DraftLimits.maxTotalAttachmentBytes / 1024 / 1024) MB in total")
            }
            urls.append(resolved.url)
            described.append(resolved.info)
        }

        // Plain-text quote, used only if Mail's native quote can't be kept.
        let original = (try? await context.bodyLoader.loadBody(messageRowId: msg.rowId, mailbox: mailbox))?.displayText ?? ""
        let quote = ReplyQuote.build(
            senderDisplay: msg.senderDisplay, senderAddress: msg.senderAddress,
            date: msg.dateSent ?? msg.dateReceived, originalText: original
        )
        let accountEmail = (try? await context.indexDB.enrichForMCP(rowids: [msg.rowId]))?[msg.rowId]?.accountEmail
        let request = ReplyDraftRequest(
            entry: MailScripter.BatchEntry(
                rfcMessageId: msg.rfcMessageId ?? "",
                appleRowId: msg.rowId,
                accountEmail: accountEmail,
                mailboxPathComponents: mailbox.pathComponents
            ),
            replyAll: replyAll,
            body: body,
            attachmentURLs: urls,
            fallbackQuote: quote
        )

        switch await drafter.draftReply(request) {
        case .success(let outcome):
            return try JSONValue.encoding(DraftReplyResult(
                opened: true, rowid: rowid, reply_all: replyAll,
                mode: outcome.mode.rawValue, attachments: described,
                notes: outcome.notes + ["The draft is open in Mail.app for the user to review and send; FMail never sends."],
                sent: false
            ))
        case .failure(let error):
            throw JSONRPCErrorPayload(code: JSONRPCErrorCode.internalError, message: "draft_reply: \(error.description)")
        }
    }

    /// Resolve one `attachments[]` entry to a local file:
    /// `{"path": …}` — a file on disk; tunnel requests are confined to
    /// iCloud Drive/FMail, local requests may name any readable file.
    /// `{"rowid": N, "attachment_index": i}` — an attachment of an indexed
    /// message, copied into a private staging folder.
    private static func resolveDraftAttachment(
        _ spec: JSONValue, index i: Int, staging: URL, context: MCPContext
    ) async throws -> (url: URL, info: DraftReplyAttachment) {
        func invalid(_ message: String) -> JSONRPCErrorPayload {
            JSONRPCErrorPayload(code: JSONRPCErrorCode.invalidParams, message: "draft_reply: attachments[\(i)]: \(message)")
        }
        guard let obj = spec.objectValue else { throw invalid("must be an object") }

        if let rawPath = obj["path"]?.stringValue {
            let path: String
            do {
                path = MCPRequestContext.isLocal
                    ? URL(fileURLWithPath: try unconfinedAbsolutePath(rawPath)).resolvingSymlinksInPath().path
                    : try safeAbsolutePath(rawPath)
            } catch {
                throw invalid(String(describing: error))
            }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue,
                  FileManager.default.isReadableFile(atPath: path) else {
                throw invalid("no readable file at \(path)")
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            let url = URL(fileURLWithPath: path)
            return (url, DraftReplyAttachment(name: url.lastPathComponent, byte_count: size, source: "file"))
        }

        guard let srcRowid = obj["rowid"]?.intValue, let attIdx = obj["attachment_index"]?.intValue else {
            throw invalid("give either `path`, or `rowid` + `attachment_index`")
        }
        guard let src = try await context.indexDB.loadMessage(rowid: srcRowid),
              let srcMailbox = try await context.indexDB.loadMailbox(rowid: src.mailboxRowId) else {
            throw invalid("no message with rowid \(srcRowid)")
        }
        guard let srcBody = try await context.bodyLoader.loadBody(messageRowId: src.rowId, mailbox: srcMailbox) else {
            throw invalid("body of rowid \(srcRowid) is not on disk — call fetch_from_server first")
        }
        guard attIdx >= 0, attIdx < srcBody.attachments.count else {
            throw invalid("attachment_index \(attIdx) out of range — rowid \(srcRowid) has \(srcBody.attachments.count) attachment(s)")
        }
        let att = srcBody.attachments[attIdx]
        guard !att.data.isEmpty else {
            throw invalid("attachment '\(att.name)' is offloaded by Apple Mail — call fetch_from_server with rowid \(srcRowid) first")
        }
        // One subfolder per entry so two attachments with the same name don't collide.
        let dir = staging.appendingPathComponent(String(i), isDirectory: true)
        let url = dir.appendingPathComponent(sanitiseFilename(att.name))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try att.data.write(to: url)
        } catch {
            throw JSONRPCErrorPayload(code: JSONRPCErrorCode.internalError, message: "draft_reply: couldn't stage '\(att.name)': \(error.localizedDescription)")
        }
        return (url, DraftReplyAttachment(name: url.lastPathComponent, byte_count: att.data.count, source: "email"))
    }

    /// Delete staged copies older than a day. Mail has long since copied them
    /// into its draft by then.
    private static func sweepStagingRoot() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: DraftLimits.stagingRoot, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-DraftLimits.stagingMaxAge)
        for dir in dirs {
            let created = (try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if created < cutoff { try? fm.removeItem(at: dir) }
        }
    }
}
