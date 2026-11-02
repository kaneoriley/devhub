import AppKit
import CoreVideo
import Testing
@testable import DevHub

@Test func screenshotEncodesMirroredFrameAtItsOriginalSize() throws {
    var pixelBuffer: CVPixelBuffer?
    let result = CVPixelBufferCreate(kCFAllocatorDefault, 2, 3, kCVPixelFormatType_32BGRA,
                                    [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary, &pixelBuffer)
    #expect(result == kCVReturnSuccess)
    let buffer = try #require(pixelBuffer)
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate)
    CVPixelBufferLockBaseAddress(buffer, [])
    let pixels = try #require(CVPixelBufferGetBaseAddress(buffer))
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    for row in 0..<3 {
        for column in 0..<2 {
            let pixel = pixels.advanced(by: row * stride + column * 4).assumingMemoryBound(to: UInt8.self)
            pixel[0] = 0; pixel[1] = 0; pixel[2] = 255; pixel[3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    let png = try Screenshot.png(from: buffer)
    #expect(png.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))
    let image = try #require(NSBitmapImageRep(data: png))
    #expect(image.pixelsWide == 2 && image.pixelsHigh == 3)
    // Inspect encoded samples directly; NSColor's calibrated-space conversion depends
    // on the host's display profile and isn't a property of the screenshot bytes.
    var samples = [Int](repeating: 0, count: image.samplesPerPixel)
    image.getPixel(&samples, atX: 0, y: 0)
    #expect(samples[0] == 255 && samples[1] == 0 && samples[2] == 0)

    let grayscale = try #require(AndroidColorTransform(mode: 0))
    let filtered = try #require(NSBitmapImageRep(data: Screenshot.png(from: buffer, rotation: QuarterTurn(1), colorMatrix: grayscale.parameters)))
    #expect(filtered.pixelsWide == 3 && filtered.pixelsHigh == 2)
    var filteredSamples = [Int](repeating: 0, count: filtered.samplesPerPixel)
    filtered.getPixel(&filteredSamples, atX: 0, y: 0)
    #expect(abs(filteredSamples[0] - filteredSamples[1]) <= 1 && abs(filteredSamples[1] - filteredSamples[2]) <= 1)
    #expect(filteredSamples[0] > 0 && filteredSamples[0] < 255 && filteredSamples[3] == 255)

    // The screenshot follows the locally rotated device even when the Android app
    // keeps its own orientation locked. A corner marker catches direction mistakes.
    CVPixelBufferLockBaseAddress(buffer, [])
    let corner = pixels.assumingMemoryBound(to: UInt8.self)
    corner[0] = 0; corner[1] = 255; corner[2] = 0
    CVPixelBufferUnlockBaseAddress(buffer, [])
    for (turn, cornerPosition) in [(1, CGPoint(x: 2, y: 0)), (2, CGPoint(x: 1, y: 2)), (3, CGPoint(x: 0, y: 1))] {
        let rotated = try #require(NSBitmapImageRep(data: Screenshot.png(from: buffer, rotation: QuarterTurn(turn))))
        #expect(rotated.pixelsWide == (turn % 2 == 0 ? 2 : 3))
        #expect(rotated.pixelsHigh == (turn % 2 == 0 ? 3 : 2))
        var cornerSamples = [Int](repeating: 0, count: rotated.samplesPerPixel)
        rotated.getPixel(&cornerSamples, atX: Int(cornerPosition.x), y: Int(cornerPosition.y))
        #expect(cornerSamples[0] == 0 && cornerSamples[1] == 255 && cornerSamples[2] == 0)
    }
}
