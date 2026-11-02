import Foundation

/// Contacts in the displayed view's point coordinates; rotation is applied when sent.
struct SimulatorGestureContact {
    let point: CGPoint
    let second: CGPoint?
    let phase: Int
    init(_ point: CGPoint, second: CGPoint? = nil, phase: Int) {
        self.point = point; self.second = second; self.phase = phase
    }
}

struct SimulatorScrollGesture {
    private(set) var point: CGPoint?

    static func delta(x: Double, y: Double, precise: Bool) -> CGPoint {
        let scale = precise ? 1.0 : 48.0
        return CGPoint(x: x * scale, y: y * scale)
    }

    mutating func move(at cursor: CGPoint, delta: CGPoint, size: CGSize) -> [SimulatorGestureContact] {
        guard size.width > 2, size.height > 2, delta != .zero else { return [] }
        func clamp(_ p: CGPoint) -> CGPoint {
            CGPoint(x: min(max(p.x, 1), size.width - 1), y: min(max(p.y, 1), size.height - 1))
        }
        var contacts: [SimulatorGestureContact] = []
        if point == nil { point = clamp(cursor); contacts.append(.init(point!, phase: 0)) }
        let current = point!
        let target = clamp(CGPoint(x: current.x + delta.x, y: current.y + delta.y))
        // Start another swipe under the pointer once this contact reaches an edge.
        // Keeping the old contact pinned there makes further wheel events ineffective.
        if target == current {
            contacts.append(.init(current, phase: 2))
            point = clamp(cursor)
            contacts.append(.init(point!, phase: 0))
        }
        let next = clamp(CGPoint(x: point!.x + delta.x, y: point!.y + delta.y))
        point = next
        contacts.append(.init(next, phase: 1))
        return contacts
    }

    mutating func end() -> [SimulatorGestureContact] {
        defer { point = nil }
        return point.map { [.init($0, phase: 2)] } ?? []
    }
}

struct SimulatorPinchGesture {
    private(set) var centre: CGPoint?
    private var radius: CGFloat = 0
    private var limit: CGFloat = 0

    mutating func magnify(at cursor: CGPoint, amount: CGFloat, size: CGSize) -> [SimulatorGestureContact] {
        guard size.width > 8, size.height > 8, amount.isFinite, amount != 0 else { return [] }
        var contacts: [SimulatorGestureContact] = []
        if centre == nil {
            // Keep the pivot under the pointer while leaving room for both contacts.
            let margin = min(16.0, size.width / 4)
            let centre = CGPoint(x: min(max(cursor.x, margin), size.width - margin), y: min(max(cursor.y, 1), size.height - 1))
            self.centre = centre
            limit = min(centre.x - 1, size.width - 1 - centre.x)
            radius = min(min(size.width, size.height) * 0.12, limit * 0.5)
            contacts.append(contact(phase: 0))
        }
        radius = min(max(radius * max(1 + amount, 0.1), 2), limit)
        contacts.append(contact(phase: 1))
        return contacts
    }

    mutating func end() -> [SimulatorGestureContact] {
        guard centre != nil else { return [] }
        let end = contact(phase: 2)
        centre = nil
        return [end]
    }

    private func contact(phase: Int) -> SimulatorGestureContact {
        let centre = centre!
        return .init(CGPoint(x: centre.x - radius, y: centre.y), second: CGPoint(x: centre.x + radius, y: centre.y), phase: phase)
    }
}
