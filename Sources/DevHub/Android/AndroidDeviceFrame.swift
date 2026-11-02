import SwiftUI

/// Device frame drawn around the screen, sized from the video's pixel dimensions.
struct AndroidDeviceFrame<Content: View>: View {
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
