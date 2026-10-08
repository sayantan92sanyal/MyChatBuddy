import AppKit
import Testing
@testable import AIChatRouterKit

@Suite("ImageDownscaler")
struct ImageDownscalerTests {
    /// Pixel-exact fixture (1 point == 1 pixel): `lockFocus` would render at the
    /// screen's backing scale and make the pixel size machine-dependent.
    private func makeSolidColorPNGData(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    @Test func imagesUnderTheLimitAreReturnedUnchanged() {
        let data = makeSolidColorPNGData(width: 100, height: 100)
        let result = ImageDownscaler().downscale(data, maxLongestEdge: 1568)
        #expect(result == data)
    }

    @Test func imagesExactlyAtTheLimitAreReturnedUnchanged() {
        // Boundary check: longest edge == limit must NOT count as "over" it.
        let data = makeSolidColorPNGData(width: 1568, height: 800)
        let result = ImageDownscaler().downscale(data, maxLongestEdge: 1568)
        #expect(result == data)
    }

    @Test func imagesOverTheLimitAreResizedSoTheLongestEdgeFitsIt() {
        let data = makeSolidColorPNGData(width: 3000, height: 1500)
        guard let result = ImageDownscaler().downscale(data, maxLongestEdge: 1000) else {
            Issue.record("Expected a non-nil downscaled result")
            return
        }
        guard let resized = NSImage(data: result), let rep = resized.representations.first else {
            Issue.record("Expected the result to decode back into an image")
            return
        }
        #expect(rep.pixelsWide <= 1000)
        #expect(rep.pixelsHigh <= 1000)
        // Aspect ratio preserved (3000:1500 == 2:1 source, within rounding).
        #expect(abs(Double(rep.pixelsWide) / Double(rep.pixelsHigh) - 2.0) < 0.05)
    }

    @Test func retinaImagesAreMeasuredInPixelsNotPoints() {
        // A 3000x2000-pixel PNG saved at 144 dpi reports NSImage.size of 1500x1000
        // points — exactly what every Retina screenshot looks like.
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 3000, pixelsHigh: 2000,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = NSSize(width: 1500, height: 1000)
        let data = rep.representation(using: .png, properties: [:])!

        guard let result = ImageDownscaler().downscale(data, maxLongestEdge: 1568),
              let out = NSBitmapImageRep(data: result) else {
            Issue.record("Expected a decodable downscaled result")
            return
        }
        #expect(max(out.pixelsWide, out.pixelsHigh) <= 1568)
        #expect(abs(Double(out.pixelsWide) / Double(out.pixelsHigh) - 1.5) < 0.05)
    }

    @Test func undecodableDataReturnsNil() {
        let garbage = Data([0x00, 0x01, 0x02, 0x03])
        #expect(ImageDownscaler().downscale(garbage) == nil)
    }
}
