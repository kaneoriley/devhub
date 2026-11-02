import Foundation
import Testing
@testable import DevHub

@Test func simulatorAppearanceParsesDeviceHubsSettingsAndOptionalCapabilities() throws {
    let state = try SimulatorAppearance.parse(Data(#"{"result":{"userInterfaceStyle":"dark","textSize":"Accessibility Extra Extra Large","showBorders":{"enabled":true}}}"#.utf8))
    #expect(state.dark == true && state.textSize == "accessibility-extra-extra-large" && state.borders == true)
    let partial = try SimulatorAppearance.parse(Data(#"{"result":{"userInterfaceStyle":"unsupported","textSize":"unknown"}}"#.utf8))
    #expect(partial.dark == nil && partial.textSize == nil && partial.borders == nil)
    #expect(partial.colorFilter == nil && partial.liquidGlassOpacity == nil)
}

@Test func appleAppearanceParsesColorFiltersAndLiquidGlassOnlyWhenReported() throws {
    let old = try SimulatorAppearance.parse(Data(#"{"result":{"colorFilter":{"enabled":false}}}"#.utf8))
    #expect(old.colorFilter == .some(.none) && old.liquidGlassOpacity == nil)
    for filter in SimulatorAppearance.ColorFilter.choices where filter != .none {
        let json = #"{"result":{"colorFilter":{"enabled":true,"filterType":{"name":"\#(filter.rawValue.capitalized)"}},"liquidGlassOpacity":0.7}}"#
        let state = try SimulatorAppearance.parse(Data(json.utf8))
        #expect(state.colorFilter == filter && state.liquidGlassOpacity == 0.7)
    }
    let future = try SimulatorAppearance.parse(Data(#"{"result":{"colorFilter":{"enabled":true,"filterType":{"name":"Future filter"}},"liquidGlassOpacity":2}}"#.utf8))
    #expect(future.colorFilter == .unknown && future.liquidGlassOpacity == nil)
}

@Test func appleColorAndGlassCommandsValidateCapabilitiesAndValues() throws {
    let state = SimulatorAppearance(colorFilter: .some(.none), liquidGlassOpacity: 0.5)
    for filter in SimulatorAppearance.ColorFilter.choices {
        let args = try state.command(.colorFilter(filter), id: "test").1
        #expect(args.contains("--color-filter"))
        #expect(args.contains("--color-filter-type") == (filter != .none))
        #expect(args.contains(filter == .none ? "off" : filter.rawValue))
        #expect(!args.contains("--color-filter-intensity"))
    }
    #expect(try state.command(.liquidGlassOpacity(0.75), id: "test").1.contains("0.75"))
    for opacity in [-0.1, 1.1, Double.nan, Double.infinity] {
        #expect(throws: (any Error).self) { try state.command(.liquidGlassOpacity(opacity), id: "test") }
    }
    #expect(throws: (any Error).self) { try state.command(.colorFilter(.unknown), id: "test") }
    let unsupported = SimulatorAppearance(native: false)
    #expect(throws: (any Error).self) { try unsupported.command(.colorFilter(.grayscale), id: "older") }
    #expect(throws: (any Error).self) { try unsupported.command(.liquidGlassOpacity(0.5), id: "older") }
}

@Test func appleAppearanceIgnoresLegacyColorPlaceholdersAndRequiresModernCustomizationCapability() async throws {
    let payload = #"{"result":{"colorFilter":{"enabled":false},"liquidGlassOpacity":0.5}}"#
    for supported in [false, true] {
        let capabilities = supported ? #"{"result":{"capabilities":[{"featureIdentifier":"com.apple.coredevice.feature.customizeliquidglass"}]}}"# : #"{"result":{"capabilities":[]}}"#
        let state = try await SimulatorAppearance.load("capability-test") { _, args in
            ToolResult(status: 0, output: args.contains("details") ? capabilities : payload)
        }
        #expect(state.supportsColorFilter == supported && state.supportsLiquidGlass == supported)
        #expect((state.colorFilter != nil) == supported)
        if !supported {
            #expect(throws: (any Error).self) { try state.command(.colorFilter(.grayscale), id: "old") }
        }
    }
    #expect(SimulatorAppearance.customizationSupport(Data(#"{"result":{}}"#.utf8)) == nil)
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
    func run(_ tool: String, _ args: [String]) -> ToolResult {
        calls.append((tool, args))
        if tool == "devicectl" { return ToolResult(status: 1, output: "Unknown subcommand") }
        return ToolResult(status: 0, output: args.last == "appearance" ? "dark\n" : "extra-large\n")
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
    #expect(calls.filter { $0.0 == "devicectl" }.count == 2)
    #expect(calls.filter { $0.0 == "simctl" }.map { $0.1.last } == ["appearance", "content_size"])
}

/// Opt in to verify the real simulator and restore each original setting afterward.
@Test func simulatorAppearanceSettingsRoundTrip() async throws {
    guard let id = ProcessInfo.processInfo.environment["DEVHUB_TEST_SETTINGS_SIMULATOR"] else { return }
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
        if original.supportsColorFilter, let filter = original.colorFilter { try await original.apply(.colorFilter(filter), id: id) }
        if original.supportsLiquidGlass, let opacity = original.liquidGlassOpacity { try await original.apply(.liquidGlassOpacity(opacity), id: id) }
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
        if original.supportsColorFilter {
            for filter in SimulatorAppearance.ColorFilter.choices {
                try await original.apply(.colorFilter(filter), id: id)
                #expect(try await SimulatorAppearance.load(id).colorFilter == filter)
            }
        }
        if original.supportsLiquidGlass {
            try await original.apply(.liquidGlassOpacity(0.8), id: id)
            #expect(try await SimulatorAppearance.load(id).liquidGlassOpacity == 0.8)
        }
        try await original.reset(id: id)
        let defaults = try await SimulatorAppearance.load(id)
        #expect(defaults.dark == false && defaults.textSize == "large" && defaults.borders == false)
        if original.supportsColorFilter { #expect(defaults.colorFilter == .some(.none)) }
        if original.supportsLiquidGlass { #expect(defaults.liquidGlassOpacity == 0.5) }
    } catch { try? await restore(); throw error }
    try await restore()
    let restored = try await SimulatorAppearance.load(id)
    #expect(restored.dark == original.dark && restored.textSize == original.textSize && restored.borders == original.borders)
}

private actor ResetRecorder {
    var appleCalls: [(String, [String])] = []
    func apple(_ tool: String, _ args: [String]) -> ToolResult {
        appleCalls.append((tool, args))
        return ToolResult(status: 0, output: "")
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
    let modern = ResetRecorder()
    try await SimulatorAppearance(colorFilter: .protanopia, liquidGlassOpacity: 0.8).reset(id: "modern") { await modern.apple($0, $1) }
    #expect(await modern.appleCalls.first?.1 == ["device", "settings", "appearance", "--device", "modern", "--color-filter", "off", "--liquid-glass-opacity", "0.5", "--quiet", "--timeout", "10"])
}
