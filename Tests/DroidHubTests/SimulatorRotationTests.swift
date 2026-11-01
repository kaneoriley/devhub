import Foundation
import SimulatorBridge
import Testing
@testable import DroidHub

@Test func simulatorRotationFollowsEveryReportedFrameIncludingExternalChanges() {
    var rotation = SimulatorRotation()
    for reported in [1, 3, 2, 4, 1, 4] {
        rotation.receive(reported, screen: 3)
        #expect(rotation.orientation == SimulatorOrientation.interface(reported))
    }
    rotation.receive(0, screen: 3)
    #expect(rotation.orientation == QuarterTurn(3))
}

@Test func simulatorRotationRequestsAccountForEachScreensNativeMounting() {
    for mount in 0..<4 {
        for start in 0..<4 {
            var rotation = SimulatorRotation()
            rotation.receive(SimulatorOrientation.device(QuarterTurn(start)), screen: 3)
            let request = rotation.requestNext(nativeRotation: QuarterTurn(mount))
            // CoreSimulator subtracts the display's mounting angle from input.
            // The Duo's inner display has nativeRotation=270, its cover has 0.
            let result = QuarterTurn(SimulatorOrientation.interface(request).value - mount)
            #expect(result == QuarterTurn(start).next)
            #expect(rotation.orientation == QuarterTurn(start))
            rotation.receive(SimulatorOrientation.device(result), screen: 3)
            #expect(rotation.orientation == result)
        }
    }
}

@Test func rapidSimulatorRotationKeepsTheLatestTargetUntilItsFrameArrives() {
    var rotation = SimulatorRotation()
    rotation.receive(1, screen: 3)
    #expect(rotation.requestNext(nativeRotation: QuarterTurn(3)) == 1)
    #expect(rotation.requestNext(nativeRotation: QuarterTurn(3)) == 3)
    rotation.receive(3, screen: 3) // The first request has arrived, the second hasn't.
    #expect(rotation.requestNext(nativeRotation: QuarterTurn(3)) == 2)
    rotation.receive(4, screen: 3)
    #expect(rotation.requestNext(nativeRotation: QuarterTurn(3)) == 4)
}

@Test func changingSimulatorScreensResetsPendingRotationAndUsesTheNewMounting() {
    var rotation = SimulatorRotation()
    rotation.receive(1, screen: 3)
    _ = rotation.requestNext(nativeRotation: QuarterTurn(3))
    rotation.receive(4, screen: 1)
    #expect(rotation.orientation == QuarterTurn(3))
    #expect(rotation.requestNext(nativeRotation: .zero) == 1)
}

/// Opt in with a booted open Duo; rotate a complete cycle and restore it on error.
@Test @MainActor func liveDuoRotationCompletesAFullTurnUsingItsNativeMounting() async throws {
    guard let id = ProcessInfo.processInfo.environment["DROIDHUB_TEST_ROTATION_SIMULATOR"] else { return }
    let bridge = try DHSimulatorBridge(deviceID: id, developerDirectory: try await Simctl.developerDirectory())
    #expect(bridge.nativeRotation(forScreen: 1) == 0)
    #expect(bridge.nativeRotation(forScreen: 3) == 270)
    bridge.stop()

    let simulator = AppleSimulator(udid: id, state: "Booted", runtime: "iOS 27.1", version: "27.1", type: "iPhone Duo", family: "iPhone")
    let mirror = SimulatorMirror(simulator: simulator)
    mirror.activate()
    defer { mirror.stop() }
    try await mirror.start()
    try await waitForRotation { mirror.hasFrame }
    #expect(mirror.selectedScreen == 3)
    let original = mirror.orientation, size = mirror.size

    func turn() async throws {
        let target = mirror.orientation.next
        mirror.rotate()
        try await waitForRotation { mirror.orientation == target }
        #expect(mirror.selectedScreen == 3)
        #expect(mirror.size == size)
    }
    do {
        for _ in 0..<4 { try await turn() }
        #expect(mirror.orientation == original)
    } catch {
        for _ in 0..<4 where mirror.orientation != original { try? await turn() }
        throw error
    }
}

@MainActor private func waitForRotation(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    while !condition() {
        guard ContinuousClock.now < deadline else { throw MirrorError("The simulator didn't report its expected rotation.") }
        try await Task.sleep(for: .milliseconds(20))
    }
}
