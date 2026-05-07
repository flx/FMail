import SwiftUI

struct ReaderView: View {
    @Bindable var model: MailModel

    var body: some View {
        Group {
            content
        }
        .sheet(item: Binding(
            get: { model.replyDraft.map { ReplyDraftWrapper(draft: $0) } },
            set: { _ in model.cancelReply() }
        )) { wrapper in
            ReplyConfirmationSheet(model: model, draft: wrapper.draft)
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.selectedThreadId == nil {
            ContentUnavailableView(
                "Select a thread",
                systemImage: "envelope",
                description: Text("Choose a thread from the list to read it here.")
            )
        } else if model.isLoadingThreadMessages {
            ProgressView("Loading thread…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let messages = model.messagesInSelectedThread
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(messages.enumerated()), id: \.element.rowId) { index, msg in
                        if index > 0 && index - 1 < messages.count {
                            timeDelta(from: messages[index - 1], to: msg)
                        }
                        MessageBlock(
                            message: msg,
                            messageBody: model.selectedMessageId == msg.rowId ? model.bodyForSelectedMessage : nil,
                            isLoadingBody: model.selectedMessageId == msg.rowId && model.isLoadingBody,
                            bodyError: model.selectedMessageId == msg.rowId ? model.bodyError : nil,
                            isExpanded: model.selectedMessageId == msg.rowId,
                            onTap: { model.selectMessage(msg) },
                            onReply: { model.startReply(kind: .reply, message: msg, body: model.bodyForSelectedMessage) },
                            onReplyAll: { model.startReply(kind: .replyAll, message: msg, body: model.bodyForSelectedMessage) },
                            onForward: { model.startReply(kind: .forward, message: msg, body: model.bodyForSelectedMessage) }
                        )
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func timeDelta(from previous: MessageHeader, to current: MessageHeader) -> some View {
        if let prev = previous.dateReceived ?? previous.dateSent,
           let curr = current.dateReceived ?? current.dateSent {
            let delta = curr.timeIntervalSince(prev)
            if delta > 0 {
                HStack {
                    Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 1)
                    Text(formatDelta(delta))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 1)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func formatDelta(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "+\(Int(seconds))s" }
        if seconds < 3600 { return "+\(Int(seconds / 60))m" }
        if seconds < 86400 { return "+\(Int(seconds / 3600))h" }
        if seconds < 86400 * 30 { return "+\(Int(seconds / 86400))d" }
        if seconds < 86400 * 365 { return "+\(Int(seconds / (86400 * 30)))mo" }
        return "+\(Int(seconds / (86400 * 365)))y"
    }
}

private struct MessageBlock: View {
    let message: MessageHeader
    let messageBody: MessageBody?
    let isLoadingBody: Bool
    let bodyError: String?
    let isExpanded: Bool
    let onTap: () -> Void
    let onReply: () -> Void
    let onReplyAll: () -> Void
    let onForward: () -> Void

    @State private var htmlMeasuredHeight: CGFloat = 200
    /// Per-message opt-in: load external `<img src="http://…">` references
    /// (e.g. newsletter graphs). False by default — privacy-preserving.
    /// Resets when the user navigates away (MessageBlock recreated).
    @State private var loadRemoteImages: Bool = false
    /// Disclosure state for the expanded-message header detail block
    /// (full sender address, To/Cc, exact date+time). Collapsed by default.
    @State private var showDetails: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if isExpanded {
                // Toolbar at the top — long footers shouldn't push Reply
                // off-screen.
                replyToolbar
                if let bodyError {
                    bodyErrorBlock(bodyError)
                } else if isLoadingBody {
                    ProgressView()
                } else if let messageBody {
                    if !messageBody.attachments.isEmpty {
                        attachmentsBlock(messageBody.attachments)
                    }
                    bodyContent(messageBody)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(message.isRead ? Color.secondary.opacity(0.05) : Color.accentColor.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isExpanded ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
        )
        .padding(.bottom, 4)
        .onTapGesture { onTap() }
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                senderLine
                if isExpanded {
                    Text(message.subject.isEmpty ? "(no subject)" : message.subject)
                        .font(.title3.weight(.semibold))
                        .padding(.top, 2)
                } else {
                    Text(message.subject.isEmpty ? "(no subject)" : message.subject)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if isExpanded && showDetails {
                    detailsBlock
                        .padding(.top, 6)
                }
            }
            Spacer()
            if message.isFlagged {
                Image(systemName: "flag.fill")
                    .foregroundStyle(.orange)
            }
            if let date = message.dateReceived ?? message.dateSent {
                Text(date, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Sender line. When the message is expanded, prepend a disclosure caret
    /// that toggles the full-headers detail block.
    @ViewBuilder
    private var senderLine: some View {
        let displayed = message.senderDisplay.isEmpty ? message.senderAddress : message.senderDisplay
        if isExpanded {
            Button {
                showDetails.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showDetails ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(displayed)
                        .font(message.isRead ? .body : .body.bold())
                }
            }
            .buttonStyle(.plain)
            .help(showDetails ? "Hide details" : "Show full sender address, recipients, and exact time")
        } else {
            Text(displayed)
                .font(message.isRead ? .body : .body.bold())
        }
    }

    /// Full-fidelity headers shown beneath the subject when the user expands
    /// the disclosure: real sender address, To/Cc, exact date+time-with-seconds.
    /// To/Cc come from the parsed `.emlx` so they're only available once the
    /// body has loaded.
    @ViewBuilder
    private var detailsBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            detailRow(label: "From", value: fromLine)
            if let to = recipientLine(forHeader: "to") {
                detailRow(label: "To", value: to)
            }
            if let cc = recipientLine(forHeader: "cc") {
                detailRow(label: "Cc", value: cc)
            }
            if let date = message.dateReceived ?? message.dateSent {
                detailRow(label: "Date", value: Self.fullDateFormatter.string(from: date))
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private var fromLine: String {
        let display = message.senderDisplay.trimmingCharacters(in: .whitespaces)
        let address = message.senderAddress.trimmingCharacters(in: .whitespaces)
        if display.isEmpty { return address }
        if address.isEmpty { return display }
        return "\(display) <\(address)>"
    }

    private func recipientLine(forHeader name: String) -> String? {
        guard let raw = messageBody?.headers[name], !raw.isEmpty else { return nil }
        return EncodedWord.decode(raw)
    }

    /// E.g. "Wed, May 6, 2026 at 10:23:45 AM EDT". Day-of-week + month name +
    /// year + time-to-the-second + timezone abbreviation. Locale-aware.
    private static let fullDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "EEE, MMM d, yyyy 'at' h:mm:ss a zzz"
        return f
    }()

    /// Clickable attachment list. Each row triggers a save panel pointing
    /// at the user's preferred destination, with the attachment's filename
    /// pre-filled. FMail isn't sandboxed so the chosen URL is writable
    /// directly without scoped-bookmark gymnastics.
    @ViewBuilder
    private func attachmentsBlock(_ attachments: [Attachment]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(attachments.enumerated()), id: \.offset) { _, att in
                Button {
                    saveAttachment(att)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "paperclip")
                            .foregroundStyle(.secondary)
                        Text(att.name)
                        Text(formatBytes(att.data.count))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 8)
                        Image(systemName: "arrow.down.circle")
                            .foregroundStyle(.tint)
                    }
                    .font(.caption)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .help("Save \(att.name)…")
            }
        }
    }

    private func saveAttachment(_ attachment: Attachment) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.name
        panel.canCreateDirectories = true
        panel.title = "Save attachment"
        panel.message = "Save \"\(attachment.name)\" (\(formatBytes(attachment.data.count)))"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try attachment.data.write(to: url)
        } catch {
            // Non-fatal: surface as an alert from a separate panel so the
            // user knows why no file appeared.
            let alert = NSAlert()
            alert.messageText = "Couldn't save attachment"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private func formatBytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    @ViewBuilder
    private func bodyContent(_ body: MessageBody) -> some View {
        // Prefer HTML rendering when the message has an HTML part — much
        // closer to Mail.app's display fidelity. WKWebView is locked down
        // (no network) so no read-tracking pixels and no remote-image leaks.
        if let html = body.html, !html.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if !loadRemoteImages && HTMLBodyView.containsRemoteImages(html) {
                    Button {
                        loadRemoteImages = true
                    } label: {
                        Label("Load remote images", systemImage: "photo.on.rectangle")
                    }
                    .controlSize(.small)
                    .help("This email includes external images. Loading them sends a network request to the sender's server, which can be used as a read receipt. Choice doesn't persist — re-open the email and they're hidden again.")
                }
                HTMLBodyView(html: html, allowRemoteImages: loadRemoteImages, measuredHeight: $htmlMeasuredHeight)
                    .frame(height: htmlMeasuredHeight)
                    .frame(maxWidth: .infinity)
            }
        } else {
            Text(body.displayText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var replyToolbar: some View {
        HStack(spacing: 8) {
            Button(action: onReply) {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }
            .keyboardShortcut("r", modifiers: .command)
            Button(action: onReplyAll) {
                Label("Reply All", systemImage: "arrowshape.turn.up.left.2")
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            Button(action: onForward) {
                Label("Forward", systemImage: "arrowshape.turn.up.right")
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            if let rfcId = message.rfcMessageId, !rfcId.isEmpty {
                Button {
                    _ = MailAppOpener.openMessage(rfcMessageId: rfcId)
                } label: {
                    Label("Open in Mail.app", systemImage: "arrow.up.right.square")
                }
                .help("Opens Mail.app at this message — useful when the body hasn't downloaded yet")
            }
            Spacer()
        }
        .controlSize(.small)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func bodyErrorBlock(_ message: String) -> some View {
        let isPermissionError = message.contains("-1743") || message.lowercased().contains("not authorized")
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            if isPermissionError {
                Text("FMail needs permission to send Apple events to Mail.app for Mark-as-Read to work. Open Automation settings, find FMail in the list, and check the box next to Mail.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button {
                    let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation")
                        ?? URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Open Privacy & Security → Automation", systemImage: "lock.shield")
                }
                .controlSize(.small)
            }
            if let rfcId = self.message.rfcMessageId, !rfcId.isEmpty {
                Button {
                    _ = MailAppOpener.openMessage(rfcMessageId: rfcId)
                } label: {
                    Label("Open in Mail.app to download", systemImage: "arrow.down.circle")
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Wraps ReplyDraft for use with `.sheet(item:)`, which requires Identifiable.
private struct ReplyDraftWrapper: Identifiable, Equatable {
    let draft: ReplyDraft
    var id: Int { draft.originalMessage.rowId }
    static func == (lhs: ReplyDraftWrapper, rhs: ReplyDraftWrapper) -> Bool {
        lhs.draft == rhs.draft
    }
}
