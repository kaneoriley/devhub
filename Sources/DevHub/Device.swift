import Foundation

struct Device: Identifiable, Hashable {
    let id: String
    var name: String
    var detail: String
    var model = ""
    var modelName = ""
    var release = ""
    var api = ""
    var kind = DeviceKind.phone
    var simulator: AppleSimulator?
    var appleDevice: AppleDevice?
    var avd: String?
    var hasSystemImage = true
    var lastUsedAt: Date?
    /// Set once the device is online and booted.
    var serial: String?
    var isEmulator: Bool { avd != nil }
    var isRunning: Bool { simulator?.isBooted ?? appleDevice?.isConnected ?? (serial != nil) }

    /// Use a presentation copy so demo names never alter device identity or saved names.
    func presented(demoMode: Bool) -> Device {
        guard demoMode else { return self }
        let model = [modelName, model, simulator?.type ?? "", kind.title]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? kind.title
        var presented = self
        presented.name = model
        return presented
    }
}
