import SwiftUI

enum DeviceKind: String, CaseIterable {
    case phone, tablet, foldable, resizable, tv, watch, automotive, desktop

    var title: String { rawValue == "tv" ? "TV" : rawValue.capitalized }
}

/// A shared 20-point outline grid keeps sidebar and display controls consistent.
struct DeviceIcon: View {
    let kind: DeviceKind
    var filled = false
    var muted = false
    var simulator = false

    init(_ kind: DeviceKind, filled: Bool = false, muted: Bool = false, simulator: Bool = false) {
        self.kind = kind; self.filled = filled; self.muted = muted; self.simulator = simulator
    }
    init(_ factor: FormFactor) {
        kind = factor == .phone ? .phone : factor == .tablet ? .tablet : .foldable
    }

    var body: some View {
        Group {
            if !filled, let asset = controlAsset {
                DeviceHubGlyph(asset)
            } else {
            switch kind {
            case .phone, .tablet, .foldable, .resizable:
                ZStack {
                    if filled {
                        if muted {
                            DeviceOutline(kind: kind).fill(.primary.opacity(0.04))
                        } else {
                            DeviceOutline(kind: kind)
                                .fill(LinearGradient(colors: simulator ? [Color(red: 0.62, green: 0.86, blue: 1), Color(red: 0.2, green: 0.66, blue: 0.9)] : [Color(red: 0.68, green: 0.94, blue: 0.48), Color(red: 0.22, green: 0.68, blue: 0.36)], startPoint: .top, endPoint: .bottom))
                        }
                    }
                    DeviceOutline(kind: kind).stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                }
            case .tv: Image(systemName: "tv")
            case .watch: Image(systemName: "applewatch")
            case .automotive: Image(systemName: "car.side")
            case .desktop: Image(systemName: "desktopcomputer")
            }
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityLabel(kind.rawValue.capitalized)
    }

    private var controlAsset: String? {
        switch kind {
        case .phone: "device-phone"
        case .tablet: "device-tablet"
        case .foldable: "device-foldable"
        default: nil
        }
    }
}

/// Load the exported PDFs explicitly; SwiftUI's named-image lookup expects catalog assets.
struct DeviceHubGlyph: View {
    let name: String
    let size: CGFloat
    init(_ name: String, size: CGFloat = 17) { self.name = name; self.size = size }

    private var image: NSImage {
        guard let url = Bundle.module.url(forResource: name, withExtension: "pdf"),
              let image = NSImage(contentsOf: url) else {
            return NSImage(systemSymbolName: "questionmark.square", accessibilityDescription: nil)!
        }
        image.isTemplate = true
        return image
    }

    var body: some View {
        Image(nsImage: image).resizable().renderingMode(.template).scaledToFit().frame(width: size, height: size)
    }
}

struct DeviceBadge: View {
    let kind: DeviceKind
    let selected: Bool
    let running: Bool
    var simulator = false

    var body: some View {
        ZStack {
            Circle().fill(.white.opacity(selected ? (running ? 0.65 : 0.25) : (running ? 0.2 : 0.08)))
            DeviceIcon(kind, filled: true, muted: !running, simulator: simulator)
                .foregroundStyle(running ? AnyShapeStyle(.black.opacity(0.85)) : AnyShapeStyle(.primary.opacity(0.25)))
                .scaleEffect(1.15)
        }
        .frame(width: 32, height: 32)
        .accessibilityHidden(true)
    }
}

private struct DeviceOutline: Shape {
    let kind: DeviceKind

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch kind {
        case .phone:
            path.addRoundedRect(in: CGRect(x: 5, y: 2, width: 10, height: 16), cornerSize: CGSize(width: 2, height: 2))
            path.move(to: CGPoint(x: 9, y: 15.5)); path.addLine(to: CGPoint(x: 11, y: 15.5))
        case .tablet:
            path.addRoundedRect(in: CGRect(x: 1.5, y: 3.5, width: 17, height: 13), cornerSize: CGSize(width: 2, height: 2))
            path.move(to: CGPoint(x: 8, y: 14)); path.addLine(to: CGPoint(x: 12, y: 14))
        case .resizable:
            path.addEllipse(in: CGRect(x: 2.5, y: 2.5, width: 15, height: 15))
        case .foldable:
            path.move(to: CGPoint(x: 2, y: 3.5))
            path.addQuadCurve(to: CGPoint(x: 3.5, y: 2.5), control: CGPoint(x: 2, y: 2))
            path.addLine(to: CGPoint(x: 10, y: 3.5))
            path.addLine(to: CGPoint(x: 16.5, y: 2.5))
            path.addQuadCurve(to: CGPoint(x: 18, y: 3.5), control: CGPoint(x: 18, y: 2))
            path.addLine(to: CGPoint(x: 18, y: 16.5))
            path.addQuadCurve(to: CGPoint(x: 16.5, y: 17.5), control: CGPoint(x: 18, y: 18))
            path.addLine(to: CGPoint(x: 10, y: 16.5))
            path.addLine(to: CGPoint(x: 3.5, y: 17.5))
            path.addQuadCurve(to: CGPoint(x: 2, y: 16.5), control: CGPoint(x: 2, y: 18))
            path.closeSubpath()
            path.move(to: CGPoint(x: 10, y: 3.5)); path.addLine(to: CGPoint(x: 10, y: 16.5))
        default: break
        }
        return path.applying(CGAffineTransform(scaleX: rect.width / 20, y: rect.height / 20)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}
