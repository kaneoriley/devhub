import SwiftUI
import CoreVideo

/// The outside edge of Apple's framebuffer mask, in normalized display coordinates.
/// Keep the native curve rather than fitting a circular or continuous corner radius.
struct SimulatorContour: Equatable {
    let points: [CGPoint]
    static let rectangle = SimulatorContour(points: [.zero, CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)])

    init(points: [CGPoint]) { self.points = points }

    init(buffer: CVPixelBuffer) {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let alpha: Int
        switch format {
        case kCVPixelFormatType_32BGRA, kCVPixelFormatType_32RGBA: alpha = 3
        case kCVPixelFormatType_32ARGB, kCVPixelFormatType_32ABGR: alpha = 0
        default: self = .rectangle; return
        }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { self = .rectangle; return }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let bytes = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { self = .rectangle; return }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        self.init(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)) { x, y in bytes[y * stride + x * 4 + alpha] }
    }

    init(width: Int, height: Int, alpha: (Int, Int) -> UInt8) {
        guard width > 0, height > 0 else { self = .rectangle; return }
        var left: [CGPoint] = [], right: [CGPoint] = []
        func append(_ point: CGPoint, to edge: inout [CGPoint]) {
            if edge.count >= 2 {
                let a = edge[edge.count - 2], b = edge[edge.count - 1]
                if abs((b.x - a.x) * (point.y - b.y) - (b.y - a.y) * (point.x - b.x)) < 0.001 { edge.removeLast() }
            }
            edge.append(point)
        }
        for y in 0..<height {
            // Only the outside silhouette belongs to the casing. Camera holes and
            // the Dynamic Island remain in the display mask, never in its bezel.
            guard let first = (0..<width).first(where: { alpha($0, y) >= 128 }),
                  let last = (first..<width).reversed().first(where: { alpha($0, y) >= 128 }) else { continue }
            let l = CGFloat(alpha(first, y)), r = CGFloat(alpha(last, y))
            let x0 = first == 0 ? 0 : CGFloat(first) + 0.5 - (l - 127.5) / (l - CGFloat(alpha(first - 1, y)))
            let x1 = last == width - 1 ? CGFloat(width) : CGFloat(last) + 0.5 + (r - 127.5) / (r - CGFloat(alpha(last + 1, y)))
            append(CGPoint(x: x0, y: CGFloat(y) + 0.5), to: &left)
            append(CGPoint(x: x1, y: CGFloat(y) + 0.5), to: &right)
        }
        guard let topLeft = left.first, let bottomLeft = left.last,
              let topRight = right.first, let bottomRight = right.last else { self = .rectangle; return }
        let outline = [CGPoint(x: topLeft.x, y: topLeft.y - 0.5)] + left +
            [CGPoint(x: bottomLeft.x, y: bottomLeft.y + 0.5), CGPoint(x: bottomRight.x, y: bottomRight.y + 0.5)] + right.reversed() +
            [CGPoint(x: topRight.x, y: topRight.y - 0.5)]
        points = outline.map { CGPoint(x: $0.x / CGFloat(width), y: $0.y / CGFloat(height)) }
    }

    func path(in rect: CGRect, rotation: QuarterTurn) -> Path {
        let inverse = QuarterTurn(-rotation.value)
        return Path { path in
            for (index, point) in points.enumerated() {
                let rotated = inverse.sourcePoint(point)
                let p = CGPoint(x: rect.minX + rotated.x * rect.width, y: rect.minY + rotated.y * rect.height)
                if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.closeSubpath()
        }
    }
}

/// Offset the native silhouette to keep a uniform bezel around every corner.
struct SimulatorFrame<Content: View>: View {
    let size: CGSize
    let contour: SimulatorContour
    let rotation: QuarterTurn
    @ViewBuilder let content: Content

    var body: some View {
        let bezel = min(size.width, size.height) * 0.02
        let outer = CGSize(width: size.width + bezel * 2, height: size.height + bezel * 2)
        GeometryReader { geo in
            let scale = geo.size.width / outer.width
            let border = bezel * scale
            let display = contour.path(in: CGRect(x: border, y: border, width: size.width * scale, height: size.height * scale), rotation: rotation)
            let shell = display.union(display.strokedPath(StrokeStyle(lineWidth: border * 2, lineCap: .round, lineJoin: .round)))
            let highlight = display.union(display.strokedPath(StrokeStyle(lineWidth: max(0.5, border * 2 - 3), lineJoin: .round)))
            ZStack {
                shell.fill(Color(white: 0.035))
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                shell.stroke(
                    LinearGradient(stops: [.init(color: Color(white: 0.48), location: 0),
                                           .init(color: Color(white: 0.22), location: 0.3),
                                           .init(color: Color(white: 0.13), location: 0.55),
                                           .init(color: Color(white: 0.38), location: 1)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5)
                highlight.stroke(.white.opacity(0.16), lineWidth: 0.5)
                content.frame(width: size.width * scale, height: size.height * scale)
                display.stroke(.white.opacity(0.14), lineWidth: 0.5).allowsHitTesting(false)
            }
            .overlay(alignment: .topTrailing) {
                if size.height > size.width {
                    let h = geo.size.height, w = max(1.5, border * 0.16)
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
