import SwiftUI

/// Route the shared inspector to the platform's device information.
struct DeviceInfoView: View {
    let device: Device
    var displaySize: CGSize?
    var folded: Bool?

    var body: some View {
        if let simulator = device.simulator {
            SimulatorInfoView(device: device, simulator: simulator, displaySize: displaySize, folded: folded)
        } else {
            AndroidDeviceInfoView(device: device)
        }
    }
}

struct DeviceInfoRow: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title; self.value = value
    }

    var body: some View {
        LabeledContent {
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        } label: { Text(title) }
    }
}
