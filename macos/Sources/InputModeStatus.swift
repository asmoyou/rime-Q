import Carbon

// Public IMK input modes own the system input menu icon. No extra status item.
enum InputMode {
    static let chinese = Product.identifier + ".Hans"
    static let english = Product.identifier + ".Latin"
    static let identifiers = [chinese, english]
    static func identifier(english: Bool) -> String { english ? self.english : chinese }
    static func isEnglish(_ identifier: String) -> Bool? {
        switch identifier {
        case chinese: return false
        case english: return true
        default: return nil
        }
    }
    static var current: String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        let identifier = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
        return identifiers.contains(identifier) ? identifier : nil
    }
}
