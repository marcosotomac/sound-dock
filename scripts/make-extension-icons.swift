// Renders the browser extension's icons: the menu bar symbol on a soft gradient tile.
// Usage: swift scripts/make-extension-icons.swift BrowserExtension/icons
import AppKit

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
for size in [16, 32, 48, 128] {
    let pixels = CGFloat(size)
    let image = NSImage(size: NSSize(width: pixels, height: pixels), flipped: false) { rect in
        let inset = rect.insetBy(dx: pixels * 0.06, dy: pixels * 0.06)
        let tile = NSBezierPath(roundedRect: inset, xRadius: inset.width * 0.24, yRadius: inset.height * 0.24)
        NSGradient(starting: NSColor(srgbRed: 0.42, green: 0.36, blue: 0.98, alpha: 1),
                   ending: NSColor(srgbRed: 0.93, green: 0.36, blue: 0.62, alpha: 1))?.draw(in: tile, angle: -60)
        let configuration = NSImage.SymbolConfiguration(pointSize: pixels * 0.5, weight: .bold)
            .applying(.init(paletteColors: [.white]))
        if let symbol = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
            let s = symbol.size
            symbol.draw(in: NSRect(x: (pixels - s.width) / 2, y: (pixels - s.height) / 2, width: s.width, height: s.height))
        }
        return true
    }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: folder.appending(path: "\(size).png"))
}
