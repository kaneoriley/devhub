import Foundation

/// Clockwise display rotation and coordinate transforms shared by both platforms.
struct QuarterTurn: Equatable {
    let value: Int
    init(_ value: Int) { self.value = (value % 4 + 4) % 4 }
    static let zero = QuarterTurn(0)
    var next: QuarterTurn { QuarterTurn(value + 1) }
    var radians: Double { Double(value) * .pi / 2 }
    var exifOrientation: Int32 { [1, 6, 3, 8][value] }

    func size(_ size: CGSize) -> CGSize { value % 2 == 0 ? size : CGSize(width: size.height, height: size.width) }

    func sourcePoint(_ point: CGPoint) -> CGPoint {
        switch value {
        case 1: CGPoint(x: point.y, y: 1 - point.x)
        case 2: CGPoint(x: 1 - point.x, y: 1 - point.y)
        case 3: CGPoint(x: 1 - point.y, y: point.x)
        default: point
        }
    }

    func sourceVector(_ vector: CGPoint) -> CGPoint {
        switch value {
        case 1: CGPoint(x: vector.y, y: -vector.x)
        case 2: CGPoint(x: -vector.x, y: -vector.y)
        case 3: CGPoint(x: -vector.y, y: vector.x)
        default: vector
        }
    }
}
