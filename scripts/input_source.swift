// Developer helper for controlled macOS acceptance tests.
import Carbon
import Foundation

func stringProperty(_ source: TISInputSource, _ key: CFString) -> String {
    guard let pointer = TISGetInputSourceProperty(source, key) else { return "" }
    return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
}

let arguments = CommandLine.arguments
if arguments.count == 1 {
    let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    print(stringProperty(source, kTISPropertyInputSourceID))
} else {
    let includeInstalled = arguments[1] == "list" || arguments[1] == "describe" || arguments[1] == "disable"
    let sources = TISCreateInputSourceList(nil, includeInstalled).takeRetainedValue() as! [TISInputSource]
    if arguments[1] == "disable" && arguments.count == 3 {
        guard arguments[2].hasPrefix("com.asmoyou.inputmethod.RimeQ"),
              let source = sources.first(where: { stringProperty($0, kTISPropertyInputSourceID) == arguments[2] }) else { exit(1) }
        let result = TISDisableInputSource(source)
        print("disable=\(result) \(arguments[2])")
        exit(result == noErr ? 0 : 1)
    } else if arguments[1] == "describe" && arguments.count == 3 {
        for source in sources where stringProperty(source, kTISPropertyInputSourceID) == arguments[2] {
            for key in [kTISPropertyInputSourceType, kTISPropertyInputSourceIsSelectCapable,
                        kTISPropertyInputSourceIsEnableCapable, kTISPropertyInputSourceIsEnabled,
                        kTISPropertyInputModeID, kTISPropertyBundleID] {
                if let key, let value = TISGetInputSourceProperty(source, key) {
                    print("\(key): \(Unmanaged<AnyObject>.fromOpaque(value).takeUnretainedValue())")
                }
            }
        }
    } else if arguments[1] == "list" {
        for source in sources {
            print(stringProperty(source, kTISPropertyInputSourceID) + "\t" + stringProperty(source, kTISPropertyLocalizedName))
        }
    } else {
        guard let source = sources.first(where: { stringProperty($0, kTISPropertyInputSourceID) == arguments[1] }) else {
            fputs("Input source not registered\n", stderr); exit(1)
        }
        // Selection tests must never re-enable an input method. Repeated enable
        // calls can reopen macOS's third-party input-method confirmation UI.
        guard let enabled = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsEnabled),
              CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(enabled).takeUnretainedValue()) else {
            fputs("Input source is not enabled; selection test stopped\n", stderr); exit(1)
        }
        let selected = TISSelectInputSource(source)
        if selected != noErr {
            fputs("Input source selection failed: select=\(selected)\n", stderr); exit(1)
        }
    }
}
