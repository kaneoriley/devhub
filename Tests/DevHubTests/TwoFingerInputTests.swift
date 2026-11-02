import AppKit
import Testing
@testable import DevHub

@Test func twoFingerFocusIsCapturedBeforeClickAndStaysFixedDuringDrag() throws {
    var gesture = TwoFingerGesture()
    let size = CGSize(width: 400, height: 800), focus = CGPoint(x: 100, y: 300)
    gesture.enable(at: focus, size: size)
    gesture.move(to: CGPoint(x: 130, y: 340), size: size)
    gesture.enable(at: CGPoint(x: 130, y: 340), size: size)
    #expect(gesture.focus == focus)
    #expect(gesture.begin() == TwoFingerPoints(first: CGPoint(x: 130, y: 340), second: CGPoint(x: 70, y: 260)))
    gesture.move(to: CGPoint(x: 160, y: 280), size: size)
    #expect(gesture.points == TwoFingerPoints(first: CGPoint(x: 160, y: 280), second: CGPoint(x: 40, y: 320)))
    #expect(gesture.dragging)
    #expect(gesture.end() == gesture.points)
    #expect(!gesture.dragging && gesture.end() == nil)
    #expect(gesture.focus == focus) // Another click while Command is held uses the same pivot.
    #expect(gesture.disable() == nil && gesture.focus == nil && gesture.points == nil)
}

@Test func mirroredContactsKeepTheirFocusAndAngleWhenClampedAtScreenEdges() throws {
    var gesture = TwoFingerGesture()
    let size = CGSize(width: 400, height: 800), focus = CGPoint(x: 60, y: 160)
    gesture.enable(at: focus, size: size)
    gesture.move(to: CGPoint(x: 600, y: 430), size: size)
    let points = try #require(gesture.points)
    #expect(points.first == CGPoint(x: 120, y: 190))
    #expect(points.second == CGPoint(x: 0, y: 130))
    for turn in 0..<4 {
        let rotation = QuarterTurn(turn)
        let first = rotation.sourcePoint(CGPoint(x: points.first.x / size.width, y: points.first.y / size.height))
        let second = rotation.sourcePoint(CGPoint(x: points.second.x / size.width, y: points.second.y / size.height))
        let pivot = rotation.sourcePoint(CGPoint(x: focus.x / size.width, y: focus.y / size.height))
        #expect(abs((first.x + second.x) / 2 - pivot.x) < 0.00001)
        #expect(abs((first.y + second.y) / 2 - pivot.y) < 0.00001)
    }
}

@Test func leavingTwoFingerModeLiftsBothContactsAndAllowsANewFocus() {
    var gesture = TwoFingerGesture()
    let size = CGSize(width: 400, height: 800)
    gesture.enable(at: CGPoint(x: 120, y: 250), size: size)
    gesture.move(to: CGPoint(x: 150, y: 250), size: size)
    _ = gesture.begin()
    #expect(gesture.disable() != nil)
    #expect(!gesture.dragging && gesture.points == nil && gesture.focus == nil)
    gesture.enable(at: CGPoint(x: 300, y: 500), size: size)
    #expect(gesture.focus == CGPoint(x: 300, y: 500))
    #expect(gesture.end() == nil) // Previewing never starts a remote touch.
}

@Test func androidTwoFingerMessagesUseSeparateTouchscreenPointersAndLiftSecondaryFirst() {
    for phase in [TwoFingerPhase.began, .moved, .ended] {
        let data = Control.touchPair(phase, first: (50, 100), second: (150, 200), width: 400, height: 800)
        #expect(data.count == 64)
        #expect(data.int(2) as Int64 == (phase == .ended ? -3 : -2))
        #expect(data.int(34) as Int64 == (phase == .ended ? -2 : -3))
        #expect(data.int(10) as Int32 == (phase == .ended ? 150 : 50))
        #expect(data.int(42) as Int32 == (phase == .ended ? 50 : 150))
        #expect(data[1] == (phase == .began ? 0 : phase == .moved ? 2 : 1))
        #expect(data[33] == data[1])
        if phase == .ended { #expect(data.int(22) as UInt16 == 0 && data.int(54) as UInt16 == 0) }
    }
}

@MainActor @Test func twoFingerPreviewDoesNotInjectTouchesAndCancelledClicksCannotLeakSingleTouches() throws {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 800))
    var calls: [(TwoFingerPoints, TwoFingerPhase)] = []
    var previews = 0
    let input = TwoFingerInput(view: view, beginPreview: { previews += 1 }) { calls.append(($0, $1)) }
    input.layout()
    func event(_ type: NSEvent.EventType, _ point: CGPoint, command: Bool = true) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: command ? .command : [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
    }
    input.hover(try event(.mouseMoved, CGPoint(x: 120, y: 300)))
    input.hover(try event(.mouseMoved, CGPoint(x: 150, y: 320)))
    #expect(input.active && calls.isEmpty && previews == 1)
    #expect(view.subviews.contains { !$0.isHidden })
    #expect(view.hitTest(CGPoint(x: 150, y: 320)) === view)
    if let path = ProcessInfo.processInfo.environment["DEVHUB_TEST_GESTURE_PREVIEW"] {
        let overlay = try #require(view.subviews.first)
        let bitmap = try #require(overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds))
        overlay.cacheDisplay(in: overlay.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
    #expect(input.mouseDown(try event(.leftMouseDown, CGPoint(x: 150, y: 320))))
    #expect(input.mouseDragged(try event(.leftMouseDragged, CGPoint(x: 170, y: 340))))
    input.hover(try event(.mouseMoved, CGPoint(x: 170, y: 340), command: false))
    #expect(calls.map { $0.1 } == [.began, .moved, .ended])
    #expect(!input.active && !input.dragging)
    #expect(input.mouseDragged(try event(.leftMouseDragged, CGPoint(x: 180, y: 340), command: false)))
    #expect(input.mouseUp(try event(.leftMouseUp, CGPoint(x: 180, y: 340), command: false)))
    #expect(calls.count == 3)
    #expect(view.subviews.allSatisfy { $0.isHidden })
    input.reset()
    #expect(calls.count == 3)
}
