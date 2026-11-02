import Foundation

/// Unlike the polling helpers, user actions need exit status and stderr to report failures.
struct ADBResult {
    let status: Int32
    let output: String

    func checked() throws {
        // The emulator console can report KO even when adb itself exits successfully.
        let rejected = output.split(whereSeparator: \.isNewline).contains {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("KO")
        }
        guard status == 0, !rejected else {
            throw MirrorError(output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              ? "ADB failed (exit \(status))." : output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

func runADB(_ args: [String]) async throws -> ADBResult {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: SDK.adb)
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: ADBResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self)))
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

enum FormFactor: Int, CaseIterable {
    case phone = 0, foldable = 1, tablet = 2

    static let controlOrder: [FormFactor] = [.phone, .foldable, .tablet]

    var title: String {
        switch self {
        case .phone: "Phone"
        case .tablet: "Tablet"
        case .foldable: "Foldable"
        }
    }

}

struct DisplayPreset: Identifiable, Equatable {
    let factor: FormFactor
    let width: Int
    let height: Int
    let density: Int
    var id: Int { factor.rawValue }

    func matches(_ size: CGSize) -> Bool {
        (size.width == CGFloat(width) && size.height == CGFloat(height)) ||
        (size.width == CGFloat(height) && size.height == CGFloat(width))
    }

    /// Same AVD definition used by Studio's EmulatorConfiguration.parseDisplayModes.
    /// Names vary ("foldable" / "unfolded"); the numeric IDs define the modes.
    static func parse(_ config: String) -> [DisplayPreset] {
        var presets: [DisplayPreset] = []
        for entry in config.split(separator: ",") {
            let parts = entry.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "-")
            guard parts.count == 5, let id = Int(parts[1]), let factor = FormFactor(rawValue: id),
                  let width = Int(parts[2]), width > 0, let height = Int(parts[3]), height > 0,
                  let density = Int(parts[4]), density > 0, !presets.contains(where: { $0.id == id }) else { continue }
            presets.append(DisplayPreset(factor: factor, width: width, height: height, density: density))
        }
        return FormFactor.controlOrder.compactMap { factor in presets.first { $0.factor == factor } }
    }

    static func available(config: String, console: String) -> [DisplayPreset] {
        // Querying resize-display returns usage prefixed with KO. That is expected here.
        guard console.contains("resize-display") else { return [] }
        let pattern = #"\b(\d+):\s*(?:phone|unfolded|foldable|tablet)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ids = regex.matches(in: console, range: NSRange(console.startIndex..., in: console)).compactMap { match -> Int? in
            guard let range = Range(match.range(at: 1), in: console) else { return nil }
            return Int(console[range])
        }
        return parse(config).filter { ids.contains($0.id) }
    }
}

struct DisplayState {
    let size: CGSize
    let density: Int

    func matches(_ preset: DisplayPreset) -> Bool { preset.matches(size) && density == preset.density }

    static func parse(size: String, density: String) -> DisplayState? {
        let dimensions = size.split(whereSeparator: \.isNewline).last?.split(separator: ":").last?
            .trimmingCharacters(in: .whitespaces).split(separator: "x").compactMap { Int($0) } ?? []
        guard dimensions.count == 2, dimensions.allSatisfy({ $0 > 0 }),
              let dpi = Mirror.density(from: density), dpi > 0 else { return nil }
        return DisplayState(size: CGSize(width: dimensions[0], height: dimensions[1]), density: Int(dpi))
    }
}

struct DeviceActions {
    var run: ([String]) async throws -> ADBResult = runADB
    var console: (String, String) async throws -> String = { try await emulatorConsole(serial: $0, command: $1) }
    var pause: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    func displayPresets(for device: Device) async -> [DisplayPreset] {
        guard let avd = device.avd, let serial = device.serial else { return [] }
        let config = Hub.ini(SDK.avdHome.appending(path: "\(avd).avd/config.ini"))["hw.resizable.configs"] ?? ""
        guard !DisplayPreset.parse(config).isEmpty,
              let response = try? await run(["-s", serial, "emu", "resize-display"]) else { return [] }
        return DisplayPreset.available(config: config, console: response.output)
    }

    func resize(_ preset: DisplayPreset, serial: String) async throws {
        let result = try await run(["-s", serial, "emu", "resize-display", String(preset.id)])
        if result.output.contains("Failed to resize display") {
            throw MirrorError("The emulator couldn't change form factor. If it was started headless, shut it down and boot it again in DroidHub to enable resizing.\n\n\(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        try result.checked()
        // Google's ToolWindow::startSleepTimer keeps the transition flag set for two
        // seconds even when wm size/density have already changed. Do not submit another
        // request or write density overrides while that native transition is active.
        try await pause(.milliseconds(2250))
        for _ in 0..<40 {
            try Task.checkCancellation()
            let state = try await displayState(serial: serial)
            if preset.matches(state.size) {
                // Also repairs a restored snapshot with this mode's size but another mode's
                // density. Native presetSizeAdvance is a no-op when its mode is already active.
                if state.density != preset.density {
                    try await run(["-s", serial, "shell", "wm", "density", String(preset.density)]).checked()
                } else {
                    return
                }
            }
            try await pause(.milliseconds(250))
        }
        throw MirrorError("The emulator didn't finish changing to \(preset.factor.title). Try again after it finishes starting up.")
    }

    func displayState(serial: String) async throws -> DisplayState {
        let size = try await run(["-s", serial, "shell", "wm", "size"])
        try size.checked()
        let density = try await run(["-s", serial, "shell", "wm", "density"])
        try density.checked()
        guard let state = DisplayState.parse(size: size.output, density: density.output) else {
            throw MirrorError("Couldn't read the device's display size and density.")
        }
        return state
    }

    func synchronizeDisplay(presets: [DisplayPreset], serial: String, preferredDensity: (DisplayState) -> Int? = { _ in nil }) async throws -> DisplayState {
        let state = try await displayState(serial: serial)
        if preferredDensity(state) == state.density { return state }
        if let preset = presets.first(where: { $0.matches(state.size) }), state.density != preset.density {
            // Quick Boot can restore guest density from a different form factor. Use the
            // active resolution's AVD density, just as Google's mode-change code does.
            try await run(["-s", serial, "shell", "wm", "density", String(preset.density)]).checked()
            return try await displayState(serial: serial)
        }
        return state
    }

    /// Studio treats multiple APKs as one app's base + splits, and other files as Downloads.
    @MainActor
    func transfer(_ files: [URL], serial: String, progress: (String) -> Void) async throws -> String {
        guard !files.isEmpty else { throw MirrorError("Drop one or more files.") }
        let scoped = files.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        for file in files {
            guard file.isFileURL, (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
                throw MirrorError("\(file.lastPathComponent) isn't a regular file. Drop files, not folders.")
            }
            guard FileManager.default.isReadableFile(atPath: file.path) else {
                throw MirrorError("\(file.lastPathComponent) isn't readable.")
            }
        }
        let apks = files.filter { $0.pathExtension.lowercased() == "apk" }
        guard apks.isEmpty || apks.count == files.count else {
            throw MirrorError("Drop APKs to install an app, or other files to copy to Downloads, in separate drops.")
        }
        if !apks.isEmpty {
            let name = files.count == 1 ? files[0].lastPathComponent : "app from \(files.count) APKs"
            progress("Installing \(name)…")
            let command = files.count == 1 ? "install" : "install-multiple"
            try await run(["-s", serial, command, "-r", "-t", "--user", "current", "--full"] + files.map(\.path)).checked()
            return "Installed \(name)"
        }
        try await run(["-s", serial, "shell", "mkdir", "-p", "/sdcard/Download"]).checked()
        var copied = 0
        do {
            for file in files {
                progress("Copying \(file.lastPathComponent) (\(copied + 1)/\(files.count))…")
                // adb push uses the sync protocol. Keep filenames as arguments, never shell text.
                try await run(["-s", serial, "push", file.path, "/sdcard/Download/\(file.lastPathComponent)"]).checked()
                copied += 1
            }
        } catch {
            throw MirrorError("\(copied) of \(files.count) files copied.\n\(error)")
        }
        return files.count == 1 ? "Copied \(files[0].lastPathComponent) to Downloads" : "Copied \(files.count) files to Downloads"
    }
}
