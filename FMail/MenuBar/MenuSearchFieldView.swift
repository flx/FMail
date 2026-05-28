import AppKit

/// A view-based menu item host for a live search field. Embedding an editable
/// control inside a tracking `NSMenu` is the one genuinely fragile part of the
/// menu-bar UI: the menu runs its own event-tracking loop, so the field only
/// receives keystrokes while it is the first responder of the menu's window.
/// We grab first-responder status as soon as the view is shown; on current
/// macOS that's enough for typing to land in the field.
final class MenuSearchFieldView: NSView, NSSearchFieldDelegate {
    let field = NSSearchField()
    /// Called on every keystroke with the current trimmed-or-raw string.
    var onChange: ((String) -> Void)?

    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 30))
        field.translatesAutoresizingMaskIntoConstraints = false
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.placeholderString = "Search…"
        field.focusRingType = .none
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func controlTextDidChange(_ obj: Notification) {
        onChange?(field.stringValue)
    }

    /// Take keyboard focus as soon as the menu's window hosts this view.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.field)
        }
    }
}
