import Foundation

/// Phase B1 stub. Real implementation will use OAuth 2.0 with PKCE +
/// `users.messages.modify` / `users.messages.trash` against the Gmail
/// REST API. See WRITEBACK_PLAN.md §"OAuth flow (Gmail only)" and
/// §"Gmail API endpoints used".
///
/// Until B1 lands, every call returns `failed` for every message so the
/// router never silently swallows a request meant for this service. In
/// practice the router won't pick `.gmailApi` for any account until B1
/// adds the Settings UI to authorize one.
struct GmailAPIWritebackService: WritebackService {
    let kind: WritebackKind = .gmailApi

    func setReadStatus(_ messages: [MessageRef], isRead: Bool) async -> WritebackResult {
        _ = isRead
        return notYetImplementedResult(for: messages)
    }

    func moveToJunk(_ messages: [MessageRef]) async -> WritebackResult {
        notYetImplementedResult(for: messages)
    }

    func delete(_ messages: [MessageRef]) async -> WritebackResult {
        notYetImplementedResult(for: messages)
    }

    private func notYetImplementedResult(for messages: [MessageRef]) -> WritebackResult {
        var out = WritebackResult.empty()
        let msg = "Gmail API service not yet implemented (Phase B1). Authorize the account or wait."
        out.error = msg
        for ref in messages { out.perMessage[ref.appleRowId] = .failed(msg) }
        return out
    }
}
