import AppKit
import Carbon
import InputMethodKit
import QRimeBridge

final class InputSession: NSObject {
    private var session: UInt = 0
    private var active = false
    private var marked = false
    private var owner: IMKTextInput?
    private var shiftAlone = false
    private var appliedSchema = ""
    private var generation: UInt = 0

    deinit { if session != 0 { QRimeDestroySession(session) } }

    private func owns(_ client: IMKTextInput) -> Bool {
        active && owner.map { ObjectIdentifier($0 as AnyObject) == ObjectIdentifier(client as AnyObject) } == true
    }

    private func ensureSession() -> Bool {
        guard Engine.ready else { return false }
        if session == 0 { session = QRimeCreateSession() }
        guard session != 0 else { return false }
        if appliedSchema != Product.schema {
            QRimeClear(session)
            guard QRimeSchema(session, Product.schema) else { return false }
            appliedSchema = Product.schema
        }
        return true
    }

    func activate(_ sender: Any!) {
        generation &+= 1
        owner = sender as? IMKTextInput
        active = true
        marked = false
        shiftAlone = false
        _ = ensureSession()
    }

    func deactivate(_ sender: Any!) {
        if let client = sender as? IMKTextInput, owns(client) { commitCurrent(client) }
        active = false
        generation &+= 1
        owner = nil
        marked = false
        shiftAlone = false
        CandidatePanel.shared.hide(owner: ObjectIdentifier(self))
        if session != 0 { QRimeClear(session) }
    }

    func commit(_ sender: Any!) {
        if let client = sender as? IMKTextInput, owns(client) { commitCurrent(client) }
    }

    func eventMask(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.rawValue | NSEvent.EventTypeMask.flagsChanged.rawValue)
    }

    func process(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, let client = sender as? IMKTextInput, owns(client), ensureSession() else { return false }
        // Password/secure input remains owned by the system's direct keyboard path.
        if IsSecureEventInputEnabled() {
            CandidatePanel.shared.hide(owner: ObjectIdentifier(self))
            QRimeClear(session)
            return false
        }
        if event.type == .flagsChanged {
            guard event.keyCode == 56 || event.keyCode == 60 else { shiftAlone = false; return false }
            if event.modifierFlags.contains(.shift) {
                shiftAlone = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            } else {
                if shiftAlone {
                    commitCurrent(client)
                    QRimeSetOption(session, "ascii_mode", !QRimeGetOption(session, "ascii_mode"))
                }
                shiftAlone = false
            }
            return false
        }
        shiftAlone = false
        guard event.type == .keyDown else { return false }
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            commitCurrent(client)
            return false
        }
        guard let key = Self.key(event) else { commitCurrent(client); return false }
        let mask: Int32 = event.modifierFlags.contains(.shift) ? 1 : 0
        let consumed = QRimeProcess(session, key, mask)
        deliverAndRefresh(client)
        return consumed
    }

    private static func key(_ event: NSEvent) -> Int32? {
        switch event.keyCode {
        case 36, 76: return 0xff0d
        case 48: return 0xff09
        case 51: return 0xff08
        case 53: return 0xff1b
        case 117: return 0xffff
        case 115: return 0xff50
        case 119: return 0xff57
        case 123: return 0xff51
        case 124: return 0xff53
        case 125: return 0xff54
        case 126: return 0xff52
        case 116: return 0xff55
        case 121: return 0xff56
        case 118: return 0xffc1
        default:
            guard let scalar = event.characters?.unicodeScalars.first,
                  (0x20...0x7e).contains(scalar.value) else { return nil }
            return Int32(scalar.value)
        }
    }

    private func commitCurrent(_ client: IMKTextInput) {
        guard session != 0, owns(client) else { return }
        let before = Engine.snapshot(session)
        guard before.active else { return }
        _ = QRimeCommitComposition(session)
        let text = String(cString: QRimeTakeCommit(session))
        QRimeClear(session)
        marked = false
        CandidatePanel.shared.hide(owner: ObjectIdentifier(self))
        client.insertText(text.isEmpty ? before.input : text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func deliverAndRefresh(_ client: IMKTextInput) {
        guard owns(client) else { return }
        let epoch = generation
        let committed = String(cString: QRimeTakeCommit(session))
        if !committed.isEmpty {
            marked = false
            CandidatePanel.shared.hide(owner: ObjectIdentifier(self))
            client.insertText(committed, replacementRange: NSRange(location: NSNotFound, length: 0))
            guard owns(client), generation == epoch else { return }
        }
        let composition = Engine.snapshot(session)
        if composition.active {
            marked = true
            client.setMarkedText(composition.preedit,
                selectionRange: NSRange(location: composition.cursorUTF16, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0))
        } else if marked {
            marked = false
            client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        guard owns(client), generation == epoch else { return }
        var rect = NSRect.zero
        if composition.active { _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect) }
        guard owns(client), generation == epoch else { return }
        CandidatePanel.shared.show(composition, anchor: rect, owner: ObjectIdentifier(self)) { [weak self, weak clientObject = client as AnyObject] index in
            guard let self, let current = clientObject as? IMKTextInput,
                  self.owns(current), self.generation == epoch else { return }
            if QRimeSelect(self.session, index) { self.deliverAndRefresh(current) }
        }
    }

    func makeMenu() -> NSMenu! {
        let menu = NSMenu()
        let english = menu.addItem(withTitle: "英文输入", action: #selector(toggleEnglish), keyEquivalent: "")
        english.target = self
        english.state = session != 0 && QRimeGetOption(session, "ascii_mode") ? .on : .off
        menu.addItem(.separator())
        let settings = menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        let data = menu.addItem(withTitle: "打开个人数据文件夹", action: #selector(openData), keyEquivalent: "")
        data.target = self
        return menu
    }

    @objc fileprivate func toggleEnglish() {
        if let owner { commitCurrent(owner) }
        if ensureSession() { QRimeSetOption(session, "ascii_mode", !QRimeGetOption(session, "ascii_mode")) }
    }
    @objc fileprivate func openSettings() { if let owner { commitCurrent(owner) }; SettingsWindow.shared.show() }
    @objc fileprivate func openData() { NSWorkspace.shared.open(Product.userRoot) }
}

// InputMethodKit owns the actual client proxy. Keep event/session behavior independently testable.
@objc(RimeQController)
final class RimeQController: IMKInputController {
    private let input = InputSession()
    override func activateServer(_ sender: Any!) { input.activate(sender) }
    override func deactivateServer(_ sender: Any!) { input.deactivate(sender) }
    override func commitComposition(_ sender: Any!) { input.commit(sender) }
    override func recognizedEvents(_ sender: Any!) -> Int { input.eventMask(sender) }
    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool { input.process(event, client: sender) }
    override func menu() -> NSMenu! { input.makeMenu() }
    @objc private func toggleEnglish() { input.toggleEnglish() }
    @objc private func openSettings() { input.openSettings() }
    @objc private func openData() { input.openData() }
}
