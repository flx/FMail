import XCTest
@testable import FMail

/// Exact-output coverage for `HTMLStripper.toPlainText` — the no-WebKit HTML →
/// text converter used for body indexing and first-pass reader display. Covers
/// script/style/head removal, entity decoding (named + numeric decimal + hex),
/// block-level spacing, and bare tag stripping.
final class HTMLStripperTests: XCTestCase {

    private func strip(_ html: String) -> String { HTMLStripper.toPlainText(html) }

    // MARK: — script / style / head removal

    func testScriptContentIsRemoved() {
        let html = "<p>Before</p><script>alert('x'); var y = 1 < 2;</script><p>After</p>"
        let out = strip(html)
        XCTAssertFalse(out.contains("alert"), "script body must be removed")
        XCTAssertFalse(out.contains("var y"))
        XCTAssertTrue(out.contains("Before"))
        XCTAssertTrue(out.contains("After"))
    }

    func testStyleContentIsRemoved() {
        let html = "<style>.foo { color: red; }</style><p>Visible</p>"
        let out = strip(html)
        XCTAssertFalse(out.contains("color"))
        XCTAssertFalse(out.contains(".foo"))
        XCTAssertEqual(out, "Visible")
    }

    func testHeadContentIsRemoved() {
        let html = "<head><title>Secret</title><meta charset=\"utf-8\"></head><body><p>Body</p></body>"
        let out = strip(html)
        XCTAssertFalse(out.contains("Secret"), "head content (incl. title) must be removed")
        XCTAssertEqual(out, "Body")
    }

    func testScriptRemovalIsCaseInsensitive() {
        let html = "<SCRIPT>bad()</SCRIPT><p>ok</p>"
        let out = strip(html)
        XCTAssertFalse(out.contains("bad"))
        XCTAssertEqual(out, "ok")
    }

    // MARK: — entity decoding

    func testNamedEntitiesAreDecoded() {
        XCTAssertEqual(strip("a &amp; b"), "a & b")
        XCTAssertEqual(strip("1 &lt; 2 &gt; 0"), "1 < 2 > 0")
        XCTAssertEqual(strip("&quot;quoted&quot;"), "\"quoted\"")
        // &nbsp; decodes to a normal space, which then collapses with neighbours.
        XCTAssertEqual(strip("x&nbsp;y"), "x y")
    }

    func testNumericDecimalEntityIsDecoded() {
        // &#65; == 'A'
        XCTAssertEqual(strip("&#65;BC"), "ABC")
    }

    func testNumericHexEntityIsDecoded() {
        // &#x41; == 'A'. The decoder's regex (&#(x?)([0-9a-fA-F]+);) only
        // recognises a *lowercase* x marker, which is the common form.
        XCTAssertEqual(strip("&#x41;BC"), "ABC")
        // Hex digits themselves are case-insensitive: &#xA9; == ©.
        XCTAssertEqual(strip("&#xA9;"), "©")
    }

    func testMixedEntitiesDecodeTogether() {
        // &#169; == ©  (decimal), &amp; named.
        XCTAssertEqual(strip("&#169; Acme &amp; Co"), "© Acme & Co")
    }

    // MARK: — block-level spacing

    func testBlockTagsProduceLineBreaks() {
        // Two paragraphs become two lines separated by a blank line.
        XCTAssertEqual(strip("<p>Hello</p><p>World</p>"), "Hello\n\nWorld")
    }

    func testBrProducesNewline() {
        let out = strip("Line one<br>Line two")
        XCTAssertTrue(out.contains("Line one"))
        XCTAssertTrue(out.contains("Line two"))
        XCTAssertTrue(out.contains("\n"), "a <br> should introduce a line break")
        XCTAssertFalse(out.contains("Line oneLine two"), "the two lines must not be glued together")
    }

    func testListItemsAreSeparated() {
        let out = strip("<ul><li>Apple</li><li>Banana</li></ul>")
        let lines = out.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains("Apple"))
        XCTAssertTrue(lines.contains("Banana"))
        XCTAssertNotEqual(out, "AppleBanana", "list items must not be concatenated")
    }

    // MARK: — tag stripping & whitespace collapse

    func testBareTagsAreStripped() {
        XCTAssertEqual(strip("<span>plain</span> <b>text</b>"), "plain text")
    }

    func testWhitespaceRunsCollapsePerLine() {
        XCTAssertEqual(strip("a        b\t\tc"), "a b c")
    }

    func testLeadingAndTrailingWhitespaceTrimmed() {
        XCTAssertEqual(strip("   <p>  trimmed  </p>   "), "trimmed")
    }

    func testRunsOfBlankLinesCollapseToOne() {
        // Several block boundaries in a row shouldn't pile up blank lines.
        let out = strip("<p>One</p><div></div><div></div><p>Two</p>")
        XCTAssertFalse(out.contains("\n\n\n"), "no more than one blank line between blocks")
        XCTAssertTrue(out.contains("One"))
        XCTAssertTrue(out.contains("Two"))
    }

    func testPlainTextWithoutTagsIsUnchangedExceptTrim() {
        XCTAssertEqual(strip("just text"), "just text")
    }

    func testEmptyInputProducesEmptyString() {
        XCTAssertEqual(strip(""), "")
    }
}
