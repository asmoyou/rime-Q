import AppKit
import InputMethodKit
import QRimeBridge

// Controlled IMK host used only by --controller-smoke, never a user's application.
final class MockTextClient: NSObject, IMKTextInput {
    var document = ""
    var preedit = ""
    var onInsert: (() -> Void)?
    var selectedMode: String?
    var modeSelections: [String] = []
    var onSelectMode: ((String) -> Void)?
    func insertText(_ string: Any!, replacementRange: NSRange) {
        document += (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        preedit = ""
        onInsert?()
    }
    func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) {
        preedit = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
    }
    func selectedRange() -> NSRange { NSRange(location: document.utf16.count, length: 0) }
    func markedRange() -> NSRange { NSRange(location: document.utf16.count, length: preedit.utf16.count) }
    func attributedSubstring(from range: NSRange) -> NSAttributedString! { NSAttributedString(string: "") }
    func length() -> Int { document.utf16.count }
    func characterIndex(for point: NSPoint, tracking mappingMode: IMKLocationToOffsetMappingMode,
                        inMarkedRange: UnsafeMutablePointer<ObjCBool>!) -> Int { NSNotFound }
    func attributes(forCharacterIndex index: Int, lineHeightRectangle lineRect: UnsafeMutablePointer<NSRect>!) -> [AnyHashable: Any]! {
        lineRect?.pointee = NSRect(x: 100, y: 400, width: 1, height: 20)
        return [:]
    }
    func validAttributesForMarkedText() -> [Any]! { [] }
    func overrideKeyboard(withKeyboardNamed keyboardUniqueName: String!) {}
    func selectMode(_ modeIdentifier: String!) {
        selectedMode = modeIdentifier
        modeSelections.append(modeIdentifier)
        onSelectMode?(modeIdentifier)
    }
    func supportsUnicode() -> Bool { true }
    func bundleIdentifier() -> String! { "com.asmoyou.rimeq.smoke-client" }
    func windowLevel() -> CGWindowLevel { 0 }
    func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { false }
    func uniqueClientIdentifierString() -> String! { "rimeq-smoke-client" }
    func string(from range: NSRange, actualRange: NSRangePointer!) -> String! { "" }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer!) -> NSRect { .zero }
}

enum ControllerSmoke {
    static func run() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rimeq-controller-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Engine.start(user: root)
        Engine.ready = true
        defer { Engine.ready = false; QRimeStop() }
        let first = MockTextClient()
        let second = MockTextClient()
        let controller = InputSession()
        let other = InputSession()
        defer { controller.deactivate(first); other.deactivate(second) }
        func key(_ value: String, code: UInt16 = 0, into client: MockTextClient, through target: InputSession) -> Bool {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: 0, context: nil, characters: value,
                                        charactersIgnoringModifiers: value, isARepeat: false, keyCode: code)!
            return target.process(event, client: client)
        }
        func type(_ value: String, into client: MockTextClient, through target: InputSession) throws {
            for character in value {
                try EngineSmoke.check(key(String(character), into: client, through: target), "typing key rejected")
            }
        }
        controller.activate(first)
        try type("nihao", into: first, through: controller)
        try EngineSmoke.check(!first.preedit.isEmpty && CandidatePanel.shared.isVisible, "marked text or panel missing")
        _ = key(" ", into: first, through: controller)
        try EngineSmoke.check(first.document == "你好" && first.preedit.isEmpty, "space did not replace marked text")
        try type("zhongguo", into: first, through: controller)
        CandidatePanel.shared.canvas.select?(0)
        try EngineSmoke.check(first.document == "你好中国", "mouse selection committed the wrong candidate")
        try type("ceshi", into: first, through: controller)
        _ = key("\u{1b}", code: 53, into: first, through: controller)
        try EngineSmoke.check(first.preedit.isEmpty && first.document == "你好中国", "cancel inserted or left composition")
        // A late deactivation from the old controller must not hide the new owner's panel.
        other.activate(second)
        try type("nihao", into: second, through: other)
        controller.deactivate(first)
        try EngineSmoke.check(CandidatePanel.shared.isVisible, "old controller hid the new candidate panel")
        // A host can synchronously move focus while accepting committed text.
        second.onInsert = { other.deactivate(second) }
        _ = key(" ", into: second, through: other)
        try EngineSmoke.check(second.document == "你好" && !CandidatePanel.shared.isVisible, "reentrant commit left stale UI")
        let old = second.document
        _ = key("a", into: second, through: other)
        try EngineSmoke.check(second.document == old && second.preedit.isEmpty, "inactive host received input")
        try modeStatus()
        print("PASS controller: marked text, space, mouse, cancellation, panel ownership, reentrant focus, mode status")
    }

    private static func modeStatus() throws {
        let client = MockTextClient()
        let nextClient = MockTextClient()
        let input = InputSession()
        let next = InputSession()
        defer { input.deactivate(client); next.deactivate(nextClient) }
        func checkMode(_ english: Bool, _ label: String, host: MockTextClient? = nil) throws {
            try EngineSmoke.check((host ?? client).selectedMode == InputMode.identifier(english: english), label)
        }
        client.onSelectMode = { input.selectInputMode($0, client: client) }
        nextClient.onSelectMode = { next.selectInputMode($0, client: nextClient) }
        func event(_ kind: NSEvent.EventType, _ flags: NSEvent.ModifierFlags = [], code: UInt16 = 56,
                   text: String = "", target: InputSession? = nil, host: MockTextClient? = nil) -> Bool {
            let key = NSEvent.keyEvent(with: kind, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
                isARepeat: false, keyCode: code)!
            return (target ?? input).process(key, client: host ?? client)
        }
        func shift(_ code: UInt16 = 56) {
            _ = event(.flagsChanged, .shift, code: code)
            _ = event(.flagsChanged, code: code)
        }

        input.activate(client)
        try checkMode(false, "first activation did not show Chinese")
        shift()
        try checkMode(true, "left Shift did not show English")
        // Emulate the host's normal passthrough when the engine returns false.
        if !event(.keyDown, code: 0, text: "a") { client.insertText("a", replacementRange: client.selectedRange()) }
        try EngineSmoke.check(client.document == "a" && client.preedit.isEmpty, "English icon disagrees with actual input")
        shift(60)
        try checkMode(false, "right Shift did not restore Chinese")
        for char in "nihao" { _ = event(.keyDown, code: 0, text: String(char)) }
        try EngineSmoke.check(!client.preedit.isEmpty, "Chinese icon disagrees with actual composition")
        _ = event(.keyDown, code: 49, text: " ")
        try EngineSmoke.check(client.document == "a你好", "Chinese mode did not commit text")

        let menuItem = input.makeMenu().items[0]
        try EngineSmoke.check(NSApp.sendAction(menuItem.action!, to: menuItem.target, from: menuItem), "English menu action failed")
        try checkMode(true, "menu toggle left a stale status")
        let requests = client.modeSelections.count
        client.selectedMode = InputMode.chinese // The system has already selected this mode.
        input.selectInputMode(InputMode.chinese, client: client)
        try checkMode(false, "native menu did not select Chinese")
        try EngineSmoke.check(client.modeSelections.count == requests, "native callback caused a selection loop")
        _ = event(.flagsChanged, [.shift, .command])
        _ = event(.flagsChanged, .command)
        try checkMode(false, "modified Shift unexpectedly changed mode")
        _ = event(.flagsChanged, .shift)
        _ = event(.keyDown, .shift, code: 0, text: "A")
        _ = event(.flagsChanged)
        try checkMode(false, "Shift typing unexpectedly changed mode")
        _ = event(.keyDown, code: 53, text: "\u{1b}")

        input.toggleEnglish(nil)
        try checkMode(true, "failed to prepare English focus test")
        next.activate(nextClient)
        input.deactivate(client)
        try checkMode(false, "old deactivation changed the new session's mode", host: nextClient)
        input.activate(client)
        next.deactivate(nextClient)
        try checkMode(true, "focus return did not restore this session's English state")
        let beforeMaintenance = client.modeSelections.count
        try Engine.maintain {
            try EngineSmoke.check(client.modeSelections.count == beforeMaintenance, "maintenance changed native mode without an engine")
        }
        try checkMode(true, "engine maintenance lost the English status")
        Engine.ready = false
        try EngineSmoke.check(!event(.keyDown, code: 0, text: "b"), "unready engine swallowed a key")
        client.selectedMode = InputMode.chinese
        input.selectInputMode(InputMode.chinese, client: client)
        Engine.ready = true
        try checkMode(false, "readiness recovery lost native menu selection")
        input.toggleEnglish(nil)

        // Committing before a toggle may transfer focus synchronously. Neither
        // the old toggle nor its late cleanup may modify the new owner's mode.
        input.toggleEnglish(nil)
        for char in "nihao" { _ = event(.keyDown, code: 0, text: String(char)) }
        client.onInsert = { next.activate(nextClient); input.deactivate(client) }
        input.toggleEnglish(nil)
        try checkMode(false, "reentrant toggle changed the next host's mode", host: nextClient)
        next.deactivate(nextClient)
        let previousRequests = client.modeSelections.count
        input.toggleEnglish(nil)
        try EngineSmoke.check(client.modeSelections.count == previousRequests, "inactive toggle selected a native mode")

        // IMK may deliver its mode property before activateServer.
        client.onInsert = nil
        input.selectInputMode(InputMode.english, client: client)
        input.activate(client, mode: InputMode.chinese)
        if !event(.keyDown, code: 0, text: "z") { client.insertText("z", replacementRange: client.selectedRange()) }
        try EngineSmoke.check(client.document.hasSuffix("z") && client.preedit.isEmpty, "pre-activation mode property was lost")
        input.selectInputMode(InputMode.chinese, client: nextClient)
        input.selectInputMode("unrelated.input.mode", client: client)
        if !event(.keyDown, code: 0, text: "x") { client.insertText("x", replacementRange: client.selectedRange()) }
        try EngineSmoke.check(client.document.hasSuffix("zx"), "foreign host/mode changed the engine")
    }
}
