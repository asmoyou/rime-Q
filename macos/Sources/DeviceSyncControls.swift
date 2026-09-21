import AppKit

@MainActor final class SyncActionButton: NSButton {
    var handler: (() -> Void)?
    init(_ title: String, symbol: String? = nil, primary: Bool = false, action: @escaping () -> Void) {
        super.init(frame: .zero)
        self.title = title; handler = action; bezelStyle = .rounded
        target = self; self.action = #selector(invoke)
        controlSize = .large; font = .systemFont(ofSize: 13, weight: primary ? .medium : .regular)
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); imagePosition = .imageLeading }
        if primary { bezelColor = .controlAccentColor }
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func invoke() { handler?() }
}

@MainActor enum SyncUI {
    static func text(_ value: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, secondary: Bool = false) -> NSTextField {
        let label = SettingsUI.label(value, size: size, secondary: secondary)
        label.font = .systemFont(ofSize: size, weight: weight)
        return label
    }
    static func icon(_ symbol: String, size: CGFloat = 24, tint: NSColor = .controlAccentColor) -> NSImageView {
        let view = NSImageView()
        view.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        view.symbolConfiguration = .init(pointSize: size, weight: .regular)
        view.contentTintColor = tint
        view.widthAnchor.constraint(equalToConstant: size + 12).isActive = true
        view.heightAnchor.constraint(equalToConstant: size + 12).isActive = true
        return view
    }
    static func row(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
        let stack = SettingsUI.row(views); stack.spacing = spacing; stack.distribution = .fill; stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }
    static func spacer() -> NSView {
        let view = NSView(); view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }
    static func centered(_ view: NSView) -> NSView {
        let leading = spacer(), trailing = spacer()
        let row = row([leading, view, trailing])
        leading.widthAnchor.constraint(equalTo: trailing.widthAnchor).isActive = true
        return row
    }
    static func field(_ label: String, value: NSTextField, placeholder: String) -> NSView {
        value.placeholderString = placeholder; value.font = .systemFont(ofSize: 14)
        value.controlSize = .large; value.bezelStyle = .roundedBezel; value.setAccessibilityLabel(label)
        return SettingsLayout.vertical([text(label, size: 12, weight: .medium, secondary: true), value], spacing: 7)
    }
    static func footer(_ title: String) -> NSView {
        row([icon("lock.shield", size: 14, tint: .secondaryLabelColor), text(title, size: 11, secondary: true)], spacing: 8)
    }
    static func pin(_ child: NSView, to parent: NSView, inset: CGFloat = 0) {
        child.translatesAutoresizingMaskIntoConstraints = false; parent.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
        ])
    }
    static func replace(_ stack: NSStackView, with views: [NSView]) {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        for view in views {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }
}

@MainActor final class SyncDeviceRow: NSView {
    private let name = NSTextField(labelWithString: "")
    private let detail = SyncUI.text("", size: 11, secondary: true)
    private let status = SyncUI.text("", size: 11, weight: .medium)
    private let symbol = SyncUI.icon("desktopcomputer", size: 22, tint: .secondaryLabelColor)
    private let more: SyncActionButton
    private var remove: (() -> Void)?

    init(remove: (() -> Void)?) {
        self.remove = remove
        more = SyncActionButton("", symbol: "ellipsis") {}
        super.init(frame: .zero)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let labels = SettingsLayout.vertical([name, detail], spacing: 4)
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        status.setContentHuggingPriority(.required, for: .horizontal)
        status.setContentCompressionResistancePriority(.required, for: .horizontal)
        more.isBordered = false; more.controlSize = .small
        more.widthAnchor.constraint(equalToConstant: 26).isActive = true
        more.toolTip = "设备选项"; more.setAccessibilityLabel("设备选项")
        more.handler = { [weak self] in self?.showMenu() }
        let options = NSView()
        options.widthAnchor.constraint(equalToConstant: 26).isActive = true
        options.heightAnchor.constraint(equalToConstant: 26).isActive = true
        SyncUI.pin(more, to: options)
        let row = SyncUI.row([symbol, labels, status, options], spacing: 12)
        SyncUI.pin(row, to: self, inset: 14)
        heightAnchor.constraint(equalToConstant: 60).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ device: [String: Any], paused: Bool) {
        let own = device["self"] as? Bool == true
        name.stringValue = device["name"] as? String ?? "未命名设备"; name.toolTip = name.stringValue
        detail.stringValue = own ? "这台电脑" : "最近成功：" + DeviceSync.successTime((device["last_sync_at"] as? NSNumber)?.doubleValue ?? 0)
        let online = device["online"] as? Bool == true, applied = device["applied"] as? Bool == true
        let needsUpgrade = device["needs_upgrade"] as? Bool == true
        status.stringValue = paused && own ? "已暂停" : needsUpgrade ? "需要升级" : online ? (applied ? "已同步" : "等待应用") : "等待连接"
        status.textColor = paused && own ? .secondaryLabelColor : online && applied && !needsUpgrade ? NSColor.adaptive(0x237947, 0x70D59C) : .secondaryLabelColor
        status.toolTip = needsUpgrade ? "请将两端 Rime Q 升级到支持完整学习记录同步的版本；无需重新配对。" : online && applied ? "已应用当前已知变更；离线设备可能仍有未传出的词条。" : "连接后自动同步；有组合输入时等待输入结束。"
        more.isHidden = remove == nil
        more.setAccessibilityLabel("管理“\(name.stringValue)”")
    }
    private func showMenu() {
        guard remove != nil else { return }
        let menu = NSMenu()
        let item = NSMenuItem(title: "移除这台设备…", action: #selector(removeDevice), keyEquivalent: "")
        item.target = self; menu.addItem(item)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height + 4), in: more)
    }
    @objc private func removeDevice() { remove?() }
}
