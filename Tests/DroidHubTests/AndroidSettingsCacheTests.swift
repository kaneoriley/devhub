import Foundation
import Testing
@testable import DroidHub

private actor AndroidCacheBackend {
    var reads: [String: Int] = [:]
    var packageQueries = 0
    var serviceQueries = 0
    var blocked: Set<Int> = []
    var pending: [String: CheckedContinuation<ADBResult, Error>] = [:]
    var modes: [String: String] = [:]
    var failCapabilities = false
    var failDisplay = false
    var failValues = false
    var failWrites = false
    var installed = true

    func block(_ index: Int) { blocked.insert(index) }
    func setFailures(capabilities: Bool = false, display: Bool = false, values: Bool = false, writes: Bool = false) {
        failCapabilities = capabilities; failDisplay = display; failValues = values; failWrites = writes
    }
    func setInstalled(_ value: Bool) { installed = value }
    func setMode(_ value: String, serial: String) { modes[serial] = value }
    func release(_ index: Int, serial: String = "emulator-9000", mode: String = "no") {
        pending.removeValue(forKey: "\(serial):\(index)")?.resume(returning: ADBResult(status: 0, output: "Night mode: \(mode)"))
    }
    func run(_ args: [String]) async throws -> ADBResult {
        let serial = args[1], command = Array(args.dropFirst(3))
        func ok(_ text: String) -> ADBResult { ADBResult(status: 0, output: text) }
        let failed = ADBResult(status: 1, output: "temporary query failure")
        if command == ["cmd", "uimode", "night"] {
            reads[serial, default: 0] += 1
            let index = reads[serial]!
            if blocked.contains(index) { return try await withCheckedThrowingContinuation { pending["\(serial):\(index)"] = $0 } }
            return failValues ? failed : ok("Night mode: \(modes[serial] ?? "no")")
        }
        if command.starts(with: ["cmd", "uimode", "night"]), command.count == 4 {
            if failWrites { return ADBResult(status: 1, output: "write rejected") }
            modes[serial] = command.last; return ok("")
        }
        if command.contains("lookup") { return ok("1") }
        if command.contains("list"), command.contains("overlay") {
            return failCapabilities ? failed : ok("[x] \(AndroidUISettings.gesturesOverlay)\n[ ] \(AndroidUISettings.buttonsOverlay)")
        }
        if command.contains("packages") {
            packageQueries += 1
            return failCapabilities ? failed : ok(installed ? "package:\(AndroidUISettings.talkBackPackage)" : "")
        }
        if command.contains("query-services") {
            serviceQueries += 1
            return failCapabilities ? failed : ok(installed ? "2 services found:\n\(AndroidUISettings.talkBackService)\n\(AndroidUISettings.selectToSpeakService)" : "No services found")
        }
        if command == ["wm", "size"] { return failDisplay ? failed : ok("Physical size: 1080x2400") }
        if command == ["wm", "density"] { return failDisplay ? failed : ok("Physical density: 420") }
        if command.last == "font_scale" { return ok("1") }
        if command.last == "show_touches" { return ok("0") }
        if command.first == "getprop" { return ok("false") }
        if command.contains("get"), command.contains("secure") { return ok("null") }
        return failWrites ? ADBResult(status: 1, output: "write rejected") : ok("")
    }
}

private func androidCacheDevice(_ id: String = "one", serial: String? = "emulator-9000") -> Device {
    Device(id: "avd:cache-test-\(id)", name: id, detail: "Emulator", avd: "cache-test-\(id)", serial: serial)
}
@MainActor private func androidCacheState(_ backend: AndroidCacheBackend, device: Device = androidCacheDevice(), now: @escaping () -> Date = Date.init) -> AndroidSettingsState {
    AndroidSettingsState(device: device, run: { try await backend.run($0) }, now: now, recordDensity: { _, _, _ in })
}
private func waitForAndroidReads(_ count: Int, serial: String = "emulator-9000", backend: AndroidCacheBackend) async throws {
    for _ in 0..<200 {
        if await backend.reads[serial, default: 0] >= count { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw MirrorError("Timed out waiting for Android settings")
}

@MainActor @Test func androidDeviceSwitchesReuseSeparatePrefetchedCapabilitiesAndValues() async {
    let backend = AndroidCacheBackend()
    let one = androidCacheDevice(), two = androidCacheDevice("two", serial: "emulator-9002")
    await backend.setMode("yes", serial: "emulator-9002")
    let cache = AndroidSettingsCache(create: { androidCacheState(backend, device: $0) })
    cache.prepare([one, two])
    let first = cache.state(for: one), second = cache.state(for: two)
    await first.refresh(); await second.refresh()
    #expect(first !== second && first.snapshot?.nightMode == "no" && second.snapshot?.nightMode == "yes")
    #expect(first.snapshot?.runtime.talkBackAvailable == true && second.snapshot?.runtime.display != nil)
    for _ in 0..<4 {
        #expect(cache.state(for: one) === first && cache.state(for: two) === second)
        await first.refresh(); await second.refresh()
    }
    #expect(await backend.reads == ["emulator-9000": 1, "emulator-9002": 1])
}

@MainActor @Test func androidBackgroundRefreshKeepsControlsAndSkipsCapabilityProbes() async {
    let backend = AndroidCacheBackend()
    let state = androidCacheState(backend)
    await state.refresh()
    await backend.setFailures(capabilities: true, display: true)
    await state.refresh(force: true)
    #expect(state.snapshot?.runtime.navigation == .gestures)
    #expect(state.snapshot?.runtime.talkBackAvailable == true && state.snapshot?.runtime.selectToSpeakAvailable == true)
    #expect(state.snapshot?.runtime.display?.physicalDensity == 420)
    #expect(await backend.packageQueries == 1)
    #expect(await backend.serviceQueries == 1)
}

@MainActor @Test func androidCapabilityChangesRefreshAfterTheirOwnIntervalWithoutDroppingFailures() async {
    let backend = AndroidCacheBackend()
    var instant = Date(timeIntervalSince1970: 0)
    let state = androidCacheState(backend, now: { instant })
    await state.refresh()
    await backend.setFailures(capabilities: true)
    instant = instant.addingTimeInterval(61)
    await state.refresh()
    #expect(state.snapshot?.runtime.navigation == .gestures && state.snapshot?.runtime.talkBackAvailable == true)
    await backend.setFailures()
    await backend.setInstalled(false)
    instant = instant.addingTimeInterval(61)
    await state.refresh()
    #expect(state.snapshot?.runtime.talkBackAvailable == false && state.snapshot?.runtime.selectToSpeakAvailable == false)
    #expect(await backend.packageQueries == 3)
}

@MainActor @Test func androidSettingsReadsCoalesceAndLateRepliesCannotUndoChanges() async throws {
    let backend = AndroidCacheBackend()
    let state = androidCacheState(backend)
    await state.refresh()
    await backend.block(2)
    let first = Task { await state.refresh(force: true) }
    try await waitForAndroidReads(2, backend: backend)
    let second = Task { await state.refresh() }
    #expect(state.loading && state.snapshot?.runtime.talkBackAvailable == true)
    await state.apply(.appearance("yes"))
    await backend.release(2, mode: "no")
    await first.value; await second.value
    #expect(state.snapshot?.nightMode == "yes")
    #expect(await backend.reads["emulator-9000"] == 2)
}

@MainActor @Test func androidFailedQueriesAndWritesKeepKnownAvailability() async {
    let backend = AndroidCacheBackend()
    let state = androidCacheState(backend)
    await state.refresh()
    await backend.setFailures(values: true)
    await state.refresh(force: true)
    #expect(state.snapshot?.runtime.navigation == .gestures && state.snapshot?.runtime.display != nil)
    #expect(state.failure?.contains("temporary query failure") == true)
    await backend.setFailures(writes: true)
    await state.apply(.appearance("yes"))
    #expect(state.snapshot?.nightMode == "no" && state.snapshot?.runtime.talkBackAvailable == true)
    #expect(state.failure?.contains("write rejected") == true && !state.saving)
}

@MainActor @Test func androidCacheRetainsAvailabilityOfflineAndRechecksTheNextConnection() async {
    let backend = AndroidCacheBackend()
    let device = androidCacheDevice()
    let cache = AndroidSettingsCache(create: { androidCacheState(backend, device: $0) })
    let original = cache.state(for: device)
    await original.refresh()
    var offline = device; offline.serial = nil
    cache.prepare([offline])
    #expect(cache.state(for: offline) === original && original.serial == nil)
    #expect(original.snapshot?.runtime.navigation != nil && original.snapshot?.runtime.talkBackAvailable == true)
    let queries = await backend.packageQueries
    var reconnected = device; reconnected.serial = "emulator-9002"
    cache.prepare([reconnected])
    await original.refresh()
    #expect(original.serial == "emulator-9002" && original.snapshot?.runtime.display != nil)
    #expect(await backend.packageQueries == queries + 1)
}

@MainActor @Test func anOldAndroidConnectionCannotOverwriteTheNewConnectionsSettings() async throws {
    let backend = AndroidCacheBackend()
    await backend.block(1)
    let state = androidCacheState(backend)
    let old = Task { await state.refresh() }
    try await waitForAndroidReads(1, backend: backend)
    var next = androidCacheDevice(); next.serial = "emulator-9002"
    await backend.setMode("yes", serial: "emulator-9002")
    // Release the new connection's first read separately, then the obsolete reply.
    state.configure(next)
    let fresh = Task { await state.refresh() }
    try await waitForAndroidReads(1, serial: "emulator-9002", backend: backend)
    await backend.release(1, serial: "emulator-9002", mode: "yes")
    await fresh.value
    await backend.release(1, mode: "no")
    await old.value
    #expect(state.snapshot?.nightMode == "yes")
}

@MainActor @Test func androidResetReloadsTheCachedValuesAndKeepsCapabilities() async {
    let backend = AndroidCacheBackend()
    let state = androidCacheState(backend)
    await state.refresh()
    await state.apply(.appearance("yes"))
    await state.reset()
    #expect(state.snapshot?.nightMode == "no")
    #expect(state.snapshot?.runtime.talkBackAvailable == true && state.snapshot?.runtime.display != nil)
    #expect(!state.saving && state.failure == nil)
}

/// Read-only opt-in check of the complete snapshot against a running emulator.
@MainActor @Test func androidSettingsCacheReadsACompleteLiveSnapshot() async throws {
    guard let serial = ProcessInfo.processInfo.environment["DROIDHUB_TEST_ANDROID_SETTINGS_CACHE"], serial.hasPrefix("emulator-") else { return }
    let state = AndroidSettingsState(device: Device(id: serial, name: "Settings test", detail: "Android", serial: serial))
    await state.refresh()
    let first = try #require(state.snapshot)
    #expect(["yes", "no", "auto"].contains(first.nightMode))
    #expect(first.fontScale > 0 && first.runtime.display != nil)
    #expect(state.failure == nil)
    await state.refresh()
    #expect(state.snapshot?.runtime.display == first.runtime.display)
    #expect(!state.loading)
}
