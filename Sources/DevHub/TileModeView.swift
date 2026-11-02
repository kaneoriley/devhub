import SwiftUI

enum TileDevices {
    static func available(_ devices: [Device], booting: Set<Device.ID>) -> [Device] {
        devices.filter { $0.isRunning && $0.appleDevice == nil && !booting.contains($0.id) }
    }
}

enum TileScreenGeometry {
    static func aspectRatio(_ size: CGSize) -> CGFloat {
        let border = min(size.width, size.height) * 0.04
        return (size.width + border) / (size.height + border)
    }
}

struct TileConnectionFailure: View {
    let name: String
    let error: String
    let retry: () -> Void
    var body: some View {
        VStack(spacing: 8) {
            Text(name).font(.headline)
            Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(4)
            Button("Retry", action: retry)
        }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TileDevicePicker: View {
    @Environment(Hub.self) private var hub
    @Environment(\.dismiss) private var dismiss
    let previousSelection: Set<Device.ID>
    let start: (Set<Device.ID>) -> Void
    @State private var selection: Set<Device.ID> = []
    private var devices: [Device] { TileDevices.available(hub.displayedDevices, booting: hub.booting) }
    private var availableIDs: Set<Device.ID> { Set(devices.map(\.id)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tile Devices").font(.title2.bold())
            Text("Choose running Android devices and iOS simulators to watch together.").foregroundStyle(.secondary)
            List(devices) { device in
                HStack(alignment: .center, spacing: 10) {
                    Toggle(device.name, isOn: Binding(get: { selection.contains(device.id) }, set: { selected in
                        if selected { selection.insert(device.id) } else { selection.remove(device.id) }
                    }))
                    .toggleStyle(.checkbox).labelsHidden()
                    DeviceBadge(kind: device.kind, selected: false, running: true, simulator: device.simulator != nil)
                    VStack(alignment: .leading) {
                        Text(device.name).lineLimit(1)
                        Text(device.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                }
                .padding(.vertical, 3)
                .padding(.trailing, 12)
            }
            .overlay { if devices.isEmpty { Text("No running devices").foregroundStyle(.secondary) } }
            .frame(height: min(360, max(120, CGFloat(devices.count) * 55)))
            HStack {
                Button("Select All") { selection = availableIDs }.disabled(devices.isEmpty)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Tile Devices") {
                    let selected = selection.intersection(availableIDs)
                    guard !selected.isEmpty else { return }
                    dismiss()
                    start(selected)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(selection.intersection(availableIDs).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 450)
        .onAppear {
            let previous = previousSelection.intersection(availableIDs)
            selection = previous.isEmpty ? availableIDs : previous
        }
        .onChange(of: availableIDs) { _, ids in selection.formIntersection(ids) }
    }
}

struct TileAspectRatios: PreferenceKey {
    static var defaultValue: [Device.ID: CGFloat] = [:]
    static func reduce(value: inout [Device.ID: CGFloat], nextValue: () -> [Device.ID: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct TileModeView: View {
    @Environment(Hub.self) private var hub
    let selection: Set<Device.ID>
    let exit: () -> Void
    @State private var ratios: [Device.ID: CGFloat] = [:]
    @State private var removed: Set<Device.ID> = []
    private var devices: [Device] {
        TileDevices.available(hub.displayedDevices, booting: hub.booting)
            .filter { selection.contains($0.id) && !removed.contains($0.id) }
    }

    var body: some View {
        GeometryReader { geometry in
            let devices = devices
            let frames = TileArrangement.frames(aspectRatios: devices.map { ratios[$0.id] ?? 0.5 }, in: geometry.size)
            ZStack(alignment: .topLeading) {
                ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                    TileScreenView(device: device)
                        .frame(width: frames[index].width, height: frames[index].height)
                        .position(x: frames[index].midX, y: frames[index].midY)
                        .accessibilityLabel(device.name)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }
        .padding(16)
        .overlay {
            if devices.isEmpty {
                ContentUnavailableView("No Running Devices", systemImage: "rectangle.split.2x2",
                                       description: Text("The selected devices have stopped or disconnected."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: exit) { Image(systemName: "chevron.left") }
                    .help("Exit tile mode").accessibilityLabel("Exit Tile Mode")
            }
        }
        .toolbarVisibility(.visible, for: .windowToolbar)
        .onPreferenceChange(TileAspectRatios.self) { ratios = $0 }
        .onChange(of: Set(devices.map(\.id)), initial: true) { _, ids in
            // A device that disconnects stays removed even if it comes back later.
            removed.formUnion(selection.subtracting(ids))
        }
    }
}

struct TileScreenView: View {
    let device: Device
    var body: some View {
        Group {
            if let simulator = device.simulator {
                SimulatorTileScreen(device: device, simulator: simulator)
            } else {
                AndroidTileScreen(device: device)
            }
        }
    }
}
