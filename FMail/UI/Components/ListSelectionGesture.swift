import AppKit

/// Resolves a click on a list row into one of three intents based on
/// modifier keys. Used by both the threads list and search results so the
/// plain/⌘/⇧ semantics stay identical across the two views.
enum ListSelectionGesture {
    enum Action {
        /// Plain click — replace selection with this row and open it.
        case open
        /// ⌘-click — toggle this row in the selection without opening.
        case toggle
        /// ⇧-click — extend selection from anchor to this row.
        case rangeFromAnchor
    }

    static func action(from modifierFlags: NSEvent.ModifierFlags = NSEvent.modifierFlags) -> Action {
        if modifierFlags.contains(.command) { return .toggle }
        if modifierFlags.contains(.shift) { return .rangeFromAnchor }
        return .open
    }
}
