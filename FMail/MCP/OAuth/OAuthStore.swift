import Foundation
import Observation

/// State for the MCP OAuth flow:
///
///   1. Pending **authorization codes** — short-lived (10 min), one-time use.
///      Holds the PKCE challenge + redirect_uri + client_id that were
///      supplied at `/authorize` so `/token` can verify the round-trip.
///   2. Issued **session tokens** — long-lived bearer tokens we hand to
///      clients via `/token`. Persisted to `UserDefaults` so a Cowork
///      connector keeps working across FMail restarts. Validated alongside
///      the static `MCPSettings.authToken` on every `POST /mcp`.
///   3. The **approval window** — a short, opt-in time period during
///      which `/authorize` will render the Approve/Deny page. Outside
///      the window, the page tells the user to open it in Settings. This
///      gates against drive-by approvals via the public URL.
///
/// All state lives on the main actor; `MCPServer` handlers hop in to read/
/// write. Pending codes are scrubbed lazily on access; explicit GC isn't
/// needed at our scale (one user, a handful of OAuth grants ever).
///
/// `@Observable` so SwiftUI (the Settings "Paired sessions" row) re-renders
/// when `sessions` changes — a new pairing or a revoke updates the count live.
@MainActor
@Observable
final class OAuthStore {
    static let shared = OAuthStore()

    // MARK: — Pending authorization codes

    struct PendingCode {
        let challenge: String
        let challengeMethod: String
        let redirectURI: String
        let clientID: String
        let createdAt: Date
        var isExpired: Bool { Date().timeIntervalSince(createdAt) > OAuthStore.codeTTL }
    }

    nonisolated static let codeTTL: TimeInterval = 600  // 10 minutes per RFC 6749 §4.1.2

    /// Issued session lifetime — after this many seconds since
    /// `issuedAt`, `tokenIsValid` returns false and the client is
    /// expected to re-authenticate. Mirrors the `expires_in` value
    /// returned to clients at `/token`.
    nonisolated static let sessionTTL: TimeInterval = 30 * 24 * 60 * 60  // 30 days

    private var pendingCodes: [String: PendingCode] = [:]

    // MARK: — Pending authorization requests (nonce-bound approval)

    /// A *reviewed* authorization request. Created when `GET /authorize`
    /// renders the approval page, keyed by a server-generated CSPRNG
    /// nonce embedded as a hidden field in the approve/deny forms.
    ///
    /// The point: the values the user actually saw on the page (client_id,
    /// redirect_uri, PKCE challenge, …) are captured here at render time.
    /// `POST /authorize/approve` then issues the code from THIS record
    /// rather than from the approve POST body, so an attacker can't swap
    /// in their own redirect_uri/challenge to consume the approval window.
    struct PendingAuthorization {
        let clientID: String
        let redirectURI: String
        let codeChallenge: String
        let codeChallengeMethod: String
        let scope: String?
        let state: String
        let createdAt: Date
        var isExpired: Bool { Date().timeIntervalSince(createdAt) > OAuthStore.pendingAuthorizationTTL }
    }

    /// How long a rendered-but-unapproved request stays pending. Generous
    /// enough that the user can flip to FMail, open the approval window,
    /// and come back to click Approve, but short so a stale nonce can't be
    /// replayed later. Independent of `codeTTL`.
    nonisolated static let pendingAuthorizationTTL: TimeInterval = 600  // 10 minutes

    private var pendingAuthorizations: [String: PendingAuthorization] = [:]

    /// Record a reviewed authorization request and return its nonce. The
    /// nonce is a fresh CSPRNG token (same generator as codes/sessions);
    /// it's embedded as a hidden form field so the subsequent approve/deny
    /// POST can be bound back to exactly this record.
    func recordPendingAuthorization(
        clientID: String,
        redirectURI: String,
        codeChallenge: String,
        codeChallengeMethod: String,
        scope: String?,
        state: String
    ) -> String {
        gcExpiredPendingAuthorizations()
        let nonce = randomToken(byteCount: 32)
        pendingAuthorizations[nonce] = PendingAuthorization(
            clientID: clientID,
            redirectURI: redirectURI,
            codeChallenge: codeChallenge,
            codeChallengeMethod: codeChallengeMethod,
            scope: scope,
            state: state,
            createdAt: Date()
        )
        return nonce
    }

    /// Look up and CONSUME (remove) the pending request for `nonce`.
    /// One-shot: a nonce is valid for exactly one approve-or-deny. Returns
    /// nil if the nonce is unknown or expired (an expired record is also
    /// removed). Callers must treat nil as "reject".
    func consumePendingAuthorization(nonce: String) -> PendingAuthorization? {
        gcExpiredPendingAuthorizations()
        guard let record = pendingAuthorizations.removeValue(forKey: nonce) else {
            return nil
        }
        if record.isExpired { return nil }
        return record
    }

    /// Drop pending authorizations that have aged out, bounding the dict
    /// against an attacker repeatedly hitting `GET /authorize`. Called
    /// opportunistically on record/consume.
    private func gcExpiredPendingAuthorizations() {
        let cutoff = Date().addingTimeInterval(-Self.pendingAuthorizationTTL)
        pendingAuthorizations = pendingAuthorizations.filter { $0.value.createdAt > cutoff }
    }

    /// Generate a fresh authorization code and store the round-trip
    /// context (challenge + redirect_uri + client_id) so the token
    /// endpoint can verify the exchange.
    func issueAuthorizationCode(
        challenge: String,
        challengeMethod: String,
        redirectURI: String,
        clientID: String
    ) -> String {
        gcExpiredPendingCodes()
        let code = randomToken(byteCount: 32)
        pendingCodes[code] = PendingCode(
            challenge: challenge,
            challengeMethod: challengeMethod,
            redirectURI: redirectURI,
            clientID: clientID,
            createdAt: Date()
        )
        return code
    }

    /// Drop codes that have aged out so an attacker poking `/authorize/approve`
    /// can't grow `pendingCodes` without bound. Called opportunistically on
    /// every issue/exchange — at our scale (low single-digit OAuth grants
    /// ever) explicit periodic sweep isn't worth the complexity.
    private func gcExpiredPendingCodes() {
        let cutoff = Date().addingTimeInterval(-Self.codeTTL)
        pendingCodes = pendingCodes.filter { $0.value.createdAt > cutoff }
    }

    /// Consume an authorization code (one-time use). Verifies PKCE +
    /// redirect_uri + client_id match what was stored at `/authorize`.
    /// On success returns a fresh session token; on failure returns the
    /// reason as a string suitable for OAuth `error_description`.
    func exchangeCode(
        _ code: String,
        verifier: String,
        redirectURI: String,
        clientID: String
    ) -> Result<String, OAuthExchangeError> {
        gcExpiredPendingCodes()
        guard let pending = pendingCodes[code] else {
            return .failure(.invalidGrant("unknown or already-used authorization code"))
        }
        // Remove eagerly — even on PKCE failure, the code is now spent.
        pendingCodes.removeValue(forKey: code)

        if pending.isExpired {
            return .failure(.invalidGrant("authorization code expired"))
        }
        guard pending.redirectURI == redirectURI else {
            return .failure(.invalidGrant("redirect_uri mismatch"))
        }
        guard pending.clientID == clientID else {
            return .failure(.invalidClient("client_id mismatch"))
        }
        guard OAuthPKCE.verify(
            verifier: verifier,
            challenge: pending.challenge,
            method: pending.challengeMethod
        ) else {
            return .failure(.invalidGrant("PKCE verifier mismatch"))
        }

        let sessionToken = randomToken(byteCount: 32)
        sessions[sessionToken] = Session(
            clientID: clientID,
            issuedAt: Date(),
            label: "OAuth connector"
        )
        persistSessions()
        return .success(sessionToken)
    }

    // MARK: — Issued session tokens (long-lived, persisted)

    struct Session: Codable, Equatable {
        let clientID: String
        let issuedAt: Date
        let label: String  // human-readable for the Settings UI
    }

    private(set) var sessions: [String: Session] = [:]

    /// True iff the token is in `sessions` AND was issued within the
    /// last `sessionTTL`. Expired sessions are dropped lazily on this
    /// call — no periodic sweep needed at our scale.
    func tokenIsValid(_ token: String) -> Bool {
        guard let session = sessions[token] else { return false }
        if Date().timeIntervalSince(session.issuedAt) > Self.sessionTTL {
            sessions.removeValue(forKey: token)
            persistSessions()
            return false
        }
        return true
    }

    func revokeAllSessions() {
        sessions.removeAll()
        persistSessions()
    }

    func revokeSession(token: String) {
        sessions.removeValue(forKey: token)
        persistSessions()
    }

    // MARK: — Dynamic client registration

    /// Issue a stable `client_id` for a newly-registered MCP client. We
    /// don't differentiate clients — the single-user model means every
    /// grant flows through one approval anyway. The client secret is
    /// empty (we're a "public client" using PKCE). The supplied `name`
    /// is currently ignored; it's accepted because RFC 7591 callers
    /// supply it and we may want to surface it in the Settings UI.
    func registerClient(name: String?) -> (clientID: String, clientSecret: String) {
        _ = name
        let id = randomToken(byteCount: 24)
        return (id, "")
    }

    // MARK: — Approval window

    private var approvalWindowExpiresAt: Date?

    /// Caller-visible state used by Settings UI to render the status row.
    enum ApprovalWindowState: Equatable {
        case closed
        case open(secondsRemaining: Int)
    }

    var approvalWindowState: ApprovalWindowState {
        guard let until = approvalWindowExpiresAt, until > Date() else {
            return .closed
        }
        return .open(secondsRemaining: Int(until.timeIntervalSinceNow))
    }

    /// Open the approval window for `duration` seconds. Subsequent calls
    /// extend the window. Settings UI calls this when the user clicks
    /// "Open approval window".
    func openApprovalWindow(duration: TimeInterval = 300) {
        approvalWindowExpiresAt = Date().addingTimeInterval(duration)
    }

    /// Close the window — called after a successful approval, or by the
    /// user via Settings.
    func closeApprovalWindow() {
        approvalWindowExpiresAt = nil
    }

    /// True iff the window is open right now. The approval endpoint
    /// calls this *before* issuing a code; we close the window
    /// immediately after, so each window grants exactly one code.
    var approvalWindowIsOpen: Bool {
        if case .open = approvalWindowState { return true }
        return false
    }

    // MARK: — Init / persistence

    init() {
        loadSessions()
    }

    private static let sessionsKey = "mcp.oauth.sessions.v1"

    /// Load persisted sessions resiliently. We decode entry-by-entry
    /// (`[String: JSONValue]` first, then each value into `Session`) so a
    /// single malformed/forward-incompatible entry is skipped rather than
    /// silently un-pairing EVERY connector. Concretely: if a future build
    /// adds a non-optional `Session` field, old-build entries written
    /// without it won't wipe the whole store — only entries that genuinely
    /// fail to decode are dropped, and the failure is logged.
    ///
    /// If a future field must survive a round-trip through an older build,
    /// add it as `Optional` (or with a `decodeIfPresent` default) so
    /// per-entry decode keeps succeeding here.
    private func loadSessions() {
        guard let data = UserDefaults.standard.data(forKey: Self.sessionsKey) else { return }

        // First try the whole-blob decode (the common, all-current path).
        if let decoded = try? JSONDecoder().decode([String: Session].self, from: data) {
            sessions = decoded
            return
        }

        // Fall back to per-entry decoding so one bad entry doesn't drop all.
        guard let raw = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
            Log.mcp.error("OAuthStore.loadSessions: sessions blob is not a JSON object; keeping current sessions")
            return
        }
        var recovered: [String: Session] = [:]
        var skipped = 0
        for (token, value) in raw {
            guard let entryData = try? JSONEncoder().encode(value),
                  let session = try? JSONDecoder().decode(Session.self, from: entryData) else {
                skipped += 1
                continue
            }
            recovered[token] = session
        }
        if skipped > 0 {
            Log.mcp.error("OAuthStore.loadSessions: skipped \(skipped, privacy: .public) undecodable session entry(ies); recovered \(recovered.count, privacy: .public)")
        }
        sessions = recovered
    }

    private func persistSessions() {
        do {
            let data = try JSONEncoder().encode(sessions)
            UserDefaults.standard.set(data, forKey: Self.sessionsKey)
        } catch {
            // Don't silently drop: a failed persist means a pairing/revoke
            // won't survive restart, which is a real (if rare) bug.
            Log.mcp.error("OAuthStore.persistSessions: failed to encode sessions: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: — Helpers

    /// Random base64url token (~43 chars for 32 bytes, no padding).
    private func randomToken(byteCount: Int) -> String {
        OAuthPKCE.randomToken(byteCount: byteCount)
    }
}

/// OAuth 2.0 errors per RFC 6749 §5.2. We only surface the ones the
/// token endpoint can produce.
enum OAuthExchangeError: Error {
    case invalidGrant(String)
    case invalidClient(String)
    case invalidRequest(String)

    var code: String {
        switch self {
        case .invalidGrant: return "invalid_grant"
        case .invalidClient: return "invalid_client"
        case .invalidRequest: return "invalid_request"
        }
    }

    var description: String {
        switch self {
        case .invalidGrant(let m), .invalidClient(let m), .invalidRequest(let m): return m
        }
    }
}
