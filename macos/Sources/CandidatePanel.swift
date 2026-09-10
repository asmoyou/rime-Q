import AppKit

final class CandidateCanvas: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    var composition = Composition()
    var select: ((Int) -> Void)?
    var fontSize: CGFloat = 18
    let padding: CGFloat = 8
    private let horizontalPadding: CGFloat = 10
    private let labelGap: CGFloat = 8
    private let commentGap: CGFloat = 8
    var rowHeight: CGFloat { fontSize + 16 }
    private var textFont: NSFont { .systemFont(ofSize: fontSize) }
    private var smallFont: NSFont { .systemFont(ofSize: 12) }
    private var numberFont: NSFont { .monospacedDigitSystemFont(ofSize: 12, weight: .regular) }
    private var secondaryTextColor: NSColor { .labelColor.withAlphaComponent(0.68) }
    private func width(_ string: String, font: NSFont) -> CGFloat {
        ceil((string as NSString).size(withAttributes: [.font: font]).width)
    }
    private var numberWidth: CGFloat {
        width(String(max(1, composition.candidates.count)), font: numberFont)
    }
    private var textX: CGFloat { horizontalPadding + numberWidth + labelGap }

    func measuredSize() -> NSSize {
        guard !composition.candidates.isEmpty else { return .zero }
        let widest = composition.candidates.map {
            width($0.text, font: textFont) + ($0.comment.isEmpty ? 0 : commentGap + width($0.comment, font: smallFont))
        }.max() ?? 0
        return NSSize(width: min(580, ceil(textX + widest + horizontalPadding)),
                      height: CGFloat(composition.candidates.count) * rowHeight + padding * 2)
    }

    func textWidths(for item: CandidateItem) -> (text: CGFloat, comment: CGFloat) {
        let available = max(0, bounds.width - textX - horizontalPadding)
        let naturalText = width(item.text, font: textFont)
        guard !item.comment.isEmpty else { return (available, 0) }
        let minimumText = min(naturalText, max(fontSize * 2, available * 0.65))
        let comment = min(width(item.comment, font: smallFont), max(0, available - minimumText - commentGap))
        return (max(0, available - (comment > 0 ? comment + commentGap : 0)), comment)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, item) in composition.candidates.enumerated() {
            let row = NSRect(x: 4, y: padding + CGFloat(index) * rowHeight, width: bounds.width - 8, height: rowHeight)
            if index == composition.highlighted {
                NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
                NSBezierPath(roundedRect: row, xRadius: 6, yRadius: 6).fill()
            }
            let y = row.minY + (rowHeight - fontSize - 4) / 2
            ("\(index + 1)" as NSString).draw(at: NSPoint(x: horizontalPadding, y: y + 3),
                withAttributes: [.font: numberFont,
                                 .foregroundColor: secondaryTextColor])
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let widths = textWidths(for: item)
            (item.text as NSString).draw(in: NSRect(x: textX, y: y, width: widths.text, height: rowHeight),
                withAttributes: [.font: textFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
            let commentX = textX + min(width(item.text, font: textFont), widths.text) + commentGap
            if widths.comment > 0 {
                (item.comment as NSString).draw(in: NSRect(x: commentX, y: y + 4,
                    width: widths.comment, height: rowHeight),
                    withAttributes: [.font: smallFont,
                                     .foregroundColor: secondaryTextColor, .paragraphStyle: paragraph])
            }
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    func candidateIndex(at point: NSPoint) -> Int? {
        guard bounds.contains(point), point.y >= padding else { return nil }
        let index = Int((point.y - padding) / rowHeight)
        return composition.candidates.indices.contains(index) ? index : nil
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = candidateIndex(at: point) { select?(index) }
    }
}

final class CandidateSurface: NSVisualEffectView {
    let canvas = CandidateCanvas(frame: .zero)

    init() {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        canvas.autoresizingMask = [.width, .height]
        addSubview(canvas)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class CandidatePanel: NSPanel {
    static let shared = CandidatePanel()
    let surface = CandidateSurface()
    var canvas: CandidateCanvas { surface.canvas }
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
        contentView = surface
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
