import SwiftUI

/// Read-only device details stay separate from runtime settings on both platforms.
struct DeviceInfoView: View {
    @Environment(Hub.self) private var hub
    let device: Device
    var displaySize: CGSize?
    var folded: Bool?
    @State private var configuration: [String: String] = [:]
    @State private var androidDisplay: DisplayState?
    @State private var configuring = false

    private var simulator: AppleSimulator? { device.simulator }
    private var state: String {
        if hub.booting.contains(device.id) { return "Booting" }
        if let simulator { return simulator.state == "Shutdown" ? "Shut Down" : simulator.state }
        return device.isRunning ? "Running" : "Shut Down"
    }
    private var graphicsMode: String {
        guard !configuration.isEmpty else { return "Unknown" }
        if configuration["hw.gpu.enabled"] == "no" { return "Disabled" }
        let mode = configuration["hw.gpu.mode"] ?? "auto"
        return ["auto": "Automatic", "host": "Hardware", "software": "Software"][mode] ?? mode
    }
    private var bootMode: String {
        guard !configuration.isEmpty else { return "Unknown" }
        if configuration["fastboot.forceColdBoot"] == "yes" { return "Cold" }
        if configuration["fastboot.forceChosenSnapshotBoot"] == "yes" { return "Snapshot" }
        return "Quick"
    }
    private var configuredDisplay: String? {
        guard let width = configuration["hw.lcd.width"], let height = configuration["hw.lcd.height"],
              let density = configuration["hw.lcd.density"] else { return nil }
        return "\(width)×\(height) · \(density) dpi"
    }
    private var model: String {
        if !device.model.isEmpty { return device.model }
        return configuration["hw.device.name"] ?? "Unknown"
    }

    var body: some View {
        Form {
            Section("Device") {
                detail("Name", device.name)
                detail("Model", model)
                detail("Form Factor", device.kind.title)
                detail("State", state)
                if let simulator {
                    detail("OS", "\(device.platform) \(simulator.version)")
                    detail("Runtime", simulator.runtime)
                    detail("Family", simulator.family)
                    detail("Identifier", simulator.udid)
                    if let lastUsed = device.lastUsedAt {
                        detail("Last Used", lastUsed.formatted(date: .abbreviated, time: .shortened))
                    }
                } else {
                    if !device.release.isEmpty { detail("Android", device.release) }
                    if !device.api.isEmpty { detail("API", device.api) }
                    if let serial = device.serial { detail("Serial", serial) }
                    if let avd = device.avd { detail("AVD", avd) }
                }
            }
            if let simulator {
                if let displaySize {
                    Section("Display") {
                        detail("Screen", "\(Int(displaySize.width))×\(Int(displaySize.height))")
                        detail("Orientation", displaySize.width > displaySize.height ? "Landscape" : "Portrait")
                        if simulator.isFoldable, let folded { detail("Fold State", folded ? "Closed" : "Opened") }
                    }
                }
            } else if let androidDisplay {
                Section("Display") {
                    detail("Screen", "\(Int(androidDisplay.size.width))×\(Int(androidDisplay.size.height)) · \(androidDisplay.density) dpi")
                }
            } else if device.serial == nil, let configuredDisplay {
                Section("Display") { detail("Configured Screen", configuredDisplay) }
            }
            if device.isEmulator {
                Section {
                    detail("Graphics Acceleration", graphicsMode)
                    detail("Boot Mode", bootMode)
                } header: {
                    Text("Emulator")
                } footer: {
                    SettingsFooterButton(title: "Edit Configuration", icon: "pencil", alignment: .trailing) { configuring = true }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $configuring, onDismiss: loadConfiguration) {
            EditEmulatorConfiguration(device: device).environment(hub)
        }
        .task(id: device.avd) { loadConfiguration() }
        .task(id: device.serial) {
            guard simulator == nil, let serial = device.serial else { androidDisplay = nil; return }
            while !Task.isCancelled {
                let current = try? await DeviceActions().displayState(serial: serial)
                guard !Task.isCancelled else { return }
                androidDisplay = current
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }

    private func detail(_ title: String, _ value: String) -> some View {
        LabeledContent {
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        } label: { Text(title) }
    }
    private func loadConfiguration() {
        configuration = device.avd.map { Hub.ini(SDK.avdDirectory($0).appending(path: "config.ini")) } ?? [:]
    }
}
