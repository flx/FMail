import AppKit
import ApplicationServices
import Foundation

/// Why opening or filling a reply draft failed.
enum ReplyDraftError: Error, Equatable, CustomStringConvertible {
    case messageNotFound
    case script(String)

    var description: String {
        switch self {
        case .messageNotFound:
            return "Mail.app couldn't find the message to reply to"
        case .script(let detail):
            return "AppleScript failed: \(detail.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}

/// Everything needed to open and fill one reply draft. Built by the MCP
/// handler; the drafter only talks to Mail.app.
struct ReplyDraftRequest: Sendable {
    let entry: MailScripter.BatchEntry
    let replyAll: Bool
    /// Draft text to put above the quoted original. May be empty.
    let body: String
    /// Local files to attach, already resolved and confined by the caller.
    let attachmentURLs: [URL]
    /// Plain-text quote used only by the AppleScript fallback, which can't
    /// keep Mail's native quote (see ``ReplyQuote``).
    let fallbackQuote: String
}

/// How the draft was filled.
enum ReplyDraftMode: String, Sendable, Codable {
    /// Reply opened; there was nothing to add.
    case openedOnly = "opened_only"
    /// Text/attachments pasted at the cursor; Mail's rich quote kept.
    case pasted
    /// Content set via AppleScript with a plain-text quote FMail built.
    case applescript
}

struct ReplyDraftOutcome: Sendable {
    let draftId: Int
    let mode: ReplyDraftMode
    /// Human-readable notes, e.g. why the fallback was used.
    let notes: [String]
}

/// The one deliberate Mail-mutating capability the MCP layer is handed.
/// Opens a draft in Mail.app; there is intentionally no way to send.
protocol ReplyDrafting: Sendable {
    func draftReply(_ request: ReplyDraftRequest) async -> Swift.Result<ReplyDraftOutcome, ReplyDraftError>
}

/// Builds the plain-text "On …, X wrote:" quote for the AppleScript fallback.
enum ReplyQuote {
    /// Upper bound on quoted characters, so a huge original doesn't produce a
    /// multi-megabyte draft.
    static let maxQuotedCharacters = 20_000

    static func build(senderDisplay: String, senderAddress: String, date: Date?, originalText: String) -> String {
        let who: String
        if senderDisplay.isEmpty || senderDisplay == senderAddress {
            who = senderAddress
        } else {
            who = "\(senderDisplay) <\(senderAddress)>"
        }
        let header: String
        if let date {
            header = "On \(dateFormatter.string(from: date)), \(who) wrote:"
        } else {
            header = "\(who) wrote:"
        }
        var text = originalText.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > maxQuotedCharacters {
            text = String(text.prefix(maxQuotedCharacters)) + "\n[…]"
        }
        guard !text.isEmpty else { return header }
        let quoted = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? ">" : "> \($0)" }
            .joined(separator: "\n")
        return header + "\n" + quoted
    }

    /// Draft text, a blank line, then the quote.
    static func compose(body: String, quote: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? quote : trimmed + "\n\n" + quote
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, yyyy 'at' HH:mm"
        return f
    }()
}

/// Production drafter. Opens Mail's native reply, then either
///
/// * **pastes** the text and files at the cursor via System Events, which
///   keeps Mail's rich quoted original (needs Accessibility, an unlocked
///   screen), or
/// * falls back to setting `content` via AppleScript with a plain-text quote
///   — any AppleScript write to a reply's content (even just inserting an
///   attachment) discards Mail's native quote, verified on macOS 27.
///
/// Drafts are serialised: two concurrent pastes would fight over the
/// clipboard and the front window. Never sends.
@MainActor
final class MailReplyDrafter: ReplyDrafting {
    private var tail: Task<Void, Never>?

    nonisolated init() {}

    nonisolated func draftReply(_ request: ReplyDraftRequest) async -> Swift.Result<ReplyDraftOutcome, ReplyDraftError> {
        await enqueue(request)
    }

    private func enqueue(_ request: ReplyDraftRequest) async -> Swift.Result<ReplyDraftOutcome, ReplyDraftError> {
        let previous = tail
        let work = Task { @MainActor in
            await previous?.value
            return await self.perform(request)
        }
        tail = Task { _ = await work.value }
        return await work.value
    }

    private func perform(_ request: ReplyDraftRequest) async -> Swift.Result<ReplyDraftOutcome, ReplyDraftError> {
        let draftId: Int
        switch await MailScripter.openReply(request.entry, replyAll: request.replyAll) {
        case .success(let id): draftId = id
        case .failure(let error): return .failure(error)
        }

        let hasText = !request.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasText || !request.attachmentURLs.isEmpty else {
            return .success(ReplyDraftOutcome(draftId: draftId, mode: .openedOnly, notes: []))
        }

        var notes: [String] = []
        if let reason = pasteUnavailableReason() {
            notes.append("\(reason) — filled via AppleScript, so the quoted original is plain text instead of Mail's native quote.")
        } else {
            switch await paste(request, draftId: draftId, hasText: hasText) {
            case .pasted:
                return .success(ReplyDraftOutcome(draftId: draftId, mode: .pasted, notes: []))
            case .notStarted(let why):
                notes.append("\(why) — filled via AppleScript instead; the quoted original is plain text.")
            case .partial(let why):
                // Some content already landed; an AppleScript fill now would
                // wipe it. Report rather than retry.
                return .failure(.script("paste interrupted after partial insert: \(why). Check the open draft in Mail."))
            }
        }

        let text = ReplyQuote.compose(body: request.body, quote: request.fallbackQuote)
        let paths = request.attachmentURLs.map(\.path)
        switch await MailScripter.runDraftScript(MailScripter.fillDraftScript, draftId: draftId, extra: [text] + paths) {
        case .success:
            return .success(ReplyDraftOutcome(draftId: draftId, mode: .applescript, notes: notes))
        case .failure(let error):
            return .failure(error)
        }
    }

    // MARK: — Paste path

    private enum PasteResult {
        case pasted
        case notStarted(String)
        case partial(String)
    }

    /// Nil when GUI paste can run; otherwise why not.
    private func pasteUnavailableReason() -> String? {
        if !AXIsProcessTrusted() {
            // Shows the system prompt once; later calls are silent.
            // Literal value of `kAXTrustedCheckOptionPrompt` (that global
            // isn't concurrency-safe to reference under Swift 6).
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            return "FMail doesn't have Accessibility permission (System Settings → Privacy & Security → Accessibility)"
        }
        if Self.screenIsLocked() {
            return "the screen is locked, so keystrokes can't reach Mail"
        }
        return nil
    }

    private func paste(_ request: ReplyDraftRequest, draftId: Int, hasText: Bool) async -> PasteResult {
        guard case .success("ready") = await MailScripter.runDraftScript(MailScripter.draftFrontScript, draftId: draftId) else {
            return .notStarted("the reply window didn't come to the front")
        }
        let snapshot = ClipboardSnapshot.capture()
        defer { snapshot.restore() }

        var pastedSomething = false
        var steps: [(NSPasteboard) -> Void] = []
        if hasText {
            let text = request.body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
            steps.append { $0.setString(text, forType: .string) }
        }
        if !request.attachmentURLs.isEmpty {
            let urls = request.attachmentURLs.map { $0 as NSURL }
            steps.append { $0.writeObjects(urls) }
        }
        for step in steps {
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.mail" else {
                return pastedSomething ? .partial("Mail lost focus") : .notStarted("Mail isn't the frontmost app")
            }
            let pb = NSPasteboard.general
            pb.clearContents()
            step(pb)
            let result = await MailScripter.runDraftScript(MailScripter.pasteIntoDraftScript, draftId: draftId)
            guard case .success("pasted") = result else {
                let why: String
                if case .failure(let e) = result { why = e.description } else { why = "the draft is no longer the front window" }
                return pastedSomething ? .partial(why) : .notStarted(why)
            }
            pastedSomething = true
            // Mail reads the pasteboard when it handles the key event; give it
            // time before the next step overwrites (or restore() resets) it.
            try? await Task.sleep(for: .milliseconds(600))
        }
        return .pasted
    }

    private nonisolated static func screenIsLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}

/// Copy of every item/type on the general pasteboard, so a paste-driven draft
/// can put the user's clipboard back afterwards.
@MainActor
private struct ClipboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture() -> ClipboardSnapshot {
        let items = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            var types: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { types[type] = data }
            }
            return types
        }
        return ClipboardSnapshot(items: items)
    }

    func restore() {
        let pb = NSPasteboard.general
        pb.clearContents()
        let restored = items.map { types -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pb.writeObjects(restored) }
    }
}
