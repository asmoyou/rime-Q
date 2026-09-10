import AppKit

final class ModelSettingsView: NSView {
    private let model: OptionalModel
    private let status = SettingsUI.label("", size: 12, secondary: true)
    private let actionButton = NSButton()
    private let progress = NSProgressIndicator()

    init(model: OptionalModel) {
        self.model = model
        super.init(frame: .zero)
        actionButton.bezelStyle = .rounded
        actionButton.target = self; actionButton.action = #selector(performAction)
        actionButton.widthAnchor.constraint(equalToConstant: 120).isActive = true
        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        progress.style = .bar; progress.minValue = 0; progress.maxValue = 1
        progress.isDisplayedWhenStopped = false
        let row = SettingsUI.row([status, actionButton]); row.spacing = 18
        row.distribution = .fill
        status.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = SettingsLayout.vertical([row, progress], spacing: 10)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: OptionalModel.didChange, object: model)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func refresh() {
        status.stringValue = model.statusDescription
        actionButton.isEnabled = model.descriptor != nil
        progress.stopAnimation(nil); progress.isHidden = true
        switch model.state {
        case .checking, .waiting:
            actionButton.title = "请稍候…"; actionButton.isEnabled = false
        case .downloading(let received):
            actionButton.title = "取消下载"
            progress.isHidden = false; progress.isIndeterminate = false
            progress.doubleValue = Double(received) / Double(model.descriptor?.bytes ?? 1)
        case .verifying:
            actionButton.title = "取消"
            progress.isHidden = false; progress.isIndeterminate = true; progress.startAnimation(nil)
        case .ready: actionButton.title = "移除模型…"
        case .missing: actionButton.title = "下载并开启"
        case .failed: actionButton.title = model.available ? "移除模型…" : "重试下载"
        }
    }
    @objc private func performAction() {
        if model.state.busy { model.cancel() }
        else if model.available {
            SettingsUI.confirm("移除万象模型？", detail: "释放约 \(model.descriptor?.sizeDescription ?? "420 MB") 空间，并关闭整句优化。基础输入、词库和学习记录会保留。", action: "移除模型", window: window) {
                try? self.model.remove()
            }
        } else { model.download() }
    }
}
