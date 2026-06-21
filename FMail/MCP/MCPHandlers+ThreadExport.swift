import Foundation

/// `export_thread` — render a whole conversation to Markdown, either returned
/// inline or written to a file. Builds on the same `buildEmailFulls` path as
/// `get_thread`, so body cleaning (`body_format`) works identically. Writes
/// honour the same local-vs-tunnel path policy as the attachment tools.
extension MCPHandlers {

    static func exportThread(_ args: JSONValue, context: MCPContext) async throws -> JSONValue {
        guard let obj = args.objectValue,
              let threadId = obj["thread_id"]?.intValue
        else {
            throw JSONRPCErrorPayload(
                code: JSONRPCErrorCode.invalidParams,
                message: "export_thread: `thread_id` (integer) is required"
            )
        }
        let bodyFormat = try BodyFormat.parseStrict(obj["body_format"]?.stringValue ?? "clean")
        let maxBodyChars = MCPHelpers.clampInt(obj["max_body_chars"]?.intValue ?? 50_000, min: 0, max: 200_000)
        let savePathRaw = obj["save_to_path"]?.stringValue?.trimmingCharacters(in: .whitespaces)

        let messages = try await context.indexDB.loadThreadMessages(threadId: threadId, scope: .excludeDrafts)
        guard !messages.isEmpty else {
            throw JSONRPCErrorPayload(
                code: JSONRPCErrorCode.invalidParams,
                message: "export_thread: no thread with id \(threadId) (or it's empty / drafts-only)"
            )
        }
        let full = try await buildEmailFulls(
            for: messages,
            includeBodies: true,
            maxBodyChars: maxBodyChars,
            bodyFormat: bodyFormat,
            context: context
        )
        let markdown = renderThreadMarkdown(full)

        if let savePathRaw, !savePathRaw.isEmpty {
            let absolute: String
            do {
                absolute = try resolveSavePath(savePathRaw)
            } catch let err as PathSafetyError {
                throw JSONRPCErrorPayload(code: JSONRPCErrorCode.invalidParams, message: "export_thread: \(err.description)")
            }
            let data = Data(markdown.utf8)
            do {
                let dir = (absolute as NSString).deletingLastPathComponent
                if !dir.isEmpty {
                    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                }
                try data.write(to: URL(fileURLWithPath: absolute))
            } catch {
                throw JSONRPCErrorPayload(
                    code: JSONRPCErrorCode.internalError,
                    message: "export_thread: failed to write to \(absolute): \(error.localizedDescription)"
                )
            }
            return try JSONValue.encoding(ExportThreadResult(
                thread_id: threadId, message_count: full.count, format: "markdown",
                markdown: nil, saved_path: absolute, byte_count: data.count
            ))
        }

        return try JSONValue.encoding(ExportThreadResult(
            thread_id: threadId, message_count: full.count, format: "markdown",
            markdown: markdown, saved_path: nil, byte_count: nil
        ))
    }

    /// Render a chronological thread as Markdown: a title from the first
    /// message's subject, then one section per message with its headers,
    /// cleaned body, and attachment list.
    private static func renderThreadMarkdown(_ messages: [EmailFull]) -> String {
        var out = ""
        let title = messages.first?.subject.trimmingCharacters(in: .whitespaces)
        out += "# \(title?.isEmpty == false ? title! : "(no subject)")\n\n"
        out += "_\(messages.count) message\(messages.count == 1 ? "" : "s")_\n"

        for (i, m) in messages.enumerated() {
            out += "\n---\n\n"
            let subj = m.subject.trimmingCharacters(in: .whitespaces)
            out += "## \(i + 1). \(subj.isEmpty ? "(no subject)" : subj)\n\n"

            let fromName = m.sender_display.isEmpty ? m.sender_address : m.sender_display
            out += "**From:** \(fromName)"
            if !m.sender_display.isEmpty, !m.sender_address.isEmpty {
                out += " <\(m.sender_address)>"
            }
            out += "  \n"
            if !m.to.isEmpty { out += "**To:** \(m.to.joined(separator: ", "))  \n" }
            if !m.cc.isEmpty { out += "**Cc:** \(m.cc.joined(separator: ", "))  \n" }
            if let date = m.date_received { out += "**Date:** \(date)  \n" }

            let body = m.plain_text_body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                out += "\n\(body)\n"
                if m.plain_text_truncated { out += "\n_[body truncated]_\n" }
            } else {
                out += "\n_[no text body]_\n"
            }

            if !m.attachments.isEmpty {
                out += "\n**Attachments:**\n"
                for a in m.attachments {
                    let avail = (a.locally_available == false) ? " — offloaded" : ""
                    out += "- \(a.name) (\(a.content_type), \(a.byte_count) bytes\(avail))\n"
                }
            }
        }
        return out
    }
}
