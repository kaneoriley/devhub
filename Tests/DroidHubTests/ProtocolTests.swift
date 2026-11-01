import Foundation
import Testing
@testable import DroidHub

@Test func annexBToAVCC() {
    let annexB = Data([0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 4, 5, 6])
    #expect(H264.nalUnits(annexB) == [Data([0x67, 1, 2]), Data([0x68, 3]), Data([0x65, 4, 5, 6])])
    #expect(H264.avcc(annexB) == Data([0, 0, 0, 3, 0x67, 1, 2, 0, 0, 0, 2, 0x68, 3, 0, 0, 0, 4, 0x65, 4, 5, 6]))
}

// Sizes and layouts from scrcpy 5.0.1's app/src/control_msg.c.
@Test func controlMessages() {
    let touch = Control.touch(0, x: 10, y: 20, width: 1080, height: 2424)
    #expect(touch.count == 32)
    #expect([UInt8](touch.prefix(10)) == [2, 0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe])
    #expect(touch.int(10) as Int32 == 10)
    #expect(touch.int(18) as UInt16 == 1080)
    #expect(touch.int(22) as UInt16 == 0xffff)

    #expect(Control.key(0, 3).count == 14)
    #expect(Control.text("hi") == Data([1, 0, 0, 0, 2, 0x68, 0x69]))
    #expect(Control.setClipboard("é", paste: true) == Data([9, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 2, 0xc3, 0xa9]))

    let scroll = Control.scroll(x: 0, y: 0, width: 1, height: 1, dx: 0, dy: 16)
    #expect(scroll.count == 21)
    #expect(scroll.int(15) as Int16 == .max)
}

@Test func scrollNotchesFollowDensityAndZoom() {
    #expect(Mirror.density(from: "Physical density: 420\n") == 420)
    #expect(Mirror.density(from: "Physical density: 420\r\nOverride density: 480\r\n") == 480)
    #expect(Mirror.density(from: "") == nil)
    // 64dp at 420 dpi is 168 px; shown at half size that is 84 points.
    #expect(Mirror.pointsPerNotch(density: 420, viewWidth: 540, videoWidth: 1080) == 84)
}
