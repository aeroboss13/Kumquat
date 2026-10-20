import AppKit
// Draws the app icon: a kumquat-orange squircle with circular arrows.
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    let inset = rect.insetBy(dx: 100, dy: 100)
    let path = NSBezierPath(roundedRect: inset, xRadius: 185, yRadius: 185)
    NSGradient(colors: [NSColor(red: 1, green: 0.72, blue: 0.28, alpha: 1), NSColor(red: 0.98, green: 0.42, blue: 0.12, alpha: 1)])!
        .draw(in: path, angle: -70)
    let config = NSImage.SymbolConfiguration(pointSize: 470, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let s = symbol.size
        symbol.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
    }
    // Leaf
    let leaf = NSBezierPath()
    leaf.move(to: NSPoint(x: 640, y: 850)); leaf.curve(to: NSPoint(x: 820, y: 900), controlPoint1: NSPoint(x: 700, y: 940), controlPoint2: NSPoint(x: 780, y: 950))
    leaf.curve(to: NSPoint(x: 640, y: 850), controlPoint1: NSPoint(x: 780, y: 840), controlPoint2: NSPoint(x: 700, y: 820))
    NSColor(red: 0.3, green: 0.72, blue: 0.3, alpha: 1).setFill(); leaf.fill()
    return true
}
let out = CommandLine.arguments[1]
for px in [16, 32, 64, 128, 256, 512, 1024] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    for (name, scale) in [("icon_\(px)x\(px).png", 1), ("icon_\(px / 2)x\(px / 2)@2x.png", 2)] where px / scale >= 16 && px / scale <= 512 {
        try! data.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
    }
}
