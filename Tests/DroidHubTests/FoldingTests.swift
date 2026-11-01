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
