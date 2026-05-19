import XCTest
@testable import FMail

/// Tests `CloudflaredLogParser` against captured `cloudflared` output. The
/// real binary's log format has shifted between versions; the parser
/// accepts the union of seen phrasings.
final class CloudflaredLogParserTests: XCTestCase {

    // MARK: — Named-tunnel readiness

    func testDetectsRegisteredTunnelConnection() {
        let sample = """
            2026-05-19T14:00:00Z INF Starting tunnel tunnelID=e7a78b42-a0eb-4eca-af48-c0333cbb4987
            2026-05-19T14:00:00Z INF Version 2024.5.0
            2026-05-19T14:00:01Z INF Registered tunnel connection connIndex=0 connection=abcd ip=198.41.200.13 location=lhr01 protocol=quic
            """
        XCTAssertTrue(CloudflaredLogParser.didRegisterConnection(in: sample))
    }

    /// Older cloudflared emits the shorter "Registered connection ..."
    /// without the "tunnel" qualifier. Both should be recognised.
    func testDetectsAlternatePhrasing() {
        XCTAssertTrue(CloudflaredLogParser.didRegisterConnection(in: "INF Registered connection connIndex=0 ip=198.41.200.13"))
    }

    func testIgnoresPreReadyLines() {
        let pre = """
            2026-05-19T14:00:00Z INF Requesting new quic connection
            2026-05-19T14:00:00Z INF Initiating tunnel connection
            """
        XCTAssertFalse(CloudflaredLogParser.didRegisterConnection(in: pre))
    }

    // MARK: — Early failure

    func testDetectsMissingCredentialsFailure() {
        let err = "tunnel credentials file /Users/felix/.cloudflared/xxx.json doesn't exist"
        XCTAssertTrue(CloudflaredLogParser.didFailEarly(in: err))
    }

    func testDetectsNotLoggedInFailure() {
        XCTAssertTrue(CloudflaredLogParser.didFailEarly(in: "Error: You don't appear to be logged in. Run cloudflared tunnel login to authenticate."))
    }

    func testDoesNotFlagBenignLines() {
        XCTAssertFalse(CloudflaredLogParser.didFailEarly(in: "INF Starting tunnel tunnelID=abcd"))
        XCTAssertFalse(CloudflaredLogParser.didFailEarly(in: "INF Registered tunnel connection"))
    }

    // MARK: — Quick-tunnel URL extraction (retained for completeness)

    func testExtractsTryCloudflareURL() {
        let block = """
            +--------------------------------------------------------------------------------------------+
            |  Your quick Tunnel has been created! Visit it at (it may take some time to be reachable):  |
            |  https://random-words-12345.trycloudflare.com                                              |
            +--------------------------------------------------------------------------------------------+
            """
        let url = CloudflaredLogParser.extractQuickTunnelURL(in: block)
        XCTAssertEqual(url?.absoluteString, "https://random-words-12345.trycloudflare.com")
    }

    func testReturnsNilForNamedTunnelLog() {
        // Named tunnels never print a trycloudflare URL — the operator
        // already knows the public hostname.
        XCTAssertNil(CloudflaredLogParser.extractQuickTunnelURL(in: "INF Registered tunnel connection"))
    }
}
