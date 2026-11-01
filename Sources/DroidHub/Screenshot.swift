import CoreImage
import Foundation

/// Encodes the frame from the same renderer the user is watching, at device resolution.
enum Screenshot {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func png(from buffer: CVPixelBuffer, rotation: QuarterTurn = .zero) throws -> Data {
        var options: [CIImageOption: Any] = [:]
        if let sourceColorSpace = CVImageBufferGetColorSpace(buffer) {
            options[.colorSpace] = sourceColorSpace.takeUnretainedValue()
        }
        let image = CIImage(cvPixelBuffer: buffer, options: options).oriented(forExifOrientation: rotation.exifOrientation)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let png = context.pngRepresentation(of: image, format: .RGBA8, colorSpace: colorSpace) else {
            throw MirrorError("Couldn't encode the displayed frame as a PNG.")
        }
        return png
    }
}
