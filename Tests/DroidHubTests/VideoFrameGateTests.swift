import Foundation
import Testing
@testable import DroidHub

@Test func hiddenVideoStreamsDoNotSubmitAnyFramesForDecoding() {
    let gate = VideoFrameGate()
    #expect(gate.accept(keyframe: true) == nil)
    #expect(gate.accept(keyframe: false) == nil)
    gate.setActive(true)
    _ = gate.accept(keyframe: true)
    gate.setActive(false)
    for _ in 0..<100 {
        #expect(gate.accept(keyframe: false) == nil)
        #expect(gate.accept(keyframe: true) == nil)
    }
}

@Test func resumingVideoWaitsForAKeyframeAndResetsTheDecoderOnce() throws {
    let gate = VideoFrameGate()
    #expect(gate.setActive(true))
    #expect(!gate.setActive(true))
    #expect(gate.accept(keyframe: false) == nil)
    let first = try #require(gate.accept(keyframe: true))
    #expect(first.resetDecoder && gate.isCurrent(first))
    #expect(try #require(gate.accept(keyframe: false)).resetDecoder == false)
    gate.setActive(false)
    gate.setActive(true)
    #expect(gate.accept(keyframe: false) == nil)
    #expect(try #require(gate.accept(keyframe: true)).resetDecoder)
    #expect(!gate.isCurrent(first))
    #expect(Control.resetVideo() == Data([17]))
}

@Test func queuedFramesCannotRenderAfterHidingOrRapidlySwitchingAwayAndBack() throws {
    let gate = VideoFrameGate()
    gate.setActive(true)
    let queued = try #require(gate.accept(keyframe: true))
    gate.setActive(false)
    #expect(!gate.isCurrent(queued))
    gate.setActive(true)
    #expect(!gate.isCurrent(queued))
    let current = try #require(gate.accept(keyframe: true))
    #expect(gate.isCurrent(current))
    #expect(!gate.isCurrent(queued))
}
