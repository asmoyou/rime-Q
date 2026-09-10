import AppKit

final class SkinChoiceButton: NSButton {
    let skin: CandidateSkin
    private let sample = CandidateCanvas(frame: .zero)
    var selected = false { didSet { needsDisplay = true; setAccessibilityValue(selected ? "已选择" : "") } }
    init(skin: CandidateSkin, target: AnyObject, action: Selector) {
        self.skin = skin
        super.init(frame: .zero)
        title = skin.name; self.target = target; self.action = action
        setButtonType(.momentaryChange); isBordered = false
        setAccessibilityLabel("\(skin.name)皮肤")
        toolTip = skin.summary
        sample.skin = skin; sample.fontSize = 12
        sample.decorationEnabled = false
        sample.isHidden = skin.animated
        sample.composition.candidates = [.init(text: "你好世界", comment: ""), .init(text: "你好", comment: "")]
        addSubview(sample)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12)
        SettingsPalette.card.setFill(); outline.fill()
        (selected ? NSColor.controlAccentColor : SettingsPalette.border).setStroke()
        outline.lineWidth = selected ? 2 : 1; outline.stroke()
        if skin.animated {
            skin.background.setFill()
            NSBezierPath(roundedRect: NSRect(x: 10, y: 10, width: 86, height: bounds.height - 20), xRadius: 8, yRadius: 8).fill()
            TypingCatView.draw(in: NSRect(x: 20, y: 17, width: 66, height: 44), pose: 1)
            (skin.name as NSString).draw(at: NSPoint(x: 112, y: 18),
                withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.labelColor])
            ("随按键敲击 · 停止输入后静止" as NSString).draw(at: NSPoint(x: 112, y: 43),
                withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
            if selected { drawCheck(at: NSPoint(x: bounds.width - 33, y: 31)) }
            return
        }
        let preview = NSBezierPath(roundedRect: NSRect(x: 12, y: 10, width: bounds.width - 24, height: 80), xRadius: 8, yRadius: 8)
        skin.background.setFill(); preview.fill()
        (skin.name as NSString).draw(at: NSPoint(x: 16, y: 102),
            withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor])
        if selected {
            drawCheck(at: NSPoint(x: bounds.width - 33, y: 100))
        }
    }
    private func drawCheck(at point: NSPoint) {
            let circle = NSRect(origin: point, size: NSSize(width: 17, height: 17))
            NSColor.controlAccentColor.setFill(); NSBezierPath(ovalIn: circle).fill()
            let check = NSBezierPath()
            check.move(to: NSPoint(x: circle.minX + 4, y: circle.minY + 8))
            check.line(to: NSPoint(x: circle.minX + 7, y: circle.minY + 11))
            check.line(to: NSPoint(x: circle.minX + 13, y: circle.minY + 5))
            NSColor.white.setStroke(); check.lineWidth = 1.8; check.lineCapStyle = .round; check.lineJoinStyle = .round; check.stroke()
    }
    override func layout() {
        super.layout()
        let size = sample.measuredSize()
        sample.frame = NSRect(x: skin.animated ? 20 : (bounds.width - size.width) / 2, y: 14, width: size.width, height: size.height)
    }
}

final class SkinGrid: NSView {
    override var isFlipped: Bool { true }
    let choices: [SkinChoiceButton]
    private var columns = 3
    init(choices: [SkinChoiceButton]) {
        self.choices = choices
        super.init(frame: .zero)
        choices.forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize {
        let rows = (choices.count + columns - 1) / columns
        return NSSize(width: NSView.noIntrinsicMetric, height: CGFloat(rows) * 132 + CGFloat(rows - 1) * 12)
    }
    override func layout() {
        super.layout()
        let next = bounds.width >= 660 ? 3 : 2
        if columns != next { columns = next; invalidateIntrinsicContentSize() }
        let width = (bounds.width - CGFloat(columns - 1) * 12) / CGFloat(columns)
        for (index, button) in choices.enumerated() {
            button.frame = NSRect(x: CGFloat(index % columns) * (width + 12), y: CGFloat(index / columns) * 144,
                                  width: width, height: 132)
        }
    }
}

final class SkinSettingsViewController: NSViewController {
    let preferences: AppearancePreferences
    private let preview = CandidatePreviewView(rows: 3, height: 200)
    private let animateButton = NSButton(title: "试敲一下", target: nil, action: nil)
    private let selection = SettingsUI.label("", size: 12, secondary: true)
    private var choices: [SkinChoiceButton] = []
    init(preferences: AppearancePreferences = .shared) {
        self.preferences = preferences
        super.init(nibName: nil, bundle: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: AppearancePreferences.didChange, object: preferences)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }
    override func loadView() {
        view = SettingsBackgroundView()
        animateButton.bezelStyle = .rounded; animateButton.target = self; animateButton.action = #selector(previewTap)
        choices = CandidateSkin.allCases.map { SkinChoiceButton(skin: $0, target: self, action: #selector(choose(_:))) }
        let animated = choices.first { $0.skin.animated }!
        animated.heightAnchor.constraint(equalToConstant: 80).isActive = true
        SettingsLayout.scrollPage([
            SettingsLayout.heading("皮肤", subtitle: "为候选栏选一种舒服的颜色。", action: animateButton),
            SettingsLayout.section("实时预览", content: preview),
            SettingsLayout.section("内置皮肤", content: SettingsLayout.vertical([
                animated, SkinGrid(choices: choices.filter { !$0.skin.animated })], spacing: 12)), selection
        ], in: view)
        refresh()
    }
    @objc func refresh() {
        guard isViewLoaded else { return }
        preview.skin = preferences.skin; preview.fontSize = preferences.fontSize
        animateButton.isHidden = !preferences.skin.animated
        choices.forEach { $0.selected = $0.skin == preferences.skin }
        selection.stringValue = "\(preferences.skin.name) · \(preferences.skin.summary)。选择即保存，下一次输入时生效。"
    }
    @objc private func choose(_ sender: SkinChoiceButton) { preferences.skin = sender.skin }
    @objc private func previewTap() { preview.surface.cat.tap() }
}

final class InputSettingsViewController: NSViewController {
    let preferences: AppearancePreferences
    private let optimization = NSSwitch()
    private let font = NSPopUpButton()
    private let skinButton = NSButton()
    private let preview = CandidatePreviewView()
    private var explanation: NSPopover?
    var manageSkins: (() -> Void)?
    init(preferences: AppearancePreferences = .shared) {
        self.preferences = preferences
        super.init(nibName: nil, bundle: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: AppearancePreferences.didChange, object: preferences)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }
    override func loadView() {
        view = SettingsBackgroundView()
        optimization.target = self; optimization.action = #selector(changeOptimization)
        optimization.setAccessibilityLabel("整句优化（万象语法模型）")
        let help = NSButton(image: NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: "了解整句优化")!, target: self, action: #selector(explain(_:)))
        help.isBordered = false; help.contentTintColor = .secondaryLabelColor
        help.widthAnchor.constraint(equalToConstant: 20).isActive = true
        let switches = SettingsUI.row([help, optimization])
        switches.widthAnchor.constraint(equalToConstant: 72).isActive = true
        let inputRow = SettingsLayout.setting("整句优化", detail: "使用万象语法模型，辅助连续输入时的组词。",
            control: switches, height: 76)
        font.addItems(withTitles: ["16", "18", "20", "22"])
        font.target = self; font.action = #selector(changeFont)
        font.widthAnchor.constraint(equalToConstant: 78).isActive = true
        skinButton.target = self; skinButton.action = #selector(openSkins)
        skinButton.bezelStyle = .rounded
        skinButton.setAccessibilityLabel("选择候选皮肤")
        let rows = SettingsCard([
            SettingsLayout.setting("候选字号", control: font), SettingsLayout.separator(),
            SettingsLayout.setting("候选皮肤", control: skinButton)
        ])
        let appearance = SettingsLayout.vertical([rows, preview], spacing: 12)
        let shortcuts = NSStackView(views: [shortcut("⇧ Shift", "中英文切换"), shortcut("数字键", "选择候选"), shortcut("− / =", "候选翻页")])
        shortcuts.distribution = .fillEqually; shortcuts.spacing = 12
        SettingsLayout.scrollPage([
            SettingsLayout.heading("输入与外观", subtitle: "按自己的习惯，调整输入与候选显示。"),
            SettingsLayout.section("输入", content: SettingsCard([inputRow]), note: "开启或关闭，都共用雾凇词库和同一份个人学习记录。"),
            SettingsLayout.section("候选显示", content: appearance),
            SettingsLayout.section("常用按键", content: shortcuts)
        ], in: view)
        refresh()
    }
    private func shortcut(_ key: String, _ description: String) -> NSView {
        let keyLabel = SettingsUI.label(key, size: 12)
        keyLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        return SettingsLayout.vertical([keyLabel, SettingsUI.label(description, size: 12, secondary: true)], spacing: 5)
    }
    @objc func refresh() {
        guard isViewLoaded else { return }
        optimization.state = UserDefaults.standard.bool(forKey: "sentenceOptimization") ? .on : .off
        font.selectItem(withTitle: "\(Int(preferences.fontSize))")
        skinButton.title = preferences.skin.name + "  ›"
        preview.skin = preferences.skin; preview.fontSize = preferences.fontSize
    }
    @objc private func changeOptimization() { UserDefaults.standard.set(optimization.state == .on, forKey: "sentenceOptimization") }
    @objc private func changeFont() { preferences.fontSize = CGFloat(Int(font.titleOfSelectedItem ?? "18") ?? 18) }
    @objc private func openSkins() { manageSkins?() }
    @objc private func explain(_ sender: NSButton) {
        let controller = NSViewController(); controller.view = SettingsBackgroundView(frame: NSRect(x: 0, y: 0, width: 350, height: 215))
        SettingsUI.layout([
            SettingsUI.label("整句优化如何工作", size: 16),
            SettingsUI.label("开启：通过万象语法模型，辅助整句中的同音字词选择。\n\n关闭：使用 librime 原生组词、词频与个人学习。\n\n两种状态共享词库和学习记录。短词候选可能相同，模型也不保证每句更准确；这里不会切换为完整万象输入方案。", size: 12, secondary: true)
        ], in: controller.view)
        let popover = NSPopover(); popover.contentViewController = controller; popover.behavior = .transient
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        explanation = popover
    }
}
