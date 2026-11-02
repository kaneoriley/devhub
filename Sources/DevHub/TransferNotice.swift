import SwiftUI

struct TransferNotice: View {
    let message: String
    let isTransferring: Bool
    let dismiss: () -> Void
    @State private var hovered = false

    private struct Dismissal: Equatable {
        let message: String
        let busy: Bool
        let hovered: Bool
    }

    var body: some View {
        HStack(spacing: 10) {
            if isTransferring { ProgressView().controlSize(.small) }
            else { Image(systemName: "checkmark.circle") }
            Text(message).lineLimit(2)
            if !isTransferring {
                Button("Dismiss", systemImage: "xmark", action: dismiss)
                    .labelStyle(.iconOnly).buttonStyle(.plain)
            }
        }
        .padding(12)
        .glassEffect(in: .rect(cornerRadius: 12))
        .padding(16)
        .accessibilityElement(children: .contain)
        .onHover { hovered = $0 }
        .task(id: Dismissal(message: message, busy: isTransferring, hovered: hovered)) {
            guard !isTransferring, !hovered else { return }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }
}
