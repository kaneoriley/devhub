import Foundation

extension Hub {
    func androidDevices() async -> [Device] {
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
        return list
    }

    func bootEmulator(_ device: Device) {
        guard let avd = device.avd, !booting.contains(device.id), !configuring.contains(device.id) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: SDK.emulator)
        let config = Self.ini(SDK.avdDirectory(avd).appending(path: "config.ini"))
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

    func shutdownAndroid(_ device: Device) {
        guard let serial = device.serial else { return }
        Task { await adb("-s", serial, "emu", "kill") }
    }

    func deleteEmulator(_ avd: String) throws {
        guard !AVD.isRunning(avd) else { throw MirrorError("Shut down the emulator before deleting it.") }
        try AVD.delete(avd)
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
            let config = ini(SDK.avdDirectory(avd).appending(path: "config.ini"))
            let model = config["hw.device.name"] ?? ""
            let modelName = DeviceProfile.modelName(for: model) ?? model.replacingOccurrences(of: "_", with: " ")
            let sysdir = config["image.sysdir.1"] ?? ""
            let imageDirectory = sysdir.hasPrefix("/") ? URL(fileURLWithPath: sysdir) : SDK.root.appending(path: sysdir)
            let imageProperties = sysdir.isEmpty ? [:] : ini(imageDirectory.appending(path: "source.properties"))
            let api = AndroidAPI.imageVersion(path: sysdir, properties: imageProperties).map { "API \($0)" } ?? ""
            return Device(id: "avd:\(avd)", name: config["avd.ini.displayname"] ?? avd.replacingOccurrences(of: "_", with: " "), detail: "Emulator", model: model, modelName: modelName, api: api, kind: DeviceKind.from(config: config), avd: avd,
                          hasSystemImage: !sysdir.isEmpty && FileManager.default.fileExists(atPath: imageDirectory.path))
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
