import SwiftUI

struct AndroidSettingsView: View {
    let settings: AndroidSettingsState
    var refreshDensity: () async -> Void
    @State private var fontIndex: Double
    @State private var displayIndex: Double
    @State private var editingDisplaySize = false

    init(settings: AndroidSettingsState, refreshDensity: @escaping () async -> Void = {}) {
        self.settings = settings; self.refreshDensity = refreshDensity
        _fontIndex = State(initialValue: Double(settings.snapshot?.fontIndex ?? 1))
        _displayIndex = State(initialValue: Double(settings.snapshot?.runtime.display?.index ?? 0))
    }

    var body: some View {
        Form {
            if let snapshot = settings.snapshot {
                let runtime = snapshot.runtime
                Section {
                    LabeledContent {
                        AppearanceControl(dark: Binding(get: { snapshot.nightMode == "yes" }, set: { change(.appearance($0 ? "yes" : "no")) }),
                                          automatic: snapshot.nightMode == "auto", setAutomatic: { change(.appearance("auto")) })
                    } label: { SettingsLabel(title: "Appearance", icon: "circle.lefthalf.filled") }
                    if runtime.navigation != nil {
                        LabeledContent {
                            Picker("Navigation Mode", selection: Binding(get: { runtime.navigation ?? .gestures }, set: { change(.navigation($0)) })) {
                                ForEach(AndroidUISettings.Navigation.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }.labelsHidden().fixedSize().accessibilityLabel("Navigation Mode")
                        } label: { SettingsLabel(title: "Navigation Mode", icon: "hand.draw") }
                    }
                    if runtime.talkBackAvailable {
                        Toggle(isOn: Binding(get: { runtime.talkBack }, set: { change(.talkBack($0)) })) {
                            SettingsLabel(title: "TalkBack", icon: "voiceover")
                        }
                    }
                    if runtime.selectToSpeakAvailable {
                        Toggle(isOn: Binding(get: { runtime.selectToSpeak }, set: { change(.selectToSpeak($0)) })) {
                            SettingsLabel(title: "Select to Speak", icon: "text.bubble")
                        }
                    }
                    LabeledContent {
                        TextSizeControl(value: $fontIndex, count: AndroidSettingsSnapshot.fontScales.count, title: "Font Size",
                                        description: "\(Int(AndroidSettingsSnapshot.fontScales[Int(fontIndex)] * 100))%") {
                            change(.fontSize(Int(fontIndex)))
                        }
                    } label: { SettingsLabel(title: "Font Size", icon: "textformat.size") }
                    if let display = runtime.display, display.values.count > 1 {
                        LabeledContent {
                            Slider(value: $displayIndex, in: 0...Double(display.values.count - 1), step: 1) { Text("Display Size") }
                                onEditingChanged: { editing in
                                    editingDisplaySize = editing
                                    if !editing { change(.displaySize(Int(displayIndex))) }
                                }
                                .labelsHidden().frame(width: 120).accessibilityLabel("Display Size")
                                .accessibilityValue(displayDescription(display)).help(displayDescription(display))
                        } label: { SettingsLabel(title: "Display Size", icon: "display") }
                    }
                    Toggle(isOn: Binding(get: { snapshot.showTaps }, set: { change(.showTaps($0)) })) {
                        SettingsLabel(title: "Show Taps", icon: "hand.tap")
                    }.accessibilityLabel("Show Taps")
                    Toggle(isOn: Binding(get: { snapshot.layoutBounds }, set: { change(.layoutBounds($0)) })) {
                        SettingsLabel(title: "Layout Bounds", icon: "square.on.square.dashed")
                    }.accessibilityLabel("Layout Bounds")
                } footer: {
                    SettingsFooterButton(title: "Reset to Defaults", icon: "arrow.counterclockwise", alignment: .trailing) {
                        Task { await settings.reset(); await refreshDensity() }
                    }
                    .help("Restore default appearance and display size, gesture navigation where supported, 100% font size, and turn TalkBack, Select to Speak, Show Taps and Layout Bounds off.")
                    if let failure = settings.failure { Text(failure).font(.caption).foregroundStyle(.red) }
                }.disabled(settings.serial == nil || settings.saving)
            } else if let failure = settings.failure {
                Text(failure).foregroundStyle(.red)
            } else if settings.serial != nil {
                ProgressView("Loading Settings…").controlSize(.small)
            } else {
                Text("Boot the device to load its settings.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).toggleStyle(.switch)
        .onChange(of: settings.snapshot?.fontScale) { _, _ in fontIndex = Double(settings.snapshot?.fontIndex ?? 1) }
        .onChange(of: settings.snapshot?.runtime.display) { _, display in
            if !editingDisplaySize { displayIndex = Double(display?.index ?? 0) }
        }
        .task(id: settings.serial) {
            guard settings.serial != nil else { return }
            while !Task.isCancelled {
                if !settings.saving && !editingDisplaySize {
                    let previous = settings.snapshot?.runtime.display?.currentDensity
                    await settings.refresh()
                    if previous != settings.snapshot?.runtime.display?.currentDensity { await refreshDensity() }
                }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }
    private func change(_ change: AndroidSettingsState.Change) {
        Task { await settings.apply(change); await refreshDensity() }
    }
    private func displayDescription(_ display: AndroidDisplaySize) -> String {
        let index = min(max(0, Int(displayIndex)), display.values.count - 1)
        let value = display.values[index]
        return value == display.defaultDensity ? "Default · \(value) dpi" : "\(Int((Double(value) / Double(display.defaultDensity) * 100).rounded()))% · \(value) dpi"
    }
}
