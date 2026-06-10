import Foundation

/// HTTP endpoint handlers for the MCP OAuth flow. Each function takes the
/// parsed request line + body and returns the response data ready for
/// `HTTPParser.formatResponse`. Pure-ish: state lives on
/// `OAuthStore.shared` (main actor).
enum OAuthHandlers {

    // MARK: — Metadata discovery (`GET /.well-known/oauth-authorization-server`)

    static func metadata(issuer: String) -> Data {
        let body = OAuthMetadata.make(issuer: issuer)
        let jsonBody = (try? JSONEncoder().encode(JSONValue.object(body))) ?? Data("{}".utf8)
        return HTTPParser.formatResponse(status: 200, body: jsonBody)
    }

    // MARK: — Protected-resource metadata (`GET /.well-known/oauth-protected-resource`)

    /// RFC 9728. Discovered via the `WWW-Authenticate: ..., resource_metadata=...`
    /// hint on the 401 response from `/mcp`. Tells the client to look for
    /// the actual authorization-server metadata at `authorization_servers[0]`.
    static func protectedResource(issuer: String) -> Data {
        let body = OAuthMetadata.makeProtectedResource(issuer: issuer, resourcePath: MCPProtocol.mcpPath)
        let jsonBody = (try? JSONEncoder().encode(JSONValue.object(body))) ?? Data("{}".utf8)
        return HTTPParser.formatResponse(status: 200, body: jsonBody)
    }

    // MARK: — Dynamic client registration (`POST /register`)

    /// RFC 7591 dynamic client registration. The MCP authorization spec
    /// expects the response to echo back the fields the client sent
    /// (especially `redirect_uris`) so the client knows the server has
    /// accepted them — without that, clients bail before the
    /// authorization request. We're a single-user public-client server,
    /// so we issue a fresh `client_id` for every registration and
    /// accept whatever redirect URI is supplied (the user still has to
    /// click Approve on `/authorize`, so the redirect URI is a UX hint
    /// rather than a trust boundary).
    @MainActor
    static func register(body: Data) -> Data {
        let parsed = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let name = parsed["client_name"] as? String
        let (clientID, _) = OAuthStore.shared.registerClient(name: name)

        var payload: [String: JSONValue] = [
            "client_id": .string(clientID),
            "client_id_issued_at": .int(Int64(Date().timeIntervalSince1970)),
            "token_endpoint_auth_method": .string("none"),
            "grant_types": .array([.string("authorization_code")]),
            "response_types": .array([.string("code")])
        ]

        // Echo back the client's metadata so it knows we accepted it.
        // RFC 7591 §3.2.1: the response is "essentially the metadata the
        // client sent" plus the issued `client_id`.
        if let redirects = parsed["redirect_uris"] as? [String] {
            payload["redirect_uris"] = .array(redirects.map { .string($0) })
        }
        if let scope = parsed["scope"] as? String, !scope.isEmpty {
            payload["scope"] = .string(scope)
        }
        if let clientName = name, !clientName.isEmpty {
            payload["client_name"] = .string(clientName)
        }
        if let clientURI = parsed["client_uri"] as? String, !clientURI.isEmpty {
            payload["client_uri"] = .string(clientURI)
        }

        let jsonBody = (try? JSONEncoder().encode(JSONValue.object(payload))) ?? Data("{}".utf8)
        return HTTPParser.formatResponse(status: 201, body: jsonBody)
    }

    // MARK: — Authorize page (`GET /authorize`)

    @MainActor
    static func authorizePage(query: [String: String], clientNameLookup: (String) -> String? = { _ in nil }) -> Data {
        // Validate the well-typed pieces. The MCP spec mandates PKCE-S256.
        guard let responseType = query["response_type"], responseType == "code" else {
            return htmlResponse(status: 400, html: OAuthApprovalPage.renderError(message: "Unsupported response_type. Only 'code' is allowed."))
        }
        guard let clientID = query["client_id"], !clientID.isEmpty else {
            return htmlResponse(status: 400, html: OAuthApprovalPage.renderError(message: "Missing client_id."))
        }
        guard let redirectURI = query["redirect_uri"], isAllowedRedirectURI(redirectURI) else {
            return htmlResponse(status: 400, html: OAuthApprovalPage.renderError(message: "Missing or unsupported redirect_uri. Only http/https schemes are accepted."))
        }
        guard let codeChallenge = query["code_challenge"], !codeChallenge.isEmpty else {
            return htmlResponse(status: 400, html: OAuthApprovalPage.renderError(message: "Missing code_challenge (PKCE is required)."))
        }
        let challengeMethod = query["code_challenge_method"] ?? "S256"
        guard challengeMethod.uppercased() == "S256" else {
            return htmlResponse(status: 400, html: OAuthApprovalPage.renderError(message: "Only S256 code_challenge_method is supported."))
        }

        let state = query["state"] ?? ""
        let scope = query["scope"]

        // Record the *reviewed* request server-side and bind it to a fresh
        // CSPRNG nonce. The approve/deny POST carries only this nonce; the
        // handler reissues the code from this stored record, so an attacker
        // can't substitute their own redirect_uri/challenge by racing the
        // approve POST. (Fix #1 — token-theft race / confused deputy.)
        let nonce = OAuthStore.shared.recordPendingAuthorization(
            clientID: clientID,
            redirectURI: redirectURI,
            codeChallenge: codeChallenge,
            codeChallengeMethod: challengeMethod,
            scope: scope,
            state: state
        )

        let ctx = OAuthApprovalPage.Context(
            clientID: clientID,
            clientName: clientNameLookup(clientID),
            redirectURI: redirectURI,
            state: state,
            codeChallenge: codeChallenge,
            codeChallengeMethod: challengeMethod,
            scope: scope,
            windowState: OAuthStore.shared.approvalWindowState,
            nonce: nonce
        )
        return htmlResponse(status: 200, html: OAuthApprovalPage.render(ctx))
    }

    // MARK: — Approve (`POST /authorize/approve`)

    /// Approves the pending request. Two gates, both required:
    ///   1. The approval window must be open *now* (5-minute one-shot).
    ///   2. The `nonce` from the form must resolve to a server-side
    ///      pending record created when the user loaded `GET /authorize`.
    ///
    /// The authorization code is issued from the STORED record's
    /// client_id / redirect_uri / code_challenge — NOT from the approve
    /// POST body — so an attacker can't race the approve POST with their
    /// own redirect_uri/challenge to hijack the single-shot grant.
    /// (Fixes #1.) On success, 302s the browser to
    /// `redirect_uri?code=...&state=...`, then closes the window so one
    /// window grants exactly one code.
    @MainActor
    static func authorizeApprove(form: [String: String]) -> Data {
        guard OAuthStore.shared.approvalWindowIsOpen else {
            return htmlResponse(status: 403, html: OAuthApprovalPage.renderError(
                message: "Approval window not open. Open it in FMail Settings, then start the connector flow again."
            ))
        }
        guard let nonce = form["nonce"], !nonce.isEmpty else {
            return htmlResponse(status: 400, html: OAuthApprovalPage.renderError(
                message: "Approval form was missing the request nonce. Reload the authorization page and try again."
            ))
        }
        // Consume (one-shot) the pending record. nil ⇒ unknown/expired/replayed.
        guard let pending = OAuthStore.shared.consumePendingAuthorization(nonce: nonce) else {
            return htmlResponse(status: 403, html: OAuthApprovalPage.renderError(
                message: "This authorization request is unknown or has expired. Reload the authorization page and try again."
            ))
        }
        // Re-validate the STORED redirect_uri against current policy (it was
        // already validated at /authorize, but policy is cheap to re-assert).
        guard isAllowedRedirectURI(pending.redirectURI) else {
            return htmlResponse(status: 400, html: OAuthApprovalPage.renderError(
                message: "redirect_uri policy not satisfied."
            ))
        }

        // Issue the code from the reviewed record — never from the POST body.
        let code = OAuthStore.shared.issueAuthorizationCode(
            challenge: pending.codeChallenge,
            challengeMethod: pending.codeChallengeMethod,
            redirectURI: pending.redirectURI,
            clientID: pending.clientID
        )
        OAuthStore.shared.closeApprovalWindow()

        guard let location = buildRedirectLocation(
            redirectURI: pending.redirectURI,
            params: [("code", code), ("state", pending.state)]
        ) else {
            // Should be unreachable (redirectURI passed policy above), but
            // never emit a header we couldn't sanitize.
            return htmlResponse(status: 400, html: OAuthApprovalPage.renderError(
                message: "redirect_uri could not be turned into a safe redirect."
            ))
        }
        return HTTPParser.formatResponse(
            status: 302,
            body: Data(),
            extraHeaders: [("Location", location)]
        )
    }

    // MARK: — Deny (`POST /authorize/deny`)

    @MainActor
    static func authorizeDeny(form: [String: String]) -> Data {
        // Per RFC 6749 §4.1.2.1, deny redirects back with `error=access_denied`.
        // Like approve, the redirect target comes from the stored pending
        // record (keyed by nonce), not from the POST body.
        guard let nonce = form["nonce"], !nonce.isEmpty,
              let pending = OAuthStore.shared.consumePendingAuthorization(nonce: nonce) else {
            return htmlResponse(status: 403, html: OAuthApprovalPage.renderError(
                message: "This authorization request is unknown or has expired."
            ))
        }
        guard isAllowedRedirectURI(pending.redirectURI) else {
            return htmlResponse(status: 400, html: OAuthApprovalPage.renderError(
                message: "redirect_uri policy not satisfied."
            ))
        }
        guard let location = buildRedirectLocation(
            redirectURI: pending.redirectURI,
            params: [("error", "access_denied"), ("state", pending.state)]
        ) else {
            return htmlResponse(status: 400, html: OAuthApprovalPage.renderError(
                message: "redirect_uri could not be turned into a safe redirect."
            ))
        }
        return HTTPParser.formatResponse(
            status: 302,
            body: Data(),
            extraHeaders: [("Location", location)]
        )
    }

    // MARK: — Token (`POST /token`)

    @MainActor
    static func token(form: [String: String]) -> Data {
        guard form["grant_type"] == "authorization_code" else {
            return errorResponse(status: 400, code: "unsupported_grant_type", description: "Only authorization_code is supported.")
        }
        guard let code = form["code"], !code.isEmpty else {
            return errorResponse(status: 400, code: "invalid_request", description: "Missing code.")
        }
        guard let verifier = form["code_verifier"], !verifier.isEmpty else {
            return errorResponse(status: 400, code: "invalid_request", description: "Missing code_verifier (PKCE is required).")
        }
        guard let redirectURI = form["redirect_uri"] else {
            return errorResponse(status: 400, code: "invalid_request", description: "Missing redirect_uri.")
        }
        guard let clientID = form["client_id"], !clientID.isEmpty else {
            return errorResponse(status: 400, code: "invalid_request", description: "Missing client_id.")
        }

        // `exchangeCode` byte-compares `redirectURI` against the value bound
        // to the code at issue time. That bound value originates from the
        // server-side pending record (the reviewed redirect_uri), not from
        // any client-supplied field on the approve POST — so this enforces
        // an exact round-trip back to what the user approved. (Fixes #1/#2.)
        let result = OAuthStore.shared.exchangeCode(
            code, verifier: verifier, redirectURI: redirectURI, clientID: clientID
        )
        switch result {
        case .success(let accessToken):
            let payload: [String: JSONValue] = [
                "access_token": .string(accessToken),
                "token_type": .string("Bearer"),
                // Matches the server-side soft expiry in
                // `OAuthStore.sessionTTL` — sessions older than this are
                // dropped lazily by `tokenIsValid`. Clients re-auth via
                // the dynamic-registration flow after expiry.
                "expires_in": .int(Int64(OAuthStore.sessionTTL))
            ]
            let jsonBody = (try? JSONEncoder().encode(JSONValue.object(payload))) ?? Data("{}".utf8)
            // OAuth requires Cache-Control: no-store on the token response.
            return HTTPParser.formatResponse(
                status: 200,
                body: jsonBody,
                extraHeaders: [("Cache-Control", "no-store"), ("Pragma", "no-cache")]
            )
        case .failure(let err):
            return errorResponse(status: 400, code: err.code, description: err.description)
        }
    }

    // MARK: — Helpers

    /// Wrap an HTML string in an HTTP response with `Content-Type: text/html`.
    private static func htmlResponse(status: Int, html: String) -> Data {
        HTTPParser.formatResponse(
            status: status,
            body: Data(html.utf8),
            contentType: "text/html; charset=utf-8"
        )
    }

    private static func errorResponse(status: Int, code: String, description: String) -> Data {
        let payload: [String: JSONValue] = [
            "error": .string(code),
            "error_description": .string(description)
        ]
        let body = (try? JSONEncoder().encode(JSONValue.object(payload))) ?? Data("{}".utf8)
        return HTTPParser.formatResponse(status: status, body: body)
    }

    private static func percentEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }

    /// Build the 302 `Location` value for a redirect back to the client,
    /// appending percent-encoded query params. Returns nil if the result
    /// would be unsafe to emit as an HTTP header.
    ///
    /// Defense-in-depth (Fix #3): the redirect_uri has already passed
    /// `isAllowedRedirectURI` (which rejects raw CR/LF), but header
    /// injection is severe enough to re-check here rather than trust
    /// `URL(string:)` leniency. If the base or any param contains CR/LF
    /// we refuse outright instead of emitting a splittable header.
    private static func buildRedirectLocation(
        redirectURI: String,
        params: [(String, String)]
    ) -> String? {
        guard !containsCRLF(redirectURI) else { return nil }
        let separator = redirectURI.contains("?") ? "&" : "?"
        var location = redirectURI + separator
        location += params
            .map { "\($0.0)=\(percentEncode($0.1))" }
            .joined(separator: "&")
        // percentEncode already removes CR/LF from param values, but assert
        // the final string is header-safe before we hand it back.
        guard !containsCRLF(location) else { return nil }
        return location
    }

    /// True if the string contains a raw CR or LF (header-injection chars).
    private static func containsCRLF(_ s: String) -> Bool {
        s.contains("\r") || s.contains("\n")
    }

    /// Redirect-URI policy for `redirect_uri` (Fix #2).
    ///
    /// FMail is a single-user app pairing a small, known set of OAuth
    /// clients. Two legitimate shapes exist:
    ///   • Hosted connectors (e.g. claude.ai) → **https** callback URLs.
    ///   • Native/CLI clients → **loopback** `http://127.0.0.1[:port]/…`
    ///     or `http://localhost[:port]/…` (RFC 8252 §7.3).
    ///
    /// Policy, tightest-reasonable without a connector allowlist UI:
    ///   1. Scheme must be parseable and either `https`, or `http` ONLY
    ///      when the host is the loopback literal `127.0.0.1` / `localhost`
    ///      (`::1` too). Any other plain-`http` is rejected — that closes
    ///      cleartext exfiltration of the code.
    ///   2. No `userinfo` (`user:pass@host`) — a common phishing/spoofing
    ///      vector and never needed for an OAuth callback.
    ///   3. No URL `fragment` — codes go in the query, and a fragment can
    ///      smuggle data past server-side checks.
    ///   4. No raw CR/LF anywhere — header-injection defense in depth.
    ///   5. A host must be present (rules out scheme-only / opaque URLs and
    ///      things like `javascript:` / `data:` that have no host).
    ///
    /// Rationale for not maintaining an explicit host allowlist: hosted
    /// connector hostnames change and the user still has to click Approve
    /// on a page that shows the exact redirect_uri, so the scheme/host
    /// policy plus the visible-approval gate is sufficient here.
    static func isAllowedRedirectURI(_ s: String) -> Bool {
        // Reject control chars up front; URLComponents would otherwise
        // tolerate some and we never want them in a redirect target.
        guard !containsCRLF(s) else { return false }
        guard let comps = URLComponents(string: s),
              let scheme = comps.scheme?.lowercased() else {
            return false
        }
        // No userinfo, no fragment.
        guard comps.user == nil, comps.password == nil, comps.fragment == nil else {
            return false
        }
        // Must have a real host.
        guard let host = comps.host, !host.isEmpty else { return false }
        let lowerHost = host.lowercased()

        switch scheme {
        case "https":
            return true
        case "http":
            // Loopback only — native OAuth clients (RFC 8252). Accept the
            // IPv6 literal with or without brackets, depending on how the
            // platform's URLComponents surfaces `host`.
            return lowerHost == "127.0.0.1"
                || lowerHost == "localhost"
                || lowerHost == "::1"
                || lowerHost == "[::1]"
        default:
            return false
        }
    }
}

// MARK: — Query / form-encoded body parsing

enum FormParser {
    /// Parse `application/x-www-form-urlencoded` body content into a
    /// dictionary. Per HTML5 — `+` decodes to space, `%XX` is percent.
    static func parse(_ body: Data) -> [String: String] {
        guard let str = String(data: body, encoding: .utf8) else { return [:] }
        return parseURLEncodedString(str)
    }

    /// Parse a `?a=1&b=2` query string into a dictionary. Strips any
    /// leading `?` if present.
    static func parseQuery(_ raw: String) -> [String: String] {
        var s = raw
        if s.hasPrefix("?") { s.removeFirst() }
        return parseURLEncodedString(s)
    }

    private static func parseURLEncodedString(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in s.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard !parts.isEmpty else { continue }
            let key = decode(String(parts[0]))
            let value = parts.count > 1 ? decode(String(parts[1])) : ""
            if !key.isEmpty { out[key] = value }
        }
        return out
    }

    private static func decode(_ s: String) -> String {
        let withSpaces = s.replacingOccurrences(of: "+", with: " ")
        return withSpaces.removingPercentEncoding ?? withSpaces
    }
}
