import Foundation

struct SimulatorCatalog {
    struct Model: Decodable, Hashable, Identifiable {
        let identifier: String
        let name: String
        let productFamily: String
        let minRuntimeVersion: Int?
        let maxRuntimeVersion: Int?
        var id: String { identifier }
        var isIOS: Bool { productFamily == "iPhone" || productFamily == "iPad" }
        var kind: DeviceKind { productFamily == "iPad" ? .tablet : name.localizedCaseInsensitiveContains("Duo") ? .foldable : .phone }
    }

    struct Runtime: Decodable, Hashable, Identifiable {
        let identifier: String
        let name: String
        let version: String
        let isAvailable: Bool
        let supportedDeviceTypes: [Model]?
        var id: String { identifier }
    }

    let runtimes: [Runtime]
    let deviceTypes: [Model]
    let existingNames: Set<String>
    private let devices: [String: [ExistingDevice]]
    private let reusableIDs: Set<String>

    private struct ExistingDevice: Decodable {
        let name: String
        let udid: String?
        let state: String?
        let deviceTypeIdentifier: String?
        let isAvailable: Bool?
        let lastUsedAt: String?
        let lastBootedAt: String?
        var unused: Bool { state == "Shutdown" && isAvailable == true && lastUsedAt == nil && lastBootedAt == nil }
    }

    static func load() async throws -> Self {
        let result = try await Simctl.run(["list", "--json"])
        try result.checked()
        let included = Set(UserDefaults.standard.stringArray(forKey: "createdSimulatorIDs") ?? [])
        return try parse(Data(result.output.utf8), defaultDeviceIDs: AppleSimulator.defaultDeviceIDs().subtracting(included))
    }

    static func parse(_ data: Data, defaultDeviceIDs: Set<String> = []) throws -> Self {
        struct Inventory: Decodable {
            let runtimes: [Runtime]
            let devicetypes: [Model]
            let devices: [String: [ExistingDevice]]?
        }
        let inventory = try JSONDecoder().decode(Inventory.self, from: data)
        let runtimes = inventory.runtimes.filter { $0.isAvailable && $0.identifier.hasPrefix("com.apple.CoreSimulator.SimRuntime.iOS-") }
            .sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
        return Self(runtimes: runtimes, deviceTypes: inventory.devicetypes,
                    existingNames: Set(inventory.devices?.values.flatMap { $0.map(\.name) } ?? []),
                    devices: inventory.devices ?? [:], reusableIDs: defaultDeviceIDs)
    }

    func models(for runtime: Runtime) -> [Model] {
        // Runtime-specific lists also cover special images such as the Duo's.
        if let supported = runtime.supportedDeviceTypes { return supported.filter(\.isIOS) }
        let components = runtime.version.split(separator: ".").compactMap { Int($0) }
        let version = (components.first ?? 0) * 65536 + (components.count > 1 ? components[1] : 0) * 256 + (components.count > 2 ? components[2] : 0)
        return deviceTypes.filter { $0.isIOS && ($0.minRuntimeVersion ?? 0) <= version && version <= ($0.maxRuntimeVersion ?? Int.max) }
    }

    var kinds: [DeviceKind] { [.phone, .tablet, .foldable].filter { !runtimes(for: $0).isEmpty } }

    func runtimes(for kind: DeviceKind) -> [Runtime] {
        runtimes.filter { models(for: $0).contains { $0.kind == kind } }
    }

    private func reusableDevice(modelID: String, runtimeID: String) -> ExistingDevice? {
        devices[runtimeID]?.first {
            $0.unused && $0.deviceTypeIdentifier == modelID && $0.udid.map(reusableIDs.contains) == true
        }
    }

    func uniqueName(for model: Model, runtimeID: String? = nil) -> String {
        let reused = runtimeID.flatMap { reusableDevice(modelID: model.id, runtimeID: $0) }?.udid
        let names = reused == nil ? existingNames : Set(devices.values.flatMap { $0 }.filter { $0.udid != reused }.map(\.name))
        var name = model.name, number = 2
        while names.contains(name) { name = "\(model.name) (\(number))"; number += 1 }
        return name
    }

    func create(name: String, modelID: String, runtimeID: String,
                run: ([String]) async throws -> ToolResult = { try await Simctl.run($0) }) async throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.rangeOfCharacter(from: .controlCharacters) == nil else { throw MirrorError("Enter a simulator name.") }
        guard let runtime = runtimes.first(where: { $0.id == runtimeID }), models(for: runtime).contains(where: { $0.id == modelID }) else {
            throw MirrorError("Choose a model supported by the selected iOS version.")
        }
        if let candidate = reusableDevice(modelID: modelID, runtimeID: runtimeID), let id = candidate.udid, UUID(uuidString: id) != nil {
            struct Inventory: Decodable { let devices: [String: [ExistingDevice]] }
            let result = try await run(["list", "devices", "--json"])
            try result.checked()
            let current = try JSONDecoder().decode(Inventory.self, from: Data(result.output.utf8))
            guard let device = current.devices[runtimeID]?.first(where: { $0.udid == id }),
                  device.unused, device.deviceTypeIdentifier == modelID, device.name == candidate.name else {
                throw MirrorError("The unused simulator changed. Reopen this dialog to refresh the available devices.")
            }
            if device.name != name { try await run(["rename", id, name]).checked() }
            return id
        }
        let result = try await run(["create", name, modelID, runtimeID])
        try result.checked()
        let id = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: id) != nil else { throw MirrorError("The simulator didn't return a valid device identifier. Refresh the device list before trying again.") }
        return id
    }
}

struct SimulatorCreationSelection {
    var kind: DeviceKind = .phone
    var runtimeID = ""
    var modelID = ""

    mutating func reconcile(_ catalog: SimulatorCatalog) {
        if !catalog.kinds.contains(kind) { kind = catalog.kinds.first ?? .phone }
        let runtimes = catalog.runtimes(for: kind)
        if !runtimes.contains(where: { $0.id == runtimeID }) { runtimeID = runtimes.first?.id ?? "" }
        let models = runtimes.first { $0.id == runtimeID }.map { catalog.models(for: $0).filter { $0.kind == kind } } ?? []
        if !models.contains(where: { $0.id == modelID }) { modelID = models.first?.id ?? "" }
    }
}
