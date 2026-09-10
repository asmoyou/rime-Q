import AppKit

final class CandidateCanvas: NSView {
    override var isFlipped: Bool { true }
    var composition = Composition()
    var select: ((Int) -> Void)?
    var fontSize: CGFloat = 18
    let padding: CGFloat = 12
    var rowHeight: CGFloat { fontSize + 16 }

    func measuredSize() -> NSSize {
        let font = NSFont.systemFont(ofSize: fontSize)
        let widest = composition.candidates.map {
            ($0.text as NSString).size(withAttributes: [.font: font]).width +
            ($0.comment as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
        }.max() ?? 120
        return NSSize(width: min(580, max(190, widest + 76)),
                      height: CGFloat(composition.candidates.count) * rowHeight + padding * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        for (index, item) in composition.candidates.enumerated() {
            let row = NSRect(x: 6, y: padding + CGFloat(index) * rowHeight, width: bounds.width - 12, height: rowHeight)
            if index == composition.highlighted {
                NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
                NSBezierPath(roundedRect: row, xRadius: 6, yRadius: 6).fill()
            }
            let y = row.minY + (rowHeight - fontSize - 4) / 2
            ("\(index + 1)" as NSString).draw(at: NSPoint(x: 16, y: y + 3),
                withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                                 .foregroundColor: NSColor.secondaryLabelColor])
            let font = NSFont.systemFont(ofSize: fontSize)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            (item.text as NSString).draw(in: NSRect(x: 38, y: y, width: bounds.width - 54, height: rowHeight),
                withAttributes: [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
            let commentX = 48 + (item.text as NSString).size(withAttributes: [.font: font]).width
            if commentX + 30 < bounds.width {
                (item.comment as NSString).draw(in: NSRect(x: commentX, y: y + 4,
                    width: bounds.width - commentX - 12, height: rowHeight),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 12),
                                     .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph])
            }
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard point.y >= padding else { return }
        let index = Int((point.y - padding) / rowHeight)
        if composition.candidates.indices.contains(index) { select?(index) }
    }
}

final class CandidatePanel: NSPanel {
    static let shared = CandidatePanel()
    let canvas = CandidateCanvas(frame: .zero)
    private var owner: ObjectIdentifier?
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = canvas
    }

    func show(_ composition: Composition, anchor: NSRect, owner: ObjectIdentifier, select: @escaping (Int) -> Void) {
        guard !composition.candidates.isEmpty else { hide(owner: owner); return }
        self.owner = owner
        canvas.composition = composition
        canvas.select = select
        let configured = UserDefaults.standard.double(forKey: "candidateFontSize")
        canvas.fontSize = [16.0, 18.0, 20.0, 22.0].contains(configured) ? configured : 18
        let size = canvas.measuredSize()
        let plausible = anchor.origin.x.isFinite && anchor.origin.y.isFinite && anchor.height.isFinite && anchor.height > 0
        let caret = plausible ? anchor : NSRect(origin: NSEvent.mouseLocation, size: NSSize(width: 1, height: 20))
        let screen = NSScreen.screens.first { $0.frame.contains(caret.origin) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let x = max(visible.minX, min(caret.minX, visible.maxX - size.width))
        var y = caret.minY - size.height - 5
        if y < visible.minY { y = caret.maxY + 5 }
        y = max(visible.minY, min(y, visible.maxY - size.height))
        setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: false)
        canvas.needsDisplay = true
        orderFrontRegardless()
    }

    func hide(owner: ObjectIdentifier) {
        guard self.owner == owner else { return }
        self.owner = nil
        canvas.select = nil
        orderOut(nil)
    }
}
