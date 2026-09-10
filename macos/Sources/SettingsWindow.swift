import AppKit
import QRimeBridge

enum SettingsPage: String, CaseIterable {
    case input, skins, personal, resources
    var title: String {
        switch self {
        case .input: return "输入与外观"
        case .skins: return "皮肤"
        case .personal: return "个人词库"
        case .resources: return "词库与模型"
        }
    }
    var symbol: String {
        switch self {
        case .input: return "keyboard"
        case .skins: return "paintpalette"
        case .personal: return "text.book.closed"
        case .resources: return "square.stack.3d.up"
        }
    }
}

final class SettingsWindow: NSObject {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    private let content = SettingsBackgroundView()
    private var navigation: [SettingsSidebarButton] = []
    private var selected: SettingsPage = .input
    private let general: InputSettingsViewController
    private let skins: SkinSettingsViewController
    private let personal: PersonalDictionaryViewController
    private let resources: DictionaryResourcesViewController

    init(personalStore: PersonalDictionary = .shared, resourceStore: DictionaryResources = .shared,
         preferences: AppearancePreferences = .shared) {
        general = InputSettingsViewController(preferences: preferences)
        skins = SkinSettingsViewController(preferences: preferences)
        personal = PersonalDictionaryViewController(store: personalStore)
        resources = DictionaryResourcesViewController(store: resourceStore)
        super.init()
    }
    func show() {
        if window == nil { build(); window?.setFrameAutosaveName("RimeQ.Settings.Sidebar") }
        selectPage(selected)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    private func build() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Rime Q 设置"; window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 840, height: 600)
        window.center()
        let root = SettingsBackgroundView(frame: window.contentView!.bounds)
        window.contentView = root
        let sidebar = SettingsBackgroundView(frame: NSRect(x: 0, y: 0, width: 204, height: root.bounds.height))
        sidebar.color = SettingsPalette.sidebar
        sidebar.autoresizingMask = [.height]
        content.frame = NSRect(x: 205, y: 0, width: root.bounds.width - 205, height: root.bounds.height)
        content.autoresizingMask = [.width, .height]
        root.addSubview(sidebar); root.addSubview(content)
        let separator = NSBox(frame: NSRect(x: 204, y: 0, width: 1, height: root.bounds.height))
        separator.boxType = .separator; separator.autoresizingMask = [.height]
        root.addSubview(separator)
        let icon = NSImageView()
        icon.image = NSImage(contentsOf: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/AppIcon.icns"))
        icon.widthAnchor.constraint(equalToConstant: 34).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 34).isActive = true
        let brand = SettingsUI.label("Rime Q", size: 18); brand.font = .systemFont(ofSize: 18, weight: .semibold)
        let identity = SettingsUI.row([icon, SettingsLayout.vertical([brand, SettingsUI.label("输入法设置", size: 11, secondary: true)], spacing: 2)])
        identity.spacing = 10
        let preferenceTitle = SettingsUI.label("偏好设置", size: 11, secondary: true)
        let dictionaryTitle = SettingsUI.label("词库", size: 11, secondary: true)
        navigation = SettingsPage.allCases.enumerated().map { index, page in
            let button = SettingsSidebarButton(title: page.title, symbol: page.symbol, target: self, action: #selector(navigate(_:)))
            button.tag = index
            return button
        }
        let stack = SettingsLayout.vertical([identity, preferenceTitle, navigation[0], navigation[1], dictionaryTitle, navigation[2], navigation[3]], spacing: 5)
        stack.setCustomSpacing(30, after: identity)
        stack.setCustomSpacing(18, after: navigation[1])
        stack.setCustomSpacing(8, after: preferenceTitle); stack.setCustomSpacing(8, after: dictionaryTitle)
        sidebar.addSubview(stack)
        let help = SettingsSidebarButton(title: "使用说明", symbol: "questionmark.circle", target: self, action: #selector(openHelp))
        let version = SettingsUI.label("版本 \(Product.version)\n构建 \(Product.build)", size: 10, secondary: true)
        let footer = SettingsLayout.vertical([help, version], spacing: 10)
        sidebar.addSubview(footer)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 26),
            footer.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12), footer.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -20)
        ])
        general.manageSkins = { [weak self] in self?.selectPage(.skins) }
        self.window = window
        selectPage(.input)
    }
    @objc private func navigate(_ sender: NSButton) { selectPage(SettingsPage.allCases[sender.tag]) }
    @objc private func openHelp() { AppMaintenance.openHelp() }
    private func selectPage(_ page: SettingsPage) {
        selected = page
        for (index, button) in navigation.enumerated() { button.selected = SettingsPage.allCases[index] == page }
        let controller: NSViewController
        switch page {
        case .input: controller = general
        case .skins: controller = skins
        case .personal: controller = personal
        case .resources: controller = resources
        }
        if controller.view.superview !== content {
            content.subviews.forEach { $0.removeFromSuperview() }
            let view = controller.view
            view.frame = content.bounds
            view.autoresizingMask = [.width, .height]
            content.addSubview(view)
        }
        switch page {
        case .input: general.refresh()
        case .skins: skins.refresh()
        case .personal: personal.activate()
        case .resources: resources.activate()
        }
    }

    static func render(to directory: URL) throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("rimeq-settings-" + UUID().uuidString)
        let suite = "RimeQ.Render." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: temporary); defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsWindow(personalStore: .init(root: temporary), resourceStore: .init(root: temporary),
                                      preferences: .init(defaults: defaults))
        settings.build()
        settings.window?.orderFront(nil)
        defer { settings.window?.close() }
        settings.personal.showPreview([
            .init(text: "星河词库实验", code: "xing he ci ku shi yan", weight: 12),
            .init(text: "输入体验", code: "shu ru ti yan", weight: 7),
            .init(text: "项目进展", code: "xiang mu jin zhan", weight: 5)
        ])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            settings.window?.appearance = NSAppearance(named: appearance)
            for size in [NSSize(width: 1000, height: 740), NSSize(width: 840, height: 600), NSSize(width: 1240, height: 860)] {
                settings.window?.setContentSize(size)
                for page in SettingsPage.allCases {
                    settings.selectPage(page)
                    let view = settings.window!.contentView!
                    RunLoop.current.run(until: Date().addingTimeInterval(0.03))
                    view.layoutSubtreeIfNeeded()
                    try EngineSmoke.check(abs(view.bounds.height - size.height) < 1 && abs(view.bounds.width - size.width) < 1,
                                          "window content changed requested size: \(view.bounds.size), expected \(size)")
                    try EngineSmoke.check(settings.content.bounds.width > 500, "sidebar squeezed content below usable width")
                    for scroll in settings.content.subviews.flatMap({ $0.subviews }).compactMap({ $0 as? NSScrollView }) {
                        if let doc = scroll.documentView {
                            try EngineSmoke.check(doc.frame.height > 300 && doc.frame.width <= scroll.contentView.bounds.width + 1,
                                                  "scroll page \(page.rawValue): document \(doc.frame), viewport \(scroll.contentView.bounds)")
                        }
                    }
                    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw LexiconError.message("无法渲染设置界面。") }
                    settings.window!.appearance!.performAsCurrentDrawingAppearance {
                        view.displayIfNeeded(); view.cacheDisplay(in: view.bounds, to: bitmap)
                    }
                    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw LexiconError.message("无法导出设置预览。") }
                    let name = "\(page.rawValue)-\(appearance == .aqua ? "light" : "dark")-\(Int(size.width))"
                    try data.write(to: directory.appendingPathComponent(name + ".png"))
                }
            }
        }
        print("PASS settings rendering: four sidebar pages, light/dark, compact/default/wide windows; synthetic records")
    }

    static func smoke() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rimeq-settings-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try Engine.start(user: root.appendingPathComponent("rime")); Engine.ready = true
        defer { Engine.ready = false; QRimeStop() }
        let store = PersonalDictionary(root: root)
        let suite = "RimeQ.SettingsSmoke." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppearancePreferences(defaults: defaults)
        let settings = SettingsWindow(personalStore: store, resourceStore: .init(root: root), preferences: preferences)
        settings.build()
        defer { settings.window?.close() }
        settings.window?.orderFront(nil)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func click(_ title: String, in view: NSView) throws {
            guard let button = descendants(view).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }), button.isEnabled else {
                throw LexiconError.message("Missing or disabled UI button: \(title)")
            }
            button.performClick(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        }
        func fillEditor(_ text: String) throws {
            guard let sheet = settings.window?.attachedSheet, let content = sheet.contentView else { throw LexiconError.message("Editor sheet missing") }
            let fields = descendants(content).compactMap { $0 as? NSTextField }.filter(\.isEditable)
            guard let phrase = fields.first(where: { $0.accessibilityLabel() == "词条" }),
                  let code = fields.first(where: { $0.accessibilityLabel() == "全拼" }) else { throw LexiconError.message("Editor fields missing") }
            phrase.stringValue = text; code.stringValue = "xing he ci ku jie mian"
            try click("保存", in: content)
        }
        try click("个人词库", in: settings.window!.contentView!)
        let page = settings.personal.view
        try click("新增…", in: page)
        try fillEditor("星河词库界面")
        try EngineSmoke.check(try store.entries().contains(where: { $0.text == "星河词库界面" }), "UI add did not reach live engine")
        guard let table = descendants(page).compactMap({ $0 as? NSTableView }).first else { throw LexiconError.message("Personal table missing") }
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try click("编辑…", in: page)
        try fillEditor("星河词库介面")
        try EngineSmoke.check(try store.entries().contains(where: { $0.text == "星河词库介面" }), "UI edit did not update engine")
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try click("删除…", in: page)
        guard let sheet = settings.window?.attachedSheet?.contentView else { throw LexiconError.message("Delete confirmation missing") }
        try click("删除记录", in: sheet)
        try EngineSmoke.check(try store.entries().isEmpty, "UI delete did not update engine")
        try click("撤销上次修改", in: page)
        try EngineSmoke.check(try store.entries().contains(where: { $0.text == "星河词库介面" }), "UI undo failed")
        settings.selectPage(.resources)
        try EngineSmoke.check(settings.resources.numberOfRows(in: NSTableView()) >= 8, "resource page is empty")
        try click("皮肤", in: settings.window!.contentView!)
        try click("敲敲猫", in: settings.skins.view)
        try EngineSmoke.check(preferences.skin == .typingCat, "animated skin selection was not saved")
        try click("试敲一下", in: settings.skins.view)
        try EngineSmoke.check(descendants(settings.skins.view).compactMap({ $0 as? CandidateCanvas }).contains(where: { $0.skin == .typingCat }),
                              "animated skin preview did not update")
        try click("暮色", in: settings.skins.view)
        try EngineSmoke.check(preferences.skin == .midnight, "skin selection was not saved")
        try EngineSmoke.check(AppearancePreferences(defaults: defaults).skin == .midnight, "skin did not persist")
        try click("输入与外观", in: settings.window!.contentView!)
        guard let font = descendants(settings.general.view).compactMap({ $0 as? NSPopUpButton }).first else {
            throw LexiconError.message("Font control missing")
        }
        font.selectItem(withTitle: "22"); _ = font.sendAction(font.action, to: font.target)
        try EngineSmoke.check(preferences.fontSize == 22, "font change was not saved")
        try EngineSmoke.check(descendants(settings.general.view).compactMap({ $0 as? CandidateCanvas })
            .contains(where: { $0.skin == .midnight && $0.fontSize == 22 }), "live preview did not update")
        print("PASS native settings actions: skin selection/persistence, live font preview,  tab navigation, add/edit sheets, deletion confirmation, undo, real learning records")
    }
}
