import Foundation
import Testing
import simd
@testable import DevHub

private actor ColorSettingsBackend {
    var enabled = "null"
    var mode = "null"
    var fail = false
    var calls: [[String]] = []
    func configure(enabled: String, mode: String, fail: Bool = false) { self.enabled = enabled; self.mode = mode; self.fail = fail }
    func run(_ args: [String]) -> ToolResult {
        calls.append(args)
        if fail { return ToolResult(status: 1, output: "Permission denied") }
        if args.contains("get") { return ToolResult(status: 0, output: args.last == AndroidColorFilter.enabledKey ? enabled : mode) }
        if args.contains("put"), args.count >= 2 {
            if args[args.count - 2] == AndroidColorFilter.enabledKey { enabled = args.last! }
            if args[args.count - 2] == AndroidColorFilter.modeKey { mode = args.last! }
        }
        return ToolResult(status: 0, output: "")
    }
}

@Test func androidColorFilterReadsDefaultsSimulationAndAccessibilityModesWithoutConfusingThem() async {
    let backend = ColorSettingsBackend()
    let none = await AndroidColorFilter.load(serial: "test", previous: nil) { await backend.run($0) }
    #expect(none?.mode == -1)
    for mode in [0, 1, 2, 3, 11, 12, 13, 99] {
        await backend.configure(enabled: "1", mode: String(mode))
        let filter = await AndroidColorFilter.load(serial: "test", previous: nil) { await backend.run($0) }
        #expect(filter?.mode == mode)
        #expect((AndroidColorFilter.Mode(rawValue: mode) != nil) == (mode <= 3))
    }
    await backend.configure(enabled: "1", mode: "null")
    #expect(await AndroidColorFilter.load(serial: "test", previous: nil) { await backend.run($0) }?.mode == 12)
    await backend.configure(enabled: "0", mode: "2")
    #expect(await AndroidColorFilter.load(serial: "test", previous: nil) { await backend.run($0) }?.mode == -1)
}

@Test func androidColorFilterKeepsCachedAvailabilityOnReadFailuresAndHidesAnUnsupportedFirstRead() async {
    let backend = ColorSettingsBackend()
    let previous = AndroidColorFilter(mode: 2)
    await backend.configure(enabled: "1", mode: "2", fail: true)
    #expect(await AndroidColorFilter.load(serial: "test", previous: previous) { await backend.run($0) } == previous)
    #expect(await AndroidColorFilter.load(serial: "test", previous: nil) { await backend.run($0) } == nil)
    await backend.configure(enabled: "not a boolean", mode: "2")
    #expect(await AndroidColorFilter.load(serial: "test", previous: previous) { await backend.run($0) } == previous)
}

@Test func androidColorFilterCommandsUseCurrentUserAndSimulationValuesAndNonePreservesTheMode() async throws {
    let backend = ColorSettingsBackend()
    let prefix = ["-s", "chosen-device", "shell", "settings", "--user", "current", "put", "secure"]
    try await AndroidColorFilter.apply(.protanomaly, serial: "chosen-device") { await backend.run($0) }
    try await AndroidColorFilter.apply(.none, serial: "chosen-device") { await backend.run($0) }
    #expect(await backend.calls == [prefix + [AndroidColorFilter.modeKey, "1"],
                                    prefix + [AndroidColorFilter.enabledKey, "1"],
                                    prefix + [AndroidColorFilter.enabledKey, "0"]])
    #expect(await backend.mode == "1")
    await backend.configure(enabled: "0", mode: "1", fail: true)
    await #expect(throws: (any Error).self) {
        try await AndroidColorFilter.apply(.grayscale, serial: "chosen-device") { await backend.run($0) }
    }
}

@Test func androidResetTurnsOffSupportedColorFilters() async throws {
    let backend = ColorSettingsBackend()
    // Other reset commands only need a known default-theme response for this focused check.
    try await AndroidSettingsDefaults.reset(serial: "test", settings: AndroidUISettings(), colorFilterAvailable: true) { args in
        if args.contains("lookup") { return ToolResult(status: 0, output: "1") }
        if args.contains(AndroidColorFilter.enabledKey) { return await backend.run(args) }
        return ToolResult(status: 0, output: "null")
    }
    #expect(await backend.calls == [["-s", "test", "shell", "settings", "--user", "current", "put", "secure", AndroidColorFilter.enabledKey, "0"]])
}

@Test func androidPreviewSimulationPreservesNeutralColorsAndRemovesTheMissingCone() throws {
    #expect(AndroidColorTransform(mode: -1) == nil && AndroidColorTransform(mode: nil) == nil)
    #expect(AndroidColorTransform(mode: 12) == nil)
    for mode in 0...3 {
        let matrix = try #require(AndroidColorTransform(mode: mode)).matrix
        let white = matrix * SIMD3<Float>(repeating: 1)
        #expect(simd_length(white - SIMD3<Float>(repeating: 1)) < 0.0001)
        #expect(abs(simd_determinant(matrix)) < 0.0001)
        for sample in [SIMD3<Float>(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)] {
            #expect(simd_length(matrix * (matrix * sample) - matrix * sample) < 0.0001)
        }
    }
}

@Test func androidColorFilterLiveRoundTrip() async throws {
    guard let serial = ProcessInfo.processInfo.environment["DEVHUB_TEST_ANDROID_COLOR_FILTER"], serial.hasPrefix("emulator-") else { return }
    let prefix = ["-s", serial, "shell", "settings", "--user", "current"]
    var original: [String: String] = [:]
    for key in [AndroidColorFilter.enabledKey, AndroidColorFilter.modeKey] {
        let result = try await runADB(prefix + ["get", "secure", key]); try result.checked()
        let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value == "null" || Int(value) != nil else { throw MirrorError("Unexpected colour-filter value; refusing to change the device.") }
        original[key] = value
    }
    func restore() async throws {
        for key in [AndroidColorFilter.modeKey, AndroidColorFilter.enabledKey] {
            let value = original[key]!
            try await runADB(prefix + (value == "null" ? ["delete", "secure", key] : ["put", "secure", key, value])).checked()
        }
    }
    do {
        for mode in AndroidColorFilter.Mode.allCases {
            try await AndroidColorFilter.apply(mode, serial: serial)
            #expect(await AndroidColorFilter.load(serial: serial, previous: nil, run: runADB)?.mode == mode.rawValue)
        }
    } catch { try? await restore(); throw error }
    try await restore()
}
