import AppKit
import Foundation

/// AppleScript-driven write-back to Mail.app. Runs scripts via `/usr/bin/osascript`
/// in a subprocess — keeps FMail's main thread free and avoids NSAppleScript's
/// fussy main-thread / runloop requirements. The first invocation triggers
/// macOS's Automation permission prompt ("FMail wants to control Mail.app").
///
/// The script needs to wait for Mail.app's responses (to look up account /
/// mailbox / message), so we don't use `ignoring application responses` —
/// that would make the lookup steps return nothing. Mail.app does block its
/// own UI briefly while it scans the target mailbox; we keep that scan to
/// one specific mailbox to minimise the lockup.
enum MailScripter {
    /// Asks Mail.app to set a message's read status. Returns when osascript
    /// finishes (Mail.app has applied the change or reported it couldn't find
    /// the message). Caller should run this with a Task and not await it on
    /// the main actor — UI feedback should be optimistic (already done before
    /// this is called).
    static func setReadStatus(
        rfcMessageId: String,
        isRead: Bool,
        accountEmail: String?,
        mailboxPathComponents: [String]?
    ) async -> Result {
        let cleaned = rfcMessageId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        guard !cleaned.isEmpty else { return .failed("Empty Message-ID") }

        let escapedId = appleScriptEscape(cleaned)
        let readBool = isRead ? "true" : "false"

        let source = makeScript(
            escapedId: escapedId,
            readBool: readBool,
            accountEmail: accountEmail,
            mailboxPathComponents: mailboxPathComponents
        )

        let (stdout, stderr, exitCode) = await runOsascript(source)
        if exitCode != 0 {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = detail.isEmpty ? stdout : detail
            return .failed("osascript exit \(exitCode): \(body)")
        }
        let count = Int(stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return count > 0 ? .ok(matched: count) : .notFound
    }

    enum Result: Sendable {
        case ok(matched: Int)
        case notFound
        case failed(String)
    }

    // MARK: — Script construction

    private static func makeScript(
        escapedId: String,
        readBool: String,
        accountEmail: String?,
        mailboxPathComponents: [String]?
    ) -> String {
        if let accountEmail, !accountEmail.isEmpty,
           let mailboxPathComponents, !mailboxPathComponents.isEmpty {
            // Targeted: navigate directly to the message's home mailbox so
            // Mail.app only scans that one mailbox's messages.
            let escapedEmail = appleScriptEscape(accountEmail)
            let mailboxRef = buildMailboxRef(pathComponents: mailboxPathComponents)
            return """
            tell application "Mail"
                set targetId to "\(escapedId)"
                set targetEmail to "\(escapedEmail)"
                set foundCount to 0
                set theAccount to missing value
                repeat with acc in accounts
                    try
                        if (email addresses of acc) contains targetEmail then
                            set theAccount to acc
                            exit repeat
                        end if
                    end try
                end repeat
                if theAccount is not missing value then
                    try
                        set targetMailbox to \(mailboxRef)
                        set matches to (messages of targetMailbox whose message id is targetId)
                        repeat with msg in matches
                            set read status of msg to \(readBool)
                            set foundCount to foundCount + 1
                        end repeat
                    end try
                end if
                return foundCount
            end tell
            """
        } else {
            // Fallback: walk one level deep across all accounts.
            return """
            tell application "Mail"
                set targetId to "\(escapedId)"
                set foundCount to 0
                repeat with anAccount in accounts
                    try
                        repeat with mbox in (mailboxes of anAccount)
                            try
                                set matches to (messages of mbox whose message id is targetId)
                                repeat with msg in matches
                                    set read status of msg to \(readBool)
                                    set foundCount to foundCount + 1
                                end repeat
                            end try
                        end repeat
                    end try
                end repeat
                return foundCount
            end tell
            """
        }
    }

    /// Build an AppleScript object reference like
    /// `mailbox "All Mail" of mailbox "[Gmail]" of theAccount`
    /// from path components like `["[Gmail]", "All Mail"]`.
    private static func buildMailboxRef(pathComponents: [String]) -> String {
        var ref = "theAccount"
        for component in pathComponents {
            ref = "mailbox \"\(appleScriptEscape(component))\" of \(ref)"
        }
        return ref
    }

    private static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: — osascript subprocess

    /// Runs an AppleScript via `/usr/bin/osascript` in a subprocess. Returns
    /// (stdout, stderr, exitCode). Subprocess execution doesn't block our
    /// main thread; Mail.app processes the apple events on its own thread.
    private static func runOsascript(_ source: String) async -> (String, String, Int32) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", source]
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                do {
                    try process.run()
                    process.waitUntilExit()
                    let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    continuation.resume(returning: (out, err, process.terminationStatus))
                } catch {
                    continuation.resume(returning: ("", error.localizedDescription, -1))
                }
            }
        }
    }
}
