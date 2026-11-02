import Foundation
import Testing
@testable import DevHub

private actor SimulatorSettingsBackend {
    var reads = 0
    var writes = 0
    var resets = 0
    var blocked: Set<Int>
    var pending: [Int: CheckedContinuation<SimulatorAppearance, Error>] = [:]
    var failWrites: Bool
    var value = SimulatorAppearance(dark: false, textSize: "large", borders: false)
    init(blocked: Set<Int> = [], failWrites: Bool = false) { self.blocked = blocked; self.failWrites = failWrites }
    func read() async throws -> SimulatorAppearance {
        reads += 1
        if blocked.contains(reads) {
            let index = reads
            return try await withCheckedThrowingContinuation { pending[index] = $0 }
        }
        return value
    }
    func release(_ index: Int, value: SimulatorAppearance? = nil, error: Bool = false) {
        if error { pending.removeValue(forKey: index)?.resume(throwing: MirrorError("query failed")) }
        else { pending.removeValue(forKey: index)?.resume(returning: value ?? self.value) }
    }
    func write(_ appearance: SimulatorAppearance, _ change: SimulatorAppearance.Change) throws {
        writes += 1
        if failWrites { throw MirrorError("write failed") }
    }
    func reset(_ appearance: SimulatorAppearance) { resets += 1 }
}

@MainActor private func settings(_ backend: SimulatorSettingsBackend) -> SimulatorSettingsState {
    SimulatorSettingsState(read: { try await backend.read() },
                           write: { try await backend.write($0, $1) }, reset: { await backend.reset($0) })
}
private func waitForReads(_ count: Int, backend: SimulatorSettingsBackend) async throws {
    for _ in 0..<200 {
        if await backend.reads >= count { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Settings query did not start")
    throw MirrorError("Timed out")
}

@MainActor @Test func simulatorSettingsQueriesAreSharedAndFreshValuesAreReused() async throws {
    let backend = SimulatorSettingsBackend(blocked: [1])
    let state = settings(backend)
    let first = Task { await state.refresh() }
    try await waitForReads(1, backend: backend)
    let second = Task { await state.refresh() }
    #expect(state.loading && state.appearance == nil)
    await backend.release(1)
    await first.value; await second.value
    #expect(await backend.reads == 1)
    #expect(!state.loading && state.appearance?.textSize == "large")
    await state.refresh()
    #expect(await backend.reads == 1)
}

@MainActor @Test func simulatorSettingsRemainVisibleDuringBackgroundRefreshAndFailures() async throws {
    let backend = SimulatorSettingsBackend(blocked: [2])
    let state = settings(backend)
    await state.refresh()
    let refresh = Task { await state.refresh(force: true) }
    try await waitForReads(2, backend: backend)
    #expect(state.loading && state.appearance?.dark == false)
    await backend.release(2, error: true)
    await refresh.value
    #expect(!state.loading && state.appearance?.textSize == "large")
    #expect(state.failure?.contains("query failed") == true)
}

@MainActor @Test func lateSimulatorSettingsQueryCannotUndoAUserChange() async throws {
    let backend = SimulatorSettingsBackend(blocked: [2])
    let state = settings(backend)
    await state.refresh()
    let oldQuery = Task { await state.refresh(force: true) }
    try await waitForReads(2, backend: backend)
    await state.apply(.appearance(true))
    #expect(state.appearance?.dark == true)
    await backend.release(2, value: SimulatorAppearance(dark: false, textSize: "small", borders: false))
    await oldQuery.value
    #expect(state.appearance?.dark == true && state.appearance?.textSize == "large")
    #expect(await backend.writes == 1)
}

@MainActor @Test func failedSimulatorSettingsWriteReloadsActualStateAndReportsTheError() async {
    let backend = SimulatorSettingsBackend(failWrites: true)
    let state = settings(backend)
    await state.refresh()
    await state.apply(.appearance(true))
    #expect(!state.saving && state.appearance?.dark == false)
    #expect(state.failure?.contains("write failed") == true)
    #expect(await backend.reads == 2)
}

@MainActor @Test func simulatorSettingsResetUpdatesCachedValuesAndPreservesCapabilities() async {
    let state = SimulatorSettingsState(read: { SimulatorAppearance(dark: true, textSize: "extra-large", borders: nil, native: false) },
                                       write: { _, _ in }, reset: { _ in })
    await state.refresh(); await state.reset()
    #expect(state.appearance?.dark == false && state.appearance?.textSize == "large")
    #expect(state.appearance?.borders == nil && state.appearance?.native == false)
    #expect(!state.saving)
}

@MainActor @Test func bootedSimulatorSettingsArePrefetchedRetainedAndEvictedOnShutdown() async {
    let backend = SimulatorSettingsBackend()
    let cache = SimulatorSettingsCache(create: { _ in settings(backend) })
    cache.prepare(["one", "two"])
    let first = cache.state(for: "one"), second = cache.state(for: "two")
    await first.refresh(); await second.refresh()
    #expect(first !== second && cache.state(for: "one") === first)
    #expect(first.appearance != nil && second.appearance != nil)
    cache.prepare(["one", "two"])
    await first.refresh(); await second.refresh()
    #expect(await backend.reads == 2)
    cache.prepare(["two"])
    #expect(cache.state(for: "one") !== first)
    #expect(cache.state(for: "two") === second)
}

@MainActor @Test func shutdownCancelsASettingsQueryWithoutPublishingItsLateResult() async throws {
    let backend = SimulatorSettingsBackend(blocked: [1])
    let cache = SimulatorSettingsCache(create: { _ in settings(backend) })
    cache.prepare(["one"])
    let first = cache.state(for: "one")
    try await waitForReads(1, backend: backend)
    cache.prepare([])
    await backend.release(1)
    await first.refresh()
    #expect(first.appearance == nil)
    #expect(cache.state(for: "one") !== first)
}

@MainActor @Test func cachedSimulatorSettingsRefreshAfterTheFreshnessWindow() async {
    let backend = SimulatorSettingsBackend()
    var instant = Date(timeIntervalSince1970: 0)
    let state = SimulatorSettingsState(read: { try await backend.read() }, write: { _, _ in }, reset: { _ in }, now: { instant })
    await state.refresh()
    instant = instant.addingTimeInterval(2)
    await state.refresh()
    #expect(await backend.reads == 1)
    instant = instant.addingTimeInterval(2)
    await state.refresh()
    #expect(await backend.reads == 2)
}
