import SwiftUI

@main
struct DevHubApp: App {
    @State private var hub = Hub()
    @State private var installation = Installation()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("DevHub", id: "main") {
            ContentView().environment(hub)
                .task { await installation.checkAtStartup() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    Task { await installation.checkOnActivation() }
                }
                .sheet(isPresented: $installation.showUpdatePrompt) {
                    UpdatePromptView(installation: installation) { openWindow(id: "installation") }
                }
        }
        .defaultSize(width: 1000, height: 900)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About DevHub") { openWindow(id: "about") }
                Button("Check for Updates…") { openWindow(id: "installation") }
            }
            CommandGroup(replacing: .help) { Button("Welcome to DevHub") { openWindow(id: "welcome") } }
        }
        Window("About DevHub", id: "about") { AboutView().environment(hub) }
            .windowStyle(.hiddenTitleBar)
            .windowResizability(.contentSize)
        Window("Welcome to DevHub", id: "welcome") { WelcomeView() }
            .windowStyle(.hiddenTitleBar)
            .windowResizability(.contentSize)
        Window("DevHub Installation", id: "installation") { InstallationView(installation: installation) }
            .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    @Environment(Hub.self) private var hub
    @Environment(\.openWindow) private var openWindow
    @AppStorage("welcomed") private var welcomed = false
    @AppStorage("deviceList.filter") private var deviceFilter = DeviceFilter.all
    @AppStorage("deviceList.sort") private var deviceSort = DeviceSort.availability
    @AppStorage("deviceList.showGroups") private var showGroups = true
    @State private var query = ""
    @State private var panel: Panel?
    @AppStorage("inspector.width") private var inspectorWidth = 300.0
    @State private var creating: NewDeviceKind?
    @State private var choosingTiles = false
    @State private var tiledDevices: Set<Device.ID>?
    @State private var previousTiles: Set<Device.ID> = []

    private var listing: DeviceList {
        DeviceList(filter: deviceFilter, sort: deviceSort, showGroups: showGroups,
                   query: query, recentSelections: hub.recentSelections, booting: hub.booting)
    }

    var body: some View {
        Group {
            if let tiledDevices {
                TileModeView(selection: tiledDevices) { self.tiledDevices = nil }
            } else {
                deviceBrowser
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .sheet(isPresented: $choosingTiles) {
            TileDevicePicker(previousSelection: previousTiles) { selection in
                previousTiles = selection
                tiledDevices = selection
            }
        }
        .task { await hub.poll() }
        .onChange(of: hub.devices, initial: true) { _, _ in validateSelection() }
        .onChange(of: deviceFilter) { _, _ in validateSelection() }
        .onChange(of: hub.selection) { _, id in hub.recordSelection(id) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            hub.androidSessions.retain([])
            hub.simulatorSessions.retain([])
        }
        .alert("Device Action Failed", isPresented: Binding(get: { hub.failure != nil }, set: { if !$0 { hub.failure = nil } })) {
            Button("OK", role: .cancel) { hub.failure = nil }
        } message: { Text(hub.failure ?? "") }
        .onAppear { if !welcomed { openWindow(id: "welcome") } }
    }

    private var deviceBrowser: some View {
        @Bindable var hub = hub
        return NavigationSplitView {
            List(selection: $hub.selection) {
                ForEach(listing.groups(hub.displayedDevices)) { group in
                    if let title = group.title {
                        Section(title) { ForEach(group.devices) { DeviceRow(device: $0) } }
                    } else {
                        ForEach(group.devices) { DeviceRow(device: $0) }
                    }
                }
            }
            .overlay {
                if !hub.devices.isEmpty, listing.groups(hub.displayedDevices).isEmpty {
                    Text("No matching devices").foregroundStyle(.secondary).padding()
                }
            }
            .searchable(text: $query, placement: .sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .toolbar {
                ToolbarItemGroup {
                    NewDeviceMenu(selection: $creating)
                    DeviceListMenu()
                    Button("Tile Devices…", systemImage: "rectangle.split.2x2") { choosingTiles = true }
                        .help("Tile running devices")
                        .disabled(TileDevices.available(hub.devices, booting: hub.booting).isEmpty)
                }
            }
            .sheet(item: $creating) { kind in
                switch kind {
                case .android: NewEmulatorSheet().environment(hub)
                case .ios: NewSimulatorSheet().environment(hub)
                }
            }
        } detail: {
            if let device = hub.selected {
                if let simulator = device.simulator {
                    AppleSimulatorView(device: device, simulator: simulator, panel: $panel, inspectorWidth: $inspectorWidth).id(device.id)
                } else if let apple = device.appleDevice {
                    AppleDeviceView(device: device, apple: apple).id(device.id)
                } else {
                    AndroidDeviceView(device: device, panel: $panel, inspectorWidth: $inspectorWidth).id(device.id)
                }
            } else {
                ContentUnavailableView("No Devices", systemImage: "smartphone", description: Text("Create an emulator or connect a device. Apple simulators use your selected Xcode installation."))
            }
        }
    }

    private func validateSelection() {
        guard !hub.devices.isEmpty else { return }
        if let selection = hub.selection, hub.devices.contains(where: { $0.id == selection && deviceFilter.includes($0) }) { return }
        hub.selection = listing.groups(hub.displayedDevices).first?.devices.first?.id
    }
}

struct DeviceRow: View {
    @Environment(Hub.self) private var hub
    let device: Device
    @State private var confirmingDelete = false
    @State private var deleteRefused = false
    @State private var deleting = false

    var body: some View {
        HStack(spacing: 10) {
            DeviceBadge(kind: device.kind, selected: hub.selection == device.id, running: device.isRunning, simulator: device.simulator != nil || device.appleDevice != nil)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(hub.booting.contains(device.id) ? "Booting…" : device.detail)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(device.api).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).fixedSize()
        }
        .padding(.vertical, 2)
        .contextMenu {
            if let simulator = device.simulator {
                if device.isRunning { Button("Shut Down") { hub.shutdown(device) } }
                else {
                    Button("Boot") { hub.boot(device) }.disabled(hub.booting.contains(device.id) || deleting)
                    if simulator.state == "Shutdown" { Divider(); deleteButton }
                }
            }
            if device.isEmulator {
                if device.serial == nil {
                    Button("Boot") { hub.boot(device) }.disabled(hub.booting.contains(device.id) || deleting)
                    Divider()
                    deleteButton
                } else {
                    Button("Shut Down") { hub.shutdown(device) }
                }
            }
        }
        .confirmationDialog("Delete \(device.name)?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                deleting = true
                Task { @MainActor in
                    defer { deleting = false }
                    await hub.delete(device)
                }
            }
        } message: {
            Text("The \(device.simulator == nil ? "emulator" : "simulator") and everything installed on it go away. This can't be undone.")
        }
        .alert("\(device.name) is running", isPresented: $deleteRefused) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Shut it down before deleting it.")
        }
    }

    private var deleteButton: some View {
        Button("Delete…", role: .destructive) {
            // An emulator started elsewhere may still have no serial while booting.
            if let avd = device.avd, AVD.isRunning(avd) { deleteRefused = true }
            else { confirmingDelete = true }
        }
        .disabled(hub.booting.contains(device.id) || deleting)
    }
}
