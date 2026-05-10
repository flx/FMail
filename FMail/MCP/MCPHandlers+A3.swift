import Foundation

/// Phase A3 handlers — `find_unanswered_threads` (read-only) and `mark_read`
/// (writes via `ReadStatusController`'s awaitable variant). Lives separately
/// from `MCPHandlers.swift` so the read tools stay self-contained.
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

    static func markRead(_ args: JSONValue, context: MCPContext) async throws -> JSONValue {
        guard let obj = args.objectValue,
              let rowidsRaw = obj["rowids"]?.arrayValue
        else {
            throw JSONRPCErrorPayload(
                code: JSONRPCErrorCode.invalidParams,
                message: "mark_read: `rowids` (array of integers) is required"
            )
        }
        let rowids = rowidsRaw.compactMap { $0.intValue }
        guard rowids.count == rowidsRaw.count else {
            throw JSONRPCErrorPayload(
                code: JSONRPCErrorCode.invalidParams,
                message: "mark_read: `rowids` must contain integers only"
            )
        }
        guard !rowids.isEmpty else {
            return try JSONValue.encoding(MarkReadResult(applied: 0, error: nil))
        }
        let isRead = obj["is_read"]?.boolValue ?? true

        guard let handler = context.markReadHandler else {
            throw JSONRPCErrorPayload(
                code: JSONRPCErrorCode.indexNotReady,
                message: "mark_read: write thunk not wired (FMail UI may not be loaded)"
            )
        }
        let result = await handler(rowids, isRead)
        return try JSONValue.encoding(MarkReadResult(applied: result.applied, error: result.error))
    }
}

// Re-declared local so the A3 file doesn't need to widen visibility on
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
