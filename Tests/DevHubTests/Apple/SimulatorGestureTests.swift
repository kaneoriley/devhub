import Foundation
import Testing
@testable import DevHub

@Test func simulatorWheelNotchesHaveUsableDistanceWithoutAmplifyingTrackpadPoints() {
    #expect(SimulatorScrollGesture.delta(x: 0, y: 1, precise: false) == CGPoint(x: 0, y: 48))
    #expect(SimulatorScrollGesture.delta(x: 2, y: -3, precise: true) == CGPoint(x: 2, y: -3))
}

@Test func simulatorWheelStartsUnderPointerAndCanContinueAfterReachingAnEdge() {
    var gesture = SimulatorScrollGesture()
    let cursor = CGPoint(x: 80, y: 600), size = CGSize(width: 400, height: 800)
    let first = gesture.move(at: cursor, delta: CGPoint(x: 0, y: -48), size: size)
    #expect(first.map(\.phase) == [0, 1])
    #expect(first.first?.point == cursor)
    #expect(first.last?.point == CGPoint(x: 80, y: 552))
    var restarts = 0
    for _ in 0..<100 {
        let contacts = gesture.move(at: cursor, delta: CGPoint(x: 0, y: -48), size: size)
        if contacts.count == 3 {
            restarts += 1
            #expect(contacts.map(\.phase) == [2, 0, 1])
            #expect(contacts[1].point == cursor)
            #expect(contacts[2].point.y < cursor.y)
        }
    }
    #expect(restarts > 1)
    #expect(gesture.end().map(\.phase) == [2])
    #expect(gesture.point == nil && gesture.end().isEmpty)
}

@Test func simulatorEmptyScrollEventsDoNotGenerateTaps() {
    var gesture = SimulatorScrollGesture()
    #expect(gesture.move(at: .zero, delta: .zero, size: CGSize(width: 400, height: 800)).isEmpty)
    #expect(gesture.point == nil)
    #expect(gesture.move(at: .zero, delta: CGPoint(x: 0, y: 48), size: .zero).isEmpty)
}

@Test func simulatorPinchUsesTwoContactsCentredOnPointerInBothDirections() throws {
    var gesture = SimulatorPinchGesture()
    let cursor = CGPoint(x: 100, y: 600), size = CGSize(width: 400, height: 800)
    let contacts = gesture.magnify(at: cursor, amount: 0.25, size: size)
    #expect(contacts.map(\.phase) == [0, 1])
    let start = contacts[0], moved = contacts[1]
    let secondStart = try #require(start.second), secondMoved = try #require(moved.second)
    #expect((start.point.x + secondStart.x) / 2 == cursor.x)
    #expect((moved.point.x + secondMoved.x) / 2 == cursor.x)
    #expect(start.point.y == cursor.y && secondStart.y == cursor.y)
    #expect(secondMoved.x - moved.point.x > secondStart.x - start.point.x)
    let reverse = try #require(gesture.magnify(at: cursor, amount: -0.2, size: size).last)
    #expect(try #require(reverse.second).x - reverse.point.x < secondMoved.x - moved.point.x)
    let end = try #require(gesture.end().first)
    #expect(end.phase == 2 && end.second != nil)
    #expect(gesture.end().isEmpty)
}

@Test func simulatorPinchContactsStayOnscreenNearCornersAndRotateTogether() throws {
    for cursor in [CGPoint.zero, CGPoint(x: 399, y: 799)] {
        var gesture = SimulatorPinchGesture()
        let contacts = gesture.magnify(at: cursor, amount: 100, size: CGSize(width: 400, height: 800))
        for contact in contacts {
            for p in [contact.point, try #require(contact.second)] {
                for turn in 0..<4 {
                    let source = QuarterTurn(turn).sourcePoint(CGPoint(x: p.x / 400, y: p.y / 800))
                    #expect((0...1).contains(source.x) && (0...1).contains(source.y))
                }
            }
        }
    }
}
