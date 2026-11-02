import SwiftUI

/// Pixel radii in clockwise order, starting at the top left. Android uses circular
/// corners, which can differ between the top and bottom of the same display.
struct DisplayCorners: Equatable {
    var topLeft: CGFloat = 0
    var topRight: CGFloat = 0
    var bottomRight: CGFloat = 0
    var bottomLeft: CGFloat = 0
    static let square = DisplayCorners()

    func rotated(_ turn: QuarterTurn) -> DisplayCorners {
        let values = [topLeft, topRight, bottomRight, bottomLeft]
        let result = (0..<4).map { values[($0 - turn.value + 4) % 4] }
        return DisplayCorners(topLeft: result[0], topRight: result[1], bottomRight: result[2], bottomLeft: result[3])
    }

    func shape(scale: CGFloat, border: CGFloat = 0, style: RoundedCornerStyle = .circular) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: topLeft * scale + border,
                               bottomLeadingRadius: bottomLeft * scale + border,
                               bottomTrailingRadius: bottomRight * scale + border,
                               topTrailingRadius: topRight * scale + border, style: style)
    }
}

struct DisplayGeometry: Equatable {
    let size: CGSize
    let rotation: QuarterTurn
    let corners: DisplayCorners

    /// WindowInsetsStateController describes the logical display currently mirrored
    /// by scrcpy (display 0), including when a foldable swaps its physical displays.
    static func parse(_ output: String) -> DisplayGeometry? {
        guard let block = output.components(separatedBy: "Display: ").dropFirst().first(where: {
            $0.range(of: #"^mDisplayId=0\b"#, options: .regularExpression) != nil
        }) else { return nil }
        func captures(_ pattern: String, in text: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
            return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
        }
        guard let frame = captures(#"mDisplayFrame=Rect\(0, 0 - (\d+), (\d+)\)"#, in: block),
              let width = Double(frame[0]), width > 0, let height = Double(frame[1]), height > 0 else { return nil }
        let rotation = captures(#"(?m)^\s*mRotation=([0-3])\b"#, in: block)?.first.flatMap(Int.init) ?? 0
        let line = block.split(whereSeparator: \.isNewline).first { $0.contains("mRoundedCorners=") }.map(String.init) ?? ""
        func radius(_ position: String) -> CGFloat {
            captures("position=\(position), radius=(\\d+)", in: line)?.first.flatMap(Double.init).map { CGFloat($0) } ?? 0
        }
        return DisplayGeometry(size: CGSize(width: width, height: height), rotation: QuarterTurn(rotation),
                               corners: DisplayCorners(topLeft: radius("TopLeft"), topRight: radius("TopRight"),
                                                       bottomRight: radius("BottomRight"), bottomLeft: radius("BottomLeft")))
    }

    func videoCorners(size videoSize: CGSize, naturalOrientation: Bool) -> DisplayCorners {
        // Android's logical coordinates rotate counterclockwise. The emulator video
        // is locked to natural orientation, so undo that before the local view rotation.
        let referenceSize = naturalOrientation ? rotation.size(size) : size
        let referenceCorners = naturalOrientation ? corners.rotated(rotation) : corners
        let scaleX = videoSize.width / referenceSize.width
        let scaleY = videoSize.height / referenceSize.height
        let scale = min(scaleX, scaleY)
        // Never apply stale geometry to a newly resized or folded display. Encoder
        // downscaling can align dimensions independently. Measure the discrepancy on
        // the short edge so it isn't amplified by a tall phone's aspect ratio.
        guard scale > 0, abs(scaleX - scaleY) * min(referenceSize.width, referenceSize.height) <= 8 else { return .square }
        return DisplayCorners(topLeft: referenceCorners.topLeft * scale, topRight: referenceCorners.topRight * scale,
                              bottomRight: referenceCorners.bottomRight * scale, bottomLeft: referenceCorners.bottomLeft * scale)
    }
}

extension DeviceActions {
    func displayGeometry(serial: String) async throws -> DisplayGeometry? {
        let result = try await run(["-s", serial, "shell", "dumpsys", "window", "displays"])
        try result.checked()
        return DisplayGeometry.parse(result.output)
    }
}
