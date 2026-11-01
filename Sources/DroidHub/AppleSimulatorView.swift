import SwiftUI
import AppKit

struct AppleSimulatorView: View {
    @Environment(Hub.self) private var hub
    let device: Device
    let simulator: AppleSimulator
    @State private var mirror: SimulatorMirror?
    @State private var sessionToken: UUID?
    @State private var failure: String?
    @State private var actionFailure: String?
    @State private var attempt = 0
    @State private var transferring = false
    @State private var transferStatus: String?
    @State private var transferID = UUID()
    @State private var targeted = false

    var body: some View {
        ZStack { content }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeOut(duration: 0.18), value: mirror?.isConnected == true && mirror?.hasFrame == true)
            .navigationTitle(device.name)
            .navigationSubtitle(simulator.runtime)
            .task(id: "\(simulator.state)#\(attempt)#\(hub.booting.contains(device.id))") {
                guard simulator.isBooted, !hub.booting.contains(device.id) else { return }
                let lease = hub.simulatorSessions.acquire(simulator.udid) { SimulatorMirror(simulator: simulator) }
                let session = lease.session
                mirror = session; sessionToken = lease.token; failure = nil
                defer {
                    hub.simulatorSessions.release(lease)
                    if sessionToken == lease.token { mirror = nil; sessionToken = nil }
                }
                do {
                    try await session.start()
                    while !Task.isCancelled { try await Task.sleep(for: .seconds(3600)) }
                } catch is CancellationError {} catch {
                    hub.simulatorSessions.discard(lease)
                    failure = String(describing: error)
                }
            }
            .onChange(of: mirror?.failure) { _, error in if let error { actionFailure = error } }
            .onChange(of: mirror?.foldFailure) { _, error in if let error { actionFailure = error } }
            .dropDestination(for: URL.self) { files, _ in receive(files) } isTargeted: { targeted = $0 }
            .overlay {
                if targeted && simulator.isBooted && !transferring {
                    RoundedRectangle(cornerRadius: 16).fill(.tint.opacity(0.12))
                        .strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [8]))
                        .overlay { Text("Drop apps to install or files to copy to Files → Downloads").padding(20).glassEffect(in: .rect(cornerRadius: 12)) }
                        .padding(16).allowsHitTesting(false)
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
            .alert("Simulator Action Failed", isPresented: Binding(get: { actionFailure != nil }, set: { if !$0 { actionFailure = nil } })) {
                Button("OK", role: .cancel) { actionFailure = nil }
            } message: { Text(actionFailure ?? "") }
            .toolbar {
                if let mirror, mirror.isConnected, mirror.hasFrame {
                    ToolbarItemGroup {
                        Button("Volume Down", systemImage: "speaker.wave.1") { mirror.button(0xea) }
                        Button("Volume Up", systemImage: "speaker.wave.3") { mirror.button(0xe9) }
                        Button("Power", systemImage: "power") { mirror.button(0x30) }
                    }
                }
            }
    }

    @ViewBuilder private var content: some View {
        if let mirror, mirror.isConnected, mirror.hasFrame {
            // Apple's masked IOSurface already supplies the exact camera cutout and
            // display contour. Keep its alpha instead of adding a second screen mask.
            SimulatorFrame(size: mirror.orientation.size(mirror.size), contour: mirror.contour, rotation: mirror.orientation) {
                SimulatorScreen(mirror: mirror)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(ScreenshotNotice(deviceID: device.id))
            .safeAreaInset(edge: .bottom) { controls(mirror) }
            .transition(.opacity)
        } else if let failure {
            ContentUnavailableView {
                Label("Couldn't Connect", systemImage: "exclamationmark.triangle")
            } description: { Text(failure) } actions: { Button("Retry") { attempt += 1 } }
        } else if simulator.isBooted || simulator.state == "Booting" || hub.booting.contains(device.id) {
            ProgressView("Connecting to \(device.name)…")
        } else {
            ContentUnavailableView {
                Label(device.name, systemImage: simulator.kind == .tablet ? "ipad" : "iphone")
            } description: { Text("The simulator is off.") } actions: {
                Button("Boot") { hub.boot(device) }.buttonStyle(.glassProminent)
            }
        }
    }

    private func controls(_ mirror: SimulatorMirror) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                control("Home", "square.grid.3x3.fill", action: mirror.home).keyboardShortcut("h", modifiers: [.command, .shift])
                control("App Switcher", "iphone.app.switcher", action: mirror.recents)
            }.padding(4).glassEffect(in: .capsule)
            control("Screenshot", "camera.viewfinder") {
                do { try hub.saveScreenshot(device, png: mirror.screenshot()) } catch { actionFailure = String(describing: error) }
            }.keyboardShortcut("s").padding(4).glassEffect(in: .circle)
            HStack(spacing: 2) {
                Button(action: mirror.rotate) { DeviceHubGlyph("device-rotate", size: 22).frame(width: 30, height: 30).contentShape(.rect) }
                    .buttonStyle(.plain).help("Rotate").accessibilityLabel("Rotate").keyboardShortcut(.rightArrow)
                if simulator.isFoldable {
                    Divider().frame(height: 18).padding(.horizontal, 4)
                    ForEach([true, false], id: \.self) { folded in
                        Button { mirror.fold(folded) } label: {
                            DeviceIcon(folded ? DeviceKind.phone : DeviceKind.tablet)
                                .foregroundStyle(mirror.folded == folded ? Color.accentColor : Color.primary)
                                .frame(width: 30, height: 30).contentShape(.rect)
                        }.buttonStyle(.plain).help(folded ? "Closed" : "Opened").accessibilityLabel(folded ? "Closed device" : "Opened device")
                            .accessibilityAddTraits(mirror.folded == folded ? .isSelected : [])
                    }
                }
            }.padding(4).glassEffect(in: .capsule)
        }.padding(.bottom, 16)
    }

    private func control(_ title: String, _ image: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: image).font(.system(size: 14, weight: .medium)).frame(width: 30, height: 30).contentShape(.rect) }
            .buttonStyle(.plain).help(title).accessibilityLabel(title)
    }
    private func receive(_ files: [URL]) -> Bool {
        guard simulator.isBooted, !transferring, !files.isEmpty else { return false }
        transferID = UUID(); transferring = true; transferStatus = "Transferring…"
        Task {
            defer { transferring = false }
            do { transferStatus = try await Simctl.transfer(files, udid: simulator.udid) }
            catch { transferStatus = nil; actionFailure = String(describing: error) }
        }
        return true
    }
}

struct SimulatorScreen: NSViewRepresentable {
    let mirror: SimulatorMirror
    func makeNSView(context: Context) -> SimulatorScreenView { SimulatorScreenView(mirror: mirror) }
    func updateNSView(_ view: SimulatorScreenView, context: Context) { view.rotation = mirror.orientation; view.needsLayout = true }
    static func dismantleNSView(_ view: SimulatorScreenView, coordinator: ()) { view.releaseInput() }
}

final class SimulatorScreenView: NSView, NSTextInputClient {
    private let mirror: SimulatorMirror
    var rotation = QuarterTurn.zero { didSet { if rotation != oldValue { releaseInput(); needsLayout = true } } }
    private var marked: String?
    private var scrollPoint: CGPoint?
    private var scrollEdge = SimulatorTouchEdge.none
    private var mousePoint: CGPoint?
    private var mouseEdge = SimulatorTouchEdge.none
    private var scrollEnd: Task<Void, Never>?
    private var pinching = false
    private var modifiers: Set<UInt32> = []
    private var twoFingers = false
    init(mirror: SimulatorMirror) {
        self.mirror = mirror
        super.init(frame: .zero)
        wantsLayer = true; layer?.addSublayer(mirror.layer)
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Simulator screen")
        NotificationCenter.default.addObserver(self, selector: #selector(releaseOnBlur), name: NSWindow.didResignKeyNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func releaseOnBlur() { releaseInput() }
    override func resignFirstResponder() -> Bool { releaseInput(); return true }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidMoveToWindow() { DispatchQueue.main.async { self.window?.makeFirstResponder(self) } }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        mirror.layer.bounds = CGRect(origin: .zero, size: rotation.size(bounds.size))
        mirror.layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        mirror.layer.setAffineTransform(CGAffineTransform(rotationAngle: rotation.radians))
        if let image = mirror.screenMask {
            let mask = mirror.layer.mask ?? CALayer()
            // AVSampleBufferDisplayLayer presents transparent video pixels as black.
            // Restore Apple's own static mask explicitly, including the camera cutout.
            mask.frame = mirror.layer.bounds
            mask.contents = image
            mask.contentsGravity = .resize
            mirror.layer.mask = mask
        }
        CATransaction.commit()
    }
    private func point(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return rotation.sourcePoint(CGPoint(x: min(max(p.x / bounds.width, 0), 1), y: min(max(p.y / bounds.height, 0), 1)))
    }
    private func touch(_ event: NSEvent, phase: Int) {
        let p = point(event)
        mousePoint = phase == 2 ? nil : p
        mirror.touch(p, phase: phase, edge: mouseEdge, second: twoFingers ? CGPoint(x: 1-p.x, y: 1-p.y) : nil)
    }
    private func edge(_ event: NSEvent) -> SimulatorTouchEdge {
        SimulatorTouchEdge.detect(at: convert(event.locationInWindow, from: nil), in: bounds.size).sourceEdge(rotation: rotation)
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        releaseTouches()
        twoFingers = event.modifierFlags.contains(.option)
        mouseEdge = twoFingers ? .none : edge(event)
        touch(event, phase: 0)
    }
    override func mouseDragged(with event: NSEvent) { if mousePoint != nil { touch(event, phase: 1) } }
    override func mouseUp(with event: NSEvent) { if mousePoint != nil { touch(event, phase: 2) }; twoFingers = false; mouseEdge = .none }
    override func rightMouseDown(with event: NSEvent) { mirror.home() }
    override func scrollWheel(with event: NSEvent) {
        scrollEnd?.cancel()
        guard mousePoint == nil, bounds.width > 0, bounds.height > 0 else { return }
        if scrollPoint == nil { scrollEdge = edge(event); scrollPoint = point(event); mirror.touch(scrollPoint!, phase: 0, edge: scrollEdge) }
        let delta = rotation.sourceVector(CGPoint(x: event.scrollingDeltaX / bounds.width, y: event.scrollingDeltaY / bounds.height))
        let next = CGPoint(x: min(max(scrollPoint!.x + delta.x, 0.01), 0.99), y: min(max(scrollPoint!.y + delta.y, 0.01), 0.99))
        scrollPoint = next; mirror.touch(next, phase: 1, edge: scrollEdge)
        scrollEnd = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            if let point = scrollPoint { mirror.touch(point, phase: 2, edge: scrollEdge) }; scrollPoint = nil; scrollEdge = .none
        }
    }
    override func keyDown(with event: NSEvent) { interpretKeyEvents([event]) }
    override func flagsChanged(with event: NSEvent) {
        let mapping: [(NSEvent.ModifierFlags, UInt32)] = [(.shift,0xe1),(.control,0xe0),(.option,0xe2),(.command,0xe3)]
        for (flag, usage) in mapping {
            let down = event.modifierFlags.contains(flag)
            if down != modifiers.contains(usage) { mirror.key(usage, pressed: down); if down { modifiers.insert(usage) } else { modifiers.remove(usage) } }
        }
    }
    private func releaseTouches() {
        scrollEnd?.cancel()
        if let point = scrollPoint { mirror.touch(point, phase: 2, edge: scrollEdge); scrollPoint = nil }
        if let point = mousePoint { mirror.touch(point, phase: 2, edge: mouseEdge, second: twoFingers ? CGPoint(x: 1-point.x, y: 1-point.y) : nil); mousePoint = nil }
        scrollEdge = .none; mouseEdge = .none; twoFingers = false
    }
    func releaseInput() {
        releaseTouches()
        for usage in modifiers { mirror.key(usage, pressed: false) }; modifiers = []
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers {
        case "v": paste(nil)
        case "c": mirror.copy()
        case "x": mirror.copy(cut: true)
        case "a": mirror.chord(0x04)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
    override func doCommand(by selector: Selector) {
        let map: [Selector: UInt32] = [#selector(deleteBackward(_:)):0x2a,#selector(deleteForward(_:)):0x4c,#selector(insertNewline(_:)):0x28,#selector(insertTab(_:)):0x2b,#selector(moveLeft(_:)):0x50,#selector(moveRight(_:)):0x4f,#selector(moveUp(_:)):0x52,#selector(moveDown(_:)):0x51,#selector(cancelOperation(_:)):0x29]
        if let usage = map[selector] { mirror.key(usage, pressed: true); mirror.key(usage, pressed: false) }
    }
    func insertText(_ string: Any, replacementRange: NSRange) { marked = nil; mirror.type((string as? NSAttributedString)?.string ?? string as? String ?? "") }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) { marked = (string as? NSAttributedString)?.string ?? string as? String }
    func unmarkText() { marked = nil }
    func hasMarkedText() -> Bool { marked != nil }
    func markedRange() -> NSRange { NSRange(location: marked == nil ? NSNotFound : 0, length: (marked as NSString?)?.length ?? 0) }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect { window?.convertToScreen(convert(bounds, to: nil)) ?? .zero }
    @objc func paste(_ sender: Any?) { if let text = NSPasteboard.general.string(forType: .string) { mirror.paste(text) } }
    @objc func copy(_ sender: Any?) { mirror.copy() }
    @objc func cut(_ sender: Any?) { mirror.copy(cut: true) }
    override func selectAll(_ sender: Any?) { mirror.chord(0x04) }
}
