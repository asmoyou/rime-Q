import AppKit

final class UpdateSettingsViewController: NSViewController {
    private let checker: UpdateChecker
    private let automatic = NSSwitch()
    private let checkButton = NSButton(title: "检查更新…", target: nil, action: nil)
    private let status = SettingsUI.label("尚未检查更新", size: 13)
    private let checkedAt = SettingsUI.label("", size: 12, secondary: true)

    init(checker: UpdateChecker) {
        self.checker = checker
        super.init(nibName: nil, bundle: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: UpdateChecker.didChange, object: checker)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    override func loadView() {
        view = SettingsBackgroundView()
        automatic.target = self; automatic.action = #selector(changeAutomatic)
        automatic.setAccessibilityLabel("每天自动检查更新")
        checkButton.target = self; checkButton.action = #selector(check)
        checkButton.bezelStyle = .rounded
        let project = SettingsUI.button("打开 GitHub", target: self, action: #selector(openProject))
        let releases = SettingsUI.button("查看发布记录", target: self, action: #selector(openReleases))
        for button in [checkButton, project, releases] { button.widthAnchor.constraint(equalToConstant: 120).isActive = true }
        SettingsLayout.scrollPage([
            SettingsLayout.heading("版本与更新", subtitle: "Rime Q · 简洁、流畅、离线的中文输入法。"),
            SettingsLayout.section("当前版本", content: SettingsCard([
                SettingsLayout.setting("Rime Q \(Product.version)", detail: "构建 \(Product.build)", control: checkButton, height: 80)
            ])),
            SettingsLayout.section("软件更新", content: SettingsLayout.vertical([
                SettingsCard([SettingsLayout.setting("自动检查更新", detail: "每天一次，只查询 GitHub 发布信息。", control: automatic, height: 76)]),
                SettingsLayout.vertical([status, checkedAt], spacing: 6)
            ], spacing: 12), note: "发现新版会在输入法菜单和此处提示。下载与安装由你决定。"),
            SettingsLayout.section("项目", content: SettingsCard([
                SettingsLayout.setting("GitHub 项目", detail: "asmoyou / rime-Q · 源码、文档与问题反馈", control: project, height: 76),
                SettingsLayout.separator(),
                SettingsLayout.setting("发布记录", detail: "查看版本变化，下载安装包。", control: releases, height: 76)
            ])),
            SettingsUI.label("日常输入与学习都在本机完成。更新检查不发送输入内容或个人词库。", size: 12, secondary: true)
        ], in: view)
        refresh()
    }
    @objc func refresh() {
        guard isViewLoaded else { return }
        automatic.state = checker.automatic ? .on : .off
        checkButton.isEnabled = !checker.isChecking
        checkButton.title = checker.isChecking ? "正在检查…" : "检查更新…"
        status.stringValue = checker.isChecking ? "正在查询发布信息…" : checker.result?.title ?? (checker.lastAttempt == nil ? "尚未检查更新" : "等待下次检查")
        status.textColor = checker.availableTag == nil ? .labelColor : .controlAccentColor
        if let date = checker.lastAttempt {
            checkedAt.stringValue = "上次检查：" + DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
        } else {
            checkedAt.stringValue = checker.automatic ? "启用输入法后将在后台检查。" : "自动检查已关闭，可随时手动检查。"
        }
    }
    @objc private func changeAutomatic() { checker.automatic = automatic.state == .on }
    @objc private func check() { AppMaintenance.checkForUpdates(using: checker) }
    @objc private func openProject() { AppMaintenance.openProject() }
    @objc private func openReleases() { AppMaintenance.openDownloads() }
}
