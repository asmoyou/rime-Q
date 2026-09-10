import AppKit

extension NSColor {
    static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: alpha)
    }
    static func adaptive(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            .rgb(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        }
    }
}

enum CandidateSkin: String, CaseIterable {
    case system, paper, mist, jade, rose, midnight, typingCat
    var animated: Bool { self == .typingCat }
    var name: String {
        switch self {
        case .system: return "随系统"
        case .paper: return "纸白"
        case .mist: return "雾蓝"
        case .jade: return "青玉"
        case .rose: return "浅樱"
        case .midnight: return "暮色"
        case .typingCat: return "敲敲猫"
        }
    }
    var summary: String {
        switch self {
        case .system: return "原生材质，随深浅模式变化"
        case .paper: return "温润纸色，安静清晰"
        case .mist: return "清浅蓝调，轻盈柔和"
        case .jade: return "淡绿底色，自然舒适"
        case .rose: return "暖粉与陶色，柔和明亮"
        case .midnight: return "深色背景，低光环境更舒适"
        case .typingCat: return "小猫趴在栏边，陪你一起敲键盘"
        }
    }
    var background: NSColor {
        switch self {
        case .system: return .adaptive(0xF3F4F7, 0x272A31)
        case .paper: return .rgb(0xFAF8F2)
        case .mist: return .rgb(0xEFF4FC)
        case .jade: return .rgb(0xF0F6F2)
        case .rose: return .rgb(0xFCF2EF)
        case .midnight: return .rgb(0x252B38)
        case .typingCat: return .adaptive(0xFBF7EF, 0x2D2D33)
        }
    }
    var text: NSColor {
        switch self {
        case .system: return .labelColor
        case .paper: return .rgb(0x383A3B)
        case .mist: return .rgb(0x293C59)
        case .jade: return .rgb(0x244637)
        case .rose: return .rgb(0x62413B)
        case .midnight: return .rgb(0xEDF1F8)
        case .typingCat: return .adaptive(0x493F36, 0xF2E9DC)
        }
    }
    var accent: NSColor {
        switch self {
        case .system: return .controlAccentColor
        case .paper: return .rgb(0x71624C)
        case .mist: return .rgb(0x386BAF)
        case .jade: return .rgb(0x317458)
        case .rose: return .rgb(0xA45B53)
        case .midnight: return .rgb(0xB5CFF5)
        case .typingCat: return .adaptive(0xB67843, 0xE8BA83)
        }
    }
    var selection: NSColor {
        switch self {
        case .system: return .controlAccentColor.withAlphaComponent(0.15)
        case .paper: return .rgb(0xEBE5D8)
        case .mist: return .rgb(0xD6E4F7)
        case .jade: return .rgb(0xD4E9DC)
        case .rose: return .rgb(0xF1DAD4)
        case .midnight: return .rgb(0x3A4B68)
        case .typingCat: return .adaptive(0xF1E3CE, 0x514539)
        }
    }
    var border: NSColor { text.withAlphaComponent(self == .midnight ? 0.16 : 0.1) }
}

final class AppearancePreferences {
    static let shared = AppearancePreferences(defaults: .standard)
    static let didChange = Notification.Name("RimeQAppearanceDidChange")
    private let defaults: UserDefaults
    init(defaults: UserDefaults) { self.defaults = defaults }
    var skin: CandidateSkin {
        get { CandidateSkin(rawValue: defaults.string(forKey: "candidateSkin") ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: "candidateSkin"); changed() }
    }
    var fontSize: CGFloat {
        get { let value = defaults.double(forKey: "candidateFontSize"); return [16, 18, 20, 22].contains(value) ? value : 18 }
        set { guard [16, 18, 20, 22].contains(newValue) else { return }; defaults.set(Double(newValue), forKey: "candidateFontSize"); changed() }
    }
    private func changed() { NotificationCenter.default.post(name: Self.didChange, object: self) }
}

enum CandidateGeometry {
    static let cornerRadius: CGFloat = 14
    static func petSize(bodyWidth: CGFloat) -> NSSize {
        let width = min(88, max(64, bodyWidth + 12))
        return NSSize(width: width, height: width * 2 / 3)
    }
    static let petOverlap: CGFloat = 2

    static func petFrame(above body: NSRect, visible: NSRect) -> NSRect {
        let size = petSize(bodyWidth: body.width)
        let preferredX = body.width < size.width + 8 ? body.midX - size.width / 2 : body.maxX - size.width - 4
        return NSRect(x: max(visible.minX, min(preferredX, visible.maxX - size.width)),
                      y: body.maxY - petOverlap, width: size.width, height: size.height)
    }

    static func placement(size: NSSize, caret: NSRect, visible: NSRect, animated: Bool) -> (body: NSRect, pet: NSRect?) {
        let extra = animated ? petSize(bodyWidth: size.width).height - petOverlap : 0
        // Extremely small viewports retain usable text, without clipping a pet.
        let showPet = animated && size.height + extra <= visible.height
        let totalHeight = size.height + (showPet ? extra : 0)
        let x = max(visible.minX, min(caret.minX, visible.maxX - size.width))
        var y = caret.minY - totalHeight - 5
        if y < visible.minY { y = caret.maxY + 5 }
        y = max(visible.minY, min(y, visible.maxY - totalHeight))
        let body = NSRect(origin: NSPoint(x: x, y: y), size: size)
        return (body, showPet ? petFrame(above: body, visible: visible) : nil)
    }
    // NSVisualEffectView's material is rendered separately from its layer.
    // Mask that material explicitly, using a reusable nine-slice alpha image.
    static let materialMask: NSImage = {
        let r = cornerRadius, size = NSSize(width: r * 2 + 1, height: r * 2 + 1)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        image.resizingMode = .stretch
        return image
    }()
}
