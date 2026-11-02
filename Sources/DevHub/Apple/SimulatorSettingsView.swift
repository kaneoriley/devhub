import SwiftUI

struct SimulatorSettingsView: View {
    let settings: SimulatorSettingsState
    @State private var textIndex: Double

    init(settings: SimulatorSettingsState) {
        self.settings = settings
        _textIndex = State(initialValue: Double(settings.textIndex))
    }

    var body: some View {
        Form {
            Section {
                if settings.appearance?.dark != nil {
                    LabeledContent {
                        AppearanceControl(dark: Binding(get: { settings.appearance?.dark ?? false }, set: { apply(.appearance($0)) }))
                    } label: { SettingsLabel(title: "Appearance", icon: "circle.lefthalf.filled") }
                }
                if settings.appearance?.textSize != nil {
                    LabeledContent {
                        TextSizeControl(value: $textIndex, count: SimulatorAppearance.textSizes.count, title: "Text Size",
                                        description: SimulatorAppearance.textSizes[Int(textIndex)].replacingOccurrences(of: "-", with: " ").capitalized) {
                            apply(.textSize(Int(textIndex)))
                        }
                    } label: { SettingsLabel(title: "Text Size", icon: "textformat.size") }
                }
                if settings.appearance?.borders != nil {
                    Toggle(isOn: Binding(get: { settings.appearance?.borders ?? false }, set: { apply(.borders($0)) })) {
                        SettingsLabel(title: "Show Borders", icon: "square.on.square.dashed")
                    }
                }
                if settings.appearance == nil, settings.failure == nil { ProgressView().controlSize(.small) }
                if let failure = settings.failure { Text(failure).font(.caption).foregroundStyle(.red) }
            } footer: {
                SettingsFooterButton(title: "Reset to Defaults", icon: "arrow.counterclockwise", alignment: .trailing) {
                    Task { await settings.reset() }
                }
                .help("Restore Light appearance, Large text size, and Show Borders off.")
                .disabled(settings.appearance == nil || settings.saving)
            }.disabled(settings.appearance == nil || settings.saving)
        }
        .formStyle(.grouped).toggleStyle(.switch)
        .task { await settings.refresh() }
        .onChange(of: settings.appearance?.textSize) { _, _ in textIndex = Double(settings.textIndex) }
    }

    private func apply(_ change: SimulatorAppearance.Change) {
        Task { await settings.apply(change) }
    }
}
