import Foundation

extension FoldState {
    var command: String { self == .opened ? "unfold" : "fold" }

    static func parse(_ output: String) -> FoldState? {
        // Use the committed state, not a pending request or a base state overridden by Android.
        guard let committed = output.split(whereSeparator: \.isNewline).first(where: {
            $0.contains("mCommittedState=") || $0.contains("Committed state:")
        }) else { return nil }
        let pattern = #"name=['\"]([^'\"]+)['\"]"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: String(committed), range: NSRange(committed.startIndex..., in: committed)),
              let range = Range(match.range(at: 1), in: committed) else { return nil }
        let name = committed[range].uppercased()
        if name == "CLOSED" || name == "FOLDED" { return .closed }
        if name == "OPENED" || name == "OPEN" || name == "UNFOLDED" { return .opened }
        return nil
    }
}

struct FoldConfiguration {
    let states: [FoldState]
    let resizableMode: Int?
    let closedSize: CGSize?

    static func parse(config: [String: String], hardware: [String: String] = [:]) -> FoldConfiguration? {
        guard ["yes", "true"].contains(config["hw.sensor.hinge"]?.lowercased() ?? "") else { return nil }
        let postures = (config["hw.sensor.posture_list"] ?? "").split(separator: ",").compactMap {
            Int($0.trimmingCharacters(in: .whitespaces))
        }
        let states: [FoldState] = [.opened, .closed].filter { postures.contains($0 == .opened ? 3 : 1) }
        guard !states.isEmpty else { return nil }
        let mode = DisplayPreset.parse(config["hw.resizable.configs"] ?? "").isEmpty ? nil :
            Int(hardware["hw.sensor.hinge.resizable.config"] ?? config["hw.sensor.hinge.resizable.config"] ?? "1")
        let width = Int(config["hw.displayRegion.0.1.width"] ?? "") ?? 0
        let height = Int(config["hw.displayRegion.0.1.height"] ?? "") ?? 0
        return FoldConfiguration(states: states, resizableMode: mode,
                                 closedSize: width > 0 && height > 0 ? CGSize(width: width, height: height) : nil)
    }

    func matchesClosedDisplay(_ size: CGSize) -> Bool {
        guard let closedSize else { return false }
        return size == closedSize || size == CGSize(width: closedSize.height, height: closedSize.width)
    }
}

extension DeviceActions {
    func foldConfiguration(for device: Device) -> FoldConfiguration? {
        guard let avd = device.avd, device.serial != nil else { return nil }
        let directory = SDK.avdHome.appending(path: "\(avd).avd")
        return FoldConfiguration.parse(config: Hub.ini(directory.appending(path: "config.ini")),
                                       hardware: Hub.ini(directory.appending(path: "hardware-qemu.ini")))
    }

    func foldState(serial: String) async throws -> FoldState? {
        let result = try await run(["-s", serial, "shell", "dumpsys", "device_state"])
        try result.checked()
        return FoldState.parse(result.output)
    }

    func setFoldState(_ state: FoldState, serial: String) async throws {
        try await run(["-s", serial, "emu", state.command]).checked()
        for _ in 0..<40 {
            try Task.checkCancellation()
            if try await foldState(serial: serial) == state { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw MirrorError("The emulator didn't finish changing to \(state.title).")
    }
}
