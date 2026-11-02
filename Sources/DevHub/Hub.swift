import AppKit
import Observation

@Observable @MainActor
final class Hub {
    @ObservationIgnored private var displayControllers: [String: DisplayController] = [:]
    @ObservationIgnored let simulatorSessions = DeviceSessionCache<SimulatorMirror>()
    @ObservationIgnored let simulatorSettings = SimulatorSettingsCache()
    @ObservationIgnored let androidSettings = AndroidSettingsCache()
    @ObservationIgnored let androidSessions = DeviceSessionCache<AndroidMirrorSession>()

    func displayController(serial: String, isEmulator: Bool) -> DisplayController {
        if let controller = displayControllers[serial] { return controller }
        let controller = DisplayController(serial: serial, isEmulator: isEmulator)
        displayControllers[serial] = controller
        return controller
    }
    var devices: [Device] = []
    var demoMode = UserDefaults.standard.bool(forKey: "demoMode") {
        didSet { UserDefaults.standard.set(demoMode, forKey: "demoMode") }
    }
    var selection: Device.ID?
    var recentSelections: [String: Double] = UserDefaults.standard.dictionary(forKey: "deviceList.recentSelections") as? [String: Double] ?? [:]
    var booting: Set<Device.ID> = []
    var configuring: Set<Device.ID> = []
    var failure: String?
    var savedScreenshot: SavedScreenshot?
    @ObservationIgnored private var screenshotDismissal: Task<Void, Never>?
    @ObservationIgnored var props: [String: [String: String]] = [:]
    @ObservationIgnored var createdSimulatorIDs = Set(UserDefaults.standard.stringArray(forKey: "createdSimulatorIDs") ?? []) {
        didSet { UserDefaults.standard.set(Array(createdSimulatorIDs), forKey: "createdSimulatorIDs") }
    }
    @ObservationIgnored private var refreshRequest = 0

    var displayedDevices: [Device] { devices.map { $0.presented(demoMode: demoMode) } }
    var selected: Device? { devices.first { $0.id == selection }?.presented(demoMode: demoMode) }

    func recordSelection(_ id: Device.ID?) {
        guard let id else { return }
        recentSelections[id] = Date.now.timeIntervalSince1970
        UserDefaults.standard.set(recentSelections, forKey: "deviceList.recentSelections")
    }

    init() { EmulatorWindows.observe() }

    func poll() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func refresh() async {
        refreshRequest += 1
        let request = refreshRequest
        async let simulators = AppleSimulator.list(including: createdSimulatorIDs)
        var list = await androidDevices()
        list += await simulators
        guard request == refreshRequest else { return }
        simulatorSessions.retain(Set(list.compactMap { $0.simulator?.isBooted == true ? $0.simulator?.udid : nil }))
        simulatorSettings.prepare(Set(list.compactMap { $0.simulator?.isBooted == true ? $0.simulator?.udid : nil }))
        androidSessions.retain(Set(list.compactMap(\.serial)))
        androidSettings.prepare(list)
        booting.subtract(list.filter { $0.simulator == nil && $0.isRunning }.map(\.id))
        if devices != list { devices = list }
        if selection != nil, selected == nil { selection = nil }
    }

    func boot(_ device: Device) {
        if let simulator = device.simulator { bootSimulator(simulator, device: device) }
        else { bootEmulator(device) }
    }

    func shutdown(_ device: Device) {
        if let simulator = device.simulator { shutdownSimulator(simulator) }
        else { shutdownAndroid(device) }
    }

    func delete(_ device: Device) async {
        do {
            guard !booting.contains(device.id) else { throw MirrorError("Shut it down before deleting it.") }
            if let simulator = device.simulator {
                try await deleteSimulator(simulator)
            } else if let avd = device.avd {
                try deleteEmulator(avd)
            } else { return }
            await refresh()
        } catch { failure = String(describing: error) }
    }

    /// Saves to the Desktop and copies to the clipboard, like Simulator.
    func saveScreenshot(_ device: Device, png: Data) throws {
        let date = Date.now.formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) at \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits).\(second: .twoDigits)", timeZone: .current, calendar: .current))
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let url = desktop.appending(path: "\(device.name.replacingOccurrences(of: "/", with: "-")) \(date).png")
        try png.write(to: url, options: .atomic)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)
        let saved = SavedScreenshot(deviceID: device.id, url: url, thumbnail: NSImage(data: png))
        savedScreenshot = saved
        scheduleScreenshotDismissal(saved.id)
    }

    func screenshotHovered(_ id: UUID, hovering: Bool) {
        guard savedScreenshot?.id == id else { return }
        screenshotDismissal?.cancel()
        if !hovering { scheduleScreenshotDismissal(id) }
    }

    func revealScreenshot(_ saved: SavedScreenshot) {
        NSWorkspace.shared.activateFileViewerSelecting([saved.url])
        if savedScreenshot?.id == saved.id {
            screenshotDismissal?.cancel()
            savedScreenshot = nil
        }
    }

    private func scheduleScreenshotDismissal(_ id: UUID) {
        screenshotDismissal?.cancel()
        screenshotDismissal = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            if savedScreenshot?.id == id { savedScreenshot = nil }
        }
    }
}
