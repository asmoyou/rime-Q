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
        sample.frame = NSRect(x: (bounds.width - size.width) / 2, y: 14, width: size.width, height: size.height)
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

final class AdvancedSkinCard: NSView {
    let preview = CandidatePreviewView(rows: 2, height: 190)
    let skin: CandidateSkin
    private let useButton = NSButton()
    var selected = false {
        didSet {
            useButton.title = selected ? "正在使用" : "使用\(skin.name)"
            useButton.isEnabled = !selected
            needsDisplay = true
        }
    }
    init(skin: CandidateSkin, target: AnyObject, action: Selector) {
        self.skin = skin
        super.init(frame: .zero)
        preview.skin = skin
        let title = SettingsUI.label(skin.name, size: 19)
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        let tryButton = NSButton(title: "试敲一下", target: self, action: #selector(tryTyping))
        tryButton.bezelStyle = .rounded
        useButton.title = "使用\(skin.name)"; useButton.bezelStyle = .rounded
        useButton.target = target; useButton.action = action
        useButton.tag = CandidateSkin.allCases.firstIndex(of: skin)!
        let labels = SettingsLayout.vertical([
            SettingsUI.label("动态陪伴", size: 11, secondary: true), title,
            SettingsUI.label("小猫趴在候选栏外，陪你一起敲键盘。\n候选内容保持紧凑，停笔后小猫也休息。", size: 12, secondary: true),
            SettingsUI.row([tryButton, useButton])
        ], spacing: 12)
        preview.translatesAutoresizingMaskIntoConstraints = false
        addSubview(preview); addSubview(labels)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            preview.widthAnchor.constraint(equalToConstant: 196),
            preview.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            preview.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            labels.leadingAnchor.constraint(equalTo: preview.trailingAnchor, constant: 20),
            labels.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func tryTyping() { preview.cat.tap() }
    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14)
        SettingsPalette.card.setFill(); outline.fill()
        (selected ? NSColor.controlAccentColor : SettingsPalette.border).setStroke()
        outline.lineWidth = selected ? 2 : 1; outline.stroke()
    }
}

final class SkinSettingsViewController: NSViewController {
    let preferences: AppearancePreferences
    private let selection = SettingsUI.label("", size: 12, secondary: true)
    private var choices: [SkinChoiceButton] = []
    private var advanced: [AdvancedSkinCard] = []
    init(preferences: AppearancePreferences = .shared) {
        self.preferences = preferences
        super.init(nibName: nil, bundle: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: AppearancePreferences.didChange, object: preferences)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }
    override func loadView() {
        view = SettingsBackgroundView()
        choices = CandidateSkin.allCases.filter { !$0.animated }.map { SkinChoiceButton(skin: $0, target: self, action: #selector(choose(_:))) }
        advanced = CandidateSkin.allCases.filter(\.animated).map { AdvancedSkinCard(skin: $0, target: self, action: #selector(chooseAdvanced(_:))) }
        SettingsLayout.scrollPage([
            SettingsLayout.heading("皮肤", subtitle: "选择舒服的配色，或让小伙伴陪你打字。"), selection,
            SettingsLayout.section("高级皮肤", content: SettingsLayout.vertical(advanced, spacing: 12)),
            SettingsLayout.section("简洁皮肤", content: SkinGrid(choices: choices))
        ], in: view)
        refresh()
    }
    @objc func refresh() {
        guard isViewLoaded else { return }
        choices.forEach { $0.selected = $0.skin == preferences.skin }
        advanced.forEach { $0.selected = $0.skin == preferences.skin; $0.preview.fontSize = preferences.fontSize }
        selection.stringValue = "\(preferences.skin.name) · \(preferences.skin.summary)。选择即保存，下一次输入时生效。"
    }
    @objc private func choose(_ sender: SkinChoiceButton) { preferences.skin = sender.skin }
    @objc private func chooseAdvanced(_ sender: NSButton) {
        guard CandidateSkin.allCases.indices.contains(sender.tag) else { return }
        let skin = CandidateSkin.allCases[sender.tag]
        if skin.animated { preferences.skin = skin }
    }
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
        switches.widthAnchor.constraint(equalToConstant: 96).isActive = true
        switches.distribution = .gravityAreas
        switches.setViews([help, optimization], in: .trailing)
        let inputRow = SettingsLayout.setting("整句优化", detail: "使用万象语法模型，辅助连续输入时的组词。",
            control: switches, height: 76)
        font.addItems(withTitles: ["16", "18", "20", "22"])
        font.target = self; font.action = #selector(changeFont)
        font.widthAnchor.constraint(equalToConstant: 96).isActive = true
        skinButton.target = self; skinButton.action = #selector(openSkins)
        skinButton.bezelStyle = .rounded
        skinButton.setAccessibilityLabel("选择候选皮肤")
        skinButton.widthAnchor.constraint(equalToConstant: 96).isActive = true
        let rows = SettingsCard([
            SettingsLayout.setting("候选字号", control: font), SettingsLayout.separator(),
            SettingsLayout.setting("候选皮肤", control: skinButton)
        ])
        let appearance = SettingsLayout.vertical([rows, preview], spacing: 12)
        let shortcuts = NSStackView(views: [shortcut("⇧ Shift", "中英文切换"), shortcut("数字键", "选择候选"), shortcut("− / =", "候选翻页")])
        shortcuts.distribution = .fillEqually; shortcuts.spacing = 12; shortcuts.alignment = .top
        SettingsLayout.scrollPage([
            SettingsLayout.heading("输入与外观", subtitle: "按自己的习惯，调整输入与候选显示。"),
            SettingsLayout.section("输入", content: SettingsCard([inputRow]), note: "开启或关闭，都共用雾凇词库和同一份个人学习记录。"),
            SettingsLayout.section("候选显示", content: appearance),
            SettingsLayout.section("常用按键", content: shortcuts),
            SettingsLayout.section("快捷输入", content: SettingsCard([
                SettingsUI.label("rq 日期 · sj 时间 · xq 星期 · nl 农历\ncC1+2 计算器 · R123.45 金额大写 · U62fc Unicode\nuuid 随机标识 · [ / ] 取候选首字 / 尾字", size: 12, secondary: true)
            ], padding: 16), note: "中文模式下输入，空格或数字键选取结果。完整用法见“使用说明”。")
        ], in: view)
        refresh()
    }
    private func shortcut(_ key: String, _ description: String) -> NSView {
        let keyLabel = SettingsUI.label(key, size: 12)
        keyLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        return SettingsCard([keyLabel, SettingsUI.label(description, size: 12, secondary: true)], padding: 16, spacing: 8)
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
