import Foundation
import Observation

struct AndroidSettingsSnapshot {
    static let fontScales = [0.85, 1, 1.15, 1.3, 1.5, 1.8, 2]
    var nightMode = "no"
    var fontScale = 1.0
    var showTaps = false
    var layoutBounds = false
    var runtime = AndroidUISettings()
    var fontIndex: Int { Self.fontScales.indices.min { abs(Self.fontScales[$0] - fontScale) < abs(Self.fontScales[$1] - fontScale) } ?? 1 }

    static func load(device: Device, presets: [DisplayPreset], previous: Self?, refreshCapabilities: Bool,
                     run: @escaping AndroidUISettings.Runner) async throws -> Self {
        guard let serial = device.serial else { throw MirrorError("The device is offline.") }
        @Sendable func read(_ command: [String]) async throws -> String {
            let result = try await run(["-s", serial, "shell"] + command)
            try result.checked()
            return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        async let night = read(["cmd", "uimode", "night"])
        async let scale = read(["settings", "get", "system", "font_scale"])
        async let taps = read(["settings", "get", "system", "show_touches"])
        async let bounds = read(["getprop", "debug.layout"])
        async let runtime = AndroidUISettings.load(serial: serial, kind: device.kind, presets: presets, previous: previous?.runtime,
                                                  refreshCapabilities: refreshCapabilities, run: run)
        let mode = try await night.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? ""
        return try await Self(nightMode: ["yes", "no", "auto"].contains(mode) ? mode : previous?.nightMode ?? "no",
                              fontScale: Double(scale) ?? 1, showTaps: taps == "1", layoutBounds: bounds == "true", runtime: runtime)
    }
}

@Observable @MainActor final class AndroidSettingsState {
    enum Change {
        case appearance(String), fontSize(Int), showTaps(Bool), layoutBounds(Bool)
        case navigation(AndroidUISettings.Navigation), talkBack(Bool), selectToSpeak(Bool), displaySize(Int)
    }
    private(set) var snapshot: AndroidSettingsSnapshot?
    private(set) var serial: String?
    private(set) var loading = false
    private(set) var saving = false
    private(set) var failure: String?
    @ObservationIgnored private var device: Device
    private var presets: [DisplayPreset] = []
    private var query: (id: UUID, task: Task<Void, Never>)?
    private var revision = 0
    private var completedRevision: Int?
    private var updatedAt: Date?
    private var capabilitiesUpdatedAt: Date?
    private var retired = false
    private let run: AndroidUISettings.Runner
    private let now: () -> Date
    private let recordDensity: (String, CGSize, Int) -> Void

    init(device: Device, run: @escaping AndroidUISettings.Runner = runADB, now: @escaping () -> Date = Date.init,
         recordDensity: @escaping (String, CGSize, Int) -> Void = { AndroidDisplaySizePreferences.record(deviceID: $0, size: $1, density: $2) }) {
        self.device = device; serial = device.serial; self.run = run; self.now = now; self.recordDensity = recordDensity
        loadPresets()
    }
    private func loadPresets() {
        presets = device.avd.map { DisplayPreset.parse(Hub.ini(SDK.avdDirectory($0).appending(path: "config.ini"))["hw.resizable.configs"] ?? "") } ?? []
    }
    var needsPrefetch: Bool { snapshot == nil || updatedAt == nil }
    func configure(_ device: Device) {
        let changed = self.device.serial != device.serial || self.device.kind != device.kind || self.device.avd != device.avd
        self.device = device
        guard changed else { return }
        revision += 1; query?.task.cancel(); query = nil; loading = false
        serial = device.serial; updatedAt = nil; capabilitiesUpdatedAt = nil
        loadPresets()
    }
    func refresh(force: Bool = false) async {
        guard !retired, serial != nil else { return }
        if let query {
            await query.task.value
            if !force || completedRevision == revision { return }
        }
        guard !retired, serial != nil, !saving || force else { return }
        if !force, let updatedAt, now().timeIntervalSince(updatedAt) < 3 { return }
        let probe = capabilitiesUpdatedAt.map { now().timeIntervalSince($0) >= 60 } ?? true
        let previous = snapshot, target = device, modes = presets, generation = revision, token = UUID()
        loading = true
        let task = Task { @MainActor in
            defer { if query?.id == token { loading = false; query = nil } }
            do {
                let result = try await AndroidSettingsSnapshot.load(device: target, presets: modes, previous: previous, refreshCapabilities: probe, run: run)
                guard !Task.isCancelled, generation == revision else { return }
                snapshot = result; updatedAt = now(); completedRevision = generation; failure = nil
                if probe { capabilitiesUpdatedAt = now() }
            } catch {
                guard !Task.isCancelled, generation == revision else { return }
                failure = String(describing: error)
            }
        }
        query = (token, task)
        await task.value
    }

    func apply(_ change: Change) async {
        guard let original = snapshot, let serial, !saving, !retired else { return }
        var next = original
        switch change {
        case .appearance(let mode):
            guard ["yes", "no", "auto"].contains(mode) else { return }
            next.nightMode = mode
        case .fontSize(let index):
            guard AndroidSettingsSnapshot.fontScales.indices.contains(index) else { return }
            next.fontScale = AndroidSettingsSnapshot.fontScales[index]
        case .showTaps(let on): next.showTaps = on
        case .layoutBounds(let on): next.layoutBounds = on
        case .navigation(let mode): next.runtime.navigation = mode
        case .talkBack(let on): next.runtime.talkBack = on
        case .selectToSpeak(let on): next.runtime.selectToSpeak = on
        case .displaySize(let index):
            guard let display = next.runtime.display, display.values.indices.contains(index) else { return }
            next.runtime.display?.currentDensity = display.values[index]
        }
        revision += 1; saving = true; failure = nil; snapshot = next
        let generation = revision, targetID = device.id
        do {
            let prefix = ["-s", serial, "shell"]
            switch change {
            case .appearance(let mode): try await run(prefix + ["cmd", "uimode", "night", mode]).checked()
            case .fontSize: try await run(prefix + ["settings", "put", "system", "font_scale", String(next.fontScale)]).checked()
            case .showTaps(let on): try await run(prefix + ["settings", "put", "system", "show_touches", on ? "1" : "0"]).checked()
            case .layoutBounds(let on):
                try await run(prefix + ["setprop", "debug.layout", on ? "true" : "false"]).checked()
                try await run(prefix + ["service", "call", "activity", "1599295570"]).checked()
            case .navigation(let mode): try await AndroidUISettings.setNavigation(mode, serial: serial, run: run)
            case .talkBack(let on): try await AndroidUISettings.setAccessibility(.talkBack, enabled: on, serial: serial, run: run)
            case .selectToSpeak(let on): try await AndroidUISettings.setAccessibility(.selectToSpeak, enabled: on, serial: serial, run: run)
            case .displaySize(let index):
                if let display = original.runtime.display {
                    try await display.apply(index: index, serial: serial, run: run)
                    recordDensity(targetID, display.screenSize, display.values[index])
                }
            }
            if generation == revision { updatedAt = now(); completedRevision = generation }
        } catch {
            if generation == revision {
                snapshot = original
                await refresh(force: true)
                failure = String(describing: error)
            }
        }
        saving = false
    }

    func reset() async {
        guard let original = snapshot, let serial, !saving, !retired else { return }
        revision += 1; saving = true; failure = nil
        let generation = revision
        do {
            try await AndroidSettingsDefaults.reset(serial: serial, settings: original.runtime, kind: device.kind, run: run)
            if generation == revision {
                if let display = original.runtime.display { recordDensity(device.id, display.screenSize, display.defaultDensity) }
                await refresh(force: true)
            }
        } catch {
            if generation == revision { await refresh(force: true); failure = String(describing: error) }
        }
        saving = false
    }
    func cancel() { retired = true; revision += 1; query?.task.cancel() }
}

@MainActor final class AndroidSettingsCache {
    private var entries: [String: AndroidSettingsState] = [:]
    private let create: @MainActor (Device) -> AndroidSettingsState
    init(create: @escaping @MainActor (Device) -> AndroidSettingsState = { AndroidSettingsState(device: $0) }) { self.create = create }
    func state(for device: Device) -> AndroidSettingsState {
        if let existing = entries[device.id] { existing.configure(device); return existing }
        let entry = create(device); entries[device.id] = entry
        return entry
    }
    func prepare(_ devices: [Device]) {
        let devices = devices.filter { $0.simulator == nil && $0.appleDevice == nil }
        let ids = Set(devices.map(\.id))
        for id in Array(entries.keys) where !ids.contains(id) { entries.removeValue(forKey: id)?.cancel() }
        for device in devices {
            let entry = state(for: device)
            if entry.serial != nil, entry.needsPrefetch, !entry.loading { Task { await entry.refresh() } }
        }
    }
}
