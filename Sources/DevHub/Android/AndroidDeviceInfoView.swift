import SwiftUI

/// Android device metadata, live display information, and saved emulator configuration.
struct AndroidDeviceInfoView: View {
    @Environment(Hub.self) private var hub
    let device: Device
    @State private var configuration: [String: String] = [:]
    @State private var androidDisplay: DisplayState?
    @State private var configuring = false

    private var state: String {
        if hub.booting.contains(device.id) { return "Booting" }
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
                DeviceInfoRow("Name", device.name)
                DeviceInfoRow("Model", model)
                DeviceInfoRow("Form Factor", device.kind.title)
                DeviceInfoRow("State", state)
                if !device.release.isEmpty { DeviceInfoRow("Android", device.release) }
                if !device.api.isEmpty { DeviceInfoRow("API", device.api) }
                if let serial = device.serial { DeviceInfoRow("Serial", serial) }
                if let avd = device.avd, !hub.demoMode { DeviceInfoRow("AVD", avd) }
            }
            if let androidDisplay {
                Section("Display") {
                    DeviceInfoRow("Screen", "\(Int(androidDisplay.size.width))×\(Int(androidDisplay.size.height)) · \(androidDisplay.density) dpi")
                }
            } else if device.serial == nil, let configuredDisplay {
                Section("Display") { DeviceInfoRow("Configured Screen", configuredDisplay) }
            }
            if device.isEmulator {
                Section {
                    DeviceInfoRow("Graphics Acceleration", graphicsMode)
                    DeviceInfoRow("Boot Mode", bootMode)
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
            guard let serial = device.serial else { androidDisplay = nil; return }
            while !Task.isCancelled {
                let current = try? await DeviceActions().displayState(serial: serial)
                guard !Task.isCancelled else { return }
                androidDisplay = current
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }

    private func loadConfiguration() {
        configuration = device.avd.map { Hub.ini(SDK.avdDirectory($0).appending(path: "config.ini")) } ?? [:]
    }
}
