import SwiftUI

struct SimulatorTileScreen: View {
    @Environment(Hub.self) private var hub
    let device: Device
    let simulator: AppleSimulator
    @State private var mirror: SimulatorMirror?
    @State private var sessionToken: UUID?
    @State private var failure: String?
    @State private var attempt = 0

    var body: some View {
        ZStack {
            if let mirror, mirror.isConnected, mirror.hasFrame {
                SimulatorFrame(size: mirror.orientation.size(mirror.size), contour: mirror.contour, rotation: mirror.orientation) {
                    SimulatorScreen(mirror: mirror)
                }
                .preference(key: TileAspectRatios.self, value: [device.id: TileScreenGeometry.aspectRatio(mirror.orientation.size(mirror.size))])
                .transition(.opacity)
            } else if let error = failure ?? mirror?.failure {
                TileConnectionFailure(name: device.name, error: error) { attempt += 1 }
            } else { ProgressView().help("Connecting to \(device.name)…") }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.18), value: mirror?.isConnected == true && mirror?.hasFrame == true)
        .task(id: attempt) {
            failure = nil
            let lease = hub.simulatorSessions.acquire(simulator.udid) { SimulatorMirror(simulator: simulator) }
            mirror = lease.session; sessionToken = lease.token
            defer {
                hub.simulatorSessions.release(lease)
                if sessionToken == lease.token { mirror = nil; sessionToken = nil }
            }
            do {
                try await lease.session.start()
                while !Task.isCancelled { try await Task.sleep(for: .seconds(3600)) }
            } catch is CancellationError {} catch {
                hub.simulatorSessions.discard(lease)
                failure = String(describing: error)
            }
        }
    }
}
