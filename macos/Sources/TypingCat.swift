import AppKit

/// Drawn locally as vectors. A keystroke changes pose; one short timer returns
/// to rest. No animation loop, keyboard monitor, or stored input is needed.
final class TypingCatView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    private(set) var pose = 0
    private var lastPaw = 1
    private var reset: Timer?
    var isAnimating: Bool { reset != nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func tap(reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
        guard !reduceMotion else { rest(); return }
        lastPaw = lastPaw == 1 ? 2 : 1
        pose = lastPaw
        needsDisplay = true
        reset?.invalidate()
        reset = Timer(timeInterval: 0.16, repeats: false) { [weak self] _ in self?.rest() }
        RunLoop.main.add(reset!, forMode: .common)
    }
    func rest() {
        reset?.invalidate(); reset = nil
        pose = 0; needsDisplay = true
    }
    deinit { reset?.invalidate() }

    override func draw(_ dirtyRect: NSRect) { Self.draw(in: bounds, pose: pose) }
    static func draw(in rect: NSRect, pose: Int) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.minY)
        transform.scaleX(by: rect.width / 96, yBy: rect.height / 64)
        transform.concat()
        let outline = NSColor.rgb(0x9E7460)
        let fur = NSColor.adaptive(0xFFDBAE, 0xF1C896)
        let face = NSColor.adaptive(0xFFF9EF, 0xFBEAD1)
        let peach = NSColor.rgb(0xECA991)
        let ink = NSColor.rgb(0x62473F)
        func shape(_ path: NSBezierPath, _ color: NSColor, stroke: Bool = true) {
            color.setFill(); path.fill()
            if stroke { outline.setStroke(); path.lineWidth = 1.4; path.lineJoinStyle = .round; path.stroke() }
        }
        func oval(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: NSColor, stroke: Bool = false) {
            shape(NSBezierPath(ovalIn: NSRect(x: x, y: y, width: w, height: h)), color, stroke: stroke)
        }
        func line(_ points: [NSPoint], color: NSColor = .rgb(0x9E7460), width: CGFloat = 1.2) {
            let path = NSBezierPath(); path.move(to: points[0]); points.dropFirst().forEach { path.line(to: $0) }
            path.lineCapStyle = .round; path.lineJoinStyle = .round; path.lineWidth = width
            color.setStroke(); path.stroke()
        }
        // A long, low body and curled tail make this a cat lying on the rim.
        let tail = NSBezierPath(); tail.move(to: NSPoint(x: 72, y: 45))
        tail.curve(to: NSPoint(x: 83, y: pose == 0 ? 21 : 19),
                   controlPoint1: NSPoint(x: 99, y: 43), controlPoint2: NSPoint(x: 91, y: 16))
        tail.lineCapStyle = .round
        outline.setStroke(); tail.lineWidth = 8; tail.stroke()
        fur.setStroke(); tail.lineWidth = 5.4; tail.stroke()
        oval(35, 29, 48, 27, fur, stroke: true)
        oval(60, 38, 15, 13, .rgb(0xF1BB83))
        oval(68, 48, 14, 9, face, stroke: true)
        // Oversized cheeks, soft ear tips, tiny brows and bright eyes.
        NSGraphicsContext.saveGraphicsState()
        let bob = NSAffineTransform(); bob.translateX(by: 0, yBy: pose == 0 ? 0 : 0.7); bob.concat()
        let head = NSBezierPath()
        head.move(to: NSPoint(x: 13, y: 27))
        head.curve(to: NSPoint(x: 15, y: 10), controlPoint1: NSPoint(x: 12, y: 21), controlPoint2: NSPoint(x: 11, y: 10))
        head.curve(to: NSPoint(x: 26, y: 17), controlPoint1: NSPoint(x: 18, y: 8), controlPoint2: NSPoint(x: 22, y: 14))
        head.curve(to: NSPoint(x: 46, y: 16), controlPoint1: NSPoint(x: 32, y: 13), controlPoint2: NSPoint(x: 40, y: 13))
        head.curve(to: NSPoint(x: 57, y: 10), controlPoint1: NSPoint(x: 52, y: 9), controlPoint2: NSPoint(x: 56, y: 7))
        head.curve(to: NSPoint(x: 59, y: 27), controlPoint1: NSPoint(x: 60, y: 12), controlPoint2: NSPoint(x: 59, y: 20))
        head.curve(to: NSPoint(x: 36, y: 51), controlPoint1: NSPoint(x: 69, y: 44), controlPoint2: NSPoint(x: 52, y: 52))
        head.curve(to: NSPoint(x: 13, y: 27), controlPoint1: NSPoint(x: 18, y: 52), controlPoint2: NSPoint(x: 5, y: 44))
        head.close(); shape(head, fur)
        oval(14, 28, 44, 21, face)
        line([NSPoint(x: 17, y: 15), NSPoint(x: 21, y: 20)], color: peach, width: 3.5)
        line([NSPoint(x: 55, y: 15), NSPoint(x: 51, y: 20)], color: peach, width: 3.5)
        line([NSPoint(x: 33, y: 18), NSPoint(x: 35, y: 22)], color: .rgb(0xEAB783), width: 2)
        line([NSPoint(x: 40, y: 18), NSPoint(x: 39, y: 22)], color: .rgb(0xEAB783), width: 2)
        oval(23, 29, 5, 6.5, ink); oval(45, 29, 5, 6.5, ink)
        oval(24, 29.5, 1.8, 2, .white); oval(46, 29.5, 1.8, 2, .white)
        line([NSPoint(x: 23, y: 25.5), NSPoint(x: 26, y: 25)], width: 1)
        line([NSPoint(x: 46, y: 25), NSPoint(x: 49, y: 25.5)], width: 1)
        oval(16, 36, 9, 4.5, peach.withAlphaComponent(0.7))
        oval(49, 36, 9, 4.5, peach.withAlphaComponent(0.7))
        oval(34, 35, 4.5, 3, .rgb(0xCA8D80))
        let smile = NSBezierPath(); smile.move(to: NSPoint(x: 30, y: 39))
        smile.curve(to: NSPoint(x: 36, y: 38), controlPoint1: NSPoint(x: 30, y: 43), controlPoint2: NSPoint(x: 35, y: 43))
        smile.curve(to: NSPoint(x: 42, y: 39), controlPoint1: NSPoint(x: 37, y: 43), controlPoint2: NSPoint(x: 42, y: 43))
        ink.setStroke(); smile.lineWidth = 1.2; smile.lineCapStyle = .round; smile.stroke()
        NSGraphicsContext.restoreGraphicsState()
        // The keyboard sits on the panel's outside edge, with soft paws above it.
        shape(NSBezierPath(roundedRect: NSRect(x: 15, y: 54, width: 57, height: 8), xRadius: 3, yRadius: 3),
              NSColor.adaptive(0xF1E4D8, 0xB6A398))
        for row in 0..<2 {
            for column in 0..<8 {
                shape(NSBezierPath(roundedRect: NSRect(x: 20 + CGFloat(column) * 6, y: 56 + CGFloat(row) * 2.5, width: 4, height: 1.5),
                                   xRadius: 0.6, yRadius: 0.6), face, stroke: false)
            }
        }
        for (index, x) in [CGFloat(22), 46].enumerated() {
            let down = pose == index + 1
            let y: CGFloat = down ? 50 : 46
            oval(x, y, 15, 11, face, stroke: true)
            line([NSPoint(x: x + 5, y: y + 7), NSPoint(x: x + 5, y: y + 9)], width: 0.8)
            line([NSPoint(x: x + 9, y: y + 7), NSPoint(x: x + 9, y: y + 9)], width: 0.8)
            if pose != 0 && !down { oval(x + 5, y + 4, 5, 3, peach.withAlphaComponent(0.65)) }
        }
        if pose != 0 {
            let x: CGFloat = pose == 1 ? 24 : 59
            line([NSPoint(x: x, y: 48), NSPoint(x: x - 2, y: 45)], color: peach, width: 1.4)
            // A tiny warm sparkle flickers only for the short typing pose.
            line([NSPoint(x: 73, y: 16), NSPoint(x: 73, y: 23)], color: .rgb(0xD6A562), width: 1.5)
            line([NSPoint(x: 70, y: 19.5), NSPoint(x: 76, y: 19.5)], color: .rgb(0xD6A562), width: 1.5)
        }
    }
}
