import Foundation
import Observation

/// Clockwise device rotation, independent of Android's app rotation and orientation lock.
struct QuarterTurn: Equatable {
    let value: Int
    init(_ value: Int) { self.value = (value % 4 + 4) % 4 }
    static let zero = QuarterTurn(0)
    var next: QuarterTurn { QuarterTurn(value + 1) }
    var radians: Double { Double(value) * .pi / 2 }
    var exifOrientation: Int32 { [1, 6, 3, 8][value] }

    func size(_ size: CGSize) -> CGSize { value % 2 == 0 ? size : CGSize(width: size.height, height: size.width) }

    func sourcePoint(_ point: CGPoint) -> CGPoint {
        switch value {
        case 1: CGPoint(x: point.y, y: 1 - point.x)
        case 2: CGPoint(x: 1 - point.x, y: 1 - point.y)
        case 3: CGPoint(x: 1 - point.y, y: point.x)
        default: point
        }
    }

    func sourceVector(_ vector: CGPoint) -> CGPoint {
        switch value {
        case 1: CGPoint(x: vector.y, y: -vector.x)
        case 2: CGPoint(x: -vector.x, y: -vector.y)
        case 3: CGPoint(x: -vector.y, y: vector.x)
        default: vector
        }
    }

    static func acceleration(_ output: String) -> QuarterTurn? {
        guard let line = output.split(whereSeparator: \.isNewline).first(where: { $0.contains("acceleration =") }),
              let values = line.split(separator: "=").last else { return nil }
        let numbers = values.trimmingCharacters(in: .whitespaces).split(separator: ":").compactMap { Double($0) }
        guard numbers.count == 3, max(abs(numbers[0]), abs(numbers[1])) > 1 else { return nil }
        if abs(numbers[0]) > abs(numbers[1]) { return QuarterTurn(numbers[0] < 0 ? 1 : 3) }
        return QuarterTurn(numbers[1] < 0 ? 2 : 0)
    }
}

/// The standard console retains command output that recent `adb emu` versions discard.
/// Keep the local auth token on this connection; never include it in diagnostics.
func emulatorConsole(serial: String, command: String) async throws -> String {
    guard serial.hasPrefix("emulator-"), let port = UInt16(serial.dropFirst(9)),
          !command.contains("\n"), !command.contains("\r") else { throw MirrorError("Invalid emulator console command.") }
    return try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
            do {
                let socket = try Socket.connect(port: port, timeout: 3)
                defer { socket.shutdown() }
                func response() throws -> String {
                    var data = Data()
                    while data.count < 65_536 {
                        guard let byte = socket.read(1), !byte.isEmpty else { throw MirrorError("The emulator console stopped responding.") }
                        data.append(byte)
                        if byte[0] == 10 {
                            let text = String(decoding: data, as: UTF8.self)
                            if text.hasSuffix("OK\r\n") || text.split(whereSeparator: \.isNewline).last?.hasPrefix("KO") == true { return text }
                        }
                    }
                    throw MirrorError("The emulator console response was too large.")
                }
                let greeting = try response()
                if greeting.contains("Authentication required") {
                    let tokenURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".emulator_console_auth_token")
                    let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !token.contains("\n"), !token.contains("\r") else { throw MirrorError("Invalid emulator console authentication.") }
                    socket.write(Data("auth \(token)\n".utf8))
                    guard !(try response()).contains("KO:") else { throw MirrorError("Emulator console authentication failed.") }
                }
                socket.write(Data((command + "\n").utf8))
                let result = try response()
                try ADBResult(status: 0, output: result).checked()
                continuation.resume(returning: result)
            } catch { continuation.resume(throwing: error) }
        }
    }
}

extension DeviceActions {
    func emulatorOrientation(serial: String) async throws -> QuarterTurn {
        guard let value = QuarterTurn.acceleration(try await console(serial, "sensor get acceleration")) else {
            throw MirrorError("Couldn't read the emulator's physical orientation.")
        }
        return value
    }

    func orientEmulator(_ target: QuarterTurn, serial: String) async throws {
        // Use the emulator's real physical model, as Studio does, rather than changing
        // Android's auto-rotate settings or leaving a sensor-value override behind.
        for _ in 0..<8 {
            let current = try await emulatorOrientation(serial: serial)
            if current == target { return }
            _ = try await console(serial, "rotate")
            try await pause(.milliseconds(200))
        }
        throw MirrorError("The emulator didn't finish rotating.")
    }
}

/// One command worker per connected device. New selections replace pending selections;
/// an in-flight emulator transition is allowed to finish before the next command starts.
@Observable @MainActor final class DisplayController {
    var selectedPreset: Int?
    private(set) var orientation = QuarterTurn.zero
    private(set) var isChangingPreset = false
    private(set) var isBusy = false
    private(set) var revision = 0
    var failure: String?
    private let serial: String
    private let isEmulator: Bool
    private let actions: DeviceActions
    private var pendingPreset: DisplayPreset?
    private var pendingOrientation: QuarterTurn?
    private var worker: Task<Void, Never>?
    private var initialized = false
    private var lastPhysicalOrientation: QuarterTurn?

    init(serial: String, isEmulator: Bool, actions: DeviceActions = DeviceActions()) {
        self.serial = serial; self.isEmulator = isEmulator; self.actions = actions
    }

    func synchronizeOrientation() async {
        guard isEmulator, !isBusy else { return }
        if let physical = try? await actions.emulatorOrientation(serial: serial), !isBusy {
            if !initialized || physical != lastPhysicalOrientation { orientation = physical }
            lastPhysicalOrientation = physical
            initialized = true
        }
    }

    func select(_ preset: DisplayPreset) {
        pendingPreset = preset
        pendingOrientation = nil
        failure = nil
        startWorker()
    }

    func rotate() {
        if !isEmulator {
            // Preserve normal phone mirroring and request the other Android orientation.
            Task {
                do {
                    try await actions.run(["-s", serial, "shell", "r=$(dumpsys input | grep -m1 -oE 'orientation=[0-9]' | cut -d= -f2); settings put system accelerometer_rotation 0; settings put system user_rotation $(( (${r:-0} & 1) ^ 1 ))"]).checked()
                } catch { failure = String(describing: error) }
            }
            return
        }
        pendingOrientation = (pendingOrientation ?? (pendingPreset == nil ? orientation : .zero)).next
        failure = nil
        startWorker()
    }

    func waitUntilIdle() async { await worker?.value }

    private func startWorker() {
        guard worker == nil else { return }
        isBusy = true
        worker = Task { @MainActor in
            defer { worker = nil; isBusy = false; isChangingPreset = false }
            while pendingPreset != nil || pendingOrientation != nil {
                do {
                    if let preset = pendingPreset {
                        pendingPreset = nil
                        isChangingPreset = true
                        // Reset before changing the display geometry so a landscape preset
                        // doesn't first appear on its side and then rotate again later.
                        if isEmulator { try await actions.orientEmulator(.zero, serial: serial) }
                        orientation = .zero
                        lastPhysicalOrientation = .zero
                        if selectedPreset != preset.id {
                            if try await actions.foldState(serial: serial) == .closed {
                                try await actions.setFoldState(.opened, serial: serial)
                                try await actions.pause(.milliseconds(2250))
                            }
                            try await actions.resize(preset, serial: serial)
                        }
                        // Each preset's configured dimensions already define its native
                        // orientation: phone portrait, tablet/foldable landscape.
                        selectedPreset = preset.id
                        isChangingPreset = false
                        revision += 1
                    } else if let target = pendingOrientation {
                        pendingOrientation = nil
                        orientation = target
                        if isEmulator { try await actions.orientEmulator(target, serial: serial) }
                        lastPhysicalOrientation = target
                    }
                } catch {
                    // A superseded request must not discard a newer queued selection.
                    if pendingPreset == nil && pendingOrientation == nil { failure = String(describing: error) }
                }
            }
        }
    }
}
