import Foundation
import Testing
@testable import DevHub

private actor ResetRecorder {
    var androidCalls: [[String]] = []
    let mode: String
    let failAt: Int?
    init(mode: String = "1", failAt: Int? = nil) { self.mode = mode; self.failAt = failAt }
    func android(_ args: [String]) -> ToolResult {
        androidCalls.append(args)
        if androidCalls.count == failAt { return ToolResult(status: 1, output: "Reset failed") }
        return ToolResult(status: 0, output: androidCalls.count == 1 ? mode : "")
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
