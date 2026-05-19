import Foundation

/// `find_unanswered_threads` — threads where the user sent the latest
/// message and hasn't heard back. Read-only.
extension MCPHandlers {

    static func findUnansweredThreads(_ args: JSONValue, context: MCPContext) async throws -> JSONValue {
        guard let obj = args.objectValue,
              let sinceStr = obj["since"]?.stringValue,
              let since = parseISODateForA3(sinceStr)
        else {
            throw JSONRPCErrorPayload(
                code: JSONRPCErrorCode.invalidParams,
                message: "find_unanswered_threads: `since` (ISO date YYYY-MM-DD or YYYY-MM or YYYY) is required"
            )
        }
        let limit = clampIntForA3(obj["limit"]?.intValue ?? 50, min: 1, max: 500)
        let ourAddress = obj["our_address"]?.stringValue

        let rows = try await context.indexDB.findUnansweredThreads(
            since: since,
            ourAddress: ourAddress,
            limit: limit
        )
        return try JSONValue.encoding(FindUnansweredThreadsResult(threads: rows))
    }
}

// Re-declared local so this file doesn't need to widen visibility on
// the helpers in MCPHandlers.swift. Tiny duplication is cheaper than a
// public surface.

private func clampIntForA3(_ v: Int, min lo: Int, max hi: Int) -> Int {
    Swift.max(lo, Swift.min(hi, v))
}

private func parseISODateForA3(_ s: String) -> Date? {
    var components = DateComponents()
    components.timeZone = TimeZone(identifier: "UTC")
    let parts = s.split(separator: "-").map(String.init)
    guard let y = parts.first.flatMap(Int.init) else { return nil }
    components.year = y
    components.month = parts.count >= 2 ? Int(parts[1]) : 1
    components.day = parts.count >= 3 ? Int(parts[2]) : 1
    return Calendar(identifier: .gregorian).date(from: components)
}
