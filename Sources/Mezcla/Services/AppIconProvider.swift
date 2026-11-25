import AppKit
import UniformTypeIdentifiers

/// Real app icons, rasterized once at the size the panel draws them.
///
/// Workspace icons carry representations up to 1024 px. Rendering a single small bitmap keeps memory
/// flat and makes redraws free.
@MainActor
final class AppIconProvider {
    private let pointSize: CGFloat
    private var cache: [String: NSImage] = [:]

    init(pointSize: CGFloat = 20) {
        self.pointSize = pointSize
    }

    func icon(forPath path: String?) -> NSImage {
        let key = path ?? ""
        if let cached = cache[key] {
            return cached
        }
        let source = path.map { NSWorkspace.shared.icon(forFile: $0) } ?? NSWorkspace.shared.icon(for: .unixExecutable)
        let icon = rasterize(source)
        cache[key] = icon
        return icon
    }

    /// A site's favicon at 16 pt, or `nil` when it has none or the data is not an image.
    func favicon(_ data: Data?) -> NSImage? {
        guard let data else { return nil }
        let key = "favicon:\(data.hashValue)"
        if let cached = cache[key] {
            return cached
        }
        guard let image = NSImage(data: data) else { return nil }
        let icon = rasterize(image, pointSize: 16)
        cache[key] = icon
        return icon
    }

    private func rasterize(_ image: NSImage, pointSize: CGFloat? = nil) -> NSImage {
        let pointSize = pointSize ?? self.pointSize
        let scale: CGFloat = 2
        let pixels = Int(pointSize * scale)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return image }

        let size = NSSize(width: pointSize, height: pointSize)
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()

        let result = NSImage(size: size)
        result.addRepresentation(bitmap)
        return result
    }
}
