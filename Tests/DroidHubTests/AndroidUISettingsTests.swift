import Foundation
import Testing
@testable import DroidHub

private let navOverlays = """
android
[x] com.android.internal.systemui.navbar.gestural
[ ] com.android.internal.systemui.navbar.threebutton
"""
private let accessibilityServices = """
2 services found:
com.google.android.marvin.talkback/.TalkBackService
com.google.android.marvin.talkback/com.google.android.accessibility.selecttospeak.SelectToSpeakService
"""
private func runtimeState(kind: DeviceKind = .phone, packages: String = "package:com.google.android.marvin.talkback", services: String = accessibilityServices) -> AndroidUISettings {
    AndroidUISettings.parse(kind: kind, overlays: navOverlays, packages: packages, services: services,
        enabled: AndroidUISettings.talkBackService + ":" + AndroidUISettings.selectToSpeakService,
        targets: AndroidUISettings.selectToSpeakService, size: "Physical size: 1080x2400", density: "Physical density: 420")
}

@Test func androidRuntimeSettingsFollowStudioCapabilitiesAndCanonicalizeComponents() {
    let phone = runtimeState()
    #expect(phone.navigation == .gestures)
    #expect(phone.talkBackAvailable && phone.selectToSpeakAvailable)
    #expect(phone.talkBack && phone.selectToSpeak && phone.display != nil)
    let absent = runtimeState(packages: "package:com.google.android.marvin.talkbackoverlay")
    #expect(!absent.talkBackAvailable && !absent.selectToSpeakAvailable)
    let partial = runtimeState(services: "1 service found:\ncom.google.android.marvin.talkback/.TalkBackService")
    #expect(partial.talkBackAvailable && !partial.selectToSpeakAvailable)
    let old = runtimeState(services: "Unknown command: query-services")
    #expect(old.talkBackAvailable && old.selectToSpeakAvailable)
    for kind: DeviceKind in [.watch, .tv, .automotive] {
        let other = runtimeState(kind: kind)
        #expect(other.navigation == nil && other.display == nil && !other.selectToSpeakAvailable)
        #expect(other.talkBackAvailable)
    }
    let desktop = runtimeState(kind: .desktop)
    #expect(desktop.navigation == nil && desktop.display != nil && desktop.selectToSpeakAvailable)
    #expect(AndroidUISettings.component("com.google.android.marvin.talkback/.TalkBackService") == AndroidUISettings.talkBackService)
    #expect(AndroidUISettings.entries("null\n").isEmpty)
}

@Test func selectToSpeakRequiresBothEnabledServiceAndShortcut() {
    let state = AndroidUISettings.parse(kind: .phone, overlays: "", packages: "", services: "", enabled: AndroidUISettings.selectToSpeakService,
                                        targets: "null", size: "", density: "")
    #expect(!state.selectToSpeak)
}

@Test func androidDisplaySizeUsesGoogleDensityStepsAndCurrentDisplayGeometry() throws {
    let display = try #require(AndroidDisplaySize(size: "Physical size: 2076x2152", density: "Physical density: 390\nOverride density: 520"))
    #expect(display.values == [330, 390, 454, 520, 584])
    #expect(display.index == 3)
    let resized = try #require(AndroidDisplaySize(size: "Physical size: 2076x2152\nOverride size: 1080x2400", density: "Physical density: 480"))
    #expect(resized.values == [408, 480, 540])
    #expect(AndroidDisplaySize(size: "invalid", density: "Physical density: 420") == nil)
    #expect(AndroidDisplaySize(size: "Physical size: 1080x2400", density: "Override density: 420") == nil)
    #expect(AndroidDisplaySize.range(width: 100, height: 100, density: 0).isEmpty)
}

private actor RuntimeSettingsRecorder {
    var calls: [[String]] = []
    var enabled: String
    var targets: String
    var failWrites = false
    init(enabled: String = "null", targets: String = "null", failWrites: Bool = false) {
        self.enabled = enabled; self.targets = targets; self.failWrites = failWrites
    }
    func run(_ args: [String]) -> ADBResult {
        calls.append(args)
        if args.contains("get") {
            return ADBResult(status: 0, output: args.last == "enabled_accessibility_services" ? enabled : targets)
        }
        return ADBResult(status: failWrites ? 1 : 0, output: failWrites ? "Permission denied" : "")
    }
}

@Test func androidAccessibilityChangesPreserveOtherServicesAndShortcuts() async throws {
    let recorder = RuntimeSettingsRecorder(enabled: "example/.Reader:com.google.android.marvin.talkback/.TalkBackService", targets: "example/.Shortcut")
    try await AndroidUISettings.setAccessibility(.talkBack, enabled: false, serial: "chosen") { await recorder.run($0) }
    var calls = await recorder.calls
    let off = try #require(calls.last?.last)
    #expect(off.contains("example/.Reader") && !off.contains("TalkBackService"))
    #expect(calls.allSatisfy { $0.starts(with: ["-s", "chosen", "shell"]) })
    try await AndroidUISettings.setAccessibility(.selectToSpeak, enabled: true, serial: "chosen") { await recorder.run($0) }
    calls = await recorder.calls
    let serviceWrite = try #require(calls.dropLast(2).last?.last)
    #expect(serviceWrite.contains("example/.Reader") && serviceWrite.contains("TalkBackService") && serviceWrite.contains(AndroidUISettings.selectToSpeakService))
    let buttonWrite = try #require(calls.last?.last)
    #expect(buttonWrite.contains("example/.Shortcut") && buttonWrite.contains(AndroidUISettings.selectToSpeakService))
}

@Test func androidAccessibilityResetRemovesOnlyTheTwoManagedServices() async throws {
    let recorder = RuntimeSettingsRecorder(enabled: "example/.Reader:\(AndroidUISettings.talkBackService):\(AndroidUISettings.selectToSpeakService)",
                                          targets: "example/.Shortcut:\(AndroidUISettings.selectToSpeakService)")
    try await AndroidUISettings.resetAccessibility(serial: "chosen") { await recorder.run($0) }
    let writes = await recorder.calls.filter { $0.last?.contains("'put'") == true }
    #expect(writes.count == 2)
    #expect(writes[0].last?.contains("example/.Reader") == true)
    #expect(writes[1].last?.contains("example/.Shortcut") == true)
    #expect(!writes.contains { $0.last?.contains(AndroidUISettings.talkBackService) == true || $0.last?.contains(AndroidUISettings.selectToSpeakService) == true })
    let empty = RuntimeSettingsRecorder(enabled: AndroidUISettings.talkBackService)
    try await AndroidUISettings.setAccessibility(.talkBack, enabled: false, serial: "chosen") { await empty.run($0) }
    #expect(await empty.calls.last?.last?.contains("'delete' 'secure'") == true)
}

@Test func androidSettingErrorsAreSurfacedAndNavigationIsCategoryScoped() async throws {
    let recorder = RuntimeSettingsRecorder(failWrites: true)
    await #expect(throws: MirrorError.self) {
        try await AndroidUISettings.setAccessibility(.selectToSpeak, enabled: true, serial: "chosen") { await recorder.run($0) }
    }
    let navigation = RuntimeSettingsRecorder()
    try await AndroidUISettings.setNavigation(.buttons, serial: "chosen") { await navigation.run($0) }
    #expect(await navigation.calls.last == ["-s", "chosen", "shell", "cmd", "overlay", "enable-exclusive", "--user", "current", "--category", AndroidUISettings.buttonsOverlay])
    let display = try #require(AndroidDisplaySize(size: "Physical size: 1080x2400", density: "Physical density: 420"))
    try await display.apply(index: 1, serial: "chosen") { await navigation.run($0) }
    #expect(await navigation.calls.last?.suffix(3) == ["wm", "density", "reset"])
    await #expect(throws: MirrorError.self) { try await display.apply(index: -1, serial: "chosen") { await navigation.run($0) } }
}

@Test func androidResetIncludesNavigationDisplayAndAccessibilityWhenSupported() async throws {
    let recorder = RuntimeSettingsRecorder()
    try await AndroidSettingsDefaults.reset(serial: "chosen", settings: runtimeState()) { args in
        if args.contains("lookup") { return ADBResult(status: 0, output: "1") }
        return await recorder.run(args)
    }
    let calls = await recorder.calls
    #expect(calls.contains(["-s", "chosen", "shell", "wm", "density", "reset"]))
    #expect(calls.contains { $0.last == AndroidUISettings.gesturesOverlay && $0.contains("--category") })
    #expect(calls.contains { $0.last?.contains("'delete' 'secure' 'enabled_accessibility_services'") == true })
    #expect(calls.contains { $0.last?.contains("'delete' 'secure' 'accessibility_button_targets'") == true })
}

/// Changes only a named test emulator, restoring original settings even on failure.
@Test func androidRuntimeSettingsRoundTrip() async throws {
    guard let serial = ProcessInfo.processInfo.environment["DROIDHUB_TEST_UI_SETTINGS_ANDROID"], serial.hasPrefix("emulator-") else { return }
    let original = await AndroidUISettings.load(serial: serial, kind: .phone)
    let density = try #require(original.display)
    let originalDensity = try await runADB(["-s", serial, "shell", "wm", "density"])
    let originalServices = try await runADB(["-s", serial, "shell", "settings", "--user", "current", "get", "secure", "enabled_accessibility_services"])
    let originalTargets = try await runADB(["-s", serial, "shell", "settings", "--user", "current", "get", "secure", "accessibility_button_targets"])
    for result in [originalDensity, originalServices, originalTargets] { try result.checked() }
    func restore() async throws {
        let forced = originalDensity.output.split(whereSeparator: \.isNewline).first { $0.hasPrefix("Override density:") }?.split(separator: ":").last?.trimmingCharacters(in: .whitespaces)
        try await runADB(["-s", serial, "shell", "wm", "density", forced ?? "reset"]).checked()
        if let navigation = original.navigation { try await AndroidUISettings.setNavigation(navigation, serial: serial) }
        for (key, result) in [("enabled_accessibility_services", originalServices), ("accessibility_button_targets", originalTargets)] {
            let raw = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let command = raw == "null" ? ["settings", "--user", "current", "delete", "secure", key]
                : ["settings", "--user", "current", "put", "secure", key, raw]
            let quoted = command.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
            try await runADB(["-s", serial, "shell", quoted]).checked()
        }
    }
    do {
        let next = density.index == 0 ? 1 : 0
        try await density.apply(index: next, serial: serial)
        if let navigation = original.navigation { try await AndroidUISettings.setNavigation(navigation == .gestures ? .buttons : .gestures, serial: serial) }
        if original.selectToSpeakAvailable { try await AndroidUISettings.setAccessibility(.selectToSpeak, enabled: !original.selectToSpeak, serial: serial) }
        let changed = await AndroidUISettings.load(serial: serial, kind: .phone)
        #expect(changed.display?.currentDensity == density.values[next])
        if let navigation = original.navigation { #expect(changed.navigation != navigation) }
        if original.selectToSpeakAvailable { #expect(changed.selectToSpeak == !original.selectToSpeak) }
    } catch { try? await restore(); throw error }
    try await restore()
    let restored = await AndroidUISettings.load(serial: serial, kind: .phone)
    #expect(restored.display?.currentDensity == original.display?.currentDensity)
    #expect(restored.navigation == original.navigation && restored.selectToSpeak == original.selectToSpeak && restored.talkBack == original.talkBack)
}

@Test func resizableDisplaySizeUsesItsActivePresetDefaultAndKeepsChoicesAcrossRotation() async throws {
    let presets = DisplayPreset.parse("phone-0-1080-2400-420, tablet-2-1920-1200-240")
    let display = try #require(AndroidDisplaySize(size: "Physical size: 1080x2400\nOverride size: 1920x1200", density: "Physical density: 420\nOverride density: 280", presets: presets))
    #expect(display.defaultDensity == 240 && display.currentDensity == 280)
    #expect(display.values == [204, 240, 280, 320, 360])
    let recorder = RuntimeSettingsRecorder()
    try await display.reset(serial: "chosen") { await recorder.run($0) }
    #expect(await recorder.calls.last?.suffix(3) == ["wm", "density", "240"])
    let suite = "DroidHubDisplaySizeTests-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    AndroidDisplaySizePreferences.record(deviceID: "avd:one", size: display.screenSize, density: 280, defaults: preferences)
    #expect(AndroidDisplaySizePreferences.density(deviceID: "avd:one", size: CGSize(width: 1200, height: 1920), defaults: preferences) == 280)
    #expect(AndroidDisplaySizePreferences.density(deviceID: "avd:other", size: display.screenSize, defaults: preferences) == nil)
    #expect(AndroidDisplaySizePreferences.density(deviceID: "avd:one", size: CGSize(width: 1080, height: 2400), defaults: preferences) == nil)
}

@Test func reconnectingResizablePreservesAnIntentionalDisplaySizeOverride() async throws {
    let recorder = RuntimeSettingsRecorder()
    let actions = DeviceActions(run: { args in
        _ = await recorder.run(args)
        return ADBResult(status: 0, output: args.last == "size" ? "Physical size: 1920x1200" : "Physical density: 240\nOverride density: 280")
    })
    let state = try await actions.synchronizeDisplay(presets: DisplayPreset.parse("tablet-2-1920-1200-240"), serial: "chosen", preferredDensity: { _ in 280 })
    #expect(state.density == 280)
    #expect(await recorder.calls.count == 2)
}
