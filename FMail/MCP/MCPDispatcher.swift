import Foundation

/// Tool registry + JSON-RPC method dispatcher for the MCP server.
/// Stateless apart from the registered tools — connection handling lives in
/// `MCPServer`. The registry starts empty; `MCPTools.registerReadTools`
/// populates it once per server start.
actor MCPDispatcher {
    private var tools: [String: MCPTool] = [:]
    private var resources: [String: MCPResource] = [:]

    func register(_ tool: MCPTool) {
        tools[tool.name] = tool
    }

    /// Register an MCP resource (keyed by URI). Resources are read-only blobs
    /// the client can fetch on demand — used for the `fmail://schema` ontology,
    /// which is too large to ride in a tool description on every call.
    func register(resource: MCPResource) {
        resources[resource.uri] = resource
    }

    func registeredToolNames() -> [String] {
        tools.keys.sorted()
    }

    /// Dispatch a raw HTTP body containing a JSON-RPC request.
    /// Returns either a JSON response (for requests) or a notification ack
    /// (for notifications — caller maps to HTTP 202).
    ///
    /// `isLocal` marks whether the request arrived from a loopback client
    /// (local Claude Code) vs the configured tunnel host. It's published as a
    /// task-local for the duration of the handler so the attachment handler
    /// can decide whether an unconfined `save_to_path` is permitted, without
    /// every tool's handler signature having to carry request metadata.
    func dispatch(rawBody: Data, isLocal: Bool = false) async -> MCPDispatchResult {
        await MCPRequestContext.$isLocal.withValue(isLocal) {
            await self.dispatchBody(rawBody: rawBody)
        }
    }

    private func dispatchBody(rawBody: Data) async -> MCPDispatchResult {
        // Decode envelope
        let req: JSONRPCRequest
        do {
            req = try JSONDecoder().decode(JSONRPCRequest.self, from: rawBody)
        } catch {
            // No id — emit a parse-error response with id: null
            let resp = JSONRPCResponse.failure(
                id: .null,
                error: JSONRPCErrorPayload(
                    code: JSONRPCErrorCode.parseError,
                    message: "Parse error: \(error.localizedDescription)"
                )
            )
            return .response(encode(resp))
        }

        // Notifications: id absent → no response (HTTP 202).
        if req.id == nil {
            // Currently the only notification we expect is `notifications/initialized`.
            // We don't need to do anything with it.
            return .notification
        }

        let id = req.id ?? .null
        do {
            let result: JSONValue
            switch req.method {
            case "initialize":
                result = handleInitialize(req.params)
            case "ping":
                result = .object([:])
            case "tools/list":
                result = handleToolsList()
            case "tools/call":
                result = try await handleToolsCall(req.params)
            case "resources/list":
                result = handleResourcesList()
            case "resources/read":
                result = try await handleResourcesRead(req.params)
            case "resources/templates/list":
                // No templated resources — return an empty list rather than
                // method-not-found so spec-conformant clients don't log an error.
                result = .object(["resourceTemplates": .array([])])
            default:
                throw JSONRPCErrorPayload(
                    code: JSONRPCErrorCode.methodNotFound,
                    message: "Method not found: \(req.method)"
                )
            }
            return .response(encode(JSONRPCResponse.success(id: id, result: result)))
        } catch let payload as JSONRPCErrorPayload {
            return .response(encode(JSONRPCResponse.failure(id: id, error: payload)))
        } catch {
            // Log the full Swift error (with type info) locally; ship
            // only the localized description to the wire so Swift type
            // names don't leak to clients.
            Log.mcp.error("MCP internal error on \(req.method, privacy: .public): \(String(describing: error), privacy: .public)")
            return .response(encode(JSONRPCResponse.failure(
                id: id,
                error: JSONRPCErrorPayload(
                    code: JSONRPCErrorCode.internalError,
                    message: error.localizedDescription
                )
            )))
        }
    }

    // MARK: — Method handlers

    private func handleInitialize(_ params: JSONValue?) -> JSONValue {
        // `instructions` is the MCP-spec slot for "what is this server and
        // how do you use it" — claude.ai-style connectors surface a summary
        // of it on first connection. We lead with the search capability so
        // the LLM sees it at a glance rather than discovering it by digging
        // through tools/list. We advertise tools + resources support but no
        // listChanged events (both registries are fixed at app boot).
        .object([
            "protocolVersion": .string(MCPProtocol.version),
            "capabilities": .object([
                "tools": .object(["listChanged": .bool(false)]),
                "resources": .object(["listChanged": .bool(false), "subscribe": .bool(false)])
            ]),
            "serverInfo": .object([
                "name": .string(MCPProtocol.serverName),
                "version": .string(MCPProtocol.serverVersion)
            ]),
            "instructions": .string(MCPProtocol.instructions)
        ])
    }

    private func handleToolsList() -> JSONValue {
        let entries: [JSONValue] = tools.values
            .sorted(by: { $0.name < $1.name })
            .map { tool in
                .object([
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "inputSchema": tool.inputSchema
                ])
            }
        return .object(["tools": .array(entries)])
    }

    private func handleResourcesList() -> JSONValue {
        let entries: [JSONValue] = resources.values
            .sorted(by: { $0.uri < $1.uri })
            .map { r in
                .object([
                    "uri": .string(r.uri),
                    "name": .string(r.name),
                    "description": .string(r.description),
                    "mimeType": .string(r.mimeType)
                ])
            }
        return .object(["resources": .array(entries)])
    }

    private func handleResourcesRead(_ params: JSONValue?) async throws -> JSONValue {
        guard let uri = params?.objectValue?["uri"]?.stringValue else {
            throw JSONRPCErrorPayload(
                code: JSONRPCErrorCode.invalidParams,
                message: "resources/read requires `uri`"
            )
        }
        guard let resource = resources[uri] else {
            throw JSONRPCErrorPayload(
                code: JSONRPCErrorCode.resourceNotFound,
                message: "Unknown resource: \(uri)"
            )
        }
        let text = try await resource.read()
        return .object([
            "contents": .array([
                .object([
                    "uri": .string(uri),
                    "mimeType": .string(resource.mimeType),
                    "text": .string(text)
                ])
            ])
        ])
    }

    private func handleToolsCall(_ params: JSONValue?) async throws -> JSONValue {
        guard let obj = params?.objectValue,
              let name = obj["name"]?.stringValue
        else {
            throw JSONRPCErrorPayload(
                code: JSONRPCErrorCode.invalidParams,
                message: "tools/call requires `name`"
            )
        }
        let arguments = obj["arguments"] ?? .object([:])
        guard let tool = tools[name] else {
            throw JSONRPCErrorPayload(
                code: JSONRPCErrorCode.methodNotFound,
                message: "Unknown tool: \(name)"
            )
        }

        let result: JSONValue
        do {
            result = try await tool.handler(arguments)
        } catch let payload as JSONRPCErrorPayload {
            // Structured tool error → JSON-RPC error envelope (visible as an
            // exception to the LLM client).
            throw payload
        } catch {
            // Tool threw something unexpected — wrap as an `isError: true`
            // content block per MCP convention. The client can read it but
            // it doesn't fail the whole RPC.
            return .object([
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string("Error: \(error)")
                    ])
                ]),
                "isError": .bool(true)
            ])
        }

        // Wrap the result as a single text content block whose text is the
        // JSON-encoded result. This is the documented MCP convention; LLM
        // clients parse this back automatically.
        let resultJSON: String
        do {
            let data = try JSONEncoder().encode(result)
            resultJSON = String(data: data, encoding: .utf8) ?? "null"
        } catch {
            resultJSON = "null"
        }
        return .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(resultJSON)
                ])
            ]),
            "isError": .bool(false)
        ])
    }

    // MARK: — Helpers

    private func encode(_ resp: JSONRPCResponse) -> Data {
        do {
            return try JSONEncoder().encode(resp)
        } catch {
            // Fall back to a minimal error envelope; should never happen.
            return Data(
                #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"encode failed"}}"#.utf8
            )
        }
    }
}

/// One registered tool: name, description (the LLM sees this), input JSON
/// Schema, and the async handler that produces its result.
struct MCPTool: Sendable {
    let name: String
    let description: String
    let inputSchema: JSONValue
    let handler: @Sendable (JSONValue) async throws -> JSONValue
}

/// One registered resource: a stable URI, list metadata the client shows, and
/// an async `read` that produces the body text on demand (recomputed per read,
/// so it always reflects the live index).
struct MCPResource: Sendable {
    let uri: String
    let name: String
    let description: String
    let mimeType: String
    let read: @Sendable () async throws -> String
}

enum MCPDispatchResult: Sendable {
    /// A JSON-RPC response envelope to send back as HTTP 200.
    case response(Data)
    /// A JSON-RPC notification — no response (HTTP 202 with empty body).
    case notification
}

/// Per-request context published as a task-local for the duration of a
/// `tools/call`. Lets a handler read request-scoped facts (currently just the
/// local-vs-tunnel origin) without threading them through `MCPTool.handler`.
enum MCPRequestContext {
    /// True when the request came from a loopback client (local Claude Code),
    /// false when it arrived over the configured tunnel host. Bound per
    /// request by `MCPDispatcher.dispatch`. Defaults to the safe (treated-as-
    /// remote) value so an un-wrapped dispatch can't accidentally grant
    /// unconfined filesystem writes.
    @TaskLocal static var isLocal: Bool = false
}
