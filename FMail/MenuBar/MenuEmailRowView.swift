import AppKit

/// One email row inside the status menu, hosted as a view-based `NSMenuItem`.
///
/// A tracking `NSMenu` won't reliably deliver clicks to arbitrary controls in
/// a view item (it consumes mouse-up to drive its own selection), so we use
/// exactly one embedded control — the checkbox — and let the menu handle the
/// rest. `hitTest` returns the checkbox for clicks on the box (toggle, menu
/// stays open) and `nil` everywhere else, so the title/caret region is treated
/// as the menu item proper and NSMenu opens the item's real `submenu` (the
/// per-email actions) on hover or click, just like a standard submenu item.
final class MenuEmailRowView: NSView {
    private let checkbox = NSButton()
    private let label = NSTextField(labelWithString: "")
    private let caret = NSImageView()

    /// Fired when the checkbox box is clicked (selection toggled).
    var onToggleSelect: (() -> Void)?

    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 22))

        checkbox.setButtonType(.switch)
        checkbox.title = ""
        checkbox.target = self
        checkbox.action = #selector(toggle)
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        checkbox.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(checkbox)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)

        caret.image = NSImage(
            systemSymbolName: "chevron.right",
            accessibilityDescription: "Actions"
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(scale: .small))
        caret.contentTintColor = .secondaryLabelColor
        caret.translatesAutoresizingMaskIntoConstraints = false
        caret.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(caret)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: caret.leadingAnchor, constant: -6),
            caret.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            caret.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Box → checkbox (toggle). Everything else → nil, so NSMenu treats the
    /// area as the item and opens its submenu.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return checkbox.frame.contains(local) ? checkbox : nil
    }

    @objc private func toggle() { onToggleSelect?() }

    func configure(title: NSAttributedString, selected: Bool) {
        label.attributedStringValue = title
        checkbox.state = selected ? .on : .off
    }
}
