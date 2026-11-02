import SwiftUI

struct SettingsLabel: View {
    let title: String
    let icon: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
            Text(title)
        }
    }
}

/// Actions sit in the grouped form's footer, outside its cards.
struct SettingsFooterButton: View {
    let title: String
    var icon: String?
    var alignment: Alignment = .leading
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if let icon { Label(title, systemImage: icon) }
            else { Text(title) }
        }
        .font(.body)
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .frame(maxWidth: .infinity, alignment: alignment)
    }
}

/// DeviceHub's compact value-and-spinner presentation, with a native menu.
struct AppearanceControl: View {
    @Binding var dark: Bool
    var automatic = false
    var setAutomatic: (() -> Void)?
    var body: some View {
        Picker("Appearance", selection: Binding(get: { automatic ? "auto" : dark ? "dark" : "light" }, set: { value in
            if value == "auto" { setAutomatic?() } else { dark = value == "dark" }
        })) {
            Text("Light").tag("light")
            Text("Dark").tag("dark")
            if setAutomatic != nil { Text("Automatic").tag("auto") }
        }
        .labelsHidden().fixedSize()
        .accessibilityLabel("Appearance").accessibilityValue(automatic ? "Automatic" : dark ? "Dark" : "Light")
    }
}

struct TextSizeControl: View {
    @Binding var value: Double
    let count: Int
    let title: String
    let description: String
    let commit: () -> Void
    var body: some View {
        Slider(value: $value, in: 0...Double(count - 1), step: 1) { Text(title) }
            onEditingChanged: { editing in if !editing { commit() } }
            .labelsHidden().frame(width: 120)
            .help(description).accessibilityLabel(title).accessibilityValue(description)
    }
}

struct SimulatorAppearance {
    static let textSizes = ["extra-small", "small", "medium", "large", "extra-large", "extra-extra-large", "extra-extra-extra-large",
                            "accessibility-medium", "accessibility-large", "accessibility-extra-large", "accessibility-extra-extra-large", "accessibility-extra-extra-extra-large"]
    var dark: Bool?
    var textSize: String?
    var borders: Bool?
    var native = true

    static func parse(_ data: Data) throws -> Self {
        struct Response: Decodable {
            struct Result: Decodable {
                struct Enabled: Decodable { let enabled: Bool }
                let userInterfaceStyle: String?
                let textSize: String?
                let showBorders: Enabled?
            }
            let result: Result
        }
        let result = try JSONDecoder().decode(Response.self, from: data).result
        let size = result.textSize?.lowercased().replacingOccurrences(of: " ", with: "-")
        return Self(dark: result.userInterfaceStyle == "dark" ? true : result.userInterfaceStyle == "light" ? false : nil,
                    textSize: size.flatMap { textSizes.contains($0) ? $0 : nil }, borders: result.showBorders?.enabled)
    }

    static func load(_ id: String, run: (String, [String]) async throws -> ADBResult = { try await Simctl.runTool($0, $1) }) async throws -> Self {
        let result = try await run("devicectl", ["device", "info", "appearance", "--device", id, "--quiet", "--json-output", "-", "--timeout", "10"])
        if result.status == 0 { return try parse(Data(result.output.utf8)) }
        // Earlier Xcodes expose appearance and Dynamic Type through simctl.
        let appearance = try await run("simctl", ["ui", id, "appearance"])
        try appearance.checked()
        let size = try await run("simctl", ["ui", id, "content_size"])
        try size.checked()
        let value = size.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let mode = appearance.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(dark: mode == "dark" ? true : mode == "light" ? false : nil,
                    textSize: textSizes.contains(value) ? value : nil, borders: nil, native: false)
    }

    enum Change: Equatable { case appearance(Bool), textSize(Int), borders(Bool) }

    func command(_ change: Change, id: String) throws -> (String, [String]) {
        var options: [String]
        switch change {
        case .appearance(let dark):
            if !native { return ("simctl", ["ui", id, "appearance", dark ? "dark" : "light"]) }
            options = ["--mode", dark ? "dark" : "light"]
        case .textSize(let index):
            guard Self.textSizes.indices.contains(index) else { throw MirrorError("Choose a valid text size.") }
            let size = Self.textSizes[index]
            if !native { return ("simctl", ["ui", id, "content_size", size]) }
            options = ["--text-size", size]
            if index >= 7 { options += ["--larger-accessibility-sizes", "on"] }
        case .borders(let enabled):
            guard native, borders != nil else { throw MirrorError("This simulator doesn't support Show Borders.") }
            options = ["--show-borders", enabled ? "on" : "off"]
        }
        return ("devicectl", ["device", "settings", "appearance", "--device", id] + options + ["--quiet", "--timeout", "10"])
    }

    func apply(_ change: Change, id: String, run: (String, [String]) async throws -> ADBResult = { try await Simctl.runTool($0, $1) }) async throws {
        let (tool, args) = try command(change, id: id)
        try await run(tool, args).checked()
    }
}

struct SimulatorSettingsView: View {
    let device: Device
    let simulator: AppleSimulator
    @State private var appearance: SimulatorAppearance?
    @State private var dark = false
    @State private var textIndex = 3.0
    @State private var borders = false
    @State private var loading = true
    @State private var saving = false
    @State private var failure: String?

    var body: some View {
        Form {
            Section {
                if appearance?.dark != nil {
                    LabeledContent { AppearanceControl(dark: Binding(get: { dark }, set: { dark = $0; apply(.appearance($0)) })) }
                        label: { SettingsLabel(title: "Appearance", icon: "circle.lefthalf.filled") }
                }
                if appearance?.textSize != nil {
                    LabeledContent {
                        TextSizeControl(value: $textIndex, count: SimulatorAppearance.textSizes.count, title: "Text Size",
                                        description: SimulatorAppearance.textSizes[Int(textIndex)].replacingOccurrences(of: "-", with: " ").capitalized) {
                            apply(.textSize(Int(textIndex)))
                        }
                    } label: { SettingsLabel(title: "Text Size", icon: "textformat.size") }
                }
                if appearance?.borders != nil {
                    Toggle(isOn: Binding(get: { borders }, set: { borders = $0; apply(.borders($0)) })) {
                        SettingsLabel(title: "Show Borders", icon: "square.on.square.dashed")
                    }
                }
                if loading { ProgressView().controlSize(.small) }
                if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
            } footer: {
                SettingsFooterButton(title: "Reset to Defaults", icon: "arrow.counterclockwise", alignment: .trailing, action: reset)
                    .help("Restore Light appearance, Large text size, and Show Borders off.")
                    .disabled(appearance == nil || loading || saving)
            }.disabled(loading || saving)
            Section("Device") {
                LabeledContent("Model", value: device.model)
                LabeledContent("OS", value: simulator.runtime)
            }
        }
        .formStyle(.grouped).toggleStyle(.switch)
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let state = try await SimulatorAppearance.load(simulator.udid)
            appearance = state; dark = state.dark ?? false; borders = state.borders ?? false
            textIndex = Double(state.textSize.flatMap { SimulatorAppearance.textSizes.firstIndex(of: $0) } ?? 3)
            failure = nil
        } catch { failure = String(describing: error) }
    }

    private func reset() {
        guard let appearance else { return }
        saving = true; failure = nil
        Task { @MainActor in
            defer { saving = false }
            do { try await appearance.reset(id: simulator.udid); await load() }
            catch { await load(); failure = String(describing: error) }
        }
    }

    private func apply(_ change: SimulatorAppearance.Change) {
        guard let appearance else { return }
        saving = true; failure = nil
        Task { @MainActor in
            defer { saving = false }
            do { try await appearance.apply(change, id: simulator.udid) }
            catch { await load(); failure = String(describing: error) }
        }
    }
}

/// Reset only the options exposed by DroidHub, not the device's other settings.
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

extension SimulatorAppearance {
    func reset(id: String, run: (String, [String]) async throws -> ADBResult = { try await Simctl.runTool($0, $1) }) async throws {
        if !native {
            if dark != nil { try await apply(.appearance(false), id: id, run: run) }
            if textSize != nil { try await apply(.textSize(3), id: id, run: run) }
            return
        }
        var options: [String] = []
        if dark != nil { options += ["--mode", "light"] }
        if textSize != nil { options += ["--text-size", "large", "--larger-accessibility-sizes", "off"] }
        if borders != nil { options += ["--show-borders", "off"] }
        guard !options.isEmpty else { return }
        try await run("devicectl", ["device", "settings", "appearance", "--device", id] + options + ["--quiet", "--timeout", "10"]).checked()
    }
}
