import SwiftUI

struct SimulatorSettingsView: View {
    let settings: SimulatorSettingsState
    @State private var textIndex: Double
    @State private var glassOpacity: Double
    @State private var editingGlass = false

    init(settings: SimulatorSettingsState) {
        self.settings = settings
        _textIndex = State(initialValue: Double(settings.textIndex))
        _glassOpacity = State(initialValue: settings.appearance?.liquidGlassOpacity ?? SimulatorAppearance.defaultLiquidGlassOpacity)
    }

    var body: some View {
        Form {
            Section {
                if settings.appearance?.dark != nil {
                    LabeledContent {
                        AppearanceControl(dark: Binding(get: { settings.appearance?.dark ?? false }, set: { apply(.appearance($0)) }))
                    } label: { SettingsLabel(title: "Appearance", icon: "circle.lefthalf.filled") }
                }
                if settings.appearance?.supportsLiquidGlass == true {
                    LabeledContent {
                        Slider(value: $glassOpacity, in: 0...1) { Text("Liquid Glass") }
                            onEditingChanged: { editing in
                                editingGlass = editing
                                if !editing { apply(.liquidGlassOpacity(glassOpacity)) }
                            }
                            .labelsHidden().frame(width: 120).accessibilityLabel("Liquid Glass")
                            .accessibilityValue("\(Int(glassOpacity * 100))% opacity")
                            .help("Liquid Glass opacity: \(Int(glassOpacity * 100))%")
                    } label: { SettingsLabel(title: "Liquid Glass", icon: "rectangle.on.rectangle") }
                }
                if settings.appearance?.supportsColorFilter == true, let filter = settings.appearance?.colorFilter {
                    LabeledContent {
                        Picker("Color Filter", selection: Binding(get: { filter }, set: { apply(.colorFilter($0)) })) {
                            ForEach(SimulatorAppearance.ColorFilter.choices, id: \.self) { Text($0.title).tag($0) }
                            if filter == .unknown { Text("Other").tag(SimulatorAppearance.ColorFilter.unknown) }
                        }
                        .labelsHidden().lineLimit(1).truncationMode(.tail)
                        .frame(width: 130, alignment: .trailing)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Color Filter").help(filter.title)
                    } label: { SettingsLabel(title: "Color Filter", icon: "camera.filters") }
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
                .help("Restore Light appearance, Large text size, Color Filter and Show Borders off, and default Liquid Glass opacity where supported.")
                .disabled(settings.appearance == nil || settings.saving)
            }.disabled(settings.appearance == nil || settings.saving)
        }
        .formStyle(.grouped).toggleStyle(.switch)
        .task { await settings.refresh() }
        .onChange(of: settings.appearance?.textSize) { _, _ in textIndex = Double(settings.textIndex) }
        .onChange(of: settings.appearance?.liquidGlassOpacity) { _, value in
            if !editingGlass, let value { glassOpacity = value }
        }
    }

    private func apply(_ change: SimulatorAppearance.Change) {
        Task { await settings.apply(change) }
    }
}
