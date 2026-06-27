import Foundation

/// Rewrites the owner pseudo-tokens in a parsed query against a runtime-derived
/// owner-identity set, so `from:me` / `to:me` / `cc:me` and `in:sent` mean
/// "this mailbox's owner" without anything being hardcoded. The owner set comes
/// from `IndexDB.ownerIdentities()`; with an empty set the rewrites degrade
/// safely (`me` ⇒ matches nothing, `in:sent` ⇒ a `\Sent` mailbox only).
///
/// This is an AST→AST pass run *after* parsing rather than in the parser,
/// because the parser has no index access — owner identities are data, not
/// grammar. The literal value `me` (any case) is reserved as the owner token.
enum OwnerExpansion {
    /// Rewrite every owner pseudo-token in `node` against `owners`.
    static func rewrite(_ node: QueryNode, owners: [String]) -> QueryNode {
        switch node {
        case .empty:
            return .empty
        case .and(let children):
            return .and(children.map { rewrite($0, owners: owners) })
        case .or(let children):
            return .or(children.map { rewrite($0, owners: owners) })
        case .not(let inner):
            return .not(rewrite(inner, owners: owners))
        case .term(let t):
            return .term(rewriteTerm(t, owners: owners))
        }
    }

    /// True when `node` contains at least one token whose meaning depends on the
    /// owner set (`from:me`/`to:me`/`cc:me` or `in:sent`). Lets the caller skip
    /// the owner-identity query entirely for the overwhelmingly common query
    /// that mentions neither — keeping the hot search path free of extra work.
    static func referencesOwner(_ node: QueryNode) -> Bool {
        switch node {
        case .empty:
            return false
        case .and(let children), .or(let children):
            return children.contains { referencesOwner($0) }
        case .not(let inner):
            return referencesOwner(inner)
        case .term(let t):
            switch t {
            case .fromAddr(let v), .toAddr(let v), .ccAddr(let v):
                return isMe(v)
            case .mailboxKind(let kind):
                return kind == "sent"
            default:
                return false
            }
        }
    }

    private static func rewriteTerm(_ t: Term, owners: [String]) -> Term {
        switch t {
        case .fromAddr(let v) where isMe(v): return .ownerFrom(owners)
        case .toAddr(let v)   where isMe(v): return .ownerTo(owners)
        case .ccAddr(let v)   where isMe(v): return .ownerCc(owners)
        case .mailboxKind(let kind) where kind == "sent": return .sentMailbox(owners)
        default: return t
        }
    }

    private static func isMe(_ v: String) -> Bool {
        v.trimmingCharacters(in: .whitespaces).lowercased() == "me"
    }
}
