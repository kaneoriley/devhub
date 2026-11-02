import Foundation
import Testing
@testable import DevHub

@Test func tilesOnlyOfferRunningNativeMirrorsAndExcludeBootingAndOfflineDevices() {
    func sim(_ id: String, state: String) -> Device {
        Device(id: id, name: id, detail: "Simulator", simulator: AppleSimulator(udid: id, state: state, runtime: "iOS 27", version: "27", type: "iPhone", family: "iPhone"))
    }
    let devices = [
        Device(id: "android", name: "Pixel", detail: "Emulator", avd: "Pixel", serial: "emulator-5554"),
        Device(id: "usb", name: "Phone", detail: "Physical", serial: "usb"),
        Device(id: "off", name: "Offline", detail: "Emulator", avd: "Offline"),
        Device(id: "starting", name: "Starting", detail: "Emulator", avd: "Starting", serial: "emulator-5556"),
        sim("ios", state: "Booted"), sim("off-ios", state: "Shutdown"), sim("booting-ios", state: "Booting"),
        Device(id: "apple", name: "iPad", detail: "Physical", appleDevice: AppleDevice(identifier: "apple", udid: "apple", platform: "iPadOS", version: "27", connection: "connected", pairing: "paired"))
    ]
    #expect(TileDevices.available(devices, booting: ["starting"]).map(\.id) == ["android", "usb", "ios"])
    #expect(TileDevices.available([], booting: []).isEmpty)
}

@Test func oneTileFillsTheAvailableHeightAndCentersWithoutDistortingItsScreen() {
    let frames = TileArrangement.frames(aspectRatios: [0.5], in: CGSize(width: 1000, height: 800))
    #expect(frames.count == 1)
    #expect(abs(frames[0].minX - 300) < 0.001 && abs(frames[0].minY) < 0.001)
    #expect(abs(frames[0].width - 400) < 0.001 && abs(frames[0].height - 800) < 0.001)
}

@Test func portraitTilesUseOneRowInAWideWindowAndOneColumnInANarrowWindow() {
    let ratios: [CGFloat] = [0.5, 0.5, 0.5]
    let wide = TileArrangement.frames(aspectRatios: ratios, in: CGSize(width: 1600, height: 800))
    #expect(wide.allSatisfy { $0.height == 800 })
    #expect(wide.map(\.minX) == wide.map(\.minX).sorted())
    let narrow = TileArrangement.frames(aspectRatios: ratios, in: CGSize(width: 200, height: 1400))
    #expect(narrow.allSatisfy { abs($0.width - 200) < 0.001 })
    #expect(narrow.map(\.minY) == narrow.map(\.minY).sorted())
}

@Test func mixedTileLayoutsStayInsideTheWindowPreserveEveryAspectAndNeverOverlap() {
    for size in [CGSize(width: 1200, height: 800), CGSize(width: 400, height: 1200), CGSize(width: 700, height: 700), CGSize(width: 2, height: 1)] {
        for ratios: [CGFloat] in [[0.46, 0.75, 1.4, 0.5, 2.1], Array(repeating: 0.5, count: 13), [2, 2, 0.5]] {
            let frames = TileArrangement.frames(aspectRatios: ratios, in: size)
            #expect(frames.count == ratios.count)
            let areas = frames.map { $0.width * $0.height }
            #expect(areas.max()! / areas.min()! < 1.001)
            for (index, frame) in frames.enumerated() {
                #expect(frame.width > 0 && frame.height > 0)
                #expect(frame.minX >= -0.001 && frame.maxX <= size.width + 0.001)
                #expect(frame.minY >= -0.001 && frame.maxY <= size.height + 0.001)
                #expect(abs(frame.width / frame.height - ratios[index]) < 0.001)
                for other in frames.dropFirst(index + 1) { #expect(!frame.intersects(other)) }
            }
        }
    }
}

@Test func tileArrangementReflowsAfterRotationAndHandlesEmptyAndInvalidGeometry() {
    let window = CGSize(width: 1000, height: 700)
    let portrait = TileArrangement.frames(aspectRatios: [0.5, 0.5], in: window)
    let rotated = TileArrangement.frames(aspectRatios: [2, 0.5], in: window)
    #expect(portrait != rotated)
    #expect(abs(rotated[0].width / rotated[0].height - 2) < 0.001)
    #expect(TileArrangement.frames(aspectRatios: [], in: window).isEmpty)
    #expect(TileArrangement.frames(aspectRatios: [0.5], in: .zero) == [.zero])
    #expect(TileArrangement.frames(aspectRatios: [.nan, 0, -2, .infinity], in: window).allSatisfy { $0.width.isFinite && $0.height.isFinite })
}

@Test func tabletsStackTogetherBesideTallPhonesInsteadOfWastingASingleRow() {
    // The sidebar separates the iPad and open Duo with two tall iPhones.
    let ratios: [CGFloat] = [0.75, 0.47, 0.47, 0.71]
    let window = CGSize(width: 1228, height: 980)
    let frames = TileArrangement.frames(aspectRatios: ratios, in: window)
    let area = frames.reduce(CGFloat.zero) { $0 + $1.width * $1.height }
    let equalAreaRowScale = (window.width - 3 * 16) / ratios.reduce(CGFloat.zero) { $0 + sqrt($1) }
    #expect(area > 4 * equalAreaRowScale * equalAreaRowScale * 1.1)
    let areas = frames.map { $0.width * $0.height }
    #expect(areas.max()! / areas.min()! < 1.001)
    #expect(abs(frames[0].midX - frames[3].midX) < 0.001)
    #expect(!frames[0].intersects(frames[3]))
}

@Test func tilePackingUsesShapesRatherThanSidebarOrder() {
    let ratios: [CGFloat] = [0.75, 0.47, 0.47, 0.71]
    let window = CGSize(width: 1228, height: 980)
    func area(_ ratios: [CGFloat]) -> CGFloat {
        TileArrangement.frames(aspectRatios: ratios, in: window).reduce(0) { $0 + $1.width * $1.height }
    }
    #expect(abs(area(ratios) - area([0.47, 0.71, 0.75, 0.47])) < 0.001)
}
