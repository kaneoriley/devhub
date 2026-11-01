import AppKit
import AVFoundation
import CoreImage
import Observation
import SimulatorBridge

struct AppleSimulator: Hashable {
    let udid: String
    let state: String
    let runtime: String
    let version: String
    let type: String
    let family: String
    var isBooted: Bool { state == "Booted" }
    var isFoldable: Bool { type.localizedCaseInsensitiveContains("Duo") }
    var kind: DeviceKind {
        if isFoldable { return .foldable }
        switch family { case "iPad": return .tablet; case "Apple Watch": return .watch; case "Apple TV": return .tv; case "Apple Vision": return .desktop; default: return .phone }
    }

    static func parse(_ data: Data, visibleDeviceIDs: Set<String>? = nil, defaultDeviceIDs: Set<String> = []) throws -> [Device] {
        struct Inventory: Decodable {
            struct Runtime: Decodable { let identifier: String; let name: String; let version: String; let isAvailable: Bool }
            struct Kind: Decodable { let identifier: String; let name: String; let productFamily: String? }
            struct Entry: Decodable { let udid: String; let name: String; let state: String; let deviceTypeIdentifier: String; let isAvailable: Bool; let lastUsedAt: String?; let lastBootedAt: String? }
            let devices: [String: [Entry]]
            let runtimes: [Runtime]
            let devicetypes: [Kind]
        }
        let inventory = try JSONDecoder().decode(Inventory.self, from: data)
        return inventory.devices.flatMap { runtimeID, entries -> [Device] in
            guard let runtime = inventory.runtimes.first(where: { $0.identifier == runtimeID && $0.isAvailable }) else { return [] }
            return entries.filter { entry in
                guard entry.isAvailable else { return false }
                if let visibleDeviceIDs { return visibleDeviceIDs.contains(entry.udid) }
                // Older toolchains lack CoreDevice's simulator inventory. Hide only
                // unused auto-created defaults; explicitly created devices remain visible.
                return !defaultDeviceIDs.contains(entry.udid) || entry.lastUsedAt != nil || entry.lastBootedAt != nil || ["Booted", "Booting"].contains(entry.state)
            }.map { entry in
                let type = inventory.devicetypes.first { $0.identifier == entry.deviceTypeIdentifier }
                let simulator = AppleSimulator(udid: entry.udid, state: entry.state, runtime: runtime.name, version: runtime.version,
                                               type: type?.name ?? entry.deviceTypeIdentifier, family: type?.productFamily ?? "iPhone")
                return Device(id: "simulator:\(entry.udid)", name: entry.name, detail: "Simulator", model: simulator.type,
                              release: runtime.version, api: runtime.version, kind: simulator.kind, simulator: simulator)
            }
        }.sorted { ($0.name, $0.api, $0.id) < ($1.name, $1.api, $1.id) }
    }

    static func list() async -> [Device] {
        async let discovery = AppleDevice.inventory()
        let result = try? await Simctl.run(["list", "--json"])
        let data = await discovery
        let physical = data.flatMap { try? AppleDevice.parse($0) } ?? []
        guard let result, result.status == 0 else { return physical }
        let visible = data.flatMap { try? publishedIDs($0) }
        return ((try? parse(Data(result.output.utf8), visibleDeviceIDs: visible, defaultDeviceIDs: defaultDeviceIDs())) ?? []) + physical
    }

    static func publishedIDs(_ data: Data) throws -> Set<String>? {
        struct Discovery: Decodable {
            struct Result: Decodable {
                struct Entry: Decodable {
                    struct Properties: Decodable {
                        struct State: Decodable { let visibilityClass: String? }
                        let state: State?
                    }
                    let identifier: String
                    let properties: Properties?
                }
                let devices: [Entry]
            }
            let result: Result
        }
        let devices = try JSONDecoder().decode(Discovery.self, from: data).result.devices
        // Missing classification means an older devicectl schema, not an empty list.
        let simulators = devices.filter { $0.properties?.state?.visibilityClass == "simulators" }
        guard !simulators.isEmpty else { return nil }
        return Set(simulators.map(\.identifier))
    }

    private static func defaultDeviceIDs() -> Set<String> {
        // CoreSimulator's default-device registry backs isDefaultCreatedDevice.
        let path = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Developer/CoreSimulator/Devices/device_set.plist")
        guard let data = try? Data(contentsOf: path),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let defaults = root["DefaultDevices"] as? [String: [String: String]] else { return [] }
        return Set(defaults.values.flatMap(\.values))
    }
}

enum Simctl {
    static func run(_ args: [String], input: Data? = nil) async throws -> ADBResult {
        try await runTool("simctl", args, input: input)
    }

    static func runTool(_ tool: String, _ args: [String], input: Data? = nil) async throws -> ADBResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process(), output = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                process.arguments = [tool] + args
                process.standardOutput = output; process.standardError = output
                let stdin = input.map { _ in Pipe() }
                process.standardInput = stdin ?? FileHandle.nullDevice
                do {
                    try process.run()
                    if let input, let stdin { stdin.fileHandleForWriting.write(input); try? stdin.fileHandleForWriting.close() }
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: ADBResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self)))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    static func developerDirectory() async throws -> String {
        let configured = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
        let path: String
        if let configured { path = configured }
        else { path = String(decoding: await exec("/usr/bin/xcode-select", ["-p"]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !path.isEmpty else { throw MirrorError("Install Xcode and select it with xcode-select to use Apple simulators.") }
        return path.hasSuffix(".app") ? path + "/Contents/Developer" : path
    }

    static func transfer(_ urls: [URL], udid: String) async throws -> String {
        guard !urls.isEmpty else { throw MirrorError("Drop a simulator .app, photos, videos, or contacts.") }
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        let apps = urls.filter { $0.pathExtension.lowercased() == "app" }
        let media = Set(["png", "jpg", "jpeg", "heic", "gif", "mov", "mp4", "m4v", "vcf"])
        guard apps.count == urls.count || (apps.isEmpty && urls.allSatisfy({ media.contains($0.pathExtension.lowercased()) })) else {
            throw MirrorError("Drop simulator .app bundles to install, or photos, videos, and contacts to import. Install apps and import media in separate drops.")
        }
        if !apps.isEmpty {
            for app in apps { try await run(["install", udid, app.path]).checked() }
            return apps.count == 1 ? "Installed \(apps[0].lastPathComponent)" : "Installed \(apps.count) apps"
        }
        try await run(["addmedia", udid] + urls.map(\.path)).checked()
        return "Imported \(urls.count) \(urls.count == 1 ? "file" : "files")"
    }
}

@Observable @MainActor final class SimulatorMirror: DeviceSession {
    let simulator: AppleSimulator
    let layer = AVSampleBufferDisplayLayer()
    var size = CGSize(width: 1080, height: 2400)
    var orientation = QuarterTurn.zero
    var contour = SimulatorContour.rectangle
    var screenIDs: [Int] = []
    var selectedScreen = 0
    var screenMask: CGImage?
    var failure: String?
    var isConnected = false
    var hasFrame: Bool { receivedFrame }
    var folded = false
    private var bridge: DHSimulatorBridge?
    private var receivedFrame = false
    private var closed = false
    private var active = false
    private var connection: Task<Void, Error>?
    private var format: CMVideoFormatDescription?
    private var textWorker: Task<Void, Never>?
    private var pendingText: [(text: String, paste: Bool)] = []

    init(simulator: AppleSimulator) {
        self.simulator = simulator
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = .black
        if simulator.kind == .tablet { size = CGSize(width: 2048, height: 2732) }
    }

    func start() async throws {
        if let connection { try await connection.value; return }
        let task = Task { @MainActor in try await connect() }
        connection = task
        try await task.value
    }

    private func connect() async throws {
        let directory = try await Simctl.developerDirectory()
        let native = try await Task.detached { try DHSimulatorBridge(deviceID: self.simulator.udid, developerDirectory: directory) }.value
        guard !closed, !Task.isCancelled else { return }
        bridge = native
        native.isPaused = !active
        native.followsActiveDisplays = simulator.isFoldable
        native.frameHandler = { [weak self] buffer, orientation, screen in
            Task { @MainActor in self?.display(buffer, orientation: orientation, screen: screen) }
        }
        native.errorHandler = { [weak self] message in Task { @MainActor in self?.failure = message } }
        try await Task.detached { try native.start() }.value
        guard !closed, !Task.isCancelled else { native.stop(); return }
        screenIDs = native.screenIDs.map(\.intValue)
        selectedScreen = native.selectedScreen
        isConnected = true
    }

    private func display(_ buffer: CVPixelBuffer, orientation reported: Int, screen: Int) {
        guard !closed, active else { return }
        let nextSize = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        let changedScreen = selectedScreen != screen
        if !receivedFrame || changedScreen {
            orientation = SimulatorOrientation.interface(reported)
            receivedFrame = true
        }
        selectedScreen = screen
        if simulator.isFoldable { folded = screen == 1 }
        if size != nextSize || format == nil {
            size = nextSize
            var description: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &description)
            format = description
            layer.sampleBufferRenderer.flush()
        }
        if changedScreen || screenMask == nil || screenMask?.width != Int(nextSize.width) || screenMask?.height != Int(nextSize.height) {
            screenMask = Self.alphaMask(buffer)
            contour = SimulatorContour(buffer: buffer)
        }
        guard let format else { return }
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: format,
                                                     sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        if layer.sampleBufferRenderer.status == .failed { layer.sampleBufferRenderer.flush() }
        layer.sampleBufferRenderer.enqueue(sample)
    }

    private static let maskContext = CIContext(options: [.cacheIntermediates: false])
    private static func alphaMask(_ buffer: CVPixelBuffer) -> CGImage? {
        let image = CIImage(cvPixelBuffer: buffer)
        return maskContext.createCGImage(image, from: image.extent)
    }

    func activate() {
        guard !closed else { return }
        active = true
        bridge?.isPaused = false
    }
    func deactivate() {
        active = false
        bridge?.isPaused = true
    }
    func stop() {
        closed = true; active = false; connection?.cancel(); connection = nil; textWorker?.cancel()
        bridge?.stop(); bridge = nil; isConnected = false
        layer.sampleBufferRenderer.flush()
    }
    func touch(_ point: CGPoint, phase: Int, second: CGPoint? = nil) {
        bridge?.touch(at: point, phase: phase, secondPoint: second.map { NSValue(point: $0) })
    }
    func key(_ usage: UInt32, pressed: Bool) { bridge?.key(usage, pressed: pressed) }
    func button(_ usage: UInt32) { bridge?.button(usage) }
    func home() { button(0x40) }
    func recents() { home(); Task { try? await Task.sleep(for: .milliseconds(120)); home() } }
    func rotate() {
        orientation = orientation.next
        bridge?.orient(SimulatorOrientation.device(orientation))
    }
    func fold(_ folded: Bool) { bridge?.setFolded(folded); self.folded = folded }
    func selectScreen(_ screen: Int) { bridge?.selectScreen(screen); selectedScreen = screen }
    func screenshot() throws -> Data {
        guard let buffer = layer.sampleBufferRenderer.displayedPixelBuffer() else { throw MirrorError("Wait for the simulator's first frame, then try again.") }
        return try Screenshot.png(from: buffer, rotation: orientation)
    }
    func type(_ text: String) {
        enqueueText(text, paste: false)
    }
    func paste(_ text: String) { enqueueText(text, paste: true) }
    private func enqueueText(_ text: String, paste: Bool) {
        guard !text.isEmpty, !closed else { return }
        pendingText.append((text, paste))
        guard textWorker == nil else { return }
        textWorker = Task { @MainActor in
            defer { textWorker = nil }
            while !pendingText.isEmpty, !closed, !Task.isCancelled {
                let request = pendingText.removeFirst()
                if !request.paste, request.text.count <= 128, let strokes = SimulatorKeyboard.strokes(request.text) {
                    for stroke in strokes {
                        if stroke.shift { key(0xe1, pressed: true) }
                        key(stroke.usage, pressed: true); key(stroke.usage, pressed: false)
                        if stroke.shift { key(0xe1, pressed: false) }
                    }
                    continue
                }
                do {
                    try await Simctl.run(["pbcopy", simulator.udid], input: Data(request.text.utf8)).checked()
                    guard !closed else { return }
                    chord(0x19)
                    try await Task.sleep(for: .milliseconds(60))
                } catch { failure = String(describing: error) }
            }
        }
    }
    func chord(_ usage: UInt32) { key(0xe3, pressed: true); key(usage, pressed: true); key(usage, pressed: false); key(0xe3, pressed: false) }
    func copy(cut: Bool = false) {
        chord(cut ? 0x1b : 0x06)
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            if let value = try? await Simctl.run(["pbpaste", simulator.udid]), value.status == 0 {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value.output, forType: .string)
            }
        }
    }
}

enum SimulatorKeyboard {
    struct Stroke: Equatable { let usage: UInt32; let shift: Bool }
    static func strokes(_ text: String) -> [Stroke]? {
        let unshifted = Array("abcdefghijklmnopqrstuvwxyz1234567890\n\u{1b}\u{8}\t -=[]\\;\u{27}`,./")
        let shifted = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ!@#$%^&*()\n\u{1b}\u{8}\t _+{}|:\"~<>?")
        let usages = Array(4..<50) + Array(51...56) // USB usage 50 is the non-US key.
        return text.reduce(into: Optional<[Stroke]>([])) { result, character in
            guard result != nil else { return }
            if let index = unshifted.firstIndex(of: character) { result!.append(Stroke(usage: UInt32(usages[index]), shift: false)) }
            else if let index = shifted.firstIndex(of: character) { result!.append(Stroke(usage: UInt32(usages[index]), shift: true)) }
            else { result = nil }
        }
    }
}

enum SimulatorOrientation {
    // The raw IOSurface stays in native coordinates. A landscape-right display
    // (reported as 3) needs a clockwise turn when presented in the host window.
    static func interface(_ value: Int) -> QuarterTurn { QuarterTurn([1: 0, 2: 2, 3: 1, 4: 3][value] ?? 0) }
    static func device(_ turn: QuarterTurn) -> Int { [1, 3, 2, 4][turn.value] }
}
