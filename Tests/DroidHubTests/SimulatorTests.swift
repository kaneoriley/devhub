import Foundation
import SwiftUI
import Testing
@testable import DroidHub

@Test func simulatorInventoryDistinguishesDefaultPlaceholdersFromNeverBootedUserDevices() throws {
    let data = Data("""
    {"runtimes":[{"identifier":"ios27","name":"iOS 27.1","version":"27.1","isAvailable":true},
                 {"identifier":"missing","name":"iOS 18","version":"18.0","isAvailable":false}],
     "devicetypes":[{"identifier":"phone","name":"iPhone 17 Pro Max","productFamily":"iPhone"},
                    {"identifier":"tablet","name":"iPad Pro","productFamily":"iPad"}],
     "devices":{"ios27":[
       {"udid":"running","name":"Phone","state":"Booted","deviceTypeIdentifier":"phone","isAvailable":true},
       {"udid":"used","name":"Tablet","state":"Shutdown","deviceTypeIdentifier":"tablet","isAvailable":true,"lastUsedAt":"2026-10-30T07:15:26Z"},
       {"udid":"unused","name":"Empty","state":"Shutdown","deviceTypeIdentifier":"phone","isAvailable":true},
       {"udid":"new","name":"New User Simulator","state":"Shutdown","deviceTypeIdentifier":"phone","isAvailable":true},
       {"udid":"unavailable","name":"Unavailable","state":"Shutdown","deviceTypeIdentifier":"phone","isAvailable":false,"lastUsedAt":"2026-10-30T07:15:26Z"}],
       "missing":[{"udid":"missing","name":"Missing Runtime","state":"Shutdown","deviceTypeIdentifier":"phone","isAvailable":true,"lastUsedAt":"2026-10-30T07:15:26Z"}]}}
    """.utf8)
    let devices = try AppleSimulator.parse(data, defaultDeviceIDs: ["unused"])
    #expect(devices.map(\.id) == ["simulator:new", "simulator:running", "simulator:used"])
    #expect(devices[1].isRunning && !devices[1].isEmulator && devices[1].serial == nil)
    #expect(!devices[2].isRunning && devices[2].kind == .tablet)
    #expect(devices.allSatisfy { $0.api == "27.1" })
    #expect(try AppleSimulator.parse(data, visibleDeviceIDs: ["new"]).map(\.id) == ["simulator:new"])
}

@Test func canonicalSimulatorDiscoveryUsesApplesVisibilityClassification() throws {
    let data = Data("""
    {"result":{"devices":[
      {"identifier":"new","properties":{"state":{"visibilityClass":"simulators"}}},
      {"identifier":"phone","properties":{"state":{"visibilityClass":"devices"}}}]}}
    """.utf8)
    #expect(try AppleSimulator.publishedIDs(data) == ["new"])
    #expect(try AppleSimulator.publishedIDs(Data(#"{"result":{"devices":[{"identifier":"legacy"}]}}"#.utf8)) == nil)
}

@Test func bundledAndroidCatalogLoadsWithoutAndroidStudio() async throws {
    let catalog = await DeviceProfile.load()
    #expect(catalog.count > 30)
    #expect(catalog.contains { $0.id == "pixel_10" && $0.name == "Pixel 10" })
    #expect(catalog.contains { $0.id == "medium_phone" })
    #expect(Set(catalog.map(\.id)).count == catalog.count)
    #expect(catalog.allSatisfy { $0.width > 0 && $0.height > 0 && $0.density > 0 })
    let fold = try #require(catalog.first { $0.id == "pixel_10_pro_fold" })
    #expect(fold.hardware["hw.sensor.hinge"] == "yes")
    #expect(fold.hardware["hw.displayRegion.0.1.width"] == "1080")
    let resizable = try #require(catalog.first { $0.id == "resizable" })
    #expect(DisplayPreset.parse(resizable.hardware["hw.resizable.configs"] ?? "").map(\.factor) == [.phone, .foldable, .tablet])
}

@Test func simulatorTypingUsesUSBUsagesAndPreservesUnicodeForClipboardFallback() {
    #expect(SimulatorKeyboard.strokes("A;_?") == [
        .init(usage: 4, shift: true), .init(usage: 0x33, shift: false),
        .init(usage: 0x2d, shift: true), .init(usage: 0x38, shift: true)
    ])
    #expect(SimulatorKeyboard.strokes("hello é") == nil)
}

@Test func simulatorOrientationMatchesTheLiveLandscapeRightDisplayAndHIDConvention() {
    // Captured from the Duo's active inner display: uiOrientation=3, rot90,
    // currentDeviceOrientation=landscapeRight. Its raw frame is counterclockwise.
    #expect(SimulatorOrientation.interface(3) == QuarterTurn(1))
    #expect(SimulatorOrientation.device(QuarterTurn(1)) == 3)
    for value in 1...4 { #expect(SimulatorOrientation.device(SimulatorOrientation.interface(value)) == value) }
}

@Test func simulatorEdgeGesturesRecognizeOnlyTheStartingScreenEdge() {
    let size = CGSize(width: 400, height: 800)
    #expect(SimulatorTouchEdge.detect(at: CGPoint(x: 200, y: 794), in: size) == .bottom)
    #expect(SimulatorTouchEdge.detect(at: CGPoint(x: 200, y: 5), in: size) == .top)
    #expect(SimulatorTouchEdge.detect(at: CGPoint(x: 5, y: 400), in: size) == .left)
    #expect(SimulatorTouchEdge.detect(at: CGPoint(x: 395, y: 400), in: size) == .right)
    #expect(SimulatorTouchEdge.detect(at: CGPoint(x: 200, y: 400), in: size) == .none)
    #expect(SimulatorTouchEdge.detect(at: CGPoint(x: 200, y: 780), in: size) == .none)
    #expect(SimulatorTouchEdge.detect(at: CGPoint(x: -1, y: 400), in: size) == .none)
    #expect(SimulatorTouchEdge.detect(at: .zero, in: .zero) == .none)
}

@Test func simulatorEdgeGesturesRotateIntoTheSameSourceSpaceAsTouches() {
    let edges: [SimulatorTouchEdge] = [.top, .right, .bottom, .left]
    let points = [CGPoint(x: 0.5, y: 0), CGPoint(x: 1, y: 0.5), CGPoint(x: 0.5, y: 1), CGPoint(x: 0, y: 0.5)]
    for value in 0..<4 {
        let rotation = QuarterTurn(value)
        for (edge, point) in zip(edges, points) {
            let source = rotation.sourcePoint(point)
            #expect(edge.sourceEdge(rotation: rotation) == SimulatorTouchEdge.detect(at: CGPoint(x: source.x * 400, y: source.y * 800), in: CGSize(width: 400, height: 800)))
        }
        #expect(SimulatorTouchEdge.none.sourceEdge(rotation: rotation) == .none)
    }
    #expect(SimulatorTouchEdge.bottom.sourceEdge(rotation: QuarterTurn(1)) == .right)
}

@Test func simulatorCasingFollowsAsymmetricMaskWithoutTracingCameraCutouts() {
    let left = [3, 1, 0, 0, 0, 0, 0, 1]
    let right = [6, 7, 7, 7, 7, 7, 7, 6]
    let contour = SimulatorContour(width: 8, height: 8) { x, y in
        guard x >= left[y], x <= right[y], !(y == 1 && x == 4) else { return 0 }
        return 255
    }
    let rect = CGRect(x: 0, y: 0, width: 80, height: 80)
    let path = contour.path(in: rect, rotation: .zero)
    #expect(!path.contains(CGPoint(x: 5, y: 5)))
    #expect(path.contains(CGPoint(x: 65, y: 5)))
    #expect(path.contains(CGPoint(x: 45, y: 15))) // the camera is inside the casing
    #expect(contour.points.first == CGPoint(x: 3.0 / 8, y: 0))
    let rotated = contour.path(in: rect, rotation: QuarterTurn(1))
    #expect(!rotated.contains(CGPoint(x: 75, y: 5)))
    #expect(rotated.contains(CGPoint(x: 75, y: 65)))
}

@Test func simulatorContourPreservesSquareDisplaysAndTransparentMaskFallback() {
    let rect = CGRect(x: 0, y: 0, width: 80, height: 60)
    for opaque in [false, true] {
        let contour = SimulatorContour(width: 8, height: 6) { _, _ in opaque ? 255 : 0 }
        #expect(contour.path(in: rect, rotation: .zero).boundingRect == rect)
        #expect(contour.path(in: rect, rotation: .zero).contains(CGPoint(x: 1, y: 1)))
    }
}
