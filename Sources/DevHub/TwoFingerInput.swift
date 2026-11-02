import AppKit

struct TwoFingerPoints: Equatable {
    let first: CGPoint
    let second: CGPoint
}

enum TwoFingerPhase: Int { case began, moved, ended }

/// The pivot stays where Command was pressed, independently of the click position.
struct TwoFingerGesture {
    private(set) var focus: CGPoint?
    private(set) var points: TwoFingerPoints?
    private(set) var dragging = false

    mutating func enable(at point: CGPoint, size: CGSize) {
        guard focus == nil, size.width > 0, size.height > 0,
              point.x >= 0, point.y >= 0, point.x <= size.width, point.y <= size.height else { return }
        focus = point
        move(to: point, size: size)
    }

    mutating func move(to cursor: CGPoint, size: CGSize) {
        guard let focus else { return }
        let dx = cursor.x - focus.x, dy = cursor.y - focus.y
        // Clamp the pair together so its midpoint never drifts from the pivot.
        let roomX = max(0, min(focus.x, size.width - focus.x))
        let roomY = max(0, min(focus.y, size.height - focus.y))
        let scale = min(1, dx == 0 ? 1 : roomX / abs(dx), dy == 0 ? 1 : roomY / abs(dy))
        points = TwoFingerPoints(first: CGPoint(x: focus.x + dx * scale, y: focus.y + dy * scale),
                                 second: CGPoint(x: focus.x - dx * scale, y: focus.y - dy * scale))
    }

    mutating func begin() -> TwoFingerPoints? {
        guard let points, !dragging else { return nil }
        dragging = true
        return points
    }

    mutating func end() -> TwoFingerPoints? {
        guard dragging else { return nil }
        dragging = false
        return points
    }

    mutating func disable() -> TwoFingerPoints? {
        let end = end()
        focus = nil; points = nil
        return end
    }
}

/// Shared host input and preview for Android and Apple simulator screens.
@MainActor final class TwoFingerInput {
    private weak var view: NSView?
    private let send: (TwoFingerPoints, TwoFingerPhase) -> Void
    private let beginPreview: () -> Void
    private var modifierMonitor: Any?
    private let overlay = TwoFingerOverlay(frame: .zero)
    private var gesture = TwoFingerGesture()
    private var tracking: NSTrackingArea?
    private var capturedClick = false
    private var extent = CGSize.zero
    var active: Bool { gesture.focus != nil }
    var dragging: Bool { gesture.dragging }

    init(view: NSView, beginPreview: @escaping () -> Void = {}, send: @escaping (TwoFingerPoints, TwoFingerPhase) -> Void) {
        self.view = view; self.send = send; self.beginPreview = beginPreview
        overlay.isHidden = true
        view.addSubview(overlay)
        // Preview must also work when a search field or toolbar owns keyboard focus.
        modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            if let self, let window = self.view?.window, event.window === window {
                self.modifiersChanged(event.modifierFlags)
            }
            return event
        }
        NotificationCenter.default.addObserver(self, selector: #selector(blur(_:)), name: NSWindow.didResignKeyNotification, object: nil)
    }
    deinit {
        if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func blur(_ notification: Notification) {
        if notification.object as? NSWindow === view?.window { reset() }
    }

    func layout() {
        guard let view else { return }
        if extent != view.bounds.size { reset(); extent = view.bounds.size }
        overlay.frame = view.bounds
    }

    func updateTracking() {
        guard let view else { return }
        if let tracking { view.removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .enabledDuringMouseDrag], owner: view)
        tracking = area; view.addTrackingArea(area)
    }

    func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        guard let view, let window = view.window else { return }
        let cursor = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        update(flags: flags, cursor: cursor)
    }

    func hover(_ event: NSEvent) {
        guard let view else { return }
        update(flags: event.modifierFlags, cursor: view.convert(event.locationInWindow, from: nil))
    }

    func exited() { if !gesture.dragging { overlay.isHidden = true } }

    private func update(flags: NSEvent.ModifierFlags, cursor: CGPoint) {
        guard let view else { return }
        if flags.contains(.command) {
            let wasActive = active
            gesture.enable(at: cursor, size: view.bounds.size)
            if !wasActive && active { beginPreview() }
            if !gesture.dragging { gesture.move(to: cursor, size: view.bounds.size) }
            redraw(visible: view.bounds.contains(cursor) || gesture.dragging)
        } else {
            if let points = gesture.disable() { send(points, .ended) }
            redraw(visible: false)
        }
    }

    func mouseDown(_ event: NSEvent) -> Bool {
        hover(event)
        guard let view, active else { return false }
        gesture.move(to: view.convert(event.locationInWindow, from: nil), size: view.bounds.size)
        guard let points = gesture.begin() else { return false }
        capturedClick = true
        send(points, .began); redraw(visible: true)
        return true
    }

    func mouseDragged(_ event: NSEvent) -> Bool {
        guard capturedClick else { return false }
        if let view, gesture.dragging {
            gesture.move(to: view.convert(event.locationInWindow, from: nil), size: view.bounds.size)
            if let points = gesture.points { send(points, .moved) }
            redraw(visible: true)
        }
        return true
    }

    func mouseUp(_ event: NSEvent) -> Bool {
        guard capturedClick else { return false }
        _ = mouseDragged(event)
        if let points = gesture.end() { send(points, .ended) }
        capturedClick = false
        hover(event)
        return true
    }

    func reset() {
        if let points = gesture.disable() { send(points, .ended) }
        capturedClick = false
        redraw(visible: false)
    }

    private func redraw(visible: Bool) {
        overlay.focus = gesture.focus; overlay.points = gesture.points; overlay.pressed = gesture.dragging
        overlay.isHidden = !visible || gesture.focus == nil
        overlay.needsDisplay = true
    }
}

/// Draws above the video without intercepting any mouse events.
private final class TwoFingerOverlay: NSView {
    var focus: CGPoint?
    var points: TwoFingerPoints?
    var pressed = false
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let focus, let points else { return }
        NSColor.systemTeal.withAlphaComponent(0.7).setStroke()
        let guides = NSBezierPath()
        guides.move(to: points.first); guides.line(to: focus); guides.line(to: points.second)
        guides.lineWidth = 1; guides.stroke()
        for point in [points.first, points.second] {
            let circle = NSBezierPath(ovalIn: NSRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24))
            NSColor.systemTeal.withAlphaComponent(pressed ? 0.6 : 0.25).setFill(); circle.fill()
            NSColor.white.withAlphaComponent(0.9).setStroke(); circle.lineWidth = 2; circle.stroke()
        }
        NSColor.systemTeal.setStroke()
        let pivot = NSBezierPath(ovalIn: NSRect(x: focus.x - 4, y: focus.y - 4, width: 8, height: 8))
        pivot.lineWidth = 2; pivot.stroke()
        let cross = NSBezierPath()
        cross.move(to: CGPoint(x: focus.x - 7, y: focus.y)); cross.line(to: CGPoint(x: focus.x + 7, y: focus.y))
        cross.move(to: CGPoint(x: focus.x, y: focus.y - 7)); cross.line(to: CGPoint(x: focus.x, y: focus.y + 7))
        cross.stroke()
    }
}
