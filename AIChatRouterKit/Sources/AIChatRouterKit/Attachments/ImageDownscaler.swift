import AppKit

/// Downscales an attached image so its longest edge fits within a maximum before
/// it's persisted or sent for inference — keeps stored blobs small and matches
/// what the vision model needs regardless. Returns the original data unchanged
/// when it's already within the limit (never re-encodes unnecessarily), and
/// `nil` if the data doesn't decode as an image at all.
public struct ImageDownscaler: Sendable {
    public static let maxLongestEdge: CGFloat = 1568

    public init() {}

    public func downscale(_ data: Data, maxLongestEdge: CGFloat = Self.maxLongestEdge) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        // Measure in pixels, not points: NSImage.size is in points, so a 144-dpi
        // Retina screenshot (3000x2000 px) reports 1500x1000 and would slip past
        // the limit check at full resolution.
        let pixelSize: NSSize
        let sourceRep = image.representations.max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh })
        if let rep = sourceRep, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            pixelSize = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        } else {
            pixelSize = image.size
        }
        // Opaque sources (camera photos) are several times smaller as JPEG than PNG;
        // anything with transparency keeps PNG so the alpha channel survives.
        let isOpaque = sourceRep?.hasAlpha == false
        let size = pixelSize
        let longestEdge = max(size.width, size.height)
        guard longestEdge > maxLongestEdge else { return data }

        let scale = maxLongestEdge / longestEdge
        let newSize = NSSize(width: size.width * scale, height: size.height * scale)
        let pixelWidth = max(1, Int(newSize.width.rounded()))
        let pixelHeight = max(1, Int(newSize.height.rounded()))

        // Render into an explicitly pixel-sized bitmap context rather than using
        // NSImage's lockFocus/unlockFocus, which draws at the current screen's
        // backing scale factor (e.g. 2x on Retina displays) and would silently
        // produce a bitmap twice the intended pixel dimensions.
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = newSize

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(
            in: NSRect(origin: .zero, size: newSize),
            from: .zero,
            operation: .copy,
            fraction: 1.0
        )
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        return isOpaque
            ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
            : rep.representation(using: .png, properties: [:])
    }
}
