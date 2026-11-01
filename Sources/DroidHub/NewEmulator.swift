import SwiftUI

/// A hardware profile from Google's bundled Android device catalog.
struct DeviceProfile: Identifiable, Hashable {
    let id: String
    let name: String
    let manufacturer: String
    let width: Int
    let height: Int
    let density: Int
    let skin: String?
    let playStore: Bool
    let landscape: Bool
    let hardware: [String: String]

    static func load() async -> [DeviceProfile] {
        var profiles: [DeviceProfile] = []
        for file in ["nexus", "devices"] {
            guard let url = Bundle.module.url(forResource: file, withExtension: "xml"),
                  let doc = try? XMLDocument(contentsOf: url) else { continue }
            let parsed = ((try? doc.nodes(forXPath: "//*[local-name()='device']")) ?? []).compactMap(DeviceProfile.init)
            profiles += file == "nexus" ? parsed.reversed() : parsed  // newest Pixels first
        }
        var seen = Set<String>()
        return profiles.filter { seen.insert($0.id).inserted }
    }

    init?(_ node: XMLNode) {
        func value(_ name: String) -> String? {
            (try? node.nodes(forXPath: ".//*[local-name()='\(name)']"))?.first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let id = value("id"), let name = value("name"),
              let width = value("x-dimension").flatMap({ Int($0) }), let height = value("y-dimension").flatMap({ Int($0) }),
              let density = value("pixel-density").flatMap(Self.dpi)
        else { return nil }
        self.id = id
        self.name = name
        self.width = width
        self.height = height
        self.density = density
        manufacturer = value("manufacturer") ?? "Generic"
        skin = value("skin")
        playStore = value("playstore-enabled") == "true"
        let orientation = try? node.nodes(forXPath: "./*[local-name()='state'][@default='true']/*[local-name()='screen-orientation']")
        landscape = orientation?.first?.stringValue == "land"
        var hardware: [String: String] = [:]
        if let hinge = (try? node.nodes(forXPath: ".//*[local-name()='hinge']"))?.first {
            hardware["hw.sensor.hinge"] = "yes"
            for (xml, key) in [("count", "hw.sensor.hinge.count"), ("type", "hw.sensor.hinge.type"),
                               ("sub-type", "hw.sensor.hinge.sub_type"), ("ranges", "hw.sensor.hinge.ranges"),
                               ("defaults", "hw.sensor.hinge.defaults"), ("areas", "hw.sensor.hinge.areas"),
                               ("posture-list", "hw.sensor.posture_list"), ("hinge-angles-posture-definitions", "hw.sensor.hinge_angles_posture_definitions")] {
                if let value = (try? hinge.nodes(forXPath: "./*[local-name()='\(xml)']"))?.first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    hardware[key] = value
                }
            }
        }
        for (xml, key) in [("x-folded-offset", "xOffset"), ("y-folded-offset", "yOffset"),
                           ("x-folded-dimension", "width"), ("y-folded-dimension", "height")] {
            if let value = value(xml) { hardware["hw.displayRegion.0.1.\(key)"] = value }
        }
        if id == "resizable" {
            hardware["hw.resizable.configs"] = "phone-0-1080-2400-420, foldable-1-2208-1840-420, tablet-2-1920-1200-240, desktop-3-1920-1080-160"
        }
        self.hardware = hardware
    }

    /// "420dpi" or a bucket name like "xxhdpi".
    static func dpi(_ value: String) -> Int? {
        if value.hasSuffix("dpi"), let n = Int(value.dropLast(3)) { return n }
        return ["ldpi": 120, "mdpi": 160, "tvdpi": 213, "hdpi": 240, "xhdpi": 320, "xxhdpi": 480, "xxxhdpi": 640][value]
    }
}

struct SystemImage: Identifiable, Hashable {
    /// Path relative to the SDK, as config.ini wants it.
    let id: String
    let target: String
    let api: String
    let abi: String
    let tagIDs: String
    let tagDisplays: String

    var title: String { "API \(api) · \(tagDisplays.split(separator: ",").first ?? "") · \(abi)" }

    static func installed() -> [SystemImage] {
        let fm = FileManager.default
        let root = SDK.root.appending(path: "system-images")
        func children(_ path: String) -> [String] { (try? fm.contentsOfDirectory(atPath: root.appending(path: path).path)) ?? [] }
        var images: [SystemImage] = []
        for target in children("") {
            for tag in children(target) {
                for abi in children("\(target)/\(tag)") {
                    let props = Hub.ini(root.appending(path: "\(target)/\(tag)/\(abi)/source.properties"))
                    guard let api = props["AndroidVersion.ApiLevel"] else { continue }
                    images.append(SystemImage(id: "system-images/\(target)/\(tag)/\(abi)/", target: target, api: api, abi: abi,
                                              tagIDs: props["SystemImage.TagId"] ?? tag, tagDisplays: props["SystemImage.TagDisplay"] ?? tag))
                }
            }
        }
        return images.sorted { $0.api.localizedStandardCompare($1.api) == .orderedDescending }
    }
}

/// Creates and deletes AVDs by writing the same two files avdmanager does, so the
/// SDK's cmdline-tools aren't needed. The emulator builds the disk images on first boot.
enum AVD {
    static func id(for name: String) -> String {
        String(name.unicodeScalars.map { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) ? Character($0) : "_" })
    }

    static func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: SDK.avdHome.appending(path: "\(id(for: name)).ini").path)
    }

    static func config(name: String, device: DeviceProfile, image: SystemImage, skinPath: String?) -> String {
        let arch = image.abi.hasPrefix("arm64") ? "arm64" : image.abi.hasPrefix("x86_64") ? "x86_64" : image.abi
        var entries: [(String, String)] = [
            ("AvdId", id(for: name)), ("avd.ini.displayname", name), ("avd.ini.encoding", "UTF-8"),
            ("PlayStore.enabled", String(device.playStore && image.tagIDs.contains("playstore"))),
            ("abi.type", image.abi), ("disk.dataPartition.size", "6G"),
            ("fastboot.forceColdBoot", "no"), ("fastboot.forceFastBoot", "yes"),
            ("hw.accelerometer", "yes"), ("hw.audioInput", "yes"), ("hw.battery", "yes"),
            ("hw.camera.back", "virtualscene"), ("hw.camera.front", "emulated"),
            ("hw.cpu.arch", arch), ("hw.cpu.ncore", "4"), ("hw.dPad", "no"),
            ("hw.device.manufacturer", device.manufacturer), ("hw.device.name", device.id),
            ("hw.gps", "yes"), ("hw.gpu.enabled", "yes"), ("hw.gpu.mode", "host"), ("hw.gyroscope", "yes"),
            ("hw.initialOrientation", device.landscape ? "landscape" : "portrait"), ("hw.keyboard", "yes"),
            ("hw.lcd.density", "\(device.density)"), ("hw.lcd.height", "\(device.height)"), ("hw.lcd.width", "\(device.width)"),
            ("hw.mainKeys", "no"), ("hw.ramSize", "4096"), ("hw.sdCard", "no"),
            ("hw.sensors.light", "yes"), ("hw.sensors.magnetic_field", "yes"), ("hw.sensors.orientation", "yes"),
            ("hw.sensors.pressure", "yes"), ("hw.sensors.proximity", "yes"), ("hw.trackBall", "no"),
            ("image.sysdir.1", image.id), ("runtime.network.latency", "none"), ("runtime.network.speed", "full"),
            ("tag.display", String(image.tagDisplays.split(separator: ",").first ?? "")), ("tag.displaynames", image.tagDisplays),
            ("tag.id", String(image.tagIDs.split(separator: ",").first ?? "")), ("tag.ids", image.tagIDs), ("target", image.target),
        ]
        if let skin = device.skin, let skinPath {
            entries += [("showDeviceFrame", "yes"), ("skin.dynamic", "yes"), ("skin.name", skin), ("skin.path", skinPath)]
        } else {
            entries += [("showDeviceFrame", "no"), ("skin.name", "\(device.width)x\(device.height)")]
        }
        entries += device.hardware.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        return entries.map { "\($0)=\($1)\n" }.joined()
    }

    /// Returns the new AVD's id.
    static func create(name: String, device: DeviceProfile, image: SystemImage) throws -> String {
        let id = id(for: name)
        let dir = SDK.avdHome.appending(path: "\(id).avd")
        guard !exists(name) else { throw MirrorError("There's already an emulator called \(id)") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let skin = device.skin.map { SDK.root.appending(path: "skins/\($0)").path }.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        try config(name: name, device: device, image: image, skinPath: skin).write(to: dir.appending(path: "config.ini"), atomically: true, encoding: .utf8)
        try "avd.ini.encoding=UTF-8\npath=\(dir.path)\npath.rel=avd/\(id).avd\ntarget=\(image.target)\n"
            .write(to: SDK.avdHome.appending(path: "\(id).ini"), atomically: true, encoding: .utf8)
        return id
    }

    /// Removes whichever of the two files exist, so a half-deleted AVD can still go away.
    static func delete(_ id: String) throws {
        for url in [SDK.avdHome.appending(path: "\(id).ini"), SDK.avdHome.appending(path: "\(id).avd")]
        where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// True while an emulator process has this AVD open, including ones started outside DroidHub.
    static func isRunning(_ id: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", "--", "-avd \(id)( |$)"]
        p.standardOutput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

struct NewEmulatorSheet: View {
    @Environment(Hub.self) private var hub
    @Environment(\.dismiss) private var dismiss
    @State private var devices: [DeviceProfile] = []
    @State private var images = SystemImage.installed()
    @State private var device: DeviceProfile?
    @State private var image: SystemImage?
    @State private var name = ""
    @State private var loaded = false
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name)
                    Picker("Device", selection: $device) {
                        ForEach(devices) { Text($0.name).tag(Optional($0)) }
                    }
                    Picker("System Image", selection: $image) {
                        ForEach(images) { Text($0.title).tag(Optional($0)) }
                    }
                } footer: {
                    if loaded && devices.isEmpty {
                        Text("The bundled device catalog couldn't be loaded. Reinstall DroidHub.")
                    } else if images.isEmpty {
                        Text("No Android system images installed. Add one with sdkmanager or Android Studio's SDK Manager.")
                    } else if let failure {
                        Text(failure).foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(device == nil || image == nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 460)
        .task {
            devices = await DeviceProfile.load()
            image = images.first
            // Android Studio's default too; the newest Pixel in the list is a foldable.
            device = devices.first { $0.id == "medium_phone" } ?? devices.first
            loaded = true
        }
        .onChange(of: device) { old, new in
            // Follow the device name until the user types their own.
            if let new, name.isEmpty || name == old.map(uniqueName) { name = uniqueName(new) }
        }
    }

    /// "Pixel 10", or "Pixel 10 (2)" when that one exists.
    private func uniqueName(_ device: DeviceProfile) -> String {
        var candidate = device.name
        var n = 2
        while AVD.exists(candidate) {
            candidate = "\(device.name) (\(n))"
            n += 1
        }
        return candidate
    }

    private func create() {
        guard let device, let image else { return }
        do {
            let id = try AVD.create(name: name.trimmingCharacters(in: .whitespaces), device: device, image: image)
            Task {
                await hub.refresh()
                hub.selection = "avd:\(id)"
            }
            dismiss()
        } catch {
            failure = "\(error)"
        }
    }
}
