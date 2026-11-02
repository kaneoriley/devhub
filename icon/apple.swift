// Adds the system Apple-logo glyph to the existing layered app icon.
// Run from the repository root: swift icon/apple.swift
// The other layers are rendered by icon.py; Icon Composer supplies the glass finish.
// After ./build.sh, refresh the README preview with:
// sips -s format png build/DevHub.app/Contents/Resources/AppIcon.icns --out .github/icon.png
import AppKit
import CoreText

let font = CTFontCreateWithName("Helvetica" as CFString, 100, nil)
var character: UniChar = 0xF8FF
var glyph: CGGlyph = 0
guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1),
      let outline = CTFontCreatePathForGlyph(font, glyph, nil) else {
    fatalError("The system font does not contain the Apple logo.")
}

let size = 1024
let pixelsPerUnit = CGFloat(size) / 8.24
let bounds = outline.boundingBoxOfPath
let scale = 3.05 * pixelsPerUnit / bounds.height
var transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                 tx: CGFloat(size) / 2 + 1.45 * pixelsPerUnit - bounds.midX * scale,
                                 ty: CGFloat(size) / 2 - 1.45 * pixelsPerUnit - bounds.midY * scale)
let path = outline.copy(using: &transform)!
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setAllowsAntialiasing(true)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -5), blur: 10,
                  color: CGColor(srgbRed: 0.12, green: 0.28, blue: 0.53, alpha: 0.24))
context.addPath(path)
context.setFillColor(CGColor(gray: 1, alpha: 0.94))
context.fillPath()
context.restoreGState()
context.saveGState()
context.addPath(path)
context.clip()
let gradient = CGGradient(colorsSpace: colorSpace,
                          colors: [CGColor(srgbRed: 0.85, green: 0.93, blue: 1, alpha: 0.94),
                                   CGColor(gray: 1, alpha: 1)] as CFArray,
                          locations: [0, 1])!
let placed = path.boundingBoxOfPath
context.drawLinearGradient(gradient, start: CGPoint(x: placed.midX, y: placed.minY),
                           end: CGPoint(x: placed.midX, y: placed.maxY), options: [])
context.restoreGState()
context.addPath(path)
context.setStrokeColor(CGColor(gray: 1, alpha: 0.8))
context.setLineWidth(1.5)
context.strokePath()
let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
let destination = URL(fileURLWithPath: "icon/AppIcon.icon/Assets/apple.png")
try bitmap.representation(using: .png, properties: [:])!.write(to: destination)
print("Wrote \(destination.path)")
