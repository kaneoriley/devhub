import Foundation

/// Android's developer Simulate color space setting, not accessibility correction modes.
struct AndroidColorFilter: Equatable {
    enum Mode: Int, CaseIterable {
        case none = -1, grayscale = 0, protanomaly = 1, deuteranomaly = 2, tritanomaly = 3
        var title: String {
            switch self {
            case .none: return "None"
            case .grayscale: return "Grayscale"
            case .protanomaly: return "Protanomaly (red-green)"
            case .deuteranomaly: return "Deuteranomaly (green-red)"
            case .tritanomaly: return "Tritanomaly (blue-yellow)"
            }
        }
    }
    static let enabledKey = "accessibility_display_daltonizer_enabled"
    static let modeKey = "accessibility_display_daltonizer"
    var mode: Int
    var title: String {
        if let value = Mode(rawValue: mode) { return value.title }
        return [11: "Protanomaly Correction", 12: "Deuteranomaly Correction", 13: "Tritanomaly Correction"][mode] ?? "Other (\(mode))"
    }

    static func load(serial: String, previous: Self?, run: AndroidUISettings.Runner) async -> Self? {
        let prefix = ["-s", serial, "shell", "settings", "--user", "current", "get", "secure"]
        async let enabled = try? run(prefix + [enabledKey])
        async let mode = try? run(prefix + [modeKey])
        guard let enabled = await enabled, enabled.status == 0,
              let mode = await mode, mode.status == 0 else { return previous }
        let flag = enabled.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["null", "0", "1"].contains(flag) else { return previous }
        if flag != "1" { return Self(mode: Mode.none.rawValue) }
        let rawMode = mode.output.trimmingCharacters(in: .whitespacesAndNewlines)
        // ColorDisplayService defaults to accessibility deuteranomaly correction when unset.
        guard let value = rawMode == "null" ? 12 : Int(rawMode) else { return previous }
        return Self(mode: value)
    }

    static func apply(_ mode: Mode, serial: String, run: AndroidUISettings.Runner = runADB) async throws {
        let prefix = ["-s", serial, "shell", "settings", "--user", "current", "put", "secure"]
        if mode != .none { try await run(prefix + [modeKey, String(mode.rawValue)]).checked() }
        try await run(prefix + [enabledKey, mode == .none ? "0" : "1"]).checked()
    }
}
