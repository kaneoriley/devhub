import SwiftUI
import AppKit
import CoreImage

struct AndroidScreen: NSViewRepresentable {
    let mirror: Mirror
    let rotation: QuarterTurn
    let colorFilter: Int?
    let acceptsFiles: Bool
    let receiveFiles: ([URL]) -> Bool
    let dropTargeted: (Bool) -> Void

    func makeNSView(context: Context) -> AndroidScreenView {
        let view = AndroidScreenView(mirror: mirror)
        updateNSView(view, context: context)
        return view
    }

    static func dismantleNSView(_ view: AndroidScreenView, coordinator: ()) { view.releaseInput() }

    func updateNSView(_ view: AndroidScreenView, context: Context) {
        view.rotation = rotation
        view.colorFilter = colorFilter
        view.acceptsFiles = acceptsFiles
        view.receiveFiles = receiveFiles
        view.dropTargeted = dropTargeted
    }
}

/// Hosts the video layer and turns mouse and keyboard input into Android events.
final class AndroidScreenView: NSView {
    private let mirror: Mirror
    var colorFilter: Int? {
        didSet {
            guard colorFilter != oldValue else { return }
            let parameters = AndroidColorTransform(mode: colorFilter)?.parameters
            layer?.filters = parameters.flatMap { CIFilter(name: "CIColorMatrix", parameters: $0) }.map { [$0] }
            mirror.colorMatrix = parameters
        }
    }
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
extension AndroidScreenView: NSTextInputClient {
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
