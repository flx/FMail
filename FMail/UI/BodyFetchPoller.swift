import Foundation

/// Polls the `.emlx` cache for a freshly-downloaded message body. After the
/// AppleScript `source of msg` triggers Mail.app's IMAP fetch, the disk
/// writeback can lag a beat behind the AppleEvent return — so we retry the
/// local read every 500 ms for up to 8 s. The `isStillNeeded` hook lets the
/// caller bail early when the user navigates away from the message.
enum BodyFetchPoller {
    static let pollInterval: TimeInterval = 0.5
    static let timeout: TimeInterval = 8

    static func waitForBody(
        messageRowId: Int,
        mailbox: Mailbox,
        bodyLoader: BodyLoader,
        isStillNeeded: @MainActor @escaping () -> Bool
    ) async -> MessageBody? {
        await bodyLoader.invalidate(mailboxRowId: mailbox.rowId)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await !isStillNeeded() { return nil }
            if let body = try? await bodyLoader.loadBody(messageRowId: messageRowId, mailbox: mailbox) {
                return body
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            await bodyLoader.invalidate(mailboxRowId: mailbox.rowId)
        }
        return nil
    }
}
