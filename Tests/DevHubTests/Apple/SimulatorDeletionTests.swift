import Foundation
import Testing
@testable import DevHub

private let deletionDeviceID = "C88E6435-8EC0-49CE-A9DB-0406B5564F57"

private actor SimulatorDeletionRecorder {
    var calls: [[String]] = []
    let state: String?
    let deleteStatus: Int32
    init(state: String?, deleteStatus: Int32 = 0) { self.state = state; self.deleteStatus = deleteStatus }
    func run(_ args: [String]) -> ToolResult {
        calls.append(args)
        if args.first == "list" {
            let entries = state.map { [["udid": deletionDeviceID, "state": $0]] } ?? []
            let data = try! JSONSerialization.data(withJSONObject: ["devices": ["runtime": entries]])
            return ToolResult(status: 0, output: String(decoding: data, as: UTF8.self))
        }
        return ToolResult(status: deleteStatus, output: deleteStatus == 0 ? "" : "Simulator deletion failed")
    }
}

@Test func deletingAShutdownSimulatorTargetsOnlyItsUDID() async throws {
    let recorder = SimulatorDeletionRecorder(state: "Shutdown")
    try await Simctl.deleteSimulator(deletionDeviceID) { await recorder.run($0) }
    #expect(await recorder.calls == [["list", "devices", "--json"], ["delete", deletionDeviceID]])
}

@Test func simulatorDeletionRejectsFreshlyBootedOrTransitioningDevices() async {
    for state in ["Booted", "Booting", "Shutting Down", "Creating"] {
        let recorder = SimulatorDeletionRecorder(state: state)
        await #expect(throws: (any Error).self) {
            try await Simctl.deleteSimulator(deletionDeviceID) { await recorder.run($0) }
        }
        #expect(await recorder.calls == [["list", "devices", "--json"]])
    }
}

@Test func simulatorDeletionRejectsMissingDevicesAndBroadSelectors() async {
    let recorder = SimulatorDeletionRecorder(state: nil)
    await #expect(throws: (any Error).self) {
        try await Simctl.deleteSimulator(deletionDeviceID) { await recorder.run($0) }
    }
    #expect(await recorder.calls == [["list", "devices", "--json"]])
    let invalid = SimulatorDeletionRecorder(state: "Shutdown")
    for identifier in ["all", "unavailable", "booted", "not-a-uuid"] {
        await #expect(throws: (any Error).self) {
            try await Simctl.deleteSimulator(identifier) { await invalid.run($0) }
        }
    }
    #expect(await invalid.calls.isEmpty)
}

@Test func simulatorDeletionReportsCommandFailures() async {
    let recorder = SimulatorDeletionRecorder(state: "Shutdown", deleteStatus: 1)
    do {
        try await Simctl.deleteSimulator(deletionDeviceID) { await recorder.run($0) }
        Issue.record("A failed deletion was reported as successful")
    } catch { #expect(String(describing: error).contains("Simulator deletion failed")) }
}
