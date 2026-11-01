import Foundation
import Testing
@testable import DroidHub

@Test func rotationMapsScreenAndInputInAllFourOrientations() {
    let size = CGSize(width: 1080, height: 2400)
    let point = CGPoint(x: 0.2, y: 0.7)
    let vector = CGPoint(x: 2, y: -3)
    let points = [point, CGPoint(x: 0.7, y: 0.8), CGPoint(x: 0.8, y: 0.3), CGPoint(x: 0.3, y: 0.2)]
    let vectors = [vector, CGPoint(x: -3, y: -2), CGPoint(x: -2, y: 3), CGPoint(x: 3, y: 2)]
    for turn in 0..<4 {
        let rotation = QuarterTurn(turn)
        let actual = rotation.sourcePoint(point)
        #expect(abs(actual.x - points[turn].x) < 0.0001 && abs(actual.y - points[turn].y) < 0.0001)
        #expect(rotation.sourceVector(vector) == vectors[turn])
        #expect(rotation.size(size) == (turn % 2 == 0 ? size : CGSize(width: 2400, height: 1080)))
    }
    #expect(QuarterTurn(3).next == .zero)
    #expect(QuarterTurn(-1) == QuarterTurn(3))
}

@Test func physicalOrientationUsesEmulatorAccelerationRatherThanAppRotation() {
    for (turn, values) in ["0:9.81:0", "-9.81:0:0", "0:-9.81:0", "9.81:0:0"].enumerated() {
        #expect(QuarterTurn.acceleration("acceleration = \(values)\r\nOK\r\n") == QuarterTurn(turn))
    }
    #expect(QuarterTurn.acceleration("KO: unknown sensor") == nil)
    #expect(QuarterTurn.acceleration("acceleration = 0:0:0") == nil)
}

private actor DisplayBackend {
    let presets = DisplayPreset.parse("phone-0-1080-2400-420,foldable-1-2208-1840-420,tablet-2-1920-1200-240")
    var mode = 0
    var physical = 0
    var resizeCalls: [Int] = []
    var rotateCalls = 0
    var delays: [Duration] = []
    var firstTransition: CheckedContinuation<Void, Never>?
    var waitingForTransition: CheckedContinuation<Void, Never>?
    var blockFirstTransition = false
    var failFirstTransition = false

    func blockFirst(fail: Bool = false) { blockFirstTransition = true; failFirstTransition = fail }
    func waitForTransition() async {
        if firstTransition != nil { return }
        await withCheckedContinuation { waitingForTransition = $0 }
    }
    func releaseTransition() { firstTransition?.resume(); firstTransition = nil }

    func run(_ args: [String]) -> ADBResult {
        if args.contains("resize-display"), let id = Int(args.last ?? "") {
            mode = id
            resizeCalls.append(id)
        }
        let preset = presets[mode]
        let output: String
        if args.suffix(2) == ["wm", "size"] { output = "Physical size: \(preset.width)x\(preset.height)" }
        else if args.suffix(2) == ["wm", "density"] { output = "Physical density: \(preset.density)" }
        else if args.last == "device_state" { output = "mCommittedState=DeviceState{name='OPENED'}" }
        else { output = "OK" }
        return ADBResult(status: 0, output: output)
    }

    func console(_ command: String) -> String {
        if command == "rotate" { physical = (physical + 1) % 4; rotateCalls += 1; return "OK\r\n" }
        let values = ["0:9.81:0", "-9.81:0:0", "0:-9.81:0", "9.81:0:0"][physical]
        return "acceleration = \(values)\r\nOK\r\n"
    }

    func pause(_ duration: Duration) async throws {
        delays.append(duration)
        if blockFirstTransition && duration == .milliseconds(2250) {
            blockFirstTransition = false
            await withCheckedContinuation {
                firstTransition = $0
                waitingForTransition?.resume(); waitingForTransition = nil
            }
            if failFirstTransition { throw MirrorError("Superseded transition failed") }
        }
    }

    nonisolated var actions: DeviceActions {
        DeviceActions(run: { await self.run($0) }, console: { _, command in await self.console(command) }, pause: { try await self.pause($0) })
    }
}

@Test @MainActor func rapidFormChangesFinishCurrentTransitionThenApplyLatestSelection() async throws {
    let backend = DisplayBackend()
    await backend.blockFirst()
    let presets = await backend.presets
    let controller = DisplayController(serial: "emulator-5556", isEmulator: true, actions: backend.actions)
    controller.selectedPreset = 0
    controller.select(presets[2])
    await backend.waitForTransition()
    #expect(controller.isBusy && controller.isChangingPreset)
    controller.select(presets[0])
    controller.select(presets[1])
    #expect(await backend.resizeCalls == [2])
    await backend.releaseTransition()
    await controller.waitUntilIdle()
    #expect(await backend.resizeCalls == [2, 1])
    #expect(await backend.delays == [.milliseconds(2250), .milliseconds(2250)])
    #expect(controller.selectedPreset == 1 && controller.orientation == .zero)
    #expect(!controller.isBusy && controller.failure == nil)
}

@Test @MainActor func failedSupersededFormChangeStillAppliesLatestSelection() async throws {
    let backend = DisplayBackend()
    await backend.blockFirst(fail: true)
    let presets = await backend.presets
    let controller = DisplayController(serial: "emulator-5556", isEmulator: true, actions: backend.actions)
    controller.selectedPreset = 0
    controller.select(presets[2])
    await backend.waitForTransition()
    controller.select(presets[1])
    await backend.releaseTransition()
    await controller.waitUntilIdle()
    #expect(await backend.resizeCalls == [2, 1])
    #expect(controller.selectedPreset == 1 && controller.failure == nil)
}

@Test @MainActor func rotationDoesNotDependOnAndroidOrientationAndPresetRestoresNaturalLayout() async throws {
    let backend = DisplayBackend()
    let controller = DisplayController(serial: "emulator-5556", isEmulator: true, actions: backend.actions)
    controller.selectedPreset = 0
    controller.rotate()
    await controller.waitUntilIdle()
    #expect(controller.orientation == QuarterTurn(1))
    #expect(await backend.physical == 1)
    let tablet = await backend.presets[2]
    controller.select(tablet)
    await controller.waitUntilIdle()
    #expect(controller.orientation == .zero && controller.selectedPreset == 2)
    #expect(await backend.physical == 0)
    #expect(await backend.rotateCalls == 4)
    controller.rotate(); controller.rotate(); controller.rotate(); controller.rotate()
    await controller.waitUntilIdle()
    #expect(controller.orientation == .zero && controller.failure == nil)
    #expect(await backend.rotateCalls == 4)
}
