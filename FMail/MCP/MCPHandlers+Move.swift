import Foundation

/// `delete_messages` MCP handler — validates input, invokes the delete
/// thunk wired in by MailModel, and returns the count applied.
extension MCPHandlers {

    static func deleteMessages(_ args: JSONValue, context: MCPContext) async throws -> JSONValue {
        guard let obj = args.objectValue,
              let rowidsRaw = obj["rowids"]?.arrayValue
        else {
            throw JSONRPCErrorPayload(
                code: JSONRPCErrorCode.invalidParams,
                message: "delete_messages: `rowids` (array of integers) is required"
            )
        }
        let rowids = rowidsRaw.compactMap { $0.intValue }
        guard rowids.count == rowidsRaw.count else {
            throw JSONRPCErrorPayload(
                code: JSONRPCErrorCode.invalidParams,
                message: "delete_messages: `rowids` must contain integers only"
            )
        }
        guard !rowids.isEmpty else {
            return try JSONValue.encoding(MarkReadResult(applied: 0, error: nil))
        }
        guard let handler = context.deleteHandler else {
            throw JSONRPCErrorPayload(
                code: JSONRPCErrorCode.indexNotReady,
                message: "delete_messages: write thunk not wired (FMail UI may not be loaded)"
            )
        }
        let result = await handler(rowids)
        return try JSONValue.encoding(MarkReadResult(applied: result.applied, error: result.error))
    }
}
