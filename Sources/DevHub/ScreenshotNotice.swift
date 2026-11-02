import SwiftUI

struct SavedScreenshot: Identifiable {
    let id = UUID()
    let deviceID: Device.ID
    let url: URL
    let thumbnail: NSImage?
}

/// Attach before the controls' safe-area inset to float just above their top edge.
struct ScreenshotNotice: ViewModifier {
    @Environment(Hub.self) private var hub
    let deviceID: Device.ID

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let saved = hub.savedScreenshot, saved.deviceID == deviceID {
                    Button { hub.revealScreenshot(saved) } label: {
                        HStack(spacing: 10) {
                            Group {
                                if let thumbnail = saved.thumbnail {
                                    Image(nsImage: thumbnail).resizable().scaledToFit()
                                } else { Image(systemName: "photo") }
                            }
                            .frame(width: 28, height: 30)
                            .background(.white, in: .rect(cornerRadius: 5))
                            .clipShape(.rect(cornerRadius: 5))
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Screenshot Saved").font(.system(size: 13, weight: .semibold))
                                Text("Open in Finder").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.primary.opacity(0.8), .primary.opacity(0.2))
                                .font(.system(size: 17))
                        }
                        .padding(.horizontal, 10)
                        .frame(width: 282, height: 48)
                        .contentShape(.rect(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .glassEffect(in: .rect(cornerRadius: 14))
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                    .help("Show \(saved.url.lastPathComponent) in Finder")
                    .accessibilityLabel("Screenshot Saved. Open in Finder")
                    .onHover { hub.screenshotHovered(saved.id, hovering: $0) }
                    .transition(.opacity.combined(with: .offset(y: 6)))
                }
            }
            .animation(.easeOut(duration: 0.18), value: hub.savedScreenshot?.id)
    }
}
