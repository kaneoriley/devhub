import Foundation

/// Binary units match sdklib's Storage values (the UI labels them MB/GB).
/// Setting keys and bounds follow AOSP's avd/AdditionalSettingsPanel.kt and
/// sdklib/internal/avd/{AvdBuilder,ConfigKey,SdCard,UserSettingsKey}.
struct EmulatorCapacity: Equatable {
    var amount: String
    var unit: Unit
    enum Unit: String, CaseIterable { case bytes = "B", kb = "KB", mb = "MB", gb = "GB", tb = "TB"
        var multiplier: Int64 { [1, 1 << 10, 1 << 20, 1 << 30, 1 << 40][Self.allCases.firstIndex(of: self)!] }
    }
    var bytes: Int64? {
        guard let value = Int64(amount), value >= 0 else { return nil }
        let result = value.multipliedReportingOverflow(by: unit.multiplier)
        return result.overflow ? nil : result.partialValue
    }
    init(_ value: Int64, _ unit: Unit) { amount = String(value); self.unit = unit }
    init(ini: String?, defaultBytes: Int64, unsuffixedUnit: Unit = .bytes) {
        let text = (ini ?? "").trimmingCharacters(in: .whitespaces)
        let digits = text.prefix(while: { $0.isNumber })
        let suffix = text.dropFirst(digits.count).uppercased()
        let unit = suffix.isEmpty ? unsuffixedUnit : ["K": Unit.kb, "M": .mb, "G": .gb, "T": .tb, "B": .bytes][suffix]
        let parsed = unit.map { EmulatorCapacity(0, $0) }
        var capacity = parsed ?? EmulatorCapacity(0, .bytes)
        capacity.amount = String(digits)
        let bytes = unit == nil ? defaultBytes : capacity.bytes ?? defaultBytes
        let displayUnit = Unit.allCases.reversed().first { bytes >= $0.multiplier && bytes % $0.multiplier == 0 } ?? .bytes
        self.init(bytes / displayUnit.multiplier, displayUnit)
    }
    var ini: String { String(bytes ?? 0) }
}

struct EmulatorConfiguration: Equatable {
    var frontCamera = "emulated", rearCamera = "virtualscene"
    var speed = "full", latency = "none", orientation = "portrait", boot = "quick"
    var storage = EmulatorCapacity(10, .gb)
    var expanded = "none", sdSize = EmulatorCapacity(512, .mb), sdPath = ""
    var cores = 4, graphics = "auto"
    var ram = EmulatorCapacity(2, .gb), heap = EmulatorCapacity(256, .mb)
    var preferredABI = ""

    static func defaults(profile: DeviceProfile, base: String) -> Self {
        let pairs = base.split(separator: "\n").compactMap { line -> (String, String)? in
            let pair = line.split(separator: "=", maxSplits: 1)
            return pair.count == 2 ? (String(pair[0]), String(pair[1])) : nil
        }
        var result = Self(config: Dictionary(pairs, uniquingKeysWith: { _, last in last }))
        result.frontCamera = profile.cameraLocations.contains("front") ? "emulated" : "none"
        result.rearCamera = profile.cameraLocations.contains("back") ? "virtualscene" : "none"
        result.graphics = "auto"
        result.storage = EmulatorCapacity(profile.kind == .watch || profile.kind == .tv ? 6 : 10, .gb)
        result.cores = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))
        result.ram = EmulatorCapacity(min(profile.ramMB, 2048), .mb)
        result.heap = EmulatorCapacity(profile.heapMB, .mb)
        return result
    }

    init(config: [String: String] = [:], user: [String: String] = [:]) {
        frontCamera = config["hw.camera.front"] ?? frontCamera
        rearCamera = config["hw.camera.back"] ?? rearCamera
        speed = config["runtime.network.speed"] ?? speed
        latency = config["runtime.network.latency"] ?? latency
        orientation = config["hw.initialOrientation"] ?? orientation
        boot = config["fastboot.forceColdBoot"] == "yes" ? "cold" : "quick"
        storage = EmulatorCapacity(ini: config["disk.dataPartition.size"], defaultBytes: 10 << 30)
        if let path = config["sdcard.path"], !path.isEmpty { expanded = "image"; sdPath = path }
        else if let size = config["sdcard.size"], !size.isEmpty { expanded = "custom"; sdSize = EmulatorCapacity(ini: size, defaultBytes: 512 << 20, unsuffixedUnit: .mb) }
        cores = Int(config["hw.cpu.ncore"] ?? "") ?? cores
        graphics = config["hw.gpu.mode"] ?? graphics
        ram = EmulatorCapacity(ini: config["hw.ramSize"], defaultBytes: 2 << 30, unsuffixedUnit: .mb)
        heap = EmulatorCapacity(ini: config["vm.heapSize"], defaultBytes: 256 << 20, unsuffixedUnit: .mb)
        preferredABI = user["abi.type.preferred"] ?? ""
    }

    func validate(compatibility: EmulatorCompatibility, original: Self? = nil) throws {
        func capacity(_ value: EmulatorCapacity, _ old: EmulatorCapacity?, min: Int64, title: String) throws {
            if value == old { return }
            guard let bytes = value.bytes, bytes >= min else { throw MirrorError("\(title) must be at least \(min / (1 << 20)) MB and fit within a 64-bit size.") }
        }
        try capacity(storage, original?.storage, min: 6 << 30, title: "Internal storage")
        try capacity(ram, original?.ram, min: 128 << 20, title: "RAM")
        try capacity(heap, original?.heap, min: 16 << 20, title: "VM heap size")
        if cores != original?.cores, !(1...compatibility.maxCores).contains(cores) { throw MirrorError("Choose a supported CPU core count.") }
        if preferredABI != original?.preferredABI, !preferredABI.isEmpty, !compatibility.abis.contains(preferredABI) {
            throw MirrorError("The preferred ABI isn't supported by this system image.")
        }
        if expanded == "custom", expanded != original?.expanded || sdSize != original?.sdSize {
            try capacity(sdSize, nil, min: 10 << 20, title: "Expanded storage")
            guard let size = sdSize.bytes, size <= 1023 << 30, size % 1024 == 0 else {
                throw MirrorError("Expanded storage must be a whole number of KB, no larger than 1023 GB.")
            }
        }
        if expanded == "image", expanded != original?.expanded || sdPath != original?.sdPath {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: sdPath, isDirectory: &directory), !directory.boolValue,
                  FileManager.default.isReadableFile(atPath: sdPath) else { throw MirrorError("Choose a readable SD card image file.") }
        }
    }

    /// Only changed fields are written when editing, retaining legacy values and unknown keys.
    func configChanges(from old: Self? = nil) -> [String: String?] {
        var result: [String: String?] = [:]
        func set<T: Equatable>(_ value: T, _ previous: T?, _ key: String, _ text: String) {
            if value != previous { result[key] = .some(text) }
        }
        set(frontCamera, old?.frontCamera, "hw.camera.front", frontCamera)
        set(rearCamera, old?.rearCamera, "hw.camera.back", rearCamera)
        set(speed, old?.speed, "runtime.network.speed", speed)
        set(latency, old?.latency, "runtime.network.latency", latency)
        set(orientation, old?.orientation, "hw.initialOrientation", orientation)
        if boot != old?.boot {
            result["fastboot.forceColdBoot"] = boot == "cold" ? "yes" : "no"
            result["fastboot.forceFastBoot"] = boot == "quick" ? "yes" : "no"
            result["fastboot.forceChosenSnapshotBoot"] = "no"
            result["fastboot.chosenSnapshotFile"] = ""
        }
        set(storage, old?.storage, "disk.dataPartition.size", storage.ini)
        set(cores, old?.cores, "hw.cpu.ncore", String(cores))
        if graphics != old?.graphics { result["hw.gpu.enabled"] = "yes"; result["hw.gpu.mode"] = graphics }
        set(ram, old?.ram, "hw.ramSize", String((ram.bytes ?? 0) / (1 << 20)))
        set(heap, old?.heap, "vm.heapSize", String((heap.bytes ?? 0) / (1 << 20)))
        if expanded != old?.expanded || (expanded == "custom" && sdSize != old?.sdSize) || (expanded == "image" && sdPath != old?.sdPath) {
            result["hw.sdCard"] = expanded == "none" ? "no" : "yes"
            result["sdcard.size"] = .some(expanded == "custom" ? "\((sdSize.bytes ?? 0) / 1024)K" : nil)
            result["sdcard.path"] = .some(expanded == "image" ? sdPath : nil)
        }
        return result
    }
}

struct EmulatorCompatibility {
    var frontCamera: Bool
    var rearCamera: Bool
    var orientations: [String]
    var expandedStorage: Bool
    var abis: [String]
    var maxCores = max(1, ProcessInfo.processInfo.activeProcessorCount / 2)

    init(profile: DeviceProfile?, config: [String: String], imageDirectory: URL?) {
        frontCamera = profile?.cameraLocations.contains("front") ?? (config["hw.camera.front"] != nil)
        rearCamera = profile?.cameraLocations.contains("back") ?? (config["hw.camera.back"] != nil)
        orientations = profile?.orientations ?? ["portrait", "landscape"]
        expandedStorage = profile?.kind != .watch && !((config["tag.id"] ?? "").contains("wear"))
        abis = []
        if let directory = imageDirectory, let doc = try? XMLDocument(contentsOf: directory.appending(path: "package.xml")) {
            for name in ["abi", "abis", "translatedAbi", "translatedAbis"] {
                for node in (try? doc.nodes(forXPath: "//*[local-name()='type-details']/*[local-name()='\(name)']")) ?? [] {
                    for abi in (node.stringValue ?? "").split(whereSeparator: { $0.isWhitespace || $0 == "," }) {
                        if !abis.contains(String(abi)) { abis.append(String(abi)) }
                    }
                }
            }
        }
        if abis.isEmpty, let abi = config["abi.type"] { abis = [abi] }
    }
}

/// Edits known INI keys without discarding comments or unrelated settings.
enum EmulatorINI {
    static func updating(_ text: String, with changes: [String: String?]) -> String {
        var remaining = changes
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = parts.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if parts.count == 2, let replacement = changes[key] {
                if remaining.keys.contains(key), let replacement { lines.append("\(key)=\(replacement)") }
                remaining.removeValue(forKey: key)
            } else { lines.append(line) }
        }
        while lines.last == "" { lines.removeLast() }
        for key in remaining.keys.sorted() { if let value = remaining[key] ?? nil { lines.append("\(key)=\(value)") } }
        return lines.joined(separator: "\n") + "\n"
    }
}

struct EmulatorConfigurationFile {
    let directory: URL
    let configText: String
    let userText: String?
    let config: [String: String]
    let original: EmulatorConfiguration

    init(directory: URL) throws {
        self.directory = directory
        configText = try String(contentsOf: directory.appending(path: "config.ini"), encoding: .utf8)
        userText = try? String(contentsOf: directory.appending(path: "user-settings.ini"), encoding: .utf8)
        config = Hub.ini(directory.appending(path: "config.ini"))
        original = EmulatorConfiguration(config: config, user: Hub.ini(directory.appending(path: "user-settings.ini")))
    }
    var imageDirectory: URL? {
        guard let path = config["image.sysdir.1"], !path.isEmpty else { return nil }
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : SDK.root.appending(path: path)
    }
    func replacesCard(_ value: EmulatorConfiguration) -> Bool {
        value.expanded == "custom" && FileManager.default.fileExists(atPath: directory.appending(path: "sdcard.img").path)
            && cardNeedsCreation(value)
    }
    func cardNeedsCreation(_ value: EmulatorConfiguration) -> Bool {
        guard value.expanded == "custom", let bytes = value.sdSize.bytes else { return false }
        let size = (try? directory.appending(path: "sdcard.img").resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        return size.map { Int64($0) != bytes } ?? true
    }

    func save(_ value: EmulatorConfiguration, compatibility: EmulatorCompatibility, isRunning: () -> Bool,
              createCard: (String, URL) async throws -> Void = Self.createCard) async throws {
        try value.validate(compatibility: compatibility, original: original)
        func check() throws {
            guard !isRunning() else { throw MirrorError("Shut down the emulator before saving its configuration.") }
            guard (try? String(contentsOf: directory.appending(path: "config.ini"), encoding: .utf8)) == configText,
                  (try? String(contentsOf: directory.appending(path: "user-settings.ini"), encoding: .utf8)) == userText else {
                throw MirrorError("The configuration changed elsewhere. Close this dialog and open it again.")
            }
        }
        try check()
        let fm = FileManager.default
        let temporary = directory.appending(path: ".droidhub-\(UUID().uuidString)")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
        var retainBackup = false
        defer { if !retainBackup { try? fm.removeItem(at: temporary) } }
        let card = temporary.appending(path: "sdcard.img")
        if cardNeedsCreation(value) { try await createCard(value.sdSize.ini, card) }
        try check()
        let configChanges = value.configChanges(from: original)
        let newConfig = EmulatorINI.updating(configText, with: configChanges)
        let newUser = EmulatorINI.updating(userText ?? "", with: ["abi.type.preferred": value.preferredABI.isEmpty ? nil : value.preferredABI])
        var files: [(String, Data)] = []
        if !configChanges.isEmpty { files.append(("config.ini", Data(newConfig.utf8))) }
        if value.preferredABI != original.preferredABI { files.append(("user-settings.ini", Data(newUser.utf8))) }
        // Back up only the small INI files; move the potentially large card instead.
        var written: [String] = [], cardMoved = false, cardInstalled = false
        let destination = directory.appending(path: "sdcard.img"), backup = temporary.appending(path: "previous-sdcard.img")
        do {
            if fm.fileExists(atPath: card.path) {
                if fm.fileExists(atPath: destination.path) { try fm.moveItem(at: destination, to: backup); cardMoved = true }
                try fm.moveItem(at: card, to: destination); cardInstalled = true
            }
            for (name, data) in files {
                let url = directory.appending(path: name)
                if fm.fileExists(atPath: url.path) { try fm.copyItem(at: url, to: temporary.appending(path: name)) }
                try data.write(to: url, options: .atomic)
                written.append(name)
            }
        } catch {
            for name in written.reversed() {
                let url = directory.appending(path: name), old = temporary.appending(path: name)
                do {
                    if fm.fileExists(atPath: old.path) { try Data(contentsOf: old).write(to: url, options: .atomic) }
                    else { try fm.removeItem(at: url) }
                } catch { retainBackup = true }
            }
            do {
                if cardInstalled { try fm.removeItem(at: destination) }
                if cardMoved { try fm.moveItem(at: backup, to: destination) }
            } catch { retainBackup = true }
            if retainBackup { throw MirrorError("Couldn't save or fully restore the configuration. Recovery files are in \(temporary.path). \(error)") }
            throw error
        }
    }

    static func createCard(_ bytes: String, at path: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async {
                let process = Process(), output = Pipe()
                process.executableURL = SDK.root.appending(path: "emulator/mksdcard")
                // mksdcard accepts K/M/G suffixes; validation guarantees whole KB.
                process.arguments = ["\((Int64(bytes) ?? 0) / 1024)K", path.path]
                process.standardOutput = output; process.standardError = output
                do {
                    try process.run()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else { throw MirrorError("Couldn't create the SD card: \(String(decoding: data, as: UTF8.self))") }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
