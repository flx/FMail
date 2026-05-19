import Foundation
import CryptoKit

/// PKCE (RFC 7636) verification — verifies that a `code_verifier` submitted
/// at the token endpoint matches the `code_challenge` recorded at the
/// authorization endpoint. We only support `S256` (the spec mandates it
/// for new servers; `plain` is forbidden by MCP spec).
///
/// Math: challenge == base64url(SHA256(verifier)), no padding.
enum OAuthPKCE {
    /// Verifier must be 43–128 chars per RFC 7636 §4.1.
    static let minVerifierLength = 43
    static let maxVerifierLength = 128

    /// Returns true iff `verifier` is a valid PKCE code_verifier whose
    /// S256-derived challenge equals `challenge`.
    static func verify(verifier: String, challenge: String, method: String) -> Bool {
        guard method.uppercased() == "S256" else { return false }
        guard verifier.count >= minVerifierLength, verifier.count <= maxVerifierLength else {
            return false
        }
        let data = Data(verifier.utf8)
        let digest = SHA256.hash(data: data)
        let computed = base64URLEncode(Data(digest))
        return constantTimeEqual(computed, challenge)
    }

    /// `+` → `-`, `/` → `_`, drop `=` padding. Standard PKCE encoding.
    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Constant-time string compare so a leaked timing oracle can't help
    /// recover the challenge bit-by-bit.
    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        if aBytes.count != bBytes.count { return false }
        var diff: UInt8 = 0
        for i in 0..<aBytes.count { diff |= aBytes[i] ^ bBytes[i] }
        return diff == 0
    }
}
