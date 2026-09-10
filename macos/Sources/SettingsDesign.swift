import AppKit

enum SettingsPalette {
    static let background = NSColor.adaptive(0xF6F7F9, 0x202226)
    static let card = NSColor.adaptive(0xFFFFFF, 0x2A2D32)
    static let sidebar = NSColor.adaptive(0xECEEF2, 0x27292E)
    static let border = NSColor.adaptive(0xE1E4E9, 0x3C3F46)
}

class SettingsBackgroundView: NSView {
    var color: NSColor = SettingsPalette.background
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) { color.setFill(); bounds.fill() }
}

final class SettingsCard: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        SettingsPalette.card.setFill(); path.fill()
        SettingsPalette.border.setStroke(); path.lineWidth = 1; path.stroke()
    }
    init(_ views: [NSView], padding: CGFloat = 0, spacing: CGFloat = 0) {
        super.init(frame: .zero)
        let stack = SettingsLayout.vertical(views, spacing: spacing)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

enum SettingsLayout {
    static func vertical(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }
    static func heading(_ title: String, subtitle: String, action: NSView? = nil) -> NSView {
        let heading = SettingsUI.label(title, size: 25)
        heading.font = .systemFont(ofSize: 25, weight: .semibold)
        let labels = vertical([heading, SettingsUI.label(subtitle, secondary: true)], spacing: 7)
        if let action {
            let row = SettingsUI.row([labels, action]); row.spacing = 20; row.distribution = .fill
            labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
            action.setContentHuggingPriority(.required, for: .horizontal)
            return row
        }
        return labels
    }
    static func section(_ title: String, content: NSView, note: String? = nil) -> NSView {
        let label = SettingsUI.label(title, size: 12, secondary: true)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        var items: [NSView] = [label, content]
        if let note { items.append(SettingsUI.label(note, size: 12, secondary: true)) }
        return vertical(items, spacing: 9)
    }
    static func separator() -> NSView {
        let box = NSBox(); box.boxType = .separator
        return box
    }
    static func setting(_ title: String, detail: String? = nil, control: NSView, height: CGFloat = 58) -> NSView {
        let container = NSView()
        let name = SettingsUI.label(title, size: 13); name.font = .systemFont(ofSize: 13, weight: .medium)
        let labels = vertical([name] + (detail.map { [SettingsUI.label($0, size: 12, secondary: true)] } ?? []), spacing: 5)
        control.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(labels); container.addSubview(control)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: height),
            labels.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            labels.topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor, constant: 14),
            labels.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -14),
            labels.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            labels.trailingAnchor.constraint(equalTo: control.leadingAnchor, constant: -20),
            control.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            control.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        return container
    }
    @discardableResult
    static func scrollPage(_ views: [NSView], in parent: NSView) -> NSScrollView {
        let scroll = SettingsScrollView(views)
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .none; scroll.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(scroll)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: parent.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: parent.topAnchor), scroll.bottomAnchor.constraint(equalTo: parent.bottomAnchor)])
        return scroll
    }
    static func dataPage(_ views: [NSView], in parent: NSView) {
        let stack = vertical(views, spacing: 16)
        parent.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: parent.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -24)
        ])
    }
}

private final class SettingsScrollView: NSScrollView {
    private let document = SettingsBackgroundView()
    private let stack: NSStackView
    private var stackWidth: NSLayoutConstraint!
    private var stackLeading: NSLayoutConstraint!
    private var updatingGeometry = false
    init(_ views: [NSView]) {
        stack = SettingsLayout.vertical(views, spacing: 22)
        super.init(frame: .zero)
        documentView = document
        contentView.postsBoundsChangedNotifications = true
        contentView.postsFrameChangedNotifications = true
        for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged), name: name, object: contentView)
        }
        document.addSubview(stack)
        stackWidth = stack.widthAnchor.constraint(equalToConstant: 700)
        stackLeading = stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 28)
        NSLayoutConstraint.activate([stackWidth, stackLeading,
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 28)])
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func viewportChanged() {
        guard stackWidth != nil, abs(document.frame.width - contentView.bounds.width) > 0.5 else { return }
        if updatingGeometry {
            DispatchQueue.main.async { [weak self] in self?.viewportChanged() }
        } else { updateDocumentGeometry() }
    }
    override func layout() {
        super.layout()
        updateDocumentGeometry()
    }
    private func updateDocumentGeometry() {
        guard !updatingGeometry, stackWidth != nil else { return }
        updatingGeometry = true
        defer { updatingGeometry = false }
        // A legacy scroller can reserve width only after the document grows.
        // Retile before measuring so wrapped content never retains that width.
        for _ in 0..<3 {
            tile()
            let width = contentView.bounds.width
            guard width > 0 else { return }
            stackWidth.constant = min(760, max(1, width - 56))
            stackLeading.constant = max(28, floor((width - stackWidth.constant) / 2))
            document.setFrameSize(NSSize(width: width, height: max(1, document.frame.height)))
            document.layoutSubtreeIfNeeded()
            let height = ceil(stack.fittingSize.height) + 56
            document.setFrameSize(NSSize(width: width, height: max(height, contentView.bounds.height)))
            document.layoutSubtreeIfNeeded()
        }
    }
}

final class CandidatePreviewView: NSView {
    let surface = CandidateSurface()
    private let caption = SettingsUI.label("", size: 11, secondary: true)
    private let preedit = SettingsUI.label("ni hao shi jie", size: 12, secondary: true)
    var skin: CandidateSkin = .system { didSet { refresh() } }
    var fontSize: CGFloat = 18 { didSet { refresh() } }
    init(rows: Int = 2, height: CGFloat = 152) {
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: height).isActive = true
        surface.blendingMode = .withinWindow
        surface.canvas.composition.candidates = Array([
            CandidateItem(text: "你好世界", comment: ""), CandidateItem(text: "你好", comment: ""),
            CandidateItem(text: "拟好", comment: "")].prefix(rows))
        addSubview(surface); addSubview(caption); addSubview(preedit)
        surface.wantsLayer = true
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func refresh() {
        surface.skin = skin; surface.canvas.fontSize = fontSize
        caption.stringValue = "\(skin.name) · \(Int(fontSize)) 磅"
        needsLayout = true; needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        NSColor.adaptive(0xEEF0F5, 0x24272E).setFill(); path.fill()
        NSColor.labelColor.withAlphaComponent(0.045).setFill()
        for x in stride(from: CGFloat(16), to: bounds.width, by: 20) {
            for y in stride(from: CGFloat(16), to: bounds.height, by: 20) {
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 1.5, height: 1.5)).fill()
            }
        }
        SettingsPalette.border.setStroke(); path.lineWidth = 1; path.stroke()
    }
    override func layout() {
        super.layout()
        let size = surface.canvas.measuredSize()
        surface.frame = NSRect(x: floor((bounds.width - size.width) / 2), y: floor((bounds.height - size.height) / 2) - 4,
                               width: size.width, height: size.height)
        preedit.frame = NSRect(x: surface.frame.minX + 4, y: surface.frame.maxY + 5, width: 160, height: 17)
        caption.frame = NSRect(x: 14, y: 10, width: 180, height: 16)
        surface.layoutSubtreeIfNeeded()
    }
}

final class SettingsSidebarButton: NSButton {
    var selected = false { didSet { needsDisplay = true; setAccessibilityValue(selected ? "已选择" : "") } }
    private let symbol: String
    init(title: String, symbol: String, target: AnyObject, action: Selector) {
        self.symbol = symbol
        super.init(frame: .zero)
        self.title = title; self.target = target; self.action = action
        isBordered = false; setButtonType(.momentaryChange)
        alignment = .left
        heightAnchor.constraint(equalToConstant: 38).isActive = true
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        if selected || isHighlighted {
            NSColor.controlAccentColor.withAlphaComponent(selected ? 0.13 : 0.07).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 8, yRadius: 8).fill()
        }
        let color: NSColor = selected ? .controlAccentColor : .secondaryLabelColor
        let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))?
            .withSymbolConfiguration(.init(paletteColors: [color]))
        icon?.draw(in: NSRect(x: 12, y: (bounds.height - 18) / 2, width: 18, height: 18))
        (title as NSString).draw(in: NSRect(x: 40, y: (bounds.height - 18) / 2, width: bounds.width - 48, height: 20),
            withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: selected ? .semibold : .regular),
                             .foregroundColor: NSColor.labelColor])
    }
}
