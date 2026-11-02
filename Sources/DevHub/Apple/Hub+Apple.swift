import Foundation

extension Hub {
    func bootSimulator(_ simulator: AppleSimulator, device: Device) {
        guard !booting.contains(device.id) else { return }
        booting.insert(device.id)
        Task {
            defer { booting.remove(device.id) }
            do {
                if simulator.state != "Booting" { try await Simctl.run(["boot", simulator.udid]).checked() }
                try await Simctl.run(["bootstatus", simulator.udid, "-b"]).checked()
                await refresh()
            } catch { failure = String(describing: error) }
        }
    }

    func shutdownSimulator(_ simulator: AppleSimulator) {
        Task {
            do { try await Simctl.run(["shutdown", simulator.udid]).checked(); await refresh() }
            catch { failure = String(describing: error) }
        }
    }

    func deleteSimulator(_ simulator: AppleSimulator) async throws {
        try await Simctl.deleteSimulator(simulator.udid)
        createdSimulatorIDs.remove(simulator.udid)
    }

    func createSimulator(name: String, modelID: String, runtimeID: String, catalog: SimulatorCatalog) async throws {
        let id = try await catalog.create(name: name, modelID: modelID, runtimeID: runtimeID)
        // CoreDevice may publish the new device after simctl returns. Include it
        // immediately from CoreSimulator's inventory while that catches up.
        createdSimulatorIDs.insert(id)
        if UserDefaults.standard.string(forKey: "deviceList.filter") == DeviceFilter.physical.rawValue {
            UserDefaults.standard.set(DeviceFilter.all.rawValue, forKey: "deviceList.filter")
        }
        await refresh()
        selection = "simulator:\(id)"
    }
}
