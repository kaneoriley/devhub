import SwiftUI

struct SettingsLabel: View {
    let title: String
    let icon: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
            Text(title)
        }
    }
}

/// Actions sit in the grouped form's footer, outside its cards.
struct SettingsFooterButton: View {
    let title: String
    var icon: String?
    var alignment: Alignment = .leading
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if let icon { Label(title, systemImage: icon) }
            else { Text(title) }
        }
        .font(.body)
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .frame(maxWidth: .infinity, alignment: alignment)
    }
}

/// DeviceHub's compact value-and-spinner presentation, with a native menu.
struct AppearanceControl: View {
    @Binding var dark: Bool
    var automatic = false
    var setAutomatic: (() -> Void)?
    var body: some View {
        Picker("Appearance", selection: Binding(get: { automatic ? "auto" : dark ? "dark" : "light" }, set: { value in
            if value == "auto" { setAutomatic?() } else { dark = value == "dark" }
        })) {
            Text("Light").tag("light")
            Text("Dark").tag("dark")
            if setAutomatic != nil { Text("Automatic").tag("auto") }
        }
        .labelsHidden().fixedSize()
        .accessibilityLabel("Appearance").accessibilityValue(automatic ? "Automatic" : dark ? "Dark" : "Light")
    }
}

struct TextSizeControl: View {
    @Binding var value: Double
    let count: Int
    let title: String
    let description: String
    let commit: () -> Void
    var body: some View {
        Slider(value: $value, in: 0...Double(count - 1), step: 1) { Text(title) }
            onEditingChanged: { editing in if !editing { commit() } }
            .labelsHidden().frame(width: 120)
            .help(description).accessibilityLabel(title).accessibilityValue(description)
    }
}
