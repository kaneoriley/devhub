import Foundation
import SimulatorBridge
import Testing
@testable import DevHub

/// Opt in with a booted Duo's UDID. Exercise a fresh HID connection, including
/// its very first fold event, and return the simulator to its original state.
@Test @MainActor func freshSimulatorHIDConnectionCanFoldAndRestore() async throws {
    guard let udid = ProcessInfo.processInfo.environment["DEVHUB_TEST_FOLDABLE_SIMULATOR"] else { return }
    let directory = try await Simctl.developerDirectory()
    let bridge = try DHSimulatorBridge(deviceID: udid, developerDirectory: directory)
    let (screens, frames) = AsyncThrowingStream<Int, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
    bridge.followsActiveDisplays = true
    bridge.frameHandler = { _, _, screen in frames.yield(screen) }
    bridge.errorHandler = { message in frames.finish(throwing: MirrorError(message)) }
    defer { bridge.stop(); frames.finish() }
    try await Task.detached { try bridge.start() }.value
    let original = try await simulatorScreen(screens) { $0 == 1 || $0 == 3 }
    do {
        bridge.setFolded(original != 1)
        _ = try await simulatorScreen(screens) { $0 == (original == 1 ? 3 : 1) }
    } catch {
        bridge.setFolded(original == 1)
        _ = try? await simulatorScreen(screens) { $0 == original }
        throw error
    }
    bridge.setFolded(original == 1)
    _ = try await simulatorScreen(screens) { $0 == original }
}

private func simulatorScreen(_ screens: AsyncThrowingStream<Int, Error>, matching: @escaping @Sendable (Int) -> Bool) async throws -> Int {
    try await withThrowingTaskGroup(of: Int.self) { group in
        group.addTask {
            for try await screen in screens where matching(screen) { return screen }
            throw MirrorError("Simulator display stream ended.")
        }
        group.addTask {
            try await Task.sleep(for: .seconds(8))
            throw MirrorError("Simulator didn't finish its display transition.")
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
