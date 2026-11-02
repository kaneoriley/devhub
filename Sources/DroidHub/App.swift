import SwiftUI

@main
struct DroidHubApp: App {
    @State private var hub = Hub()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("DroidHub", id: "main") {
            ContentView().environment(hub)
        }
        .defaultSize(width: 1000, height: 900)
        .commands {
            CommandGroup(replacing: .appInfo) { Button("About DroidHub") { openWindow(id: "about") } }
            CommandGroup(replacing: .help) { Button("Welcome to DroidHub") { openWindow(id: "welcome") } }
        }
        Window("About DroidHub", id: "about") { AboutView() }
            .windowStyle(.hiddenTitleBar)
            .windowResizability(.contentSize)
        Window("Welcome to DroidHub", id: "welcome") { WelcomeView() }
            .windowStyle(.hiddenTitleBar)
            .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    @Environment(Hub.self) private var hub
    @Environment(\.openWindow) private var openWindow
    @AppStorage("welcomed") private var welcomed = false
    @AppStorage("deviceList.filter") private var deviceFilter = DeviceFilter.all
    @AppStorage("deviceList.sort") private var deviceSort = DeviceSort.availability
    @AppStorage("deviceList.showGroups") private var showGroups = true
    @State private var query = ""
    @State private var panel: Panel?
    @AppStorage("inspector.width") private var inspectorWidth = 300.0
    @State private var creating: NewDeviceKind?

    private var listing: DeviceList {
        DeviceList(filter: deviceFilter, sort: deviceSort, showGroups: showGroups,
                   query: query, recentSelections: hub.recentSelections, booting: hub.booting)
    }

    var body: some View {
        @Bindable var hub = hub
        NavigationSplitView {
            List(selection: $hub.selection) {
                ForEach(listing.groups(hub.devices)) { group in
                    if let title = group.title {
                        Section(title) { ForEach(group.devices) { DeviceRow(device: $0) } }
                    } else {
                        ForEach(group.devices) { DeviceRow(device: $0) }
                    }
                }
            }
            .overlay {
                if !hub.devices.isEmpty, listing.groups(hub.devices).isEmpty {
                    Text("No matching devices").foregroundStyle(.secondary).padding()
                }
            }
            .searchable(text: $query, placement: .sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .toolbar {
                ToolbarItemGroup {
                    NewDeviceMenu(selection: $creating)
                    DeviceListMenu()
                }
            }
            .sheet(item: $creating) { kind in
                switch kind {
                case .android: NewEmulatorSheet().environment(hub)
                case .ios: NewSimulatorSheet().environment(hub)
                }
            }
        } detail: {
            if let device = hub.selected {
                if let simulator = device.simulator {
                    AppleSimulatorView(device: device, simulator: simulator, panel: $panel, inspectorWidth: $inspectorWidth).id(device.id)
                } else if let apple = device.appleDevice {
                    AppleDeviceView(device: device, apple: apple).id(device.id)
                } else {
                    DeviceView(device: device, panel: $panel, inspectorWidth: $inspectorWidth).id(device.id)
                }
            } else {
                ContentUnavailableView("No Devices", systemImage: "smartphone", description: Text("Create an emulator or connect a device. Apple simulators use your selected Xcode installation."))
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .task { await hub.poll() }
        .onChange(of: hub.devices, initial: true) { _, _ in validateSelection() }
        .onChange(of: deviceFilter) { _, _ in validateSelection() }
        .onChange(of: hub.selection) { _, id in hub.recordSelection(id) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            hub.androidSessions.retain([])
            hub.simulatorSessions.retain([])
        }
        .alert("Device Action Failed", isPresented: Binding(get: { hub.failure != nil }, set: { if !$0 { hub.failure = nil } })) {
            Button("OK", role: .cancel) { hub.failure = nil }
        } message: { Text(hub.failure ?? "") }
        .onAppear { if !welcomed { openWindow(id: "welcome") } }
    }

    private func validateSelection() {
        guard !hub.devices.isEmpty else { return }
        if let selection = hub.selection, hub.devices.contains(where: { $0.id == selection && deviceFilter.includes($0) }) { return }
        hub.selection = listing.groups(hub.devices).first?.devices.first?.id
    }
}

struct DeviceRow: View {
    @Environment(Hub.self) private var hub
    let device: Device
    @State private var confirmingDelete = false
    @State private var deleteRefused = false
    @State private var deleting = false

    var body: some View {
        HStack(spacing: 10) {
            DeviceBadge(kind: device.kind, selected: hub.selection == device.id, running: device.isRunning, simulator: device.simulator != nil || device.appleDevice != nil)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(hub.booting.contains(device.id) ? "Booting…" : device.detail)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(device.api).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).fixedSize()
        }
        .padding(.vertical, 2)
        .contextMenu {
            if let simulator = device.simulator {
                if device.isRunning { Button("Shut Down") { hub.shutdown(device) } }
                else {
                    Button("Boot") { hub.boot(device) }.disabled(hub.booting.contains(device.id) || deleting)
                    if simulator.state == "Shutdown" { Divider(); deleteButton }
                }
            }
            if device.isEmulator {
                if device.serial == nil {
                    Button("Boot") { hub.boot(device) }.disabled(hub.booting.contains(device.id) || deleting)
                    Divider()
                    deleteButton
                } else {
                    Button("Shut Down") { hub.shutdown(device) }
                }
            }
        }
        .confirmationDialog("Delete \(device.name)?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                deleting = true
                Task { @MainActor in
                    defer { deleting = false }
                    await hub.delete(device)
                }
            }
        } message: {
            Text("The \(device.simulator == nil ? "emulator" : "simulator") and everything installed on it go away. This can't be undone.")
        }
        .alert("\(device.name) is running", isPresented: $deleteRefused) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Shut it down before deleting it.")
        }
    }

    private var deleteButton: some View {
        Button("Delete…", role: .destructive) {
            // An emulator started elsewhere may still have no serial while booting.
            if let avd = device.avd, AVD.isRunning(avd) { deleteRefused = true }
            else { confirmingDelete = true }
        }
        .disabled(hub.booting.contains(device.id) || deleting)
    }
}

struct DeviceView: View {
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
            .modifier(DeviceInspector(panel: $panel, width: $inspectorWidth, available: Panel.allCases, connected: mirror != nil,
                                      volumeDown: { mirror?.key(25) }, volumeUp: { mirror?.key(24) }, power: { mirror?.key(26) },
                                      progress: panel == nil ? 0 : 1) { selected in
                Group {
                    if selected == .settings, device.isEmulator || device.serial != nil {
                        SettingsView(device: device, serial: device.serial, refreshDensity: { await mirror?.refreshDensity() })
                    } else if let serial = device.serial {
                        switch selected {
                        case .logs: LogsView(serial: serial)
                        case .crashes: CrashesView(serial: serial)
                        case .settings: SettingsView(device: device, serial: serial, refreshDensity: { await mirror?.refreshDensity() })
                        }
                    } else { ContentUnavailableView("Offline", systemImage: "powersleep") }
                }
            })
            .animation(.easeInOut(duration: 0.24), value: panel != nil)
    }

    @ViewBuilder private var content: some View {
        if let serial = device.serial {
            ZStack {
                if let mirror {
                    Phone(size: videoRotation.size(size), corners: displayCorners) {
                        Screen(mirror: mirror, rotation: videoRotation, acceptsFiles: !transferring, receiveFiles: receive, dropTargeted: { dropTargeted = $0 })
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

/// Device frame drawn around the screen, sized from the video's pixel dimensions.
struct Phone<Content: View>: View {
    let size: CGSize
    let corners: DisplayCorners
    var clipsContent = true
    @ViewBuilder let content: Content

    var body: some View {
        let short = min(size.width, size.height)
        let bezel = short * 0.02
        let outer = CGSize(width: size.width + bezel * 2, height: size.height + bezel * 2)
        GeometryReader { geo in
            let k = geo.size.width / outer.width
            let shell = corners.shape(scale: k, border: bezel * k, style: .continuous)
            let screen = corners.shape(scale: k, style: .continuous)
            ZStack {
                shell.fill(Color(white: 0.035))
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                shell.strokeBorder(
                    LinearGradient(stops: [.init(color: Color(white: 0.48), location: 0),
                                           .init(color: Color(white: 0.22), location: 0.3),
                                           .init(color: Color(white: 0.13), location: 0.55),
                                           .init(color: Color(white: 0.38), location: 1)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1.5
                )
                shell.inset(by: 1.5)
                    .strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
                shell.inset(by: 3)
                    .strokeBorder(.black.opacity(0.8), lineWidth: 1)
                content
                    .frame(width: size.width * k, height: size.height * k)
                    .clipShape(clipsContent ? AnyShape(screen) : AnyShape(Rectangle()), style: FillStyle(antialiased: true))
                    .overlay {
                        screen.strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
                            .allowsHitTesting(false)
                    }
            }
            .overlay(alignment: .topTrailing) {
                if size.height > size.width {  // power and volume keys, right edge, portrait only
                    let h = geo.size.height, w = max(1.5, bezel * k * 0.16)
                    VStack(spacing: h * 0.04) {
                        Capsule().frame(width: w, height: h * 0.07)
                        Capsule().frame(width: w, height: h * 0.13)
                    }
                    .foregroundStyle(Color(white: 0.25))
                    .offset(x: w * 0.8, y: h * 0.2)
                }
            }
        }
        .aspectRatio(outer, contentMode: .fit)
    }
}

struct Screen: NSViewRepresentable {
    let mirror: Mirror
    let rotation: QuarterTurn
    let acceptsFiles: Bool
    let receiveFiles: ([URL]) -> Bool
    let dropTargeted: (Bool) -> Void

    func makeNSView(context: Context) -> ScreenView {
        let view = ScreenView(mirror: mirror)
        updateNSView(view, context: context)
        return view
    }

    static func dismantleNSView(_ view: ScreenView, coordinator: ()) { view.releaseInput() }

    func updateNSView(_ view: ScreenView, context: Context) {
        view.rotation = rotation
        view.acceptsFiles = acceptsFiles
        view.receiveFiles = receiveFiles
        view.dropTargeted = dropTargeted
    }
}

/// Hosts the video layer and turns mouse and keyboard input into Android events.
final class ScreenView: NSView {
    private let mirror: Mirror
    var rotation = QuarterTurn.zero {
        willSet { if newValue != rotation { releaseInput() } }
        didSet { if rotation != oldValue { needsLayout = true } }
    }
    var acceptsFiles = true
    var receiveFiles: (([URL]) -> Bool)?
    var dropTargeted: ((Bool) -> Void)?
    private var marked: String?
    private var mousePoint: CGPoint?
    private lazy var twoFingerInput = TwoFingerInput(view: self, beginPreview: { [weak self] in self?.releaseSingleInput() }) { [weak self] points, phase in
        guard let self, self.bounds.width > 0, self.bounds.height > 0 else { return }
        func source(_ p: CGPoint) -> CGPoint {
            self.rotation.sourcePoint(CGPoint(x: p.x / self.bounds.width, y: p.y / self.bounds.height))
        }
        self.mirror.touchPair(phase, first: source(points.first), second: source(points.second))
    }
    private static let ctrl: UInt32 = 0x3000  // META_CTRL_ON | META_CTRL_LEFT_ON
    private static let commands: [Selector: (UInt32, UInt32)] = [
        #selector(NSResponder.deleteBackward(_:)): (67, 0),
        #selector(NSResponder.deleteWordBackward(_:)): (67, ctrl),
        #selector(NSResponder.deleteForward(_:)): (112, 0),
        #selector(NSResponder.insertNewline(_:)): (66, 0),
        #selector(NSResponder.insertTab(_:)): (61, 0),
        #selector(NSResponder.moveUp(_:)): (19, 0),
        #selector(NSResponder.moveDown(_:)): (20, 0),
        #selector(NSResponder.moveLeft(_:)): (21, 0),
        #selector(NSResponder.moveRight(_:)): (22, 0),
        #selector(NSResponder.moveWordLeft(_:)): (21, ctrl),
        #selector(NSResponder.moveWordRight(_:)): (22, ctrl),
        #selector(NSResponder.scrollPageUp(_:)): (92, 0),
        #selector(NSResponder.scrollPageDown(_:)): (93, 0),
    ]

    init(mirror: Mirror) {
        self.mirror = mirror
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(mirror.layer)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Device screen")
        _ = twoFingerInput
        NotificationCenter.default.addObserver(self, selector: #selector(releaseOnBlur), name: NSWindow.didResignKeyNotification, object: nil)
        registerForDraggedTypes([.fileURL])
    }

    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func releaseOnBlur() { releaseInput() }
    override func resignFirstResponder() -> Bool { releaseInput(); return true }
    func releaseInput() {
        twoFingerInput.reset()
        releaseSingleInput()
    }
    private func releaseSingleInput() {
        if let point = mousePoint { mirror.touch(1, at: point); mousePoint = nil }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Handle Finder drops on the AppKit video surface itself as well as SwiftUI's
    // surrounding detail view. This also ensures Finder proposes a copy, never a move.
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let canDrop = acceptsFiles && sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        dropTargeted?(canDrop)
        return canDrop ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { dropTargeted?(false) }
    override func draggingEnded(_ sender: any NSDraggingInfo) { dropTargeted?(false) }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dropTargeted?(false)
        guard acceptsFiles, let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return false }
        return receiveFiles?(urls) ?? false
    }

    override func viewDidMoveToWindow() {
        DispatchQueue.main.async { self.window?.makeFirstResponder(self) }
    }

    override func layout() {
        super.layout()
        twoFingerInput.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mirror.layer.bounds = CGRect(origin: .zero, size: rotation.size(bounds.size))
        mirror.layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        mirror.layer.setAffineTransform(CGAffineTransform(rotationAngle: rotation.radians))
        CATransaction.commit()
    }

    private func point(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return rotation.sourcePoint(CGPoint(x: p.x / bounds.width, y: p.y / bounds.height))
    }

    override func updateTrackingAreas() { super.updateTrackingAreas(); twoFingerInput.updateTracking() }
    override func mouseMoved(with event: NSEvent) { twoFingerInput.hover(event) }
    override func mouseEntered(with event: NSEvent) { twoFingerInput.hover(event) }
    override func mouseExited(with event: NSEvent) { twoFingerInput.exited() }
    override func flagsChanged(with event: NSEvent) {
        twoFingerInput.modifiersChanged(event.modifierFlags)
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if twoFingerInput.mouseDown(event) { return }
        mousePoint = point(event)
        mirror.touch(0, at: mousePoint!)
    }
    override func mouseDragged(with event: NSEvent) {
        if twoFingerInput.mouseDragged(event) { return }
        guard mousePoint != nil else { return }
        mousePoint = point(event); mirror.touch(2, at: mousePoint!)
    }
    override func mouseUp(with event: NSEvent) {
        if twoFingerInput.mouseUp(event) { return }
        if mousePoint != nil { mirror.touch(1, at: point(event)); mousePoint = nil }
    }
    override func rightMouseDown(with event: NSEvent) { mirror.key(4) }

    override func scrollWheel(with event: NSEvent) {
        guard !twoFingerInput.active else { return }
        // Trackpads report points and wheels report notches. Converting points at the
        // current zoom keeps the content under the fingers.
        let k = event.hasPreciseScrollingDeltas ? 1 / mirror.pointsPerNotch(viewWidth: rotation.size(bounds.size).width) : 1
        // AppKit's vertical scroll sign is opposite to its screen coordinates.
        let delta = rotation.sourceVector(CGPoint(x: -event.scrollingDeltaX * k, y: -event.scrollingDeltaY * k))
        mirror.scroll(at: point(event), dx: Float(delta.x), dy: Float(-delta.y))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { return mirror.key(4) }  // Esc is Back, like the emulator
        interpretKeyEvents([event])
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘M opens the React Native dev menu in the emulator, keep that instead of minimizing.
        if window?.firstResponder === self, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "m" {
            mirror.key(82)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func doCommand(by selector: Selector) {
        if let (code, meta) = Self.commands[selector] { mirror.key(code, meta: meta) }
    }

    @objc func paste(_ sender: Any?) {
        if let text = NSPasteboard.general.string(forType: .string) { mirror.paste(text) }
    }

    @objc func copy(_ sender: Any?) { mirror.key(31, meta: Self.ctrl) }
    @objc func cut(_ sender: Any?) { mirror.key(52, meta: Self.ctrl) }
    override func selectAll(_ sender: Any?) { mirror.key(29, meta: Self.ctrl) }
}

/// Being a text input client is what makes dead keys and input methods work: the
/// system composes "´" and "e" into "é" and hands over the finished text.
extension ScreenView: NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        marked = nil
        mirror.type((string as? NSAttributedString)?.string ?? string as? String ?? "")
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = (string as? NSAttributedString)?.string ?? string as? String
    }

    func unmarkText() { marked = nil }
    func hasMarkedText() -> Bool { marked != nil }
    func markedRange() -> NSRange { NSRange(location: marked == nil ? NSNotFound : 0, length: (marked as NSString?)?.length ?? 0) }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        window?.convertToScreen(convert(bounds, to: nil)) ?? .zero
    }
}

struct SettingsView: View {
    @Environment(Hub.self) private var hub
    let device: Device
    let serial: String?
    var refreshDensity: () async -> Void = {}
    @State private var configuring = false
    @State private var dark = false
    @State private var automaticAppearance = false
    @State private var runtime = AndroidUISettings()
    @State private var avdConfiguration: [String: String]?
    @State private var displayIndex = 0.0
    @State private var editingDisplaySize = false
    private static let fontScales = [0.85, 1, 1.15, 1.3, 1.5, 1.8, 2]
    @State private var fontScale = 1.0
    @State private var fontIndex = 1.0
    @State private var showTaps = false
    @State private var layoutBounds = false
    @State private var screen = ""
    @State private var loading = true
    @State private var saving = false
    @State private var failure: String?

    private var displayPresets: [DisplayPreset] {
        guard let avd = device.avd else { return [] }
        return DisplayPreset.parse(Hub.ini(SDK.avdDirectory(avd).appending(path: "config.ini"))["hw.resizable.configs"] ?? "")
    }

    private var graphicsMode: String {
        guard let config = avdConfiguration else { return "Unknown" }
        if config["hw.gpu.enabled"] == "no" { return "Disabled" }
        let mode = config["hw.gpu.mode"] ?? "auto"
        return ["auto": "Automatic", "host": "Hardware", "software": "Software"][mode] ?? mode
    }

    private var bootMode: String {
        guard let config = avdConfiguration else { return "Unknown" }
        if config["fastboot.forceColdBoot"] == "yes" { return "Cold" }
        if config["fastboot.forceChosenSnapshotBoot"] == "yes" { return "Snapshot" }
        return "Quick"
    }

    private func loadConfiguration() {
        avdConfiguration = device.avd.map { Hub.ini(SDK.avdDirectory($0).appending(path: "config.ini")) }
    }

    var body: some View {
        Form {
            Group {
                Section {
                    LabeledContent {
                        AppearanceControl(dark: Binding(get: { dark }, set: { value in
                            automaticAppearance = false
                            apply($dark) { "cmd uimode night \($0 ? "yes" : "no")" }.wrappedValue = value
                        }), automatic: automaticAppearance, setAutomatic: {
                            automaticAppearance = true
                            apply($dark) { _ in "cmd uimode night auto" }.wrappedValue = false
                        })
                    } label: { SettingsLabel(title: "Appearance", icon: "circle.lefthalf.filled") }
                    if runtime.navigation != nil {
                        LabeledContent {
                            Picker("Navigation Mode", selection: Binding(get: { runtime.navigation ?? .gestures }, set: { value in
                                runtime.navigation = value
                                changeRuntime { try await AndroidUISettings.setNavigation(value, serial: $0) }
                            })) {
                                ForEach(AndroidUISettings.Navigation.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }.labelsHidden().fixedSize().accessibilityLabel("Navigation Mode")
                        } label: { SettingsLabel(title: "Navigation Mode", icon: "hand.draw") }
                    }
                    if runtime.talkBackAvailable {
                        Toggle(isOn: Binding(get: { runtime.talkBack }, set: { value in
                            runtime.talkBack = value
                            changeRuntime { try await AndroidUISettings.setAccessibility(.talkBack, enabled: value, serial: $0) }
                        })) { SettingsLabel(title: "TalkBack", icon: "voiceover") }
                    }
                    if runtime.selectToSpeakAvailable {
                        Toggle(isOn: Binding(get: { runtime.selectToSpeak }, set: { value in
                            runtime.selectToSpeak = value
                            changeRuntime { try await AndroidUISettings.setAccessibility(.selectToSpeak, enabled: value, serial: $0) }
                        })) { SettingsLabel(title: "Select to Speak", icon: "text.bubble") }
                    }
                    LabeledContent {
                        TextSizeControl(value: $fontIndex, count: Self.fontScales.count, title: "Font Size", description: "\(Int(Self.fontScales[Int(fontIndex)] * 100))%") {
                            let scale = Self.fontScales[Int(fontIndex)]
                            apply($fontScale) { "settings put system font_scale \($0)" }.wrappedValue = scale
                        }
                    } label: { SettingsLabel(title: "Font Size", icon: "textformat.size") }
                    if let display = runtime.display, display.values.count > 1 {
                        LabeledContent {
                            Slider(value: $displayIndex, in: 0...Double(display.values.count - 1), step: 1) {
                                Text("Display Size")
                            } onEditingChanged: { editing in
                                editingDisplaySize = editing
                                if !editing {
                                    let index = Int(displayIndex)
                                    changeRuntime {
                                        try await display.apply(index: index, serial: $0)
                                        AndroidDisplaySizePreferences.record(deviceID: device.id, size: display.screenSize, density: display.values[index])
                                    }
                                }
                            }
                            .labelsHidden().frame(width: 120).accessibilityLabel("Display Size")
                            .accessibilityValue(displayDescription(display)).help(displayDescription(display))
                        } label: { SettingsLabel(title: "Display Size", icon: "display") }
                    }
                    Toggle(isOn: apply($showTaps) { "settings put system show_touches \($0 ? 1 : 0)" }) {
                        SettingsLabel(title: "Show Taps", icon: "hand.tap")
                    }.accessibilityLabel("Show Taps")
                    // SYSPROPS_TRANSACTION refreshes layout bounds in running apps.
                    Toggle(isOn: apply($layoutBounds) { "setprop debug.layout \($0); service call activity 1599295570" }) {
                        SettingsLabel(title: "Layout Bounds", icon: "square.on.square.dashed")
                    }.accessibilityLabel("Layout Bounds")
                } footer: {
                    SettingsFooterButton(title: "Reset to Defaults", icon: "arrow.counterclockwise", alignment: .trailing, action: reset)
                        .help("Restore default appearance and display size, gesture navigation where supported, 100% font size, and turn TalkBack, Select to Speak, Show Taps and Layout Bounds off.")
                    if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
                }
            }.disabled(serial == nil || loading || saving)
            Section {
                LabeledContent("Model", value: device.model)
                LabeledContent("Android", value: device.release)
                LabeledContent("API", value: device.api)
                LabeledContent("Screen", value: screen)
                if let serial { LabeledContent("Serial", value: serial) }
                if device.isEmulator {
                    LabeledContent("Graphics Acceleration", value: graphicsMode)
                    LabeledContent("Boot Mode", value: bootMode)
                }
            } header: {
                Text("Device")
            } footer: {
                if device.isEmulator {
                    SettingsFooterButton(title: "Edit Configuration", icon: "pencil", alignment: .trailing, action: { configuring = true })
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .sheet(isPresented: $configuring, onDismiss: loadConfiguration) { EditEmulatorConfiguration(device: device).environment(hub) }
        .task(id: device.avd) { loadConfiguration() }
        .task(id: serial) { if serial != nil { await load() } }
        .task(id: serial) {
            guard let serial else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                if !loading && !saving && !editingDisplaySize {
                    let state = await AndroidUISettings.load(serial: serial, kind: device.kind, presets: displayPresets)
                    guard !Task.isCancelled else { return }
                    if !loading && !saving && !editingDisplaySize { updateRuntime(state) }
                }
            }
        }
    }

    private func displayDescription(_ display: AndroidDisplaySize) -> String {
        let index = min(max(0, Int(displayIndex)), display.values.count - 1)
        let value = display.values[index]
        return value == display.defaultDensity ? "Default · \(value) dpi" : "\(Int((Double(value) / Double(display.defaultDensity) * 100).rounded()))% · \(value) dpi"
    }

    private func updateRuntime(_ state: AndroidUISettings) {
        runtime = state
        displayIndex = Double(state.display?.index ?? 0)
    }

    private func changeRuntime(_ action: @escaping (String) async throws -> Void) {
        guard let serial else { return }
        saving = true; failure = nil
        Task { @MainActor in
            defer { saving = false }
            do { try await action(serial); await refreshDensity(); await load() }
            catch { await load(); failure = String(describing: error) }
        }
    }

    /// Binding that runs the adb shell command only when the user changes the value.
    private func apply<T>(_ value: Binding<T>, _ command: @escaping (T) -> String) -> Binding<T> {
        Binding(get: { value.wrappedValue }, set: { new in
            guard let serial else { return }
            value.wrappedValue = new
            saving = true; failure = nil
            Task { @MainActor in
                defer { saving = false }
                do { try await runADB(["-s", serial, "shell", command(new)]).checked() }
                catch { await load(); failure = String(describing: error) }
            }
        })
    }

    private func reset() {
        guard let serial else { return }
        saving = true; failure = nil
        Task { @MainActor in
            defer { saving = false }
            do {
                try await AndroidSettingsDefaults.reset(serial: serial, settings: runtime, kind: device.kind)
                if let display = runtime.display {
                    AndroidDisplaySizePreferences.record(deviceID: device.id, size: display.screenSize, density: display.defaultDensity)
                }
                await refreshDensity(); await load()
            }
            catch { await load(); failure = String(describing: error) }
        }
    }

    private func load() async {
        guard let serial else { return }
        loading = true
        defer { loading = false }
        func shell(_ cmd: String) async -> String {
            await adb("-s", serial, "shell", cmd).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        async let night = shell("cmd uimode night")
        async let scale = shell("settings get system font_scale")
        async let taps = shell("settings get system show_touches")
        async let bounds = shell("getprop debug.layout")
        async let size = shell("wm size")
        async let density = shell("wm density")
        async let extra = AndroidUISettings.load(serial: serial, kind: device.kind, presets: displayPresets)
        let nightMode = await night
        dark = nightMode.hasSuffix("yes")
        automaticAppearance = nightMode.hasSuffix("auto")
        fontScale = Double(await scale) ?? 1
        fontIndex = Double(Self.fontScales.indices.min { abs(Self.fontScales[$0] - fontScale) < abs(Self.fontScales[$1] - fontScale) } ?? 1)
        showTaps = await taps == "1"
        layoutBounds = await bounds == "true"
        updateRuntime(await extra)
        let last = { (s: String) in s.split(separator: "\n").last?.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "" }
        screen = "\(last(await size).replacingOccurrences(of: "x", with: "×")) · \(last(await density)) dpi"
    }
}
