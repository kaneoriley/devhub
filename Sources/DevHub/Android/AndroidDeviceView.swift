import SwiftUI

struct AndroidDeviceView: View {
    @Environment(Hub.self) private var hub
    let device: Device
    @Binding var panel: Panel?
    @Binding var inspectorWidth: Double
    @State private var session: AndroidMirrorSession?
    @State private var sessionToken: UUID?
    private var mirror: Mirror? {
        session?.isConnected == true && orientationReady && (geometryReady || session?.geometry != nil) ? session?.mirror : nil
    }
    private var size: CGSize { session?.size ?? CGSize(width: 1080, height: 2400) }
    @State private var displayGeometry: DisplayGeometry?
    @State private var geometryReady = false
    @State private var orientationReady = false
    @State private var failure: String?
    @State private var attempt = 0
    @State private var dropTargeted = false
    @State private var transferring = false
    @State private var transferStatus: String?
    @State private var transferID = UUID()
    @State private var actionFailure: String?
    @State private var presets: [DisplayPreset] = []
    @State private var displayController: DisplayController?
    @State private var foldConfiguration: FoldConfiguration?
    @State private var foldController = FoldController()
    private var foldState: FoldState? { foldController.selected }
    private var folding: Bool { foldController.isBusy }

    private var selectedPreset: Int? { displayController?.selectedPreset }
    private var resizing: Bool { displayController?.isChangingPreset == true }
    private var displayBusy: Bool { displayController?.isBusy == true }
    private var videoRotation: QuarterTurn { displayController?.orientation ?? .zero }
    private var displayCorners: DisplayCorners {
        ((displayGeometry ?? session?.geometry)?.videoCorners(size: size, naturalOrientation: device.isEmulator) ?? .square).rotated(videoRotation)
    }

    private var canFold: Bool {
        guard device.kind != .resizable, let foldConfiguration else { return false }
        return foldConfiguration.resizableMode == nil
    }

    var body: some View {
        content
            .contentShape(.rect)
            .dropDestination(for: URL.self) { files, _ in
                receive(files)
            } isTargeted: { dropTargeted = $0 }
            .overlay {
                if dropTargeted, device.serial != nil, !transferring {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.tint.opacity(0.12))
                        .strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [8]))
                        .overlay {
                            VStack(spacing: 8) {
                                Image(systemName: "square.and.arrow.down").font(.largeTitle)
                                Text("Drop to install or copy").font(.headline)
                                Text("APKs install. Other files go to Downloads.")
                            }
                            .padding(24)
                            .glassEffect(in: .rect(cornerRadius: 16))
                        }
                        .padding(16)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .top) {
                if let transferStatus {
                    let id = transferID
                    TransferNotice(message: transferStatus, isTransferring: transferring) {
                        if transferID == id, !transferring { self.transferStatus = nil }
                    }.id(id)
                }
            }
            .alert("Device Action Failed", isPresented: Binding(get: { actionFailure != nil }, set: { if !$0 { actionFailure = nil } })) {
                Button("OK", role: .cancel) { actionFailure = nil }
            } message: {
                Text(actionFailure ?? "")
            }
            .task(id: device.serial) {
                presets = []
                displayController = device.serial.map { hub.displayController(serial: $0, isEmulator: device.isEmulator) }
                await displayController?.synchronizeOrientation()
                guard !Task.isCancelled else { return }
                orientationReady = true
                foldConfiguration = DeviceActions().foldConfiguration(for: device)
                let available = await DeviceActions().displayPresets(for: device)
                guard !Task.isCancelled else { return }
                var state: DisplayState?
                if !available.isEmpty, !displayBusy, let serial = device.serial,
                   let current = try? await DeviceActions().synchronizeDisplay(presets: available, serial: serial, preferredDensity: {
                       AndroidDisplaySizePreferences.density(deviceID: device.id, size: $0.size)
                   }) {
                    state = current
                }
                guard !Task.isCancelled else { return }
                presets = available
                if let state, !displayBusy { displayController?.selectedPreset = presetID(for: state) }
                await mirror?.refreshDensity()
                guard let serial = device.serial else { return }
                while !Task.isCancelled {
                    if foldConfiguration != nil, !folding, !displayBusy {
                        let revision = foldController.revision
                        let posture = try? await DeviceActions().foldState(serial: serial)
                        guard !Task.isCancelled else { return }
                        if !displayBusy { foldController.synchronize(posture, revision: revision) }
                    }
                    if !presets.isEmpty, !displayBusy, let current = try? await DeviceActions().displayState(serial: serial), !Task.isCancelled, !displayBusy {
                        displayController?.selectedPreset = presetID(for: current)
                    }
                    await displayController?.synchronizeOrientation()
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                }
            }
            .onChange(of: size) { _, _ in
                guard !presets.isEmpty, !displayBusy, let serial = device.serial else { return }
                Task { @MainActor in
                    if let state = try? await DeviceActions().displayState(serial: serial), !displayBusy {
                        displayController?.selectedPreset = presetID(for: state)
                    }
                }
            }
            .onChange(of: displayController?.failure) { _, failure in
                if let failure { actionFailure = failure }
            }
            .onChange(of: foldController.failure) { _, failure in
                if let failure { actionFailure = failure }
            }
            .onChange(of: session?.failure) { _, error in
                if let error { failure = error }
            }
            .onChange(of: displayController?.revision) { _, _ in
                Task { await mirror?.refreshDensity() }
            }
            .navigationTitle(device.name)
            .navigationSubtitle(device.release.isEmpty ? device.detail : "Android \(device.release)")
            .modifier(DeviceInspector(panel: $panel, width: $inspectorWidth, connected: mirror != nil,
                                      volumeDown: { mirror?.key(25) }, volumeUp: { mirror?.key(24) }, power: { mirror?.key(26) },
                                      progress: panel == nil ? 0 : 1) { selected in
                Group {
                    if selected == .info {
                        DeviceInfoView(device: device)
                    } else if device.isEmulator || device.serial != nil {
                        AndroidSettingsView(settings: hub.androidSettings.state(for: device), refreshDensity: { await mirror?.refreshDensity() })
                    } else { ContentUnavailableView("Offline", systemImage: "powersleep") }
                }
            })
            .animation(.easeInOut(duration: 0.24), value: panel != nil)
    }

    @ViewBuilder private var content: some View {
        if let serial = device.serial {
            ZStack {
                if let mirror {
                    AndroidDeviceFrame(size: videoRotation.size(size), corners: displayCorners) {
                        AndroidScreen(mirror: mirror, rotation: videoRotation, acceptsFiles: !transferring, receiveFiles: receive, dropTargeted: { dropTargeted = $0 })
                    }
                    .padding(32)
                    .transition(.opacity)
                } else if let failure {
                    ContentUnavailableView {
                        Label("Couldn't Connect", systemImage: "exclamationmark.triangle")
                    } description: { Text(failure) } actions: { Button("Retry") { attempt += 1 } }
                } else {
                    ProgressView("Connecting to \(device.name)…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeOut(duration: 0.18), value: mirror != nil)
            .modifier(ScreenshotNotice(deviceID: device.id))
            .safeAreaInset(edge: .bottom) {
                if let mirror { controls(mirror) }
            }
            .task(id: "\(serial)#\(attempt)") { await connect(serial) }
            .task(id: size) {
                // Refresh geometry without tearing down an already presented screen
                // and its controls when folding changes the video dimensions.
                while !Task.isCancelled {
                    let geometry = try? await DeviceActions().displayGeometry(serial: serial)
                    guard !Task.isCancelled else { return }
                    displayGeometry = geometry
                    session?.geometry = geometry
                    geometryReady = true
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                }
            }
        } else if hub.booting.contains(device.id) {
            ProgressView("Booting \(device.name)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label(device.name, systemImage: "smartphone")
            } description: {
                Text(device.isEmulator ? "The emulator is off." : "The device is offline.")
            } actions: {
                if device.isEmulator {
                    Button("Boot") { hub.boot(device) }.buttonStyle(.glassProminent)
                }
            }
        }
    }

    private func controls(_ mirror: Mirror) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                bar("Back", "arrowtriangle.backward") { mirror.key(4) }
                bar("Home", "circle") { mirror.key(3) }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                bar("Recents", "square") { mirror.key(187) }
            }
            .padding(4)
            .glassEffect(in: .capsule)
            bar("Screenshot", "camera.viewfinder") {
                Task { @MainActor in
                    do { try hub.saveScreenshot(device, png: mirror.screenshot(rotation: videoRotation)) }
                    catch { actionFailure = "Couldn't save screenshot.\n\(error)" }
                }
            }
            .keyboardShortcut("s")
            .padding(4)
            .glassEffect(in: .circle)
            HStack(spacing: 2) {
                bar("Rotate", "device-rotate", asset: true) {
                    Task { @MainActor in
                        await foldController.waitUntilIdle()
                        displayController?.rotate()
                    }
                }
                    .keyboardShortcut(.rightArrow)
                    .disabled(resizing)
                if !presets.isEmpty {
                    controlDivider
                    ForEach(FormFactor.controlOrder, id: \.self) { factor in
                        let preset = presets.first { $0.factor == factor }
                        Button { if let preset { resize(preset) } } label: {
                            DeviceIcon(factor)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(selectedPreset == factor.rawValue ? Color.accentColor : Color.primary)
                                .frame(width: 30, height: 30)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .disabled(preset == nil || folding)
                        .help(preset == nil ? "\(factor.title) unavailable" : factor.title)
                        .accessibilityLabel(factor.title)
                        .accessibilityAddTraits(selectedPreset == factor.rawValue ? .isSelected : [])
                    }
                }
                if canFold, let foldConfiguration {
                    controlDivider
                    ForEach([FoldState.closed, .opened], id: \.self) { state in
                        Button { setFoldState(state) } label: {
                            DeviceIcon(state == .opened ? DeviceKind.tablet : DeviceKind.phone)
                                .frame(width: 30, height: 30)
                                .contentShape(.rect)
                        }
                            .foregroundStyle(foldState == state ? Color.accentColor : Color.primary)
                            .buttonStyle(.plain)
                            .help(state.title)
                            .disabled(!foldConfiguration.states.contains(state) || displayBusy)
                            .accessibilityLabel("\(state.title) device")
                            .accessibilityAddTraits(foldState == state ? .isSelected : [])
                    }
                }
            }
            .padding(4)
            .glassEffect(in: .capsule)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Display controls")
        }
        .padding(.bottom, 16)
    }

    private var controlDivider: some View {
        Divider().frame(height: 18).padding(.horizontal, 4)
    }

    private func presetID(for state: DisplayState) -> Int? {
        if let preset = presets.first(where: { state.matches($0) }) { return preset.id }
        if AndroidDisplaySizePreferences.density(deviceID: device.id, size: state.size) == state.density,
           let preset = presets.first(where: { $0.matches(state.size) }) { return preset.id }
        if foldConfiguration?.matchesClosedDisplay(state.size) == true {
            return foldConfiguration?.resizableMode
        }
        return nil
    }

    private func setFoldState(_ state: FoldState) {
        guard let serial = device.serial, !displayBusy else { return }
        foldController.select(state) { target in
            try await DeviceActions().setFoldState(target, serial: serial)
        }
    }

    private func receive(_ files: [URL]) -> Bool {
        guard let serial = device.serial, !transferring, !files.isEmpty, files.allSatisfy(\.isFileURL) else { return false }
        transferID = UUID()
        transferring = true
        transferStatus = "Preparing files…"
        Task { @MainActor in
            defer { transferring = false }
            do {
                transferStatus = try await DeviceActions().transfer(files, serial: serial) { transferStatus = $0 }
            } catch {
                transferStatus = nil
                actionFailure = String(describing: error)
            }
        }
        return true
    }

    private func resize(_ preset: DisplayPreset) {
        guard !folding else { return }
        displayController?.select(preset)
    }

    private func bar(_ title: String, _ icon: String, asset: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if asset { DeviceHubGlyph(icon, size: 22) }
                else { Image(systemName: icon).font(.system(size: 14, weight: .medium)) }
            }
            .frame(width: 30, height: 30).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }

    private func connect(_ serial: String) async {
        failure = nil
        let lease = hub.androidSessions.acquire(serial) { AndroidMirrorSession(serial: serial) }
        let current = lease.session
        session = current; sessionToken = lease.token
        defer {
            hub.androidSessions.release(lease)
            if sessionToken == lease.token { session = nil; sessionToken = nil }
        }
        do {
            try await current.start()
            while !Task.isCancelled { try await Task.sleep(for: .seconds(3600)) }
        } catch is CancellationError {
        } catch {
            hub.androidSessions.discard(lease)
            failure = "\(error)"
        }
    }
}
