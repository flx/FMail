import Foundation

/// Classifies a message as "bulk" (newsletter / mailing-list / automated
/// blast) from its RFC 5322 headers, so the relevance ranker can discount it.
///
/// Bulk mail is short, frequent, and high term-density — exactly the shape
/// that wins a naive BM25 race against a genuine one-to-one thread. We mark it
/// at index time (the body indexer has the parsed `.emlx` headers in hand) and
/// the ranker multiplies bulk rows' score by `RelevanceTuning.bulkMultiplier`.
///
/// Signals, in order of reliability:
///   - `List-Unsubscribe` present — RFC 2369; effectively every legitimate
///     mailing list / marketing platform sets it.
///   - `Precedence: bulk | list | junk` — RFC 2076 convention for automated
///     and list traffic.
enum BulkHeuristic {
    static func isBulk(_ headers: ParsedHeaders) -> Bool {
        if let unsub = headers["list-unsubscribe"], !unsub.trimmingCharacters(in: .whitespaces).isEmpty {
            return true
        }
        if let precedence = headers["precedence"]?.lowercased() {
            for marker in ["bulk", "list", "junk"] where precedence.contains(marker) {
                return true
            }
        }
        return false
    }
}
