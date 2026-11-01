import AppKit
import Observation

/// Keep the scrcpy transport and its H.264 reference frames when changing selection.
/// The shared cache bounds the number of retained servers and hardware decoders.
@Observable @MainActor final class AndroidMirrorSession: DeviceSession {
    let mirror: Mirror
    private(set) var size = CGSize(width: 1080, height: 2400)
    private(set) var isConnected = false
    private(set) var failure: String?
    var geometry: DisplayGeometry?
    var canReuse: Bool { !closed }
    private var closed = false
    private var receivedFrame = false
    private var connection: Task<Void, Error>?

    init(serial: String) {
        mirror = Mirror(serial: serial)
        mirror.onSize = { [weak self] size in
            guard let self else { return }
            if self.size != size { self.geometry = nil }
            self.size = size
            self.receivedFrame = true
            self.isConnected = true
            Task { await self.mirror.refreshDensity() }
        }
        mirror.onClose = { [weak self] in
            self?.failure = "Disconnected"
            self?.stop()
        }
    }

    func start() async throws {
        guard !closed else { throw MirrorError(failure ?? "Disconnected") }
        if let connection { try await connection.value; return }
        let task = Task { @MainActor in
            do {
                try await mirror.start()
                guard !closed else { throw CancellationError() }
                isConnected = receivedFrame
            } catch {
                stop()
                throw error
            }
        }
        connection = task
        try await task.value
    }

    func activate() { mirror.clipboardEnabled = true }
    func deactivate() { mirror.clipboardEnabled = false }
    func stop() {
        closed = true; isConnected = false
        connection?.cancel(); connection = nil
        mirror.stop()
    }
}
