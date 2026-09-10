import AppKit
import InputMethodKit
import QRimeBridge

// Controlled IMK host used only by --controller-smoke, never a user's application.
final class MockTextClient: NSObject, IMKTextInput {
    var document = ""
    var preedit = ""
    var onInsert: (() -> Void)?
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
    func selectMode(_ modeIdentifier: String!) {}
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
        print("PASS controller: marked text, space, mouse, cancellation, panel ownership, reentrant focus")
    }
}
