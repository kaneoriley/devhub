import AppKit
import Observation

struct Device: Identifiable, Hashable {
    let id: String
    var name: String
    var detail: String
    var model = ""
    var release = ""
    var api = ""
    var kind = DeviceKind.phone
    var simulator: AppleSimulator?
    var appleDevice: AppleDevice?
    var avd: String?
    /// Set once the device is online and booted.
    var serial: String?
    var isEmulator: Bool { avd != nil }
    var isRunning: Bool { simulator?.isBooted ?? appleDevice?.isConnected ?? (serial != nil) }
}

enum SDK {
    static let root: URL = {
        let env = ProcessInfo.processInfo.environment
        if let path = env["ANDROID_HOME"] ?? env["ANDROID_SDK_ROOT"] { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Android/sdk")
    }()
    static let adb = root.appending(path: "platform-tools/adb").path
    static let emulator = root.appending(path: "emulator/emulator").path
    // ponytail: ignores ANDROID_AVD_HOME and custom path= entries in the .ini files
    static let avdHome = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".android/avd")
}

/// Runs a tool and returns its stdout.
func exec(_ tool: String, _ args: [String]) async -> Data {
    await withCheckedContinuation { cont in
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return cont.resume(returning: Data()) }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            cont.resume(returning: data)
        }
    }
}

@discardableResult
func adb(_ args: String...) async -> String {
    String(decoding: await exec(SDK.adb, args), as: UTF8.self)
}

@Observable @MainActor
final class Hub {
    @ObservationIgnored private var displayControllers: [String: DisplayController] = [:]
    @ObservationIgnored let simulatorSessions = DeviceSessionCache<SimulatorMirror>()
    @ObservationIgnored let androidSessions = DeviceSessionCache<AndroidMirrorSession>()

    func displayController(serial: String, isEmulator: Bool) -> DisplayController {
        if let controller = displayControllers[serial] { return controller }
        let controller = DisplayController(serial: serial, isEmulator: isEmulator)
        displayControllers[serial] = controller
        return controller
    }
    var devices: [Device] = []
    var selection: Device.ID?
    var booting: Set<Device.ID> = []
    var failure: String?
    @ObservationIgnored private var props: [String: [String: String]] = [:]

    var selected: Device? { devices.first { $0.id == selection } }

    init() {
        // Emulators started elsewhere (Android Studio, react-native run-android) bring their
        // own window. Hiding that app leaves the screen to DroidHub. Qt activates and unhides
        // the emulator about a second after launch, so those are hidden again too, but only in
        // the first 10 s: a later unhide is the user clicking the Dock icon to get the window back.
        NSWorkspace.shared.runningApplications.forEach(Self.hideEmulator)
        let launch = NSWorkspace.didLaunchApplicationNotification
        for name in [launch, NSWorkspace.didActivateApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) {
                guard let app = $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                if name == launch { Self.launched[app.processIdentifier] = .now }
                if Date.now.timeIntervalSince(Self.launched[app.processIdentifier] ?? .distantPast) < 10 { Self.hideEmulator(app) }
            }
        }
    }

    // Main queue only. NSRunningApplication.launchDate is nil for the emulator, hence the bookkeeping.
    nonisolated(unsafe) private static var launched: [pid_t: Date] = [:]

    nonisolated private static func hideEmulator(_ app: NSRunningApplication) {
        if app.executableURL?.lastPathComponent.hasPrefix("qemu-system") == true { app.hide() }
    }

    func poll() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func refresh() async {
        async let simulators = AppleSimulator.list()
        let serials = await adb("devices").split(separator: "\n").dropFirst().compactMap { line -> String? in
            let f = line.split(separator: "\t")
            return f.count == 2 && f[1] == "device" ? String(f[0]) : nil
        }
        props = props.filter { serials.contains($0.key) }
        for serial in serials where props[serial] == nil {
            let p = await Self.getprop(serial)
            if p["sys.boot_completed"] == "1" { props[serial] = p }
        }

        var list = Self.avds()
        for (serial, p) in props.sorted(by: { $0.key < $1.key }) {
            let model = p["ro.product.model"] ?? serial
            var d: Device
            // Older images (API 30 and below) publish ro.kernel.qemu.avd_name instead.
            if let avd = p["ro.boot.qemu.avd_name"] ?? p["ro.kernel.qemu.avd_name"], let i = list.firstIndex(where: { $0.avd == avd }) {
                d = list.remove(at: i)
            } else {
                d = Device(id: serial, name: model, detail: p["ro.product.manufacturer"] ?? "Android")
            }
            d.serial = serial
            d.model = model
            d.release = p["ro.build.version.release"] ?? ""
            let avdVersion = d.isEmulator && !d.api.isEmpty ? String(d.api.dropFirst(4)) : nil
            d.api = AndroidAPI.label(properties: p, avdVersion: avdVersion) ?? d.api
            list.append(d)
        }
        list.sort { ($0.isEmulator ? 1 : 0, $0.name) < ($1.isEmulator ? 1 : 0, $1.name) }

        list += await simulators
        simulatorSessions.retain(Set(list.compactMap { $0.simulator?.isBooted == true ? $0.simulator?.udid : nil }))
        androidSessions.retain(Set(list.compactMap(\.serial)))
        booting.subtract(list.filter { $0.simulator == nil && $0.isRunning }.map(\.id))
        if devices != list { devices = list }
        if selected == nil { selection = list.first { $0.serial != nil }?.id ?? list.first?.id }
    }

    func boot(_ device: Device) {
        if let simulator = device.simulator {
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
            return
        }
        guard let avd = device.avd, !booting.contains(device.id) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: SDK.emulator)
        let config = Self.ini(SDK.avdHome.appending(path: "\(avd).avd/config.ini"))
        p.arguments = Self.bootArguments(avd: avd, config: config)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { _ in Task { @MainActor in self.booting.remove(device.id) } }
        guard (try? p.run()) != nil else { return }
        booting.insert(device.id)
    }

    nonisolated static func bootArguments(avd: String, config: [String: String]) -> [String] {
        // The headless emulator's changeResizableDisplay agent is a stub returning false.
        // Keep Qt loaded but its window hidden for Resizable AVDs, as Studio does when embedded.
        let window = DisplayPreset.parse(config["hw.resizable.configs"] ?? "").isEmpty ? "-no-window" : "-qt-hide-window"
        return ["-avd", avd, window, "-no-boot-anim"]
    }

    func shutdown(_ device: Device) {
        if let simulator = device.simulator {
            Task {
                do { try await Simctl.run(["shutdown", simulator.udid]).checked(); await refresh() }
                catch { failure = String(describing: error) }
            }
            return
        }
        guard let serial = device.serial else { return }
        Task { await adb("-s", serial, "emu", "kill") }
    }

    /// Saves to the Desktop and copies to the clipboard, like Simulator.
    func saveScreenshot(_ device: Device, png: Data) throws {
        let date = Date.now.formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) at \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits).\(second: .twoDigits)", timeZone: .current, calendar: .current))
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        try png.write(to: desktop.appending(path: "\(device.name.replacingOccurrences(of: "/", with: "-")) \(date).png"), options: .atomic)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)
    }

    private static func getprop(_ serial: String) async -> [String: String] {
        var props: [String: String] = [:]
        for line in await adb("-s", serial, "shell", "getprop").split(separator: "\n") {
            let kv = line.split(separator: "]: [", maxSplits: 1)
            if kv.count == 2 { props[String(kv[0].dropFirst())] = String(kv[1].dropLast()) }
        }
        return props
    }

    private static func avds() -> [Device] {
        let files = (try? FileManager.default.contentsOfDirectory(at: SDK.avdHome, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "ini" }.map { url in
            let avd = url.deletingPathExtension().lastPathComponent
            let config = ini(SDK.avdHome.appending(path: "\(avd).avd/config.ini"))
            let sysdir = config["image.sysdir.1"] ?? ""
            let imageDirectory = sysdir.hasPrefix("/") ? URL(fileURLWithPath: sysdir) : SDK.root.appending(path: sysdir)
            let imageProperties = sysdir.isEmpty ? [:] : ini(imageDirectory.appending(path: "source.properties"))
            let api = AndroidAPI.imageVersion(path: sysdir, properties: imageProperties).map { "API \($0)" } ?? ""
            return Device(id: "avd:\(avd)", name: config["avd.ini.displayname"] ?? avd.replacingOccurrences(of: "_", with: " "), detail: "Emulator", api: api, kind: DeviceKind.from(config: config), avd: avd)
        }
    }

    nonisolated static func ini(_ url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        let pairs = text.split(separator: "\n").compactMap { line -> (String, String)? in
            let kv = line.split(separator: "=", maxSplits: 1)
            return kv.count == 2 ? (kv[0].trimmingCharacters(in: .whitespaces), kv[1].trimmingCharacters(in: .whitespaces)) : nil
        }
        return Dictionary(pairs, uniquingKeysWith: { first, _ in first })
    }
}
