import Foundation
import SQLite3

/// Per-contact address preferences (Phase 4). Backed by the `contact_prefs`
/// table; lives as an actor extension so it shares IndexDB's SQLite handle
/// without needing a second connection.
extension IndexDB {
    func loadContactPrefs(contactId: String) throws -> ContactPrefs {
        var stmt: OpaquePointer?
        try prepare("SELECT preferred_address, blocked_addresses FROM contact_prefs WHERE contact_id = ?", into: &stmt)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, contactId)
        if sqlite3_step(stmt) == SQLITE_ROW {
            let preferred = sqlite3_column_text(stmt, 0).map { String(cString: $0) }
            let blockedJson = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "[]"
            let blocked = decodeStringArray(blockedJson)
            return ContactPrefs(contactId: contactId, preferredAddress: preferred, blockedAddresses: Set(blocked))
        }
        return ContactPrefs(contactId: contactId, preferredAddress: nil, blockedAddresses: [])
    }

    func setPreferredAddress(contactId: String, address: String?) throws {
        let existing = try loadContactPrefs(contactId: contactId)
        try writeContactPrefs(ContactPrefs(
            contactId: contactId,
            preferredAddress: address,
            blockedAddresses: existing.blockedAddresses
        ))
    }

    func addBlockedAddress(contactId: String, address: String) throws {
        let existing = try loadContactPrefs(contactId: contactId)
        var blocked = existing.blockedAddresses
        blocked.insert(address.lowercased())
        try writeContactPrefs(ContactPrefs(
            contactId: contactId,
            preferredAddress: existing.preferredAddress == address ? nil : existing.preferredAddress,
            blockedAddresses: blocked
        ))
    }

    func removeBlockedAddress(contactId: String, address: String) throws {
        let existing = try loadContactPrefs(contactId: contactId)
        var blocked = existing.blockedAddresses
        blocked.remove(address.lowercased())
        try writeContactPrefs(ContactPrefs(
            contactId: contactId,
            preferredAddress: existing.preferredAddress,
            blockedAddresses: blocked
        ))
    }

    func loadAllContactPrefs() throws -> [ContactPrefs] {
        var stmt: OpaquePointer?
        try prepare("SELECT contact_id, preferred_address, blocked_addresses FROM contact_prefs", into: &stmt)
        defer { sqlite3_finalize(stmt) }
        var out: [ContactPrefs] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let cid = String(cString: sqlite3_column_text(stmt, 0))
            let preferred = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            let blockedJson = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "[]"
            out.append(ContactPrefs(
                contactId: cid,
                preferredAddress: preferred,
                blockedAddresses: Set(decodeStringArray(blockedJson))
            ))
        }
        return out
    }

    private func writeContactPrefs(_ p: ContactPrefs) throws {
        let blockedJson = encodeStringArray(Array(p.blockedAddresses).sorted())
        let sql = """
        INSERT INTO contact_prefs(contact_id, preferred_address, blocked_addresses)
        VALUES (?, ?, ?)
        ON CONFLICT(contact_id) DO UPDATE SET
            preferred_address = excluded.preferred_address,
            blocked_addresses = excluded.blocked_addresses
        """
        var stmt: OpaquePointer?
        try prepare(sql, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, p.contactId)
        bindOptional(stmt, 2, p.preferredAddress)
        bind(stmt, 3, blockedJson)
        try stepDone(stmt)
    }

    private nonisolated func encodeStringArray(_ a: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: a, options: []) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private nonisolated func decodeStringArray(_ s: String) -> [String] {
        guard let data = s.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String]
        else { return [] }
        return arr
    }
}
