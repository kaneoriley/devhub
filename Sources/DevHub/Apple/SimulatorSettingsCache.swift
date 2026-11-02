import Foundation
import Observation

/// Retain state independently of inspector/device views and share in-flight reads.
@Observable @MainActor final class SimulatorSettingsState {
    private(set) var appearance: SimulatorAppearance?
    private(set) var loading = false
    private(set) var saving = false
    private(set) var failure: String?
    private var query: Task<Void, Never>?
    private var revision = 0
    private var completedRevision: Int?
    private var updatedAt: Date?
    private var retired = false
    private let read: () async throws -> SimulatorAppearance
    private let write: (SimulatorAppearance, SimulatorAppearance.Change) async throws -> Void
    private let resetSettings: (SimulatorAppearance) async throws -> Void
    private let now: () -> Date

    init(read: @escaping () async throws -> SimulatorAppearance,
         write: @escaping (SimulatorAppearance, SimulatorAppearance.Change) async throws -> Void,
         reset: @escaping (SimulatorAppearance) async throws -> Void,
         now: @escaping () -> Date = Date.init) {
        self.read = read; self.write = write; resetSettings = reset; self.now = now
    }
    convenience init(id: String) {
        self.init(read: { try await SimulatorAppearance.load(id) },
                  write: { try await $0.apply($1, id: id) }, reset: { try await $0.reset(id: id) })
    }

    var textIndex: Int { appearance?.textSize.flatMap { SimulatorAppearance.textSizes.firstIndex(of: $0) } ?? 3 }

    func refresh(force: Bool = false) async {
        guard !retired else { return }
        if let query {
            await query.value
            if !force || completedRevision == revision { return }
        }
        guard !retired, !saving || force else { return }
        if !force, let updatedAt, now().timeIntervalSince(updatedAt) < 3 { return }
        loading = true
        let generation = revision
        let task = Task { @MainActor in
            defer { loading = false; query = nil }
            do {
                var value = try await read()
                guard !Task.isCancelled, generation == revision else { return }
                if value.modernCustomizationSupported == nil { value.modernCustomizationSupported = appearance?.modernCustomizationSupported }
                appearance = value; updatedAt = now(); completedRevision = generation; failure = nil
            } catch {
                guard !Task.isCancelled, generation == revision else { return }
                failure = String(describing: error)
            }
        }
        query = task
        await task.value
    }

    func apply(_ change: SimulatorAppearance.Change) async {
        guard let original = appearance, !saving, !retired else { return }
        revision += 1; saving = true; failure = nil
        var next = original
        switch change {
        case .appearance(let dark): next.dark = dark
        case .textSize(let index):
            guard SimulatorAppearance.textSizes.indices.contains(index) else { saving = false; return }
            next.textSize = SimulatorAppearance.textSizes[index]
        case .borders(let enabled): next.borders = enabled
        case .colorFilter(let filter):
            guard original.supportsColorFilter, filter != .unknown else { saving = false; return }
            next.colorFilter = filter
        case .liquidGlassOpacity(let opacity):
            guard original.supportsLiquidGlass, opacity.isFinite, (0...1).contains(opacity) else { saving = false; return }
            next.liquidGlassOpacity = opacity
        }
        appearance = next
        do {
            try await write(original, change)
            updatedAt = now(); completedRevision = revision
        } catch {
            appearance = original
            await refresh(force: true)
            failure = String(describing: error)
        }
        saving = false
    }

    func reset() async {
        guard let original = appearance, !saving, !retired else { return }
        revision += 1; saving = true; failure = nil
        do {
            try await resetSettings(original)
            var next = original
            if next.dark != nil { next.dark = false }
            if next.textSize != nil { next.textSize = "large" }
            if next.borders != nil { next.borders = false }
            if next.supportsColorFilter { next.colorFilter = SimulatorAppearance.ColorFilter.none }
            if next.supportsLiquidGlass { next.liquidGlassOpacity = SimulatorAppearance.defaultLiquidGlassOpacity }
            appearance = next; updatedAt = now(); completedRevision = revision
        } catch {
            await refresh(force: true)
            failure = String(describing: error)
        }
        saving = false
    }

    func cancel() { retired = true; revision += 1; query?.cancel() }
}

@MainActor final class SimulatorSettingsCache {
    private var entries: [String: SimulatorSettingsState] = [:]
    private let create: @MainActor (String) -> SimulatorSettingsState
    init(create: @escaping @MainActor (String) -> SimulatorSettingsState = { SimulatorSettingsState(id: $0) }) { self.create = create }

    func state(for id: String) -> SimulatorSettingsState {
        if let existing = entries[id] { return existing }
        let entry = create(id); entries[id] = entry
        return entry
    }
    func prepare(_ bootedIDs: Set<String>) {
        for id in Array(entries.keys) where !bootedIDs.contains(id) { entries.removeValue(forKey: id)?.cancel() }
        for id in bootedIDs {
            let entry = state(for: id)
            if entry.appearance == nil, !entry.loading { Task { await entry.refresh() } }
        }
    }
}
