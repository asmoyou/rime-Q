import AppKit

enum InputMode {
    static let chinese = Product.identifier + ".Hans"
    static let identifiers = [chinese]
    // Retire the unpublished dual-mode experiment during repair/uninstall.
    static let retiredIdentifiers = [Product.identifier + ".Latin"]
}

// One status item follows the current IMK session. Late callbacks from another
// controller cannot replace its state, hide it, or change its input mode.
final class InputModeStatus: NSObject {
    static let shared = InputModeStatus()
    // Keep both labels the same width so switching does not move nearby items.
    private let item = NSStatusBar.system.statusItem(withLength: 18)
    private weak var session: InputSession?
    private var owner: ObjectIdentifier?
    private var displayedEnglish: Bool?

    var button: NSStatusBarButton? { item.button }
    var isVisible: Bool { item.isVisible }

    private override init() {
        super.init()
        item.isVisible = false
        button?.font = .systemFont(ofSize: 14, weight: .medium)
        button?.target = self
        button?.action = #selector(toggleEnglish(_:))
        button?.setAccessibilityLabel("Rime Q 中英文状态")
    }

    func activate(_ session: InputSession, english: Bool?) {
        self.session = session
        owner = ObjectIdentifier(session)
        render(english)
    }

    func update(_ session: InputSession, english: Bool?) {
        guard owner == ObjectIdentifier(session) else { return }
        render(english)
    }

    func deactivate(_ owner: ObjectIdentifier) {
        guard self.owner == owner else { return }
        self.owner = nil
        session = nil
        render(nil)
    }

    private func render(_ english: Bool?) {
        guard let english else {
            // Preserve the saved position across our temporary hide/show cycle.
            item.autosaveName = nil
            item.isVisible = false
            displayedEnglish = nil
            return
        }
        if displayedEnglish != english {
            let language = english ? "英文" : "中文"
            button?.title = english ? "A" : "中"
            button?.toolTip = "Rime Q：\(language)输入（点按切换为\(english ? "中文" : "英文")）"
            button?.setAccessibilityValue(language)
            displayedEnglish = english
        }
        if !item.isVisible {
            item.autosaveName = "RimeQInputMode"
            item.isVisible = true
        }
    }

    @objc private func toggleEnglish(_ sender: Any?) {
        guard item.isVisible, let session else { return }
        session.toggleEnglish(sender)
    }
}
