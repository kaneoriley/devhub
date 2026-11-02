import SwiftUI

struct SimulatorInfoView: View {
    @Environment(Hub.self) private var hub
    let device: Device
    let simulator: AppleSimulator
    var displaySize: CGSize?
    var folded: Bool?

    private var state: String {
        if hub.booting.contains(device.id) { return "Booting" }
        return simulator.state == "Shutdown" ? "Shut Down" : simulator.state
    }

    var body: some View {
        Form {
            Section("Device") {
                DeviceInfoRow("Name", device.name)
                DeviceInfoRow("Model", device.model.isEmpty ? "Unknown" : device.model)
                DeviceInfoRow("Form Factor", device.kind.title)
                DeviceInfoRow("State", state)
                DeviceInfoRow("OS", "\(device.platform) \(simulator.version)")
                DeviceInfoRow("Runtime", simulator.runtime)
                DeviceInfoRow("Family", simulator.family)
                DeviceInfoRow("Identifier", simulator.udid)
                if let lastUsed = device.lastUsedAt {
                    DeviceInfoRow("Last Used", lastUsed.formatted(date: .abbreviated, time: .shortened))
                }
            }
            if let displaySize {
                Section("Display") {
                    DeviceInfoRow("Screen", "\(Int(displaySize.width))×\(Int(displaySize.height))")
                    DeviceInfoRow("Orientation", displaySize.width > displaySize.height ? "Landscape" : "Portrait")
                    if simulator.isFoldable, let folded { DeviceInfoRow("Fold State", folded ? "Closed" : "Opened") }
                }
            }
        }
        .formStyle(.grouped)
    }
}
