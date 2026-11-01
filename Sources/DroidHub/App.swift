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
    @State private var query = ""
    @State private var panel: Panel?
    @State private var creating = false

    var body: some View {
        @Bindable var hub = hub
        NavigationSplitView {
            List(selection: $hub.selection) {
                section("Devices", hub.devices.filter { !$0.isEmulator })
                section("Emulators", hub.devices.filter(\.isEmulator))
            }
            .searchable(text: $query, placement: .sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .toolbar {
                Button("New Emulator", systemImage: "plus") { creating = true }
            }
            .sheet(isPresented: $creating) { NewEmulatorSheet().environment(hub) }
        } detail: {
            if let device = hub.selected {
                DeviceView(device: device, panel: $panel).id(device.id)
            } else {
                ContentUnavailableView("No Devices", systemImage: "smartphone", description: Text("Create an emulator in Android Studio or plug in a device."))
            }
        }
        .task { await hub.poll() }
        .onAppear { if !welcomed { openWindow(id: "welcome") } }
    }

    @ViewBuilder private func section(_ title: String, _ devices: [Device]) -> some View {
        let shown = devices.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        if !shown.isEmpty {
            Section(title) { ForEach(shown) { DeviceRow(device: $0) } }
        }
    }
}

struct DeviceRow: View {
    @Environment(Hub.self) private var hub
    let device: Device
    @State private var confirmingDelete = false
    @State private var deleteRefused = false

    var body: some View {
        HStack(spacing: 10) {
            DeviceBadge(kind: device.kind, selected: hub.selection == device.id, running: device.serial != nil)
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
            if device.isEmulator {
                if device.serial == nil {
                    Button("Boot") { hub.boot(device) }
                    Divider()
                    Button("Delete…", role: .destructive) {
                        // An emulator started outside DroidHub has no serial until it finishes booting.
                        if let avd = device.avd, AVD.isRunning(avd) { deleteRefused = true } else { confirmingDelete = true }
                    }
                    .disabled(hub.booting.contains(device.id))
                } else {
                    Button("Shut Down") { hub.shutdown(device) }
                }
            }
        }
        .confirmationDialog("Delete \(device.name)?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                if let avd = device.avd { try? AVD.delete(avd) }
                Task { await hub.refresh() }
            }
        } message: {
            Text("The emulator and everything installed on it go away. This can't be undone.")
        }
        .alert("\(device.name) is running", isPresented: $deleteRefused) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Shut it down before deleting it.")
        }
    }
}

struct DeviceView: View {
    @Environment(Hub.self) private var hub
    let device: Device
    @Binding var panel: Panel?
    @State private var mirror: Mirror?
    @State private var size = CGSize(width: 1080, height: 2400)
    @State private var displayGeometry: DisplayGeometry?
    @State private var failure: String?
    @State private var attempt = 0
    @State private var dropTargeted = false
    @State private var transferring = false
    @State private var transferStatus: String?
    @State private var actionFailure: String?
    @State private var presets: [DisplayPreset] = []
    @State private var displayController: DisplayController?
    @State private var foldConfiguration: FoldConfiguration?
    @State private var foldState: FoldState?
    @State private var folding = false

    private var selectedPreset: Int? { displayController?.selectedPreset }
    private var resizing: Bool { displayController?.isChangingPreset == true }
    private var displayBusy: Bool { displayController?.isBusy == true }
    private var videoRotation: QuarterTurn { displayController?.orientation ?? .zero }
    private var displayCorners: DisplayCorners {
        (displayGeometry?.videoCorners(size: size, naturalOrientation: device.isEmulator) ?? .square).rotated(videoRotation)
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
                    HStack(spacing: 10) {
                        if transferring { ProgressView().controlSize(.small) }
                        else { Image(systemName: "checkmark.circle") }
                        Text(transferStatus).lineLimit(2)
                        if !transferring {
                            Button("Dismiss", systemImage: "xmark") { self.transferStatus = nil }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(12)
                    .glassEffect(in: .rect(cornerRadius: 12))
                    .padding(16)
                    .accessibilityElement(children: .contain)
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
                foldConfiguration = DeviceActions().foldConfiguration(for: device)
                foldState = nil
                let available = await DeviceActions().displayPresets(for: device)
                guard !Task.isCancelled else { return }
                var state: DisplayState?
                if !available.isEmpty, !displayBusy, let serial = device.serial,
                   let current = try? await DeviceActions().synchronizeDisplay(presets: available, serial: serial) {
                    state = current
                }
                guard !Task.isCancelled else { return }
                presets = available
                if let state, !displayBusy { displayController?.selectedPreset = presetID(for: state) }
                await mirror?.refreshDensity()
                guard let serial = device.serial else { return }
                while !Task.isCancelled {
                    if foldConfiguration != nil {
                        let posture = try? await DeviceActions().foldState(serial: serial)
                        guard !Task.isCancelled else { return }
                        if !folding, !displayBusy { foldState = posture }
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
            .onChange(of: displayController?.revision) { _, _ in
                Task { await mirror?.refreshDensity() }
            }
            .navigationTitle(device.name)
            .navigationSubtitle(device.release.isEmpty ? device.detail : "Android \(device.release)")
            .toolbar {
                if let mirror {
                    ToolbarItemGroup {
                        Button("Volume Down", systemImage: "speaker.wave.1") { mirror.key(25) }
                        Button("Volume Up", systemImage: "speaker.wave.3") { mirror.key(24) }
                        Button("Power", systemImage: "power") { mirror.key(26) }
                    }
                }
                ToolbarItemGroup {
                    ForEach(Panel.allCases, id: \.self) { p in
                        Toggle(p.title, systemImage: p.icon, isOn: Binding(get: { panel == p }, set: { panel = $0 ? p : nil }))
                    }
                }
            }
            .inspector(isPresented: Binding(get: { panel != nil }, set: { if !$0 { panel = nil } })) {
                if let serial = device.serial {
                    switch panel {
                    case .logs: LogsView(serial: serial)
                    case .crashes: CrashesView(serial: serial)
                    default: SettingsView(device: device, serial: serial)
                    }
                } else {
                    ContentUnavailableView("Offline", systemImage: "powersleep")
                }
            }
    }

    @ViewBuilder private var content: some View {
        if let serial = device.serial {
            Phone(size: videoRotation.size(size), corners: displayCorners) {
                if let mirror {
                    Screen(mirror: mirror, rotation: videoRotation, acceptsFiles: !transferring, receiveFiles: receive, dropTargeted: { dropTargeted = $0 })
                } else {
                    Color.black.overlay {
                        if let failure {
                            VStack(spacing: 12) {
                                Text(failure).foregroundStyle(.white).multilineTextAlignment(.center)
                                Button("Retry") { attempt += 1 }
                            }
                            .padding()
                        } else {
                            ProgressView().controlSize(.large).tint(.white)
                        }
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom) {
                if let mirror { controls(mirror) }
            }
            .task(id: "\(serial)#\(attempt)") { await connect(serial) }
            .task(id: size) {
                while !Task.isCancelled {
                    let geometry = try? await DeviceActions().displayGeometry(serial: serial)
                    guard !Task.isCancelled else { return }
                    displayGeometry = geometry
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
                bar("Rotate", "device-rotate", asset: true) { displayController?.rotate() }
                    .keyboardShortcut(.rightArrow)
                    .disabled(resizing || folding)
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
                    ForEach(FoldState.allCases, id: \.self) { state in
                        Button { setFoldState(state) } label: {
                            DeviceIcon(state == .opened ? DeviceKind.tablet : DeviceKind.phone)
                                .frame(width: 30, height: 30)
                                .contentShape(.rect)
                        }
                            .foregroundStyle(foldState == state ? Color.accentColor : Color.primary)
                            .buttonStyle(.plain)
                            .help(state.title)
                            .disabled(!foldConfiguration.states.contains(state) || folding || displayBusy)
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
        if foldConfiguration?.matchesClosedDisplay(state.size) == true {
            return foldConfiguration?.resizableMode
        }
        return nil
    }

    private func setFoldState(_ state: FoldState) {
        guard let serial = device.serial, !folding, !displayBusy, foldState != state else { return }
        folding = true
        Task { @MainActor in
            defer { folding = false }
            do {
                try await DeviceActions().setFoldState(state, serial: serial)
                foldState = state
            } catch { actionFailure = String(describing: error) }
        }
    }

    private func receive(_ files: [URL]) -> Bool {
        guard let serial = device.serial, !transferring, !files.isEmpty, files.allSatisfy(\.isFileURL) else { return false }
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
        mirror = nil
        failure = nil
        let m = Mirror(serial: serial)
        m.onSize = { [weak m] new in
            size = new
            // Resizable modes can change density as well as resolution.
            if !presets.isEmpty { Task { await m?.refreshDensity() } }
        }
        m.onClose = { [weak m] in
            m?.stop()  // frees the server and the adb forward now, not at the next Retry
            mirror = nil
            failure = "Disconnected"
        }
        do {
            try await m.start()
        } catch {
            m.stop()
            failure = "\(error)"
            return
        }
        mirror = m
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
        m.stop()
    }
}

/// Device frame drawn around the screen, sized from the video's pixel dimensions.
struct Phone<Content: View>: View {
    let size: CGSize
    let corners: DisplayCorners
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
                    .clipShape(screen, style: FillStyle(antialiased: true))
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
        didSet { if rotation != oldValue { needsLayout = true } }
    }
    var acceptsFiles = true
    var receiveFiles: (([URL]) -> Bool)?
    var dropTargeted: ((Bool) -> Void)?
    private var marked: String?
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
        registerForDraggedTypes([.fileURL])
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

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        mirror.touch(0, at: point(event))
    }

    override func mouseDragged(with event: NSEvent) { mirror.touch(2, at: point(event)) }
    override func mouseUp(with event: NSEvent) { mirror.touch(1, at: point(event)) }
    override func rightMouseDown(with event: NSEvent) { mirror.key(4) }

    override func scrollWheel(with event: NSEvent) {
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
    let device: Device
    let serial: String
    @State private var dark = false
    @State private var fontScale = 1.0
    @State private var showTaps = false
    @State private var layoutBounds = false
    @State private var screen = ""

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: apply($dark) { "cmd uimode night \($0 ? "yes" : "no")" }) {
                    Text("Light").tag(false)
                    Text("Dark").tag(true)
                }
                .pickerStyle(.segmented)
                Picker("Font Size", selection: apply($fontScale) { "settings put system font_scale \($0)" }) {
                    ForEach([0.85, 1, 1.15, 1.3, 1.5, 1.8, 2], id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
                }
            }
            Section("Debug") {
                Toggle("Show Taps", isOn: apply($showTaps) { "settings put system show_touches \($0 ? 1 : 0)" })
                    .accessibilityLabel("Show Taps")
                // 1599295570 is SYSPROPS_TRANSACTION: makes running apps pick up the new property.
                Toggle("Layout Bounds", isOn: apply($layoutBounds) { "setprop debug.layout \($0); service call activity 1599295570" })
                    .accessibilityLabel("Layout Bounds")
            }
            Section("Device") {
                LabeledContent("Model", value: device.model)
                LabeledContent("Android", value: device.release)
                LabeledContent("API", value: device.api)
                LabeledContent("Screen", value: screen)
                LabeledContent("Serial", value: serial)
            }
        }
        .formStyle(.grouped)
        .inspectorColumnWidth(min: 240, ideal: 280)
        .task { await load() }
    }

    /// Binding that runs the adb shell command only when the user changes the value.
    private func apply<T>(_ value: Binding<T>, _ command: @escaping (T) -> String) -> Binding<T> {
        Binding(get: { value.wrappedValue }, set: { new in
            value.wrappedValue = new
            Task { await adb("-s", serial, "shell", command(new)) }
        })
    }

    private func load() async {
        func shell(_ cmd: String) async -> String {
            await adb("-s", serial, "shell", cmd).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        async let night = shell("cmd uimode night")
        async let scale = shell("settings get system font_scale")
        async let taps = shell("settings get system show_touches")
        async let bounds = shell("getprop debug.layout")
        async let size = shell("wm size")
        async let density = shell("wm density")
        dark = await night.hasSuffix("yes")
        fontScale = Double(await scale) ?? 1
        showTaps = await taps == "1"
        layoutBounds = await bounds == "true"
        let last = { (s: String) in s.split(separator: "\n").last?.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "" }
        screen = "\(last(await size).replacingOccurrences(of: "x", with: "×")) · \(last(await density)) dpi"
    }
}
