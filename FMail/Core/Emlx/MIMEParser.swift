import Foundation

/// Minimal MIME parser for `.emlx` body content. Handles:
/// - text/plain and text/html parts (single-part)
/// - multipart/alternative, multipart/mixed, multipart/related (recursively)
/// - Content-Transfer-Encoding: 7bit, 8bit, binary, quoted-printable, base64
/// - charset from Content-Type
///
/// Goal is to extract a readable body (preferring text/plain, falling back to
/// text/html stripped) and a list of attachment filenames. Not a fully
/// conformant MIME implementation.
struct MIMEContent {
    let plainText: String?
    let html: String?
    let attachments: [Attachment]

    var attachmentNames: [String] { attachments.map(\.name) }
}

enum MIMEParser {
    /// Cap on multipart nesting depth. Received mail is attacker-controlled and
    /// flows through here (indexing + MCP `get_email`); a deeply-nested crafted
    /// multipart could otherwise overflow the stack via
    /// parsePart → parseMultipart → parsePart. Real mail rarely nests past
    /// depth 2-4 (alternative inside mixed inside a forward), so 32 is generous.
    /// Beyond it we stop descending and treat the part as an opaque leaf rather
    /// than crashing.
    private static let maxDepth = 32

    /// Parses `bodyData` using the parsed top-level headers.
    static func parse(headers: ParsedHeaders, body: Data) -> MIMEContent {
        let ct = ContentType(headers["content-type"] ?? "text/plain; charset=us-ascii")
        let cte = (headers["content-transfer-encoding"] ?? "7bit").lowercased().trimmingCharacters(in: .whitespaces)
        return parsePart(contentType: ct, transferEncoding: cte, body: body, partHeaders: headers, depth: 0)
    }

    private static func parsePart(contentType: ContentType, transferEncoding: String, body: Data, partHeaders: ParsedHeaders, depth: Int) -> MIMEContent {
        if contentType.major == "multipart", let boundary = contentType.parameters["boundary"], depth < maxDepth {
            return parseMultipart(body: body, boundary: boundary, subtype: contentType.minor, depth: depth + 1)
        }

        // Single part.
        let decoded = decodeTransferEncoding(body, encoding: transferEncoding)
        let charset = contentType.parameters["charset"] ?? "utf-8"
        let ctLabel = "\(contentType.major)/\(contentType.minor)"
        // Present only on parts whose bytes Apple Mail offloaded; lets the
        // index record a real size even when `decoded` is empty.
        let declared = declaredContentLength(in: partHeaders)

        switch (contentType.major, contentType.minor) {
        case ("text", "plain"):
            let text = stringFrom(decoded, charset: charset)
            if let name = attachmentName(in: partHeaders) {
                return MIMEContent(
                    plainText: text, html: nil,
                    attachments: [Attachment(name: name, contentType: ctLabel, data: decoded, declaredByteCount: declared)]
                )
            }
            return MIMEContent(plainText: text, html: nil, attachments: [])
        case ("text", "html"):
            let text = stringFrom(decoded, charset: charset)
            if let name = attachmentName(in: partHeaders) {
                return MIMEContent(
                    plainText: nil, html: text,
                    attachments: [Attachment(name: name, contentType: ctLabel, data: decoded, declaredByteCount: declared)]
                )
            }
            return MIMEContent(plainText: nil, html: text, attachments: [])
        default:
            let name = attachmentName(in: partHeaders) ?? defaultAttachmentName(for: contentType)
            return MIMEContent(
                plainText: nil, html: nil,
                attachments: [Attachment(name: name, contentType: ctLabel, data: decoded, declaredByteCount: declared)]
            )
        }
    }

    /// Parse the `X-Apple-Content-Length` placeholder header Apple Mail leaves
    /// on an offloaded attachment part. nil when absent or non-numeric.
    private static func declaredContentLength(in headers: ParsedHeaders) -> Int? {
        guard let raw = headers["x-apple-content-length"]?.trimmingCharacters(in: .whitespaces),
              let n = Int(raw), n >= 0
        else { return nil }
        return n
    }

    /// `depth` is the nesting level of this multipart container (1 for the
    /// top-level multipart). It's threaded into each child `parsePart` so the
    /// recursion can be capped at `maxDepth` — see `parse`.
    private static func parseMultipart(body: Data, boundary: String, subtype: String, depth: Int) -> MIMEContent {
        let parts = splitMultipart(body: body, boundary: boundary)
        var aggregatePlain: String?
        var aggregateHTML: String?
        var attachments: [Attachment] = []

        for partData in parts {
            let (partHeaders, partBody) = splitHeaderBody(partData)
            let partCT = ContentType(partHeaders["content-type"] ?? "text/plain")
            let partCTE = (partHeaders["content-transfer-encoding"] ?? "7bit").lowercased().trimmingCharacters(in: .whitespaces)
            let parsed = parsePart(contentType: partCT, transferEncoding: partCTE, body: partBody, partHeaders: partHeaders, depth: depth)

            if let p = parsed.plainText, aggregatePlain == nil {
                aggregatePlain = p
            }
            if let h = parsed.html, aggregateHTML == nil {
                aggregateHTML = h
            }
            attachments.append(contentsOf: parsed.attachments)
        }

        // For multipart/alternative, prefer plain over html. Both are returned;
        // the caller decides what to render.
        return MIMEContent(plainText: aggregatePlain, html: aggregateHTML, attachments: attachments)
    }

    private static func splitMultipart(body: Data, boundary: String) -> [Data] {
        let delimiter = "--\(boundary)"
        let closeDelimiter = "--\(boundary)--"
        guard let delimData = delimiter.data(using: .ascii),
              let closeData = closeDelimiter.data(using: .ascii)
        else { return [] }

        var parts: [Data] = []
        let bytes = [UInt8](body)
        let delimBytes = [UInt8](delimData)
        let closeBytes = [UInt8](closeData)

        // Find each delimiter occurrence.
        var positions: [Int] = []
        var foundClose = false
        var i = 0
        while i <= bytes.count - delimBytes.count {
            if !foundClose, i <= bytes.count - closeBytes.count, matches(bytes, at: i, with: closeBytes) {
                positions.append(i)
                foundClose = true
                i += closeBytes.count
                continue
            }
            if matches(bytes, at: i, with: delimBytes) {
                positions.append(i)
                i += delimBytes.count
                continue
            }
            i += 1
        }

        for k in 0..<positions.count {
            let start = positions[k]
            // Skip the delimiter line itself (until newline).
            var lineEnd = start
            while lineEnd < bytes.count, bytes[lineEnd] != 0x0A { lineEnd += 1 }
            lineEnd += 1 // consume LF
            let next = (k + 1 < positions.count) ? positions[k + 1] : bytes.count
            if lineEnd < next {
                // Trim trailing CRLF before next delimiter.
                var end = next
                if end > 0, bytes[end - 1] == 0x0A { end -= 1 }
                if end > 0, bytes[end - 1] == 0x0D { end -= 1 }
                if end > lineEnd {
                    parts.append(Data(bytes[lineEnd..<end]))
                }
            }
        }
        return parts
    }

    private static func matches(_ bytes: [UInt8], at i: Int, with pat: [UInt8]) -> Bool {
        if i + pat.count > bytes.count { return false }
        for j in 0..<pat.count where bytes[i + j] != pat[j] { return false }
        return true
    }

    private static func splitHeaderBody(_ data: Data) -> (ParsedHeaders, Data) {
        // Find the first occurrence of CRLF CRLF or LF LF.
        let bytes = [UInt8](data)
        var split: Int? = nil
        var i = 0
        while i < bytes.count - 1 {
            if bytes[i] == 0x0A && bytes[i + 1] == 0x0A {
                split = i + 2
                break
            }
            if i < bytes.count - 3,
               bytes[i] == 0x0D, bytes[i + 1] == 0x0A,
               bytes[i + 2] == 0x0D, bytes[i + 3] == 0x0A {
                split = i + 4
                break
            }
            i += 1
        }
        let headerEnd = split ?? bytes.count
        let headerBytes = Array(bytes.prefix(headerEnd))
        let bodyBytes = headerEnd < bytes.count ? Array(bytes[headerEnd...]) : []

        let headerString = String(bytes: headerBytes, encoding: .utf8)
            ?? String(bytes: headerBytes, encoding: .isoLatin1)
            ?? ""
        return (HeaderParser.parse(headerString), Data(bodyBytes))
    }

    private static func decodeTransferEncoding(_ data: Data, encoding: String) -> Data {
        switch encoding {
        case "base64":
            let str = String(data: data, encoding: .ascii) ?? ""
            let cleaned = str.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
            return Data(base64Encoded: cleaned, options: .ignoreUnknownCharacters) ?? data
        case "quoted-printable":
            return decodeQuotedPrintable(data)
        case "7bit", "8bit", "binary", "":
            return data
        default:
            return data
        }
    }

    private static func decodeQuotedPrintable(_ data: Data) -> Data {
        var out: [UInt8] = []
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x3D { // '='
                if i + 1 < bytes.count, bytes[i + 1] == 0x0A {
                    // soft line break (LF)
                    i += 2
                    continue
                }
                if i + 2 < bytes.count, bytes[i + 1] == 0x0D, bytes[i + 2] == 0x0A {
                    // soft line break (CRLF)
                    i += 3
                    continue
                }
                if i + 2 < bytes.count {
                    let hex = String(bytes: [bytes[i + 1], bytes[i + 2]], encoding: .ascii) ?? ""
                    if let v = UInt8(hex, radix: 16) {
                        out.append(v)
                        i += 3
                        continue
                    }
                }
                out.append(b)
                i += 1
            } else {
                out.append(b)
                i += 1
            }
        }
        return Data(out)
    }

    private static func stringFrom(_ data: Data, charset: String) -> String {
        let enc = EncodedWord.stringEncoding(forCharsetName: charset)
        if let s = String(data: data, encoding: enc) { return s }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    private static func attachmentName(in headers: ParsedHeaders) -> String? {
        if let cd = headers["content-disposition"] {
            if let name = paramValue(in: cd, key: "filename") { return name }
            if let name = rfc2231ParamValue(in: cd, key: "filename") { return name }
        }
        if let ct = headers["content-type"] {
            if let name = paramValue(in: ct, key: "name") { return name }
            if let name = rfc2231ParamValue(in: ct, key: "name") { return name }
        }
        return nil
    }

    /// RFC 2231 continuations: `filename*0=foo; filename*1=bar` → "foobar".
    /// Also handles the encoded form `filename*0*=utf-8'en'percent-encoded`
    /// (charset prefix on segment 0 only; segments tagged with `*` at the
    /// end are percent-decoded). Plain `filename=` is handled by `paramValue`
    /// — this is the fallback for senders that always emit continuations
    /// (e.g. Outlook for long filenames).
    private static func rfc2231ParamValue(in header: String, key: String) -> String? {
        let lowerKey = key.lowercased() + "*"
        var pieces: [(index: Int, encoded: Bool, value: String)] = []
        for chunk in header.split(separator: ";") {
            let raw = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eq = raw.firstIndex(of: "=") else { continue }
            let pname = raw[..<eq].lowercased()
            guard pname.hasPrefix(lowerKey) else { continue }
            let suffix = String(pname.dropFirst(lowerKey.count))
            let isEncoded = suffix.hasSuffix("*")
            let digits = isEncoded ? String(suffix.dropLast()) : suffix
            guard let n = Int(digits) else { continue }
            var v = String(raw[raw.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 {
                v = String(v.dropFirst().dropLast())
            }
            pieces.append((n, isEncoded, v))
        }
        guard !pieces.isEmpty else { return nil }
        pieces.sort { $0.index < $1.index }

        // First segment may carry `charset'lang'` prefix (RFC 2231 §4).
        if pieces[0].encoded, let firstQuote = pieces[0].value.firstIndex(of: "'") {
            let afterCharset = pieces[0].value.index(after: firstQuote)
            if let langQuote = pieces[0].value[afterCharset...].firstIndex(of: "'") {
                pieces[0].value = String(pieces[0].value[pieces[0].value.index(after: langQuote)...])
            }
        }
        var out = ""
        for p in pieces {
            out.append(p.encoded ? (p.value.removingPercentEncoding ?? p.value) : p.value)
        }
        return out
    }

    private static func paramValue(in header: String, key: String) -> String? {
        let lowered = header.lowercased()
        let target = key.lowercased() + "="
        guard let r = lowered.range(of: target) else { return nil }
        let after = header.index(header.startIndex, offsetBy: header.distance(from: lowered.startIndex, to: r.upperBound))
        var i = after
        if i < header.endIndex, header[i] == "\"" {
            i = header.index(after: i)
            var v = ""
            while i < header.endIndex, header[i] != "\"" {
                v.append(header[i])
                i = header.index(after: i)
            }
            return EncodedWord.decode(v)
        } else {
            var v = ""
            while i < header.endIndex, header[i] != ";", !header[i].isWhitespace || !v.isEmpty {
                if header[i] == ";" { break }
                v.append(header[i])
                i = header.index(after: i)
            }
            return EncodedWord.decode(v.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func defaultAttachmentName(for ct: ContentType) -> String {
        return "attachment.\(ct.minor)"
    }
}

struct ContentType {
    let major: String
    let minor: String
    let parameters: [String: String]

    init(_ raw: String) {
        let parts = raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let typeSpec = parts.first ?? "text/plain"
        let typeParts = typeSpec.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        self.major = (typeParts.first.map(String.init) ?? "text").lowercased()
        self.minor = (typeParts.count > 1 ? String(typeParts[1]) : "plain").lowercased()

        var params: [String: String] = [:]
        if parts.count > 1 {
            let paramsPart = parts[1]
            for chunk in paramsPart.split(separator: ";") {
                let kv = chunk.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                if kv.count == 2 {
                    var v = kv[1]
                    if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 {
                        v = String(v.dropFirst().dropLast())
                    }
                    params[kv[0].lowercased()] = v
                }
            }
        }
        self.parameters = params
    }
}
