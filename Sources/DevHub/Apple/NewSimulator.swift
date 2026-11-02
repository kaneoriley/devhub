import SwiftUI

struct NewSimulatorSheet: View {
    @Environment(Hub.self) private var hub
    @Environment(\.dismiss) private var dismiss
    @State private var catalog: SimulatorCatalog?
    @State private var selection = SimulatorCreationSelection()
    @State private var name = ""
    @State private var suggestedName = ""
    @State private var loading = true
    @State private var creating = false
    @State private var failure: String?

    private var runtime: SimulatorCatalog.Runtime? { catalog?.runtimes.first { $0.id == selection.runtimeID } }
    private var models: [SimulatorCatalog.Model] { runtime.flatMap { catalog?.models(for: $0).filter { $0.kind == selection.kind } } ?? [] }
    private var model: SimulatorCatalog.Model? { models.first { $0.id == selection.modelID } }

    var body: some View {
        VStack(spacing: 0) {
            Text("New iOS Simulator").font(.headline).padding(.top, 20)
            Form {
                Section {
                    Picker("Form Factor", selection: choice(\.kind)) {
                        ForEach(catalog?.kinds ?? [], id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("OS Version", selection: choice(\.runtimeID)) {
                        ForEach(catalog?.runtimes(for: selection.kind) ?? []) { Text($0.name).tag($0.id) }
                    }
                    Picker("Model", selection: choice(\.modelID)) {
                        ForEach(models) { Text($0.name).tag($0.id) }
                    }
                    TextField("Name", text: $name)
                } footer: {
                    if let failure { Text(failure).foregroundStyle(.red) }
                    else if !loading, catalog?.runtimes.isEmpty != false {
                        Text("No iOS simulator runtimes installed. Install one in Xcode Settings → Components.")
                    } else if !loading, models.isEmpty {
                        Text("No compatible iPhone or iPad models are available for this runtime.")
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(loading || creating)
            HStack {
                if loading || creating { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).disabled(creating)
                Button("Create", action: create).keyboardShortcut(.defaultAction)
                    .disabled(loading || creating || model == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding([.horizontal, .bottom], 20)
        }
        .frame(width: 460)
        .task {
            defer { loading = false }
            do {
                let loaded = try await SimulatorCatalog.load()
                catalog = loaded
                selection.reconcile(loaded)
                updateName()
            } catch { failure = String(describing: error) }
        }
    }

    private func choice<Value>(_ key: WritableKeyPath<SimulatorCreationSelection, Value>) -> Binding<Value> {
        Binding(get: { selection[keyPath: key] }, set: { value in
            guard let catalog else { return }
            var next = selection
            next[keyPath: key] = value
            next.reconcile(catalog)
            selection = next
            failure = nil
            updateName()
        })
    }

    private func updateName() {
        guard let model, let catalog else { return }
        let suggestion = catalog.uniqueName(for: model, runtimeID: selection.runtimeID)
        if name.isEmpty || name == suggestedName { name = suggestion }
        suggestedName = suggestion
    }

    private func create() {
        guard let catalog else { return }
        creating = true; failure = nil
        Task { @MainActor in
            defer { creating = false }
            do {
                try await hub.createSimulator(name: name, modelID: selection.modelID, runtimeID: selection.runtimeID, catalog: catalog)
                dismiss()
            } catch { failure = String(describing: error) }
        }
    }
}
