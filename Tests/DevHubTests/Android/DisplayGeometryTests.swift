import Foundation
import Testing
@testable import DevHub

private func geometryDump(width: Int = 1080, height: Int = 2400, rotation: Int = 0,
                          radii: [Int] = [0, 0, 0, 0]) -> String {
    let corners = zip(["TopLeft", "TopRight", "BottomRight", "BottomLeft"], radii).map {
        "RoundedCorner{position=\($0), radius=\($1), center=Point(0, 0)}"
    }.joined(separator: ", ")
    return """
    Display: mDisplayId=0 (organized)
      DisplayRotation
        mRotation=\(rotation) mDeferredRotationPauseCount=0
      WindowInsetsStateController
        InsetsState
          mDisplayFrame=Rect(0, 0 - \(width), \(height))
          mRoundedCorners=RoundedCorners{[\(corners)]}
    """
}

@Test func squareEmulatorGeometryPreservesTheWholeScreen() throws {
    let geometry = try #require(DisplayGeometry.parse(geometryDump()))
    #expect(geometry.size == CGSize(width: 1080, height: 2400))
    #expect(geometry.corners == .square)
    #expect(geometry.videoCorners(size: geometry.size, naturalOrientation: true) == .square)
    // With a zero radius the clipping path includes the clock's corner pixels.
    #expect(geometry.corners.shape(scale: 0.3).path(in: CGRect(x: 0, y: 0, width: 324, height: 720))
        .contains(CGPoint(x: 1, y: 1)))
}

@Test func geometryReadsOnlyTheMirroredDisplayAndUsesReportedPixelRadii() throws {
    let virtual = geometryDump(width: 918, height: 2048).replacingOccurrences(of: "mDisplayId=0", with: "mDisplayId=10")
    let phone = geometryDump(width: 1344, height: 2992, radii: [153, 153, 153, 153])
    let geometry = try #require(DisplayGeometry.parse(virtual + "\n" + phone))
    #expect(geometry.size == CGSize(width: 1344, height: 2992))
    #expect(geometry.corners.topLeft == 153)
    let scaled = geometry.videoCorners(size: CGSize(width: 672, height: 1496), naturalOrientation: true)
    #expect(scaled == DisplayCorners(topLeft: 76.5, topRight: 76.5, bottomRight: 76.5, bottomLeft: 76.5))
    // Actual encoder fallback on the Pixel emulator: dimensions round independently.
    let encoded = geometry.videoCorners(size: CGSize(width: 918, height: 2048), naturalOrientation: true)
    #expect(abs(encoded.topLeft - 153 * 918 / 1344) < 0.0001)
    #expect(!scaled.shape(scale: 1).path(in: CGRect(x: 0, y: 0, width: 672, height: 1496)).contains(CGPoint(x: 1, y: 1)))
}

@Test func geometryUndoesAndroidRotationThenFollowsLocalDeviceRotation() throws {
    // Android moves corner i to i-rotation; natural TL/TR/BR/BL = 10/20/30/40.
    let geometry = try #require(DisplayGeometry.parse(geometryDump(width: 2400, height: 1080, rotation: 1,
                                                                 radii: [20, 30, 40, 10])))
    let natural = geometry.videoCorners(size: CGSize(width: 1080, height: 2400), naturalOrientation: true)
    #expect(natural == DisplayCorners(topLeft: 10, topRight: 20, bottomRight: 30, bottomLeft: 40))
    #expect(natural.rotated(QuarterTurn(1)) == DisplayCorners(topLeft: 40, topRight: 10, bottomRight: 20, bottomLeft: 30))
    #expect(natural.rotated(QuarterTurn(2)) == DisplayCorners(topLeft: 30, topRight: 40, bottomRight: 10, bottomLeft: 20))
    #expect(natural.rotated(QuarterTurn(3)) == DisplayCorners(topLeft: 20, topRight: 30, bottomRight: 40, bottomLeft: 10))
    // Physical devices mirror Android's current orientation directly.
    #expect(geometry.videoCorners(size: geometry.size, naturalOrientation: false) == geometry.corners)
}

@Test func absentOrStaleGeometryDoesNotInventCorners() throws {
    #expect(DisplayGeometry.parse("device offline") == nil)
    #expect(DisplayGeometry.parse(geometryDump().replacingOccurrences(of: "mDisplayId=0", with: "mDisplayId=3")) == nil)
    let old = try #require(DisplayGeometry.parse(geometryDump(radii: [80, 80, 120, 120])))
    #expect(old.videoCorners(size: CGSize(width: 2208, height: 1840), naturalOrientation: true) == .square)
    let legacy = geometryDump().split(whereSeparator: \.isNewline).filter { !$0.contains("mRoundedCorners") }.joined(separator: "\n")
    #expect(DisplayGeometry.parse(legacy)?.corners == .square)
}
