import Foundation

/// Reset only the options exposed by DevHub, not the device's other settings.
enum AndroidSettingsDefaults {
    static func reset(serial: String, settings: AndroidUISettings? = nil, kind: DeviceKind = .phone,
                      run: @escaping AndroidUISettings.Runner = runADB) async throws {
        let prefix = ["-s", serial, "shell"]
        let resource = try await run(prefix + ["cmd", "overlay", "lookup", "android", "android:integer/config_defaultNightMode"])
        try resource.checked()
        let value = resource.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let mode = value.hasPrefix("0x") ? Int(value.dropFirst(2), radix: 16) : Int(value)
        guard let mode, let setting = [0: "auto", 1: "no", 2: "yes"][mode] else {
            throw MirrorError("Couldn't determine this device's default appearance.")
        }
        let runtime: AndroidUISettings
        if let settings { runtime = settings }
        else { runtime = await AndroidUISettings.load(serial: serial, kind: kind, run: run) }
        for command in [["cmd", "uimode", "night", setting], ["settings", "delete", "system", "font_scale"],
                        ["settings", "delete", "system", "show_touches"], ["setprop", "debug.layout", "false"],
                        ["service", "call", "activity", "1599295570"]] {
            try await run(prefix + command).checked()
        }
        if let display = runtime.display { try await display.reset(serial: serial, run: run) }
        if runtime.navigation != nil { try await AndroidUISettings.setNavigation(.gestures, serial: serial, run: run) }
        try await AndroidUISettings.resetAccessibility(serial: serial, run: run)
    }
}
