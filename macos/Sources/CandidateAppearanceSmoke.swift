import AppKit
import ImageIO
import UniformTypeIdentifiers

private final class CandidatePreviewBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSGradient(starting: NSColor(calibratedRed: 0.62, green: 0.78, blue: 0.92, alpha: 1),
                   ending: NSColor(calibratedRed: 0.95, green: 0.79, blue: 0.62, alpha: 1))?.draw(in: bounds, angle: 25)
        NSColor.white.withAlphaComponent(0.4).setFill()
        for x in stride(from: CGFloat(0), to: bounds.width, by: 72) {
            NSBezierPath(rect: NSRect(x: x, y: 0, width: 28, height: bounds.height)).fill()
        }
    }
}

enum CandidateAppearanceSmoke {
    static func run() throws {
        let canvas = CandidateCanvas(frame: .zero)
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "RimeQ.CandidateAppearance", code: 1,
                                     userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        canvas.composition.candidates = [.init(text: "你", comment: ""), .init(text: "呢", comment: "")]
        let single = canvas.measuredSize()
        try require(single.width < 100, "Single-character candidates are padded to a fixed wide width")
        canvas.setFrameSize(single)
        try require(canvas.candidateIndex(at: NSPoint(x: single.width / 2, y: 0)) == nil, "Top padding selected a candidate")
        try require(canvas.candidateIndex(at: NSPoint(x: single.width / 2, y: canvas.padding + 1)) == 0, "First-row hit test failed")
        try require(canvas.candidateIndex(at: NSPoint(x: single.width / 2, y: canvas.padding + canvas.rowHeight + 1)) == 1, "Second-row hit test failed")
        try require(canvas.candidateIndex(at: NSPoint(x: single.width / 2, y: single.height - 1)) == nil, "Bottom padding selected a candidate")
        canvas.composition.candidates = [.init(text: "你好", comment: "")]
        let double = canvas.measuredSize()
        try require(double.width > single.width && double.width < 120, "Two-character candidates did not size to text")
        canvas.composition.candidates = [.init(text: "你好", comment: "nǐ hǎo")]
        let annotated = canvas.measuredSize()
        try require(annotated.width > double.width, "Comment width was ignored")
        canvas.setFrameSize(annotated)
        try require(canvas.textWidths(for: canvas.composition.candidates[0]).comment > 0, "Comment did not receive drawing space")
        canvas.composition.candidates = [.init(text: String(repeating: "中文", count: 100), comment: "annotation")]
        try require(canvas.measuredSize().width <= 580, "Long candidates exceeded the width limit")
        canvas.setFrameSize(canvas.measuredSize())
        let widths = canvas.textWidths(for: canvas.composition.candidates[0])
        try require(widths.text > 0 && widths.comment >= 0 && widths.text + widths.comment < canvas.bounds.width,
                    "Long text/comment geometry overlaps")
        canvas.composition.candidates = []
        try require(canvas.measuredSize() == .zero, "Empty candidate list retained a visible layout")
        let surface = CandidateSurface()
        try require(surface.maskImage != nil, "Native material lacks a rounded mask")
        let mask = CandidateGeometry.materialMask
        guard let data = mask.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) else {
            throw LexiconError.message("Candidate mask could not render")
        }
        try require((bitmap.colorAt(x: 0, y: 0)?.alphaComponent ?? 1) < 0.1, "Candidate material corner is opaque")
        try require((bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.alphaComponent ?? 0) > 0.9,
                    "Candidate material center is transparent")
        let suite = "RimeQ.CandidateSmoke." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppearancePreferences(defaults: defaults)
        let panel = CandidatePanel(preferences: preferences), owner = NSObject()
        defer { panel.hide(owner: ObjectIdentifier(owner)) }
        for skin in CandidateSkin.allCases {
            preferences.skin = skin
            panel.show(Composition(candidates: [.init(text: "你好", comment: ""), .init(text: "拟好", comment: "")]),
                       anchor: NSRect(x: 100, y: 400, width: 1, height: 20), owner: ObjectIdentifier(owner), select: { _ in })
            try require(panel.canvas.skin == skin && panel.surface.skin == skin, "Selected skin did not reach live candidate panel")
            try require(panel.contentView === panel.surface && panel.surface.maskImage != nil, "Material mask is not the window content view")
        }
        defaults.set("unknown", forKey: "candidateSkin")
        try require(preferences.skin == .system, "Unknown skin did not fall back to system")
        preferences.skin = .typingCat
        panel.show(Composition(candidates: [.init(text: "你", comment: "")]),
            anchor: NSRect(x: 100, y: 400, width: 1, height: 20), owner: ObjectIdentifier(owner), keyActivity: true, select: { _ in })
        try require(panel.canvas.candidateIndex(at: NSPoint(x: 20, y: 25)) == nil, "Cat decoration selected a candidate")
        try require(panel.canvas.candidateIndex(at: NSPoint(x: 20, y: 49)) == 0, "Cat skin first candidate hit test failed")
        let cat = panel.surface.cat
        cat.tap(reduceMotion: false); let firstPose = cat.pose
        cat.tap(reduceMotion: false)
        try require(cat.pose != firstPose && cat.isAnimating, "Typing cat did not alternate paws")
        RunLoop.current.run(until: Date().addingTimeInterval(0.22))
        try require(cat.pose == 0 && !cat.isAnimating, "Typing cat did not stop after idle")
        cat.tap(reduceMotion: true)
        try require(cat.pose == 0 && !cat.isAnimating, "Typing cat ignored Reduce Motion")
        cat.tap(reduceMotion: false); panel.hide(owner: ObjectIdentifier(owner))
        try require(!cat.isAnimating, "Hidden candidate panel kept animating")
        print("PASS candidate layout: single=\(single.width)pt two=\(double.width)pt annotated=\(annotated.width)pt; hit testing and long-text limits")
        print("PASS candidate appearance: rounded corners, saved skins, typing cat key poses/idle/hide/Reduce Motion and hit testing")
    }

    static func render(to directory: URL) throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "RimeQ.CandidateRender." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppearancePreferences(defaults: defaults)
        let panel = CandidatePanel(preferences: preferences), owner = NSObject()
        let backdrop = NSWindow(contentRect: NSRect(x: 120, y: 180, width: 500, height: 360),
                                styleMask: [.borderless], backing: .buffered, defer: false)
        backdrop.contentView = CandidatePreviewBackground(frame: backdrop.contentView!.bounds)
        backdrop.level = .floating; backdrop.orderFrontRegardless()
        defer { panel.hide(owner: ObjectIdentifier(owner)); backdrop.close() }
        let canCapture = CGPreflightScreenCaptureAccess()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            panel.appearance = NSAppearance(named: appearance)
            for skin in CandidateSkin.allCases {
                preferences.skin = skin
                panel.show(Composition(candidates: [.init(text: "你好世界", comment: ""), .init(text: "你好", comment: ""), .init(text: "拟好", comment: "")]),
                           anchor: NSRect(x: 260, y: 450, width: 1, height: 20), owner: ObjectIdentifier(owner), select: { _ in })
                RunLoop.current.run(until: Date().addingTimeInterval(0.12))
                let name = "\(skin.rawValue)-\(appearance == .aqua ? "light" : "dark")"
                if canCapture {
                    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    process.arguments = ["-x", "-o", "-l", String(panel.windowNumber), directory.appendingPathComponent(name + ".png").path]
                    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
                    try process.run(); process.waitUntilExit()
                    guard process.terminationStatus == 0 else { throw LexiconError.message("候选窗口截图失败。") }
                } else {
                    let view = CandidatePreviewView(rows: 3, height: 180)
                    view.frame = NSRect(x: 0, y: 0, width: 300, height: 180); view.skin = skin
                    view.appearance = NSAppearance(named: appearance); view.layoutSubtreeIfNeeded()
                    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw LexiconError.message("候选预览渲染失败。") }
                    view.appearance!.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
                    try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + "-preview.png"))
                }
            }
        }
        try renderCatAnimation(to: directory.appendingPathComponent("typing-cat.gif"))
        print(canCapture ? "PASS captured live rounded candidate windows in all skins, light/dark" : "Rendered candidate previews; live window capture unavailable without Screen Recording access")
    }

    private static func renderCatAnimation(to url: URL) throws {
        let canvas = CandidateCanvas(frame: .zero)
        canvas.skin = .typingCat
        canvas.composition.candidates = [.init(text: "你好世界", comment: ""), .init(text: "你好", comment: ""), .init(text: "拟好", comment: "")]
        canvas.frame.size = canvas.measuredSize()
        let size = NSSize(width: canvas.bounds.width * 2, height: canvas.bounds.height * 2)
        let poses = [0, 1, 0, 2, 0, 1, 0, 2, 0]
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, poses.count, nil) else {
            throw LexiconError.message("无法创建小猫动画预览。")
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for pose in poses {
            let appearance = NSAppearance(named: .aqua)!
            var bitmap: NSBitmapImageRep?
            appearance.performAsCurrentDrawingAppearance {
                let image = NSImage(size: size, flipped: true) { _ in
                    NSGraphicsContext.saveGraphicsState()
                    defer { NSGraphicsContext.restoreGraphicsState() }
                    let scale = NSAffineTransform(); scale.scale(by: 2); scale.concat()
                    CandidateSkin.typingCat.background.setFill()
                    NSBezierPath(roundedRect: canvas.bounds, xRadius: 14, yRadius: 14).fill()
                    canvas.draw(canvas.bounds)
                    TypingCatView.draw(in: NSRect(x: canvas.bounds.width - 72, y: 2, width: 66, height: 44), pose: pose)
                    return true
                }
                if let tiff = image.tiffRepresentation { bitmap = NSBitmapImageRep(data: tiff) }
            }
            guard let cgImage = bitmap?.cgImage else { throw LexiconError.message("小猫预览帧绘制失败。") }
            CGImageDestinationAddImage(destination, cgImage,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: pose == 0 ? 0.24 : 0.14]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw LexiconError.message("动画预览保存失败。") }
    }

    static func preview(dark: Bool) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 290),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Rime Q 候选栏预览"
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let background = CandidatePreviewBackground(frame: window.contentView!.bounds)
        window.contentView = background
        let cases: [(String, [CandidateItem])] = [
            ("单字", [.init(text: "你", comment: ""), .init(text: "呢", comment: ""), .init(text: "拟", comment: "")]),
            ("双字", [.init(text: "你好", comment: ""), .init(text: "您好", comment: ""), .init(text: "拟好", comment: "")]),
            ("带注释", [.init(text: "你好", comment: "nǐ hǎo"), .init(text: "拟好", comment: ""), .init(text: "呢", comment: "ní")])
        ]
        for (index, item) in cases.enumerated() {
            let surface = CandidateSurface()
            surface.blendingMode = .withinWindow
            surface.canvas.composition.candidates = item.1
            let size = surface.canvas.measuredSize()
            surface.frame = NSRect(origin: NSPoint(x: 35 + CGFloat(index) * 200, y: 65), size: size)
            background.addSubview(surface)
            let label = NSTextField(labelWithString: "\(item.0) · \(Int(size.width)) pt")
            label.frame = NSRect(x: surface.frame.minX, y: 220, width: 180, height: 22)
            label.font = .systemFont(ofSize: 14, weight: .medium)
            label.textColor = .black
            background.addSubview(label)
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        print("candidate-preview pid=\(ProcessInfo.processInfo.processIdentifier) window=\(window.windowNumber)")
        fflush(stdout)
        app.run()
        _ = window
    }
}
