import AppKit
import Foundation

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = destination.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for pointSize in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let size = pointSize * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor(srgbRed: 0.19, green: 0.28, blue: 0.46, alpha: 1).setFill()
        let side = CGFloat(size)
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: side, height: side),
                     xRadius: side * 0.22, yRadius: side * 0.22).fill()
        let font = NSFont.systemFont(ofSize: side * 0.71, weight: .medium)
        let text: NSString = "Q"
        let measured = text.size(withAttributes: [.font: font])
        text.draw(at: NSPoint(x: (side - measured.width) / 2, y: (side - measured.height) / 2),
                  withAttributes: [.font: font, .foregroundColor: NSColor.white])
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 1 ? "" : "@2x"
        try bitmap.representation(using: .png, properties: [:])!.write(
            to: iconset.appendingPathComponent("icon_\(pointSize)x\(pointSize)\(suffix).png"))
    }
}

var bounds = CGRect(x: 0, y: 0, width: 18, height: 18)
let consumer = CGDataConsumer(url: destination.appendingPathComponent("menu.pdf") as CFURL)!
let context = CGContext(consumer: consumer, mediaBox: &bounds, nil)!
context.beginPDFPage(nil)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
("Q" as NSString).draw(at: NSPoint(x: 2, y: 0), withAttributes: [.font: NSFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: NSColor.black])
NSGraphicsContext.restoreGraphicsState()
context.endPDFPage()
context.closePDF()
