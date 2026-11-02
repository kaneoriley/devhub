import SwiftUI
import UniformTypeIdentifiers

struct EmulatorConfigurationFields: View {
    @Binding var value: EmulatorConfiguration
    let compatibility: EmulatorCompatibility
    @State private var choosingImage = false

    var body: some View {
        if compatibility.frontCamera || compatibility.rearCamera {
            Section("Camera") {
                if compatibility.frontCamera { options("Front", value: $value.frontCamera, choices: [("none", "None"), ("emulated", "Emulated"), ("webcam0", "Webcam0")]) }
                if compatibility.rearCamera { options("Rear", value: $value.rearCamera, choices: [("none", "None"), ("virtualscene", "Virtual Scene"), ("emulated", "Emulated"), ("webcam0", "Webcam0")]) }
            }
        }
        Section("Network") {
            options("Speed", value: $value.speed, choices: ["full", "lte", "hsdpa", "umts", "edge", "gprs", "hscsd", "gsm"].map { ($0, $0 == "full" ? "Full" : $0.uppercased()) })
                .help("The initial simulated network transfer rate.")
            options("Latency", value: $value.latency, choices: ["none", "umts", "edge", "gprs"].map { ($0, $0 == "none" ? "None" : $0.uppercased()) })
                .help("The initial simulated delay across the network.")
        }
        Section("Startup") {
            if compatibility.orientations.count > 1 {
                options("Orientation", value: $value.orientation, choices: compatibility.orientations.map { ($0, $0.capitalized) })
            }
            options("Default Boot", value: $value.boot, choices: [("quick", "Quick"), ("cold", "Cold")])
                .help("Quick resumes the saved state. Cold starts the device from a power-up.")
        }
        Section("Storage") {
            capacity("Internal Storage", value: $value.storage)
            if compatibility.expandedStorage {
                options("Expanded Storage", value: $value.expanded, choices: [("custom", "Custom"), ("image", "Existing Image"), ("none", "None")])
                if value.expanded == "custom" { capacity("SD Card Size", value: $value.sdSize) }
                if value.expanded == "image" {
                    LabeledContent("SD Card Image") {
                        HStack {
                            TextField("Path", text: $value.sdPath).textFieldStyle(.roundedBorder)
                            Button("Choose Image", systemImage: "folder") { choosingImage = true }.labelStyle(.iconOnly)
                        }.frame(width: 260)
                    }
                }
            }
        }
        .fileImporter(isPresented: $choosingImage, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result { value.sdPath = url.path }
        }
        Section("Emulated Performance") {
            Picker("CPU Cores", selection: $value.cores) {
                ForEach(1...max(compatibility.maxCores, value.cores), id: \.self) { Text(String($0)).tag($0) }
            }
            options("Graphics Acceleration", value: $value.graphics, choices: [("auto", "Automatic"), ("host", "Hardware"), ("software", "Software")])
            capacity("RAM", value: $value.ram, units: [.mb, .gb]).help("Allocated from this Mac while the emulator runs.")
            capacity("VM Heap Size", value: $value.heap, units: [.mb, .gb])
            options("Preferred ABI", value: $value.preferredABI, choices: [("", "Optimal")] + compatibility.abis.map { ($0, $0) })
                .help("Preferred application ABI, also used by Android Studio's deployment tools. Optimal uses the image default.")
        }
    }

    private func options(_ title: String, value: Binding<String>, choices: [(String, String)]) -> some View {
        Picker(title, selection: value) {
            ForEach(choices, id: \.0) { item in Text(item.1).tag(item.0) }
            if !choices.contains(where: { $0.0 == value.wrappedValue }) { Text(value.wrappedValue).tag(value.wrappedValue) }
        }
    }
    private func capacity(_ title: String, value: Binding<EmulatorCapacity>, units: [EmulatorCapacity.Unit] = EmulatorCapacity.Unit.allCases) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                TextField(title, text: value.amount).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 110)
                Picker("\(title) Unit", selection: value.unit) {
                    ForEach(units.contains(value.wrappedValue.unit) ? units : [value.wrappedValue.unit] + units, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 75)
            }
        }
    }
}

struct EmulatorConfigurationDialog: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let initial: EmulatorConfiguration
    let compatibility: EmulatorCompatibility
    var running = false
    var replacesCard: (EmulatorConfiguration) -> Bool = { _ in false }
    let save: (EmulatorConfiguration) async throws -> Void
    @State private var value: EmulatorConfiguration
    @State private var saving = false
    @State private var failure: String?
    @State private var replacing = false

    init(title: String, initial: EmulatorConfiguration, compatibility: EmulatorCompatibility, running: Bool = false,
         replacesCard: @escaping (EmulatorConfiguration) -> Bool = { _ in false }, save: @escaping (EmulatorConfiguration) async throws -> Void) {
        self.title = title; self.initial = initial; self.compatibility = compatibility; self.running = running
        self.replacesCard = replacesCard; self.save = save
        _value = State(initialValue: initial)
    }
    private var validation: String? {
        do { try value.validate(compatibility: compatibility, original: initial); return nil }
        catch { return String(describing: error) }
    }
    var body: some View {
        VStack(spacing: 0) {
            Text(title).font(.headline).padding(.top, 20)
            Form {
                if running { Section { Text("Shut down this emulator before saving configuration changes.").foregroundStyle(.secondary) } }
                EmulatorConfigurationFields(value: $value, compatibility: compatibility).disabled(running || saving)
            }.formStyle(.grouped)
            if let message = failure ?? validation { Text(message).font(.caption).foregroundStyle(.red).padding([.horizontal, .bottom], 16) }
            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button("Save") {
                    if replacesCard(value) { replacing = true } else { commit() }
                }.keyboardShortcut(.defaultAction).disabled(running || saving || validation != nil)
            }.padding([.horizontal, .bottom], 20)
        }
        .frame(width: 530, height: 690)
        .interactiveDismissDisabled(saving)
        .confirmationDialog("Replace the SD card?", isPresented: $replacing) {
            Button("Replace SD Card", role: .destructive) { commit() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Changing the custom SD card size erases its existing contents. Apps and data on internal storage are kept.") }
    }
    private func commit() {
        saving = true; failure = nil
        Task { @MainActor in
            defer { saving = false }
            do { try await save(value); dismiss() }
            catch { failure = String(describing: error) }
        }
    }
}

struct EditEmulatorConfiguration: View {
    @Environment(Hub.self) private var hub
    let device: Device
    @State private var file: EmulatorConfigurationFile?
    @State private var compatibility: EmulatorCompatibility?
    @State private var failure: String?
    private var running: Bool { hub.devices.first(where: { $0.id == device.id })?.isRunning == true || hub.booting.contains(device.id) }
    var body: some View {
        Group {
            if let file, let compatibility, let avd = device.avd {
                EmulatorConfigurationDialog(title: device.name, initial: file.original, compatibility: compatibility,
                    running: running || AVD.isRunning(avd), replacesCard: file.replacesCard) { value in
                    hub.configuring.insert(device.id)
                    defer { hub.configuring.remove(device.id) }
                    try await file.save(value, compatibility: compatibility, isRunning: { running || AVD.isRunning(avd) })
                    await hub.refresh()
                }
            } else if let failure {
                VStack(spacing: 16) { Text("Couldn't Load Configuration").font(.headline); Text(failure); DismissConfigurationButton() }.padding(24).frame(width: 480)
            } else { ProgressView("Loading Configuration…").padding(40) }
        }
        .task {
            do {
                guard let avd = device.avd else { return }
                let loaded = try EmulatorConfigurationFile(directory: SDK.avdDirectory(avd))
                let profiles = await DeviceProfile.load()
                compatibility = EmulatorCompatibility(profile: profiles.first { $0.id == loaded.config["hw.device.name"] }, config: loaded.config, imageDirectory: loaded.imageDirectory)
                file = loaded
            } catch { failure = String(describing: error) }
        }
    }
}
private struct DismissConfigurationButton: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View { Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
}
