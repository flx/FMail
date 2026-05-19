import Foundation

/// `get_attachment` MCP handler — returns one attachment's raw bytes
/// (base64-encoded) for the given message rowid + 0-based attachment index.
/// The index matches the order returned by `get_email` / `get_thread`'s
/// `attachments` array.
extension MCPHandlers {

    static func getAttachment(_ args: JSONValue, context: MCPContext) async throws -> JSONValue {
        guard let obj = args.objectValue,
              let rowid = obj["rowid"]?.intValue,
              let attIdx = obj["attachment_index"]?.intValue
        else {
            throw JSONRPCErrorPayload(
                code: JSONRPCErrorCode.invalidParams,
                message: "get_attachment: `rowid` (integer) and `attachment_index` (integer) are required"
            )
        }
        // 10 MB default cap. Base64 inflates ~33% so the JSON payload tops
        // out around 13.3 MB — well under typical HTTP body limits.
        let maxBytes = max(0, obj["max_bytes"]?.intValue ?? 10_000_000)

        guard let msg = try await context.indexDB.loadMessage(rowid: rowid) else {
            throw JSONRPCErrorPayload(
                code: JSONRPCErrorCode.invalidParams,
                message: "get_attachment: no message with rowid \(rowid)"
            )
        }
        guard let mailbox = try await context.indexDB.loadMailbox(rowid: msg.mailboxRowId) else {
            throw JSONRPCErrorPayload(
                code: JSONRPCErrorCode.internalError,
                message: "get_attachment: rowid \(rowid) has no resolvable mailbox"
            )
        }
        guard let body = try await context.bodyLoader.loadBody(messageRowId: msg.rowId, mailbox: mailbox) else {
            throw JSONRPCErrorPayload(
                code: JSONRPCErrorCode.invalidParams,
                message: "get_attachment: body not on disk for rowid \(rowid) — open the message in Mail.app once to trigger an IMAP download, then retry"
            )
        }
        guard attIdx >= 0, attIdx < body.attachments.count else {
            throw JSONRPCErrorPayload(
                code: JSONRPCErrorCode.invalidParams,
                message: "get_attachment: attachment_index \(attIdx) out of range — message has \(body.attachments.count) attachment(s)"
            )
        }

        let att = body.attachments[attIdx]
        let totalBytes = att.data.count
        let truncated = totalBytes > maxBytes
        let slice = truncated ? att.data.prefix(maxBytes) : att.data
        let base64 = Data(slice).base64EncodedString()

        return try JSONValue.encoding(AttachmentContent(
            rowid: rowid,
            attachment_index: attIdx,
            name: att.name,
            content_type: att.contentType,
            byte_count: totalBytes,
            data_base64: base64,
            truncated: truncated
        ))
    }
}
