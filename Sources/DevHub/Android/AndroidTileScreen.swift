import SwiftUI

/// A tile leases the same transport as the single-device view, without creating
/// inspectors, control bars, file-transfer UI, or automatic clipboard ownership.
struct AndroidTileScreen: View {
    @Environment(Hub.self) private var hub
    let device: Device
    @State private var session: AndroidMirrorSession?
    @State private var sessionToken: UUID?
    @State private var geometry: DisplayGeometry?
    @State private var controller: DisplayController?
    @State private var ready = false
    @State private var failure: String?
    @State private var attempt = 0
    private var rotation: QuarterTurn { controller?.orientation ?? .zero }
    private var size: CGSize { session?.size ?? CGSize(width: 1080, height: 2400) }

    var body: some View {
        ZStack {
            if let session, session.isConnected, ready {
                let corners = ((geometry ?? session.geometry)?.videoCorners(size: size, naturalOrientation: device.isEmulator) ?? .square).rotated(rotation)
                AndroidDeviceFrame(size: rotation.size(size), corners: corners) {
                    AndroidScreen(mirror: session.mirror, rotation: rotation,
                                  colorFilter: hub.androidSettings.state(for: device).snapshot?.colorFilter?.mode,
                                  acceptsFiles: false, receiveFiles: { _ in false }, dropTargeted: { _ in })
                }
                .preference(key: TileAspectRatios.self, value: [device.id: TileScreenGeometry.aspectRatio(rotation.size(size))])
                .transition(.opacity)
            } else if let error = failure ?? session?.failure {
                TileConnectionFailure(name: device.name, error: error) { attempt += 1 }
            } else { ProgressView().help("Connecting to \(device.name)…") }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.18), value: session?.isConnected == true && ready)
        .task(id: "\(device.serial ?? "")#\(attempt)") {
            guard let serial = device.serial else { return }
            failure = nil
            let lease = hub.androidSessions.acquire(serial) { AndroidMirrorSession(serial: serial) }
            session = lease.session; sessionToken = lease.token
            lease.session.mirror.clipboardEnabled = false
            defer {
                hub.androidSessions.release(lease)
                if sessionToken == lease.token { session = nil; sessionToken = nil }
            }
            do {
                try await lease.session.start()
                while !Task.isCancelled { try await Task.sleep(for: .seconds(3600)) }
            } catch is CancellationError {} catch {
                hub.androidSessions.discard(lease)
                failure = String(describing: error)
            }
        }
        .task(id: size) {
            guard let serial = device.serial else { return }
            controller = hub.displayController(serial: serial, isEmulator: device.isEmulator)
            while !Task.isCancelled {
                await controller?.synchronizeOrientation()
                let geometry = try? await DeviceActions().displayGeometry(serial: serial)
                guard !Task.isCancelled else { return }
                if let geometry { self.geometry = geometry; session?.geometry = geometry }
                ready = true
                await hub.androidSettings.state(for: device).refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
}
