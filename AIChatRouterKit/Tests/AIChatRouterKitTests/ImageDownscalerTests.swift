import AppKit
import Testing
@testable import AIChatRouterKit

@Suite("ImageDownscaler")
struct ImageDownscalerTests {
    private func makeSolidColorPNGData(width: Int, height: Int) -> Data {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        let tiff = image.tiffRepresentation!
        let rep = NSBitmapImageRep(data: tiff)!
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

    @Test func undecodableDataReturnsNil() {
        let garbage = Data([0x00, 0x01, 0x02, 0x03])
        #expect(ImageDownscaler().downscale(garbage) == nil)
    }
}
