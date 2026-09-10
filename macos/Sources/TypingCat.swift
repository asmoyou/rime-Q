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
        transform.scaleX(by: rect.width / 72, yBy: rect.height / 48)
        transform.concat()
        let outline = NSColor.adaptive(0x6B5541, 0xC6AE91)
        let fur = NSColor.adaptive(0xE9CDA8, 0xB69B79)
        let face = NSColor.adaptive(0xFFF5E3, 0xEFDDC4)
        func shape(_ path: NSBezierPath, _ color: NSColor, stroke: Bool = true) {
            color.setFill(); path.fill()
            if stroke { outline.setStroke(); path.lineWidth = 1.2; path.stroke() }
        }
        func oval(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: NSColor, stroke: Bool = false) {
            shape(NSBezierPath(ovalIn: NSRect(x: x, y: y, width: w, height: h)), color, stroke: stroke)
        }
        func line(_ points: [NSPoint], color: NSColor = .rgb(0x5E4937), width: CGFloat = 1.2) {
            let path = NSBezierPath(); path.move(to: points[0]); points.dropFirst().forEach { path.line(to: $0) }
            path.lineCapStyle = .round; path.lineJoinStyle = .round; path.lineWidth = width
            color.setStroke(); path.stroke()
        }
        // Tail, shoulders, ears and face.
        let tail = NSBezierPath(); tail.move(to: NSPoint(x: 54, y: 33))
        tail.curve(to: NSPoint(x: 64, y: 23), controlPoint1: NSPoint(x: 69, y: 38), controlPoint2: NSPoint(x: 72, y: 23))
        fur.setStroke(); tail.lineWidth = 5; tail.lineCapStyle = .round; tail.stroke()
        shape(NSBezierPath(roundedRect: NSRect(x: 21, y: 22, width: 34, height: 20), xRadius: 9, yRadius: 9), fur)
        let head = NSBezierPath()
        head.move(to: NSPoint(x: 20, y: 20)); head.line(to: NSPoint(x: 20, y: 5))
        head.curve(to: NSPoint(x: 24, y: 3), controlPoint1: NSPoint(x: 20, y: 2), controlPoint2: NSPoint(x: 22, y: 1))
        head.line(to: NSPoint(x: 31, y: 9)); head.line(to: NSPoint(x: 43, y: 9)); head.line(to: NSPoint(x: 50, y: 3))
        head.curve(to: NSPoint(x: 54, y: 5), controlPoint1: NSPoint(x: 52, y: 1), controlPoint2: NSPoint(x: 54, y: 2))
        head.line(to: NSPoint(x: 55, y: 20))
        head.curve(to: NSPoint(x: 20, y: 20), controlPoint1: NSPoint(x: 55, y: 39), controlPoint2: NSPoint(x: 19, y: 39))
        head.close(); shape(head, fur)
        oval(25, 18, 24, 15, face)
        line([NSPoint(x: 24, y: 8), NSPoint(x: 27, y: 12)], color: .rgb(0xCD9D87), width: 2)
        line([NSPoint(x: 50, y: 8), NSPoint(x: 47, y: 12)], color: .rgb(0xCD9D87), width: 2)
        // Eyes and tiny muzzle remain still: the paws carry the motion.
        oval(28, 20, 2.5, 3.5, .rgb(0x49372C)); oval(44, 20, 2.5, 3.5, .rgb(0x49372C))
        oval(35, 24, 3, 2, .rgb(0xAD7369))
        line([NSPoint(x: 37, y: 26), NSPoint(x: 34, y: 28)])
        line([NSPoint(x: 37, y: 26), NSPoint(x: 40, y: 28)])
        oval(24, 25, 5, 2, .rgb(0xE3B0A0)); oval(46, 25, 5, 2, .rgb(0xE3B0A0))
        // Keyboard is fully inside the decoration area, above candidate rows.
        shape(NSBezierPath(roundedRect: NSRect(x: 12, y: 36, width: 49, height: 10), xRadius: 3, yRadius: 3),
              NSColor.adaptive(0xE0DCD5, 0x767779))
        for row in 0..<2 {
            for column in 0..<8 {
                shape(NSBezierPath(roundedRect: NSRect(x: 16 + column * 5, y: 38 + row * 3, width: 3, height: 2),
                                   xRadius: 0.6, yRadius: 0.6), NSColor.adaptive(0xFAF8F4, 0xDAD7D1), stroke: false)
            }
        }
        oval(23, pose == 1 ? 34 : 29, 10, 7, face, stroke: true)
        oval(42, pose == 2 ? 34 : 29, 10, 7, face, stroke: true)
        if pose != 0 {
            let x: CGFloat = pose == 1 ? 27 : 47
            line([NSPoint(x: x - 6, y: 33), NSPoint(x: x - 8, y: 30)], color: .rgb(0xB98A57), width: 1)
            line([NSPoint(x: x + 6, y: 33), NSPoint(x: x + 8, y: 30)], color: .rgb(0xB98A57), width: 1)
        }
    }
}
