import Testing
@testable import DevHub

@MainActor private final class TestSimulatorSession: DeviceSession {
    var canReuse = true
    var activations = 0
    var pauses = 0
    var stops = 0
    func activate() { activations += 1 }
    func deactivate() { pauses += 1 }
    func stop() { stops += 1 }
}

@Test @MainActor func disconnectedSessionIsReplacedOnTheFirstRetry() {
    let cache = DeviceSessionCache<TestSimulatorSession>()
    let old = cache.acquire("android") { TestSimulatorSession() }
    old.session.canReuse = false
    let replacement = cache.acquire("android") { TestSimulatorSession() }
    #expect(replacement.session !== old.session && old.session.stops == 1)
    cache.release(old)
    #expect(replacement.session.pauses == 0 && replacement.session.stops == 0)
    cache.release(replacement)
}

@Test @MainActor func switchingBackReusesConnectionAndPausesOffscreenRendering() {
    let cache = DeviceSessionCache<TestSimulatorSession>()
    let first = cache.acquire("phone") { TestSimulatorSession() }
    cache.release(first)
    #expect(first.session.pauses == 1)
    var recreated = false
    let again = cache.acquire("phone") { recreated = true; return TestSimulatorSession() }
    #expect(!recreated && again.session === first.session)
    #expect(again.session.activations == 2 && again.session.stops == 0)
    cache.release(again)
}

@Test @MainActor func delayedViewCancellationDoesNotPauseTheNewSelection() {
    let cache = DeviceSessionCache<TestSimulatorSession>()
    let old = cache.acquire("phone") { TestSimulatorSession() }
    let current = cache.acquire("phone") { TestSimulatorSession() }
    cache.release(old)
    cache.release(old)
    #expect(current.session.pauses == 0 && current.session.activations == 1)
    cache.release(current)
    #expect(current.session.pauses == 1)
}

@Test @MainActor func simulatorCacheEvictsLeastRecentlyUsedInactiveConnection() {
    let cache = DeviceSessionCache<TestSimulatorSession>(capacity: 2)
    let phone = cache.acquire("phone") { TestSimulatorSession() }; cache.release(phone)
    let tablet = cache.acquire("tablet") { TestSimulatorSession() }; cache.release(tablet)
    let recent = cache.acquire("phone") { TestSimulatorSession() }; cache.release(recent)
    let duo = cache.acquire("duo") { TestSimulatorSession() }
    #expect(tablet.session.stops == 1)
    #expect(phone.session.stops == 0 && duo.session.stops == 0)
    cache.release(duo)
}

@Test @MainActor func shutdownAndFailedConnectionsAreRemovedWithoutAffectingReplacement() {
    let cache = DeviceSessionCache<TestSimulatorSession>()
    let old = cache.acquire("phone") { TestSimulatorSession() }
    cache.retain([])
    #expect(old.session.stops == 1)
    let replacement = cache.acquire("phone") { TestSimulatorSession() }
    cache.release(old); cache.discard(old)
    #expect(replacement.session.pauses == 0 && replacement.session.stops == 0)
    cache.discard(replacement)
    #expect(replacement.session.stops == 1)
}

@Test @MainActor func visibleTilesStayActiveBeyondTheIdleCacheLimitAndPauseWhenLeaving() {
    let cache = DeviceSessionCache<TestSimulatorSession>(capacity: 2)
    let tiles = (0..<5).map { index in cache.acquire("tile-\(index)") { TestSimulatorSession() } }
    #expect(tiles.allSatisfy { $0.session.activations == 1 && $0.session.pauses == 0 && $0.session.stops == 0 })
    let selected = cache.acquire("tile-0") { TestSimulatorSession() }
    for tile in tiles { cache.release(tile) }
    #expect(selected.session === tiles[0].session)
    #expect(selected.session.pauses == 0 && selected.session.stops == 0)
    #expect(tiles.dropFirst().allSatisfy { $0.session.pauses == 1 })
    #expect(tiles.dropFirst().filter { $0.session.stops == 1 }.count == 3)
    cache.release(selected)
    #expect(selected.session.pauses == 1)
}
