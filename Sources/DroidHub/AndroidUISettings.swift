import Foundation

/// Runtime UI settings, following Studio's EmulatorUiSettingsController and
/// UiSettingsPanel. See docs/android-runtime-settings.md for upstream rules.
struct AndroidUISettings {
    static let gesturesOverlay = "com.android.internal.systemui.navbar.gestural"
    static let buttonsOverlay = "com.android.internal.systemui.navbar.threebutton"
    static let talkBackPackage = "com.google.android.marvin.talkback"
    static let talkBackService = talkBackPackage + "/com.google.android.marvin.talkback.TalkBackService"
    static let selectToSpeakService = talkBackPackage + "/com.google.android.accessibility.selecttospeak.SelectToSpeakService"
    typealias Runner = ([String]) async throws -> ADBResult

    enum Navigation: String, CaseIterable { case gestures = "Gestures", buttons = "Buttons"
        var overlay: String { self == .gestures ? gesturesOverlay : buttonsOverlay }
    }
    enum Accessibility { case talkBack, selectToSpeak
        var service: String { self == .talkBack ? talkBackService : selectToSpeakService }
    }
    var navigation: Navigation?
    var talkBackAvailable = false
    var selectToSpeakAvailable = false
    var talkBack = false
    var selectToSpeak = false
    var display: AndroidDisplaySize?

    static func load(serial: String, kind: DeviceKind, presets: [DisplayPreset] = [], run: @escaping Runner = runADB) async -> Self {
        let prefix = ["-s", serial, "shell"]
        @Sendable func read(_ args: [String]) async -> String {
            guard let result = try? await run(prefix + args), result.status == 0 else { return "" }
            return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        async let overlays = read(["cmd", "overlay", "list", "--user", "current", "android"])
        async let packages = read(["pm", "list", "packages", "--user", "current", talkBackPackage])
        async let services = read(["cmd", "package", "query-services", "--brief", "--user", "current", "-a", "android.accessibilityservice.AccessibilityService"])
        async let enabled = read(["settings", "--user", "current", "get", "secure", "enabled_accessibility_services"])
        async let targets = read(["settings", "--user", "current", "get", "secure", "accessibility_button_targets"])
        async let size = read(["wm", "size"])
        async let density = read(["wm", "density"])
        return await parse(kind: kind, overlays: overlays, packages: packages, services: services, enabled: enabled, targets: targets, size: size, density: density, presets: presets)
    }

    static func parse(kind: DeviceKind, overlays: String, packages: String, services: String, enabled: String, targets: String, size: String, density: String, presets: [DisplayPreset] = []) -> Self {
        let handheld = [.phone, .tablet, .foldable, .resizable].contains(kind)
        var state = Self()
        let lines = overlays.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        // Studio checks for the gestures overlay. Also require its opposite before offering a switch.
        if handheld, lines.contains(where: { $0 == "[x] \(gesturesOverlay)" || $0 == "[ ] \(gesturesOverlay)" }),
           lines.contains(where: { $0 == "[x] \(buttonsOverlay)" || $0 == "[ ] \(buttonsOverlay)" }) {
            state.navigation = lines.contains("[x] \(gesturesOverlay)") ? .gestures : .buttons
        }
        let installed = packages.split(whereSeparator: \.isNewline).contains { $0 == "package:\(talkBackPackage)" }
        let declared = services.split(whereSeparator: { $0.isWhitespace }).map { component(String($0)) }
        // Older package managers may not implement query-services. Studio uses the package check alone.
        let canInspectServices = services.contains("services found:") || services.contains("service found:") || services.contains("No services found") || declared.contains(talkBackService) || declared.contains(selectToSpeakService)
        state.talkBackAvailable = installed && (!canInspectServices || declared.contains(talkBackService))
        state.selectToSpeakAvailable = installed && (handheld || kind == .desktop) && (!canInspectServices || declared.contains(selectToSpeakService))
        state.talkBack = entries(enabled).contains { component($0) == talkBackService }
        state.selectToSpeak = entries(enabled).contains { component($0) == selectToSpeakService }
            && entries(targets).contains { component($0) == selectToSpeakService }
        if handheld || kind == .desktop { state.display = AndroidDisplaySize(size: size, density: density, presets: presets) }
        return state
    }

    static func setNavigation(_ navigation: Navigation, serial: String, run: Runner = runADB) async throws {
        // Limit exclusivity to the navigation category; retain cutout/device and other overlays.
        try await run(["-s", serial, "shell", "cmd", "overlay", "enable-exclusive", "--user", "current", "--category", navigation.overlay]).checked()
    }

    static func setAccessibility(_ service: Accessibility, enabled: Bool, serial: String, run: Runner = runADB) async throws {
        // Studio grants the notification permission to avoid an unrelated TalkBack popup.
        // Pre-33 images don't declare that permission; it is optional, not a toggle failure.
        if service == .talkBack, enabled {
            _ = try? await run(["-s", serial, "shell", "pm", "grant", "--user", "current", talkBackPackage, "android.permission.POST_NOTIFICATIONS"])
        }
        let keys = service == .talkBack ? ["enabled_accessibility_services"] : ["enabled_accessibility_services", "accessibility_button_targets"]
        for key in keys { try await updateSecure(key, removing: [service.service], adding: enabled ? service.service : nil, serial: serial, run: run) }
    }

    static func resetAccessibility(serial: String, run: Runner = runADB) async throws {
        try await updateSecure("enabled_accessibility_services", removing: [talkBackService, selectToSpeakService], serial: serial, run: run)
        try await updateSecure("accessibility_button_targets", removing: [selectToSpeakService], serial: serial, run: run)
    }

    private static func updateSecure(_ key: String, removing: [String], adding: String? = nil, serial: String, run: Runner) async throws {
        let prefix = ["-s", serial, "shell"]
        let result = try await run(prefix + ["settings", "--user", "current", "get", "secure", key])
        try result.checked()
        var values = entries(result.output).filter { !removing.contains(component($0)) }
        if let adding { values.append(adding) }
        let args = values.isEmpty ? ["settings", "--user", "current", "delete", "secure", key]
            : ["settings", "--user", "current", "put", "secure", key, values.joined(separator: ":")]
        // adb shell concatenates its arguments. Quote device-supplied component lists for the remote shell.
        try await run(prefix + [args.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")]).checked()
    }

    static func entries(_ text: String) -> [String] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text == "null" ? [] : text.split(separator: ":").map(String.init)
    }
    static func component(_ text: String) -> String {
        let parts = text.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, parts[1].hasPrefix(".") else { return text }
        return "\(parts[0])/\(parts[0])\(parts[1])"
    }
}

/// Density steps adapted from Studio's GoogleDensityRange / SettingsLib DisplayDensityUtils.
/// Copyright (C) 2023 The Android Open Source Project, Apache License 2.0.
/// See ThirdParty/android-tools-LICENSE and docs/android-runtime-settings.md.
struct AndroidDisplaySize: Equatable {
    let physicalDensity: Int
    let defaultDensity: Int
    let currentDensity: Int
    let screenSize: CGSize
    let values: [Int]
    var index: Int { values.indices.min { abs(values[$0] - currentDensity) < abs(values[$1] - currentDensity) } ?? 0 }

    init?(size: String, density: String, presets: [DisplayPreset] = []) {
        func number(_ name: String) -> Int? {
            density.split(whereSeparator: \.isNewline).first { $0.hasPrefix(name + ":") }
                .flatMap { Int($0.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") }
        }
        guard let physical = number("Physical density"), physical > 0 else { return nil }
        let sizes = size.split(whereSeparator: \.isNewline)
        guard let line = sizes.first(where: { $0.hasPrefix("Override size:") }) ?? sizes.first(where: { $0.hasPrefix("Physical size:") }),
              let dimensions = line.split(separator: ":").last else { return nil }
        let sides = dimensions.trimmingCharacters(in: .whitespaces).split(separator: "x").compactMap { Int($0) }
        guard sides.count == 2, sides.allSatisfy({ $0 > 0 && $0 < 100_000 }), physical < 100_000 else { return nil }
        let override = number("Override density")
        physicalDensity = physical
        currentDensity = override.flatMap { (1..<100_000).contains($0) ? $0 : nil } ?? physical
        screenSize = CGSize(width: sides[0], height: sides[1])
        defaultDensity = presets.first(where: { $0.matches(CGSize(width: sides[0], height: sides[1])) })?.density ?? physical
        values = Self.range(width: sides[0], height: sides[1], density: defaultDensity)
    }

    static func range(width: Int, height: Int, density: Int) -> [Int] {
        guard density > 0, min(width, height) > 0 else { return [] }
        let maxDensity = 160 * min(width, height) / 320
        let maximum = min(Float(1.5), Float(maxDensity) / Float(density))
        let count = max(0, min(3, Int((maximum - 1) / 0.09)))
        var values = [Int(Float(density) * 0.85) & ~1, density]
        if count > 0 {
            let step = (maximum - 1) / Float(count)
            values += (1...count).map { Int(Float(density) * (1 + Float($0) * step)) & ~1 }
        }
        return values
    }

    func apply(index: Int, serial: String, run: AndroidUISettings.Runner = runADB) async throws {
        guard values.indices.contains(index) else { throw MirrorError("Choose a supported display size.") }
        let target = values[index]
        try await run(["-s", serial, "shell", "wm", "density", target == physicalDensity ? "reset" : String(target)]).checked()
    }

    func reset(serial: String, run: AndroidUISettings.Runner = runADB) async throws {
        try await run(["-s", serial, "shell", "wm", "density", defaultDensity == physicalDensity ? "reset" : String(defaultDensity)]).checked()
    }
}

/// Distinguish deliberate density choices from mismatched Quick Boot snapshots.
enum AndroidDisplaySizePreferences {
    private static let key = "android.displaySizeDensities"
    private static func entry(_ deviceID: String, _ size: CGSize) -> String {
        "\(deviceID)|\(Int(min(size.width, size.height)))x\(Int(max(size.width, size.height)))"
    }
    static func density(deviceID: String, size: CGSize, defaults: UserDefaults = .standard) -> Int? {
        (defaults.dictionary(forKey: key) as? [String: Int])?[entry(deviceID, size)]
    }
    static func record(deviceID: String, size: CGSize, density: Int, defaults: UserDefaults = .standard) {
        var values = defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
        values[entry(deviceID, size)] = density
        defaults.set(values, forKey: key)
    }
}
