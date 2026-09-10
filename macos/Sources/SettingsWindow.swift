import AppKit

final class SettingsWindow: NSObject {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    private let mode = NSPopUpButton()
    private let font = NSPopUpButton()

    func show() {
        if window == nil { build() }
        mode.selectItem(at: UserDefaults.standard.bool(forKey: "sentenceOptimization") ? 1 : 0)
        let size = UserDefaults.standard.integer(forKey: "candidateFontSize")
        font.selectItem(withTitle: "\([16, 18, 20, 22].contains(size) ? size : 18)")
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 260),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Rime Q"
        window.isReleasedWhenClosed = false
        window.center()
        let title = NSTextField(labelWithString: "让打字简单一点。")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "离线输入，个人词库保存在这台电脑。")
        subtitle.textColor = .secondaryLabelColor
        mode.addItems(withTitles: ["基础输入", "长句优化 · 万象"])
        mode.target = self; mode.action = #selector(changeMode)
        font.addItems(withTitles: ["16", "18", "20", "22"])
        font.target = self; font.action = #selector(changeFont)
        let grid = NSGridView(views: [[NSTextField(labelWithString: "输入模式"), mode],
                                     [NSTextField(labelWithString: "候选字号"), font]])
        grid.rowSpacing = 14
        grid.columnSpacing = 20
        let note = NSTextField(wrappingLabelWithString: "Shift 切换中英文；数字或鼠标选词；− / = 翻页。\n模式切换在下一次开始输入时生效。")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 12)
        let stack = NSStackView(views: [title, subtitle, grid, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 26)
        ])
        self.window = window
    }

    @objc private func changeMode() { UserDefaults.standard.set(mode.indexOfSelectedItem == 1, forKey: "sentenceOptimization") }
    @objc private func changeFont() { UserDefaults.standard.set(Int(font.titleOfSelectedItem ?? "18") ?? 18, forKey: "candidateFontSize") }
}
