import Foundation
import Testing
@testable import DroidHub

@Test func simulatorAppearanceParsesDeviceHubsSettingsAndOptionalCapabilities() throws {
    let state = try SimulatorAppearance.parse(Data(#"{"result":{"userInterfaceStyle":"dark","textSize":"Accessibility Extra Extra Large","showBorders":{"enabled":true}}}"#.utf8))
    #expect(state.dark == true && state.textSize == "accessibility-extra-extra-large" && state.borders == true)
    let partial = try SimulatorAppearance.parse(Data(#"{"result":{"userInterfaceStyle":"unsupported","textSize":"unknown"}}"#.utf8))
    #expect(partial.dark == nil && partial.textSize == nil && partial.borders == nil)
}

@Test func simulatorSettingsCommandsUseNativeAppearanceAndEnableTheExtendedTextRange() throws {
    let state = SimulatorAppearance(dark: false, textSize: "large", borders: false)
    let (tool, borders) = try state.command(.borders(true), id: "simulator")
    #expect(tool == "devicectl")
    #expect(borders == ["device", "settings", "appearance", "--device", "simulator", "--show-borders", "on", "--quiet", "--timeout", "10"])
    #expect(try state.command(.appearance(true), id: "simulator").1.contains("dark"))
    for index in SimulatorAppearance.textSizes.indices {
        let args = try state.command(.textSize(index), id: "simulator").1
        #expect(args.contains(SimulatorAppearance.textSizes[index]))
        #expect(args.contains("--larger-accessibility-sizes") == (index >= 7))
    }
    #expect(throws: (any Error).self) { try state.command(.textSize(-1), id: "simulator") }
    #expect(throws: (any Error).self) { try state.command(.textSize(12), id: "simulator") }
}

private actor AppearanceRecorder {
    var calls: [(String, [String])] = []
    func run(_ tool: String, _ args: [String]) -> ADBResult {
        calls.append((tool, args))
        if tool == "devicectl" { return ADBResult(status: 1, output: "Unknown subcommand") }
        return ADBResult(status: 0, output: args.last == "appearance" ? "dark\n" : "extra-large\n")
    }
}

@Test func earlierXcodesUseSimctlForAppearanceAndTextSizeAndOmitUnsupportedBorders() async throws {
    let recorder = AppearanceRecorder()
    let state = try await SimulatorAppearance.load("older") { await recorder.run($0, $1) }
    #expect(!state.native && state.dark == true && state.textSize == "extra-large" && state.borders == nil)
    #expect(try state.command(.appearance(false), id: "older").1 == ["ui", "older", "appearance", "light"])
    #expect(try state.command(.textSize(3), id: "older").1 == ["ui", "older", "content_size", "large"])
    #expect(throws: (any Error).self) { try state.command(.borders(true), id: "older") }
    let calls = await recorder.calls
    #expect(calls.map { $0.0 } == ["devicectl", "simctl", "simctl"])
}

/// Opt in to verify the real simulator and restore each original setting afterward.
@Test func simulatorAppearanceSettingsRoundTrip() async throws {
    guard let id = ProcessInfo.processInfo.environment["DROIDHUB_TEST_SETTINGS_SIMULATOR"] else { return }
    let original = try await SimulatorAppearance.load(id)
    let snapshot = try await Simctl.runTool("devicectl", ["device", "info", "appearance", "--device", id, "--quiet", "--json-output", "-", "--timeout", "10"])
    try snapshot.checked()
    let document = try JSONSerialization.jsonObject(with: Data(snapshot.output.utf8)) as? [String: Any]
    let originalExtended = (document?["result"] as? [String: Any])?["largerAccessibilitySizesEnabled"] as? Bool
    let dark = try #require(original.dark), borders = try #require(original.borders)
    let index = try #require(original.textSize.flatMap { SimulatorAppearance.textSizes.firstIndex(of: $0) })
    func restore() async throws {
        try await original.apply(.appearance(dark), id: id)
        try await original.apply(.textSize(index), id: id)
        try await original.apply(.borders(borders), id: id)
        if let originalExtended {
            try await Simctl.runTool("devicectl", ["device", "settings", "appearance", "--device", id, "--larger-accessibility-sizes", originalExtended ? "on" : "off", "--quiet", "--timeout", "10"]).checked()
        }
    }
    do {
        try await original.apply(.appearance(!dark), id: id)
        try await original.apply(.textSize(index == 4 ? 3 : 4), id: id)
        try await original.apply(.borders(!borders), id: id)
        let changed = try await SimulatorAppearance.load(id)
        #expect(changed.dark == !dark && changed.borders == !borders)
        #expect(changed.textSize == SimulatorAppearance.textSizes[index == 4 ? 3 : 4])
        try await original.reset(id: id)
        let defaults = try await SimulatorAppearance.load(id)
        #expect(defaults.dark == false && defaults.textSize == "large" && defaults.borders == false)
    } catch { try? await restore(); throw error }
    try await restore()
    let restored = try await SimulatorAppearance.load(id)
    #expect(restored.dark == original.dark && restored.textSize == original.textSize && restored.borders == original.borders)
}

private actor ResetRecorder {
    var androidCalls: [[String]] = []
    var appleCalls: [(String, [String])] = []
    let mode: String
    let failAt: Int?
    init(mode: String = "1", failAt: Int? = nil) { self.mode = mode; self.failAt = failAt }
    func android(_ args: [String]) -> ADBResult {
        androidCalls.append(args)
        if androidCalls.count == failAt { return ADBResult(status: 1, output: "Reset failed") }
        return ADBResult(status: 0, output: androidCalls.count == 1 ? mode : "")
    }
    func apple(_ tool: String, _ args: [String]) -> ADBResult {
        appleCalls.append((tool, args))
        return ADBResult(status: 0, output: "")
    }
}

@Test func androidResetUsesTheDevicesDefaultThemeAndClearsOnlyOurSettings() async throws {
    for (mode, expected) in [("0", "auto"), ("1", "no"), ("2", "yes")] {
        let recorder = ResetRecorder(mode: mode)
        try await AndroidSettingsDefaults.reset(serial: "chosen-device", settings: AndroidUISettings()) { await recorder.android($0) }
        let prefix = ["-s", "chosen-device", "shell"]
        #expect(await recorder.androidCalls == [
            prefix + ["cmd", "overlay", "lookup", "android", "android:integer/config_defaultNightMode"],
            prefix + ["cmd", "uimode", "night", expected],
            prefix + ["settings", "delete", "system", "font_scale"],
            prefix + ["settings", "delete", "system", "show_touches"],
            prefix + ["setprop", "debug.layout", "false"],
            prefix + ["service", "call", "activity", "1599295570"],
            prefix + ["settings", "--user", "current", "get", "secure", "enabled_accessibility_services"],
            prefix + ["'settings' '--user' 'current' 'delete' 'secure' 'enabled_accessibility_services'"],
            prefix + ["settings", "--user", "current", "get", "secure", "accessibility_button_targets"],
            prefix + ["'settings' '--user' 'current' 'delete' 'secure' 'accessibility_button_targets'"]])
    }
}

@Test func androidResetRejectsUnknownDefaultsAndStopsWhenACommandFails() async throws {
    for recorder in [ResetRecorder(mode: "unknown"), ResetRecorder(failAt: 1), ResetRecorder(failAt: 3)] {
        await #expect(throws: (any Error).self) {
            try await AndroidSettingsDefaults.reset(serial: "device", settings: AndroidUISettings()) { await recorder.android($0) }
        }
        #expect(await recorder.androidCalls.count <= 3)
    }
}

@Test func simulatorResetRestoresStandardDefaultsAndSkipsUnsupportedOptions() async throws {
    let recorder = ResetRecorder()
    let all = SimulatorAppearance(dark: true, textSize: "extra-large", borders: true)
    try await all.reset(id: "simulator") { await recorder.apple($0, $1) }
    #expect(await recorder.appleCalls.first?.0 == "devicectl")
    #expect(await recorder.appleCalls.first?.1 == ["device", "settings", "appearance", "--device", "simulator", "--mode", "light", "--text-size", "large", "--larger-accessibility-sizes", "off", "--show-borders", "off", "--quiet", "--timeout", "10"])
    let partial = ResetRecorder()
    try await SimulatorAppearance(dark: nil, textSize: "large", borders: nil, native: false).reset(id: "older") { await partial.apple($0, $1) }
    #expect(await partial.appleCalls.count == 1)
    #expect(await partial.appleCalls.first?.1 == ["ui", "older", "content_size", "large"])
}
