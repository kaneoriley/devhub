import Foundation
import Testing
@testable import DroidHub

@Test func foldingReadsCommittedStateAndLeavesIntermediatePosturesUnselected() {
    let dump = """
      mCommittedState=Optional[DeviceState{identifier=0, name='CLOSED'}]
      mPendingState=Optional[DeviceState{identifier=2, name='OPENED'}]
      mBaseState=Optional[DeviceState{identifier=2, name='OPENED'}]
    """
    #expect(FoldState.parse(dump) == .closed)
    #expect(FoldState.parse("Committed state: DeviceState{identifier=2, name='OPENED'}") == .opened)
    #expect(FoldState.parse("mCommittedState=DeviceState{identifier=1, name='HALF_OPENED'}") == nil)
    #expect(FoldState.parse("mCommittedState=Optional.empty") == nil)
}

@Test func foldingAvailabilityComesFromHardwareAndPostures() throws {
    #expect(FoldConfiguration.parse(config: [:]) == nil)
    var config = ["hw.sensor.hinge": "yes", "hw.sensor.posture_list": "1, 2, 3",
                  "hw.displayRegion.0.1.width": "1080", "hw.displayRegion.0.1.height": "2092"]
    let dedicated = try #require(FoldConfiguration.parse(config: config))
    #expect(dedicated.states == [.opened, .closed])
    #expect(dedicated.resizableMode == nil)
    #expect(dedicated.matchesClosedDisplay(CGSize(width: 1080, height: 2092)))
    #expect(dedicated.matchesClosedDisplay(CGSize(width: 2092, height: 1080)))
    config["hw.resizable.configs"] = "phone-0-1080-2400-420, foldable-1-2208-1840-420"
    let resizable = try #require(FoldConfiguration.parse(config: config))
    #expect(resizable.resizableMode == FormFactor.foldable.rawValue)
    config["hw.sensor.posture_list"] = "3"
    #expect(FoldConfiguration.parse(config: config)?.states == [.opened])
}

private actor FoldingRecorder {
    var calls: [[String]] = []
    func run(_ args: [String]) -> ADBResult {
        calls.append(args)
        return ADBResult(status: 0, output: args.contains("device_state") ? "mCommittedState=DeviceState{identifier=0, name='CLOSED'}" : "OK")
    }
}

@Test func closeUsesEmulatorFoldAndVerifiesCommittedState() async throws {
    let recorder = FoldingRecorder()
    let actions = DeviceActions(run: { await recorder.run($0) })
    try await actions.setFoldState(.closed, serial: "emulator-5556")
    #expect(await recorder.calls == [["-s", "emulator-5556", "emu", "fold"], ["-s", "emulator-5556", "shell", "dumpsys", "device_state"]])
    #expect(FoldState.opened.command == "unfold")
}

@MainActor private final class FoldTransitionGate {
    var commands: [FoldState] = []
    var completion: CheckedContinuation<Void, Error>?
    func apply(_ target: FoldState) async throws {
        commands.append(target)
        try await withCheckedThrowingContinuation { completion = $0 }
    }
    func finish(error: Error? = nil) {
        let next = completion; completion = nil
        if let error { next?.resume(throwing: error) } else { next?.resume() }
    }
    func waitForCommand(_ count: Int) async {
        while commands.count < count { await Task.yield() }
    }
}

@Test @MainActor func foldSelectionStaysOnRequestedStateUntilTheDeviceConfirmsIt() async {
    let control = FoldController(initial: .opened), device = FoldTransitionGate()
    let oldRead = control.revision
    control.select(.closed, apply: device.apply)
    #expect(control.selected == .closed && control.isBusy)
    await device.waitForCommand(1)
    control.synchronize(.opened, revision: oldRead)
    control.synchronize(.opened, revision: control.revision)
    #expect(control.selected == .closed)
    device.finish()
    await control.waitUntilIdle()
    #expect(control.selected == .closed && !control.isBusy)
    // A poll begun before the command cannot undo the completed transition either.
    control.synchronize(.opened, revision: oldRead)
    #expect(control.selected == .closed)
    control.synchronize(.opened, revision: control.revision)
    #expect(control.selected == .opened) // changes made outside DroidHub still synchronize
}

@Test @MainActor func rapidFoldChoicesStaySelectedWhileCommandsFinishInOrder() async {
    let control = FoldController(initial: .opened), device = FoldTransitionGate()
    control.select(.closed, apply: device.apply)
    await device.waitForCommand(1)
    control.select(.opened, apply: device.apply)
    #expect(control.selected == .opened)
    device.finish()
    await device.waitForCommand(2)
    #expect(device.commands == [.closed, .opened])
    #expect(control.selected == .opened && control.isBusy)
    device.finish()
    await control.waitUntilIdle()
    #expect(control.confirmed == .opened && control.selected == .opened)
}

@Test @MainActor func failedFoldReturnsToConfirmedStateAndReportsTheError() async {
    let control = FoldController(initial: .closed), device = FoldTransitionGate()
    control.select(.opened, apply: device.apply)
    await device.waitForCommand(1)
    device.finish(error: MirrorError("Fold failed"))
    await control.waitUntilIdle()
    #expect(control.selected == .closed && !control.isBusy)
    #expect(control.failure?.contains("Fold failed") == true)
}
