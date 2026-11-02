import Foundation
import Testing
@testable import DevHub

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
    #expect(control.selected == .opened) // changes made outside DevHub still synchronize
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
