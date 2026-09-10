import AppKit

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
        print("PASS candidate layout: single=\(single.width)pt two=\(double.width)pt annotated=\(annotated.width)pt; hit testing and long-text limits")
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
