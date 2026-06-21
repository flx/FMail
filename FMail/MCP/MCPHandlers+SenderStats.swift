import Foundation

/// `sender_stats` — lightweight correspondent analytics. Counts messages by
/// sender over an optional date range, for triage / unsubscribe sweeps /
/// "who emails me most." Read-only; backed by one GROUP BY in
/// `IndexDB.senderStats`.
extension MCPHandlers {

    static func senderStats(_ args: JSONValue, context: MCPContext) async throws -> JSONValue {
        let obj = args.objectValue ?? [:]
        let limit = MCPHelpers.clampInt(obj["limit"]?.intValue ?? 20, min: 1, max: 200)

        let dirStr = (obj["direction"]?.stringValue ?? "incoming").lowercased()
        guard let direction = SenderDirection(rawValue: dirStr) else {
            throw JSONRPCErrorPayload(
                code: JSONRPCErrorCode.invalidParams,
                message: "sender_stats: direction must be one of incoming / outgoing / all, got \"\(dirStr)\""
            )
        }

        let since = try obj["since"]?.stringValue.flatMap { try requireValidDate($0, field: "since") }
        let until = try obj["until"]?.stringValue.flatMap { try requireValidDate($0, field: "until") }

        let rows = try await context.indexDB.senderStats(
            since: since, until: until, direction: direction, limit: limit
        )
        let senders = rows.map {
            SenderStat(
                address: $0.address,
                display_name: $0.displayName,
                message_count: $0.count,
                unread_count: $0.unread,
                latest_date_received: $0.latest.mcpISO8601()
            )
        }
        return try JSONValue.encoding(SenderStatsResult(direction: direction.rawValue, senders: senders))
    }
}
