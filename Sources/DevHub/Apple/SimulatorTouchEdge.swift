import Foundation

/// Indigo's edge identifiers, shared by the legacy HID and modern digitizer transports.
enum SimulatorTouchEdge: Int {
    case none = 0, top = 1, left = 2, bottom = 3, right = 4

    static func detect(at point: CGPoint, in size: CGSize) -> Self {
        guard size.width > 0, size.height > 0,
              point.x >= 0, point.y >= 0, point.x <= size.width, point.y <= size.height else { return .none }
        let distances: [(Self, CGFloat)] = [(.top, point.y), (.left, point.x),
                                            (.bottom, size.height - point.y), (.right, size.width - point.x)]
        let nearest = distances.min { $0.1 < $1.1 }!
        return nearest.1 <= min(12, min(size.width, size.height) / 10) ? nearest.0 : .none
    }

    func sourceEdge(rotation: QuarterTurn) -> Self {
        guard self != .none else { return .none }
        let clockwise: [Self] = [.top, .right, .bottom, .left]
        let index = clockwise.firstIndex(of: self)!
        return clockwise[(index - rotation.value + 4) % 4]
    }
}
