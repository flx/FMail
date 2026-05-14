import Foundation

/// Phase B2 stub. Real implementation will use a minimal hand-rolled IMAP
/// client (TLS over NWConnection; LOGIN / SELECT / UID STORE / UID MOVE /
/// LOGOUT). See WRITEBACK_PLAN.md §IMAP for the protocol surface.
///
/// Targets iCloud (`imap.mail.me.com`, app-specific password) and other
/// IMAP providers. Until B2 lands, every call fails so the router never
/// silently swallows a request meant for this service.
struct IMAPWritebackService: WritebackService {
    let kind: WritebackKind = .imap

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
        let msg = "IMAP service not yet implemented (Phase B2). Configure credentials or wait."
        out.error = msg
        for ref in messages { out.perMessage[ref.appleRowId] = .failed(msg) }
        return out
    }
}
