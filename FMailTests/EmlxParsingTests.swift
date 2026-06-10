import XCTest
@testable import FMail

/// Direct coverage for the attacker-controlled `.emlx` parsing surface:
/// `MIMEParser`, `EncodedWord`, `HeaderParser`, and `EmlxParser`. These types
/// process bytes that arrive over the network (raw RFC 822 from any sender),
/// so malformed / hostile input must be handled without trapping.
///
/// Until this file existed these four types had no *direct* tests — only the
/// end-to-end `BodyLoaderTests` exercised `MIMEParser`, and nothing exercised
/// `EncodedWord` / `HeaderParser` / `EmlxParser` in isolation.
final class EmlxParsingTests: XCTestCase {

    // MARK: — Helpers

    /// Parse a raw RFC 822 message (header block + blank line + body) the way
    /// `EmlxParser` does internally: split into headers + body, then run the
    /// MIME parser. Mirrors the production path without needing a framed file.
    private func parseMessage(_ rfc822: String) -> MIMEContent {
        let normalized = rfc822.replacingOccurrences(of: "\r\n", with: "\n")
        guard let blank = normalized.range(of: "\n\n") else {
            let headers = HeaderParser.parse(normalized)
            return MIMEParser.parse(headers: headers, body: Data())
        }
        let headerStr = String(normalized[..<blank.lowerBound])
        let bodyStr = String(normalized[blank.upperBound...])
        let headers = HeaderParser.parse(headerStr)
        return MIMEParser.parse(headers: headers, body: Data(bodyStr.utf8))
    }

    // MARK: — MIMEParser: multipart/alternative

    func testMultipartAlternativeExposesBothTextAndHTMLParts() {
        let rfc = """
        From: a@example.com
        Content-Type: multipart/alternative; boundary="alt"

        --alt
        Content-Type: text/plain; charset=utf-8

        Plain version here.
        --alt
        Content-Type: text/html; charset=utf-8

        <p>HTML version here.</p>
        --alt--

        """
        let content = parseMessage(rfc)
        XCTAssertEqual(content.plainText, "Plain version here.")
        XCTAssertEqual(content.html, "<p>HTML version here.</p>")
        XCTAssertTrue(content.attachments.isEmpty, "alternative parts are body, not attachments")
    }

    // MARK: — MIMEParser: multipart/mixed with an attachment

    func testMultipartMixedExposesAttachmentPart() {
        let rfc = """
        From: a@example.com
        Content-Type: multipart/mixed; boundary="mix"

        --mix
        Content-Type: text/plain; charset=utf-8

        See attached.
        --mix
        Content-Disposition: attachment; filename="report.pdf"
        Content-Type: application/pdf
        Content-Transfer-Encoding: base64

        \(Data("PDFDATA".utf8).base64EncodedString())
        --mix--

        """
        let content = parseMessage(rfc)
        XCTAssertEqual(content.plainText, "See attached.")
        XCTAssertEqual(content.attachments.count, 1)
        let att = content.attachments[0]
        XCTAssertEqual(att.name, "report.pdf")
        XCTAssertEqual(att.contentType, "application/pdf")
        XCTAssertEqual(att.data, Data("PDFDATA".utf8),
                       "base64 transfer-encoding must be decoded for the attachment bytes")
    }

    /// RFC 2231 continuation / encoded parameter — the parser reassembles
    /// `filename*0`, `filename*1`, ... and percent-decodes `*`-tagged segments.
    func testRFC2231ContinuationFilenameIsReassembled() {
        let rfc = """
        From: a@example.com
        Content-Type: multipart/mixed; boundary="mix"

        --mix
        Content-Type: text/plain

        Body.
        --mix
        Content-Type: application/octet-stream
        Content-Disposition: attachment;
        \tfilename*0=really_long_;
        \tfilename*1=name_part_two.bin

        \(Data("BYTES".utf8).base64EncodedString())
        --mix--

        """
        let content = parseMessage(rfc)
        XCTAssertEqual(content.attachments.count, 1)
        XCTAssertEqual(content.attachments[0].name, "really_long_name_part_two.bin",
                       "RFC 2231 continuation segments must be concatenated in order")
    }

    /// RFC 2231 *encoded* form: `filename*0*=utf-8''...` carries a
    /// charset'lang' prefix on segment 0 and percent-encoded bytes.
    func testRFC2231EncodedFilenameIsPercentDecoded() {
        // "naïve.txt" — the ï (U+00EF) is UTF-8 0xC3 0xAF.
        let rfc = """
        From: a@example.com
        Content-Type: multipart/mixed; boundary="mix"

        --mix
        Content-Type: text/plain

        Body.
        --mix
        Content-Type: application/octet-stream
        Content-Disposition: attachment; filename*0*=utf-8''na%C3%AF; filename*1*=ve.txt

        \(Data("BYTES".utf8).base64EncodedString())
        --mix--

        """
        let content = parseMessage(rfc)
        XCTAssertEqual(content.attachments.count, 1)
        XCTAssertEqual(content.attachments[0].name, "naïve.txt",
                       "charset'lang' prefix stripped and percent-encoding decoded")
    }

    // MARK: — MIMEParser: pathological recursion depth

    /// CRITICAL hardening case. A hostile sender can nest multipart bodies
    /// arbitrarily deep; naive recursion would stack-overflow and crash the
    /// app. Build ~200 levels of nested multipart/mixed and assert the parser
    /// returns *some* value within a bounded time without trapping.
    ///
    /// The parser is being given a depth cap (~32). This test does NOT assert
    /// a specific output — only that the call returns a `MIMEContent` and does
    /// not stack-overflow. If the depth cap is in place the deep inner parts
    /// are simply ignored below the cap; either way we must not crash.
    func testDeeplyNestedMultipartDoesNotStackOverflow() {
        // Build N nested multipart/mixed parts. Each level introduces a
        // distinct boundary so the splitter actually descends.
        let depth = 200
        var body = "innermost text body\n"
        for level in (0..<depth).reversed() {
            let boundary = "b\(level)"
            body = """
            --\(boundary)
            Content-Type: \(level == depth - 1 ? "text/plain" : "multipart/mixed; boundary=\"b\(level + 1)\"")

            \(body)
            --\(boundary)--

            """
        }
        let rfc = """
        From: attacker@example.com
        Content-Type: multipart/mixed; boundary="b0"

        \(body)
        """

        // Run on a worker thread with a generous timeout; if the parser traps
        // (stack overflow) the process dies and the test fails outright, and if
        // it hangs the expectation times out. A bounded return is the pass.
        let done = expectation(description: "deep multipart parse returns")
        DispatchQueue.global().async {
            _ = self.parseMessage(rfc)
            done.fulfill()
        }
        wait(for: [done], timeout: 10.0)
        // Reaching here means parse() returned a value and didn't trap/hang.
    }

    // MARK: — EncodedWord (RFC 2047)

    func testEncodedWordBase64UTF8() {
        // =?UTF-8?B?<base64 of "Héllo">?=
        let payload = Data("Héllo".utf8).base64EncodedString()
        let decoded = EncodedWord.decode("=?UTF-8?B?\(payload)?=")
        XCTAssertEqual(decoded, "Héllo")
    }

    func testEncodedWordQuotedPrintableUTF8() {
        // "=?UTF-8?Q?...?=" — Q-encoding: '_' = space, '=XX' = hex byte.
        // "a=b c" encodes 'b' literally, space as '_'.
        let decoded = EncodedWord.decode("=?UTF-8?Q?Caf=C3=A9_time?=")
        XCTAssertEqual(decoded, "Café time")
    }

    func testAdjacentEncodedWordsCollapseFoldingWhitespace() {
        // RFC 2047 §6.2: whitespace *between* adjacent encoded-words is removed.
        let one = Data("Hello ".utf8).base64EncodedString()
        let two = Data("World".utf8).base64EncodedString()
        // A space + newline + space between the two encoded words is folding WS.
        let input = "=?UTF-8?B?\(one)?= \n =?UTF-8?B?\(two)?="
        XCTAssertEqual(EncodedWord.decode(input), "Hello World",
                       "the encoded space is preserved; the inter-word folding WS is dropped")
    }

    func testMalformedEncodedWordLeftAsIs() {
        // Missing the closing ?= — must pass through unchanged, not crash.
        let input = "=?UTF-8?B?not-really-closed"
        XCTAssertEqual(EncodedWord.decode(input), input)
    }

    func testPlainTextWithoutEncodedWordPassesThrough() {
        XCTAssertEqual(EncodedWord.decode("just a normal subject"), "just a normal subject")
    }

    // MARK: — HeaderParser

    func testFoldedHeaderLineIsReassembled() {
        let block = "Subject: This is a very\n long folded subject\nFrom: a@example.com"
        let headers = HeaderParser.parse(block)
        XCTAssertEqual(headers["subject"], "This is a very long folded subject",
                       "continuation line (leading whitespace) folds into the prior header")
        XCTAssertEqual(headers["from"], "a@example.com")
    }

    func testHeaderLookupIsCaseInsensitive() {
        let headers = HeaderParser.parse("Content-Type: text/plain\nX-Custom: v")
        XCTAssertEqual(headers["content-type"], "text/plain")
        XCTAssertEqual(headers["CONTENT-TYPE"], "text/plain")
        XCTAssertEqual(headers["Content-Type"], "text/plain")
    }

    func testMultipleRecipientsAndDuplicateHeaders() {
        let block = """
        To: alice@example.com, bob@example.com
        Received: from a
        Received: from b
        """
        let headers = HeaderParser.parse(block)
        XCTAssertEqual(headers["to"], "alice@example.com, bob@example.com")
        // `all(_:)` returns every occurrence in order; subscript is last-wins.
        XCTAssertEqual(headers.all("received"), ["from a", "from b"])
        XCTAssertEqual(headers["received"], "from b", "subscript is last-wins for duplicates")
    }

    // MARK: — EmlxParser end-to-end (length-prefix framing)

    /// Synthesize a minimal `.emlx` from the on-disk format observed in
    /// `BodyLoaderTests` (decimal byte length + LF + RFC822 [+ optional plist
    /// trailer]) and assert the body round-trips through `EmlxParser.parse`.
    func testEmlxParserExtractsBodyFromFramedFile() throws {
        let rfc822 = """
        From: sender@example.com
        To: me@example.com
        Subject: Hello
        Content-Type: text/plain; charset=utf-8

        This is the body text.
        """
        let rfcData = Data(rfc822.utf8)
        let framed = Data("\(rfcData.count)\n".utf8) + rfcData

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fmail-emlx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("1.emlx")
        try framed.write(to: url)

        let parsed = try EmlxParser.parse(url: url)
        XCTAssertEqual(parsed.headers["subject"], "Hello")
        XCTAssertEqual(parsed.headers["from"], "sender@example.com")
        XCTAssertEqual(parsed.mime.plainText?.trimmingCharacters(in: .whitespacesAndNewlines),
                       "This is the body text.")
    }

    /// Trailer plist with a `flags` NSNumber: bit 0 = read, bit 6 = flagged.
    /// Confirms the framing peels the trailer off after the declared length
    /// and the flag bits decode.
    func testEmlxParserDecodesTrailerFlags() throws {
        let rfc822 = "From: s@example.com\nSubject: t\n\nBody.\n"
        let rfcData = Data(rfc822.utf8)

        // flags: read (bit 0) + flagged (bit 6) = 1 | 64 = 65.
        let trailerPlist: [String: Any] = ["flags": NSNumber(value: 65)]
        let trailerData = try PropertyListSerialization.data(
            fromPropertyList: trailerPlist, format: .binary, options: 0
        )
        let framed = Data("\(rfcData.count)\n".utf8) + rfcData + trailerData

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fmail-emlx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("2.emlx")
        try framed.write(to: url)

        let parsed = try EmlxParser.parse(url: url)
        let flags = try XCTUnwrap(parsed.flagBits, "trailer plist should decode to flag bits")
        XCTAssertTrue(flags.isRead, "bit 0 set → read")
        XCTAssertTrue(flags.isFlagged, "bit 6 set → flagged")
        XCTAssertFalse(flags.isReplied, "bit 4 clear → not replied")
        XCTAssertEqual(flags.raw, 65)
    }

    /// A file too small to contain a length prefix must throw, not trap.
    func testEmlxParserThrowsOnTooSmallFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fmail-emlx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("3.emlx")
        try Data("12".utf8).write(to: url)  // < 8 bytes

        XCTAssertThrowsError(try EmlxParser.parse(url: url)) { error in
            guard case EmlxParserError.fileTooSmall = error else {
                return XCTFail("expected .fileTooSmall, got \(error)")
            }
        }
    }
}
