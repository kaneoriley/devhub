import Foundation
import Testing
@testable import DevHub

private let resizeConfig = "phone-0-1080-2400-420, foldable-1-2208-1840-420, tablet-2-1920-1200-240, desktop-3-1920-1080-160"
private let resizeUsage = "KO usage: \"resize-display <index>\" 0: phone\t1: unfolded\t2: tablet\r\n"

@Test func sidebarDeviceKindsFollowAVDHardware() {
    #expect(DeviceKind.from(config: ["hw.device.name": "pixel_10_pro_xl"]) == .phone)
    #expect(DeviceKind.from(config: ["hw.device.name": "pixel_tablet"]) == .tablet)
    #expect(DeviceKind.from(config: ["hw.lcd.width": "1600", "hw.lcd.height": "2560", "hw.lcd.density": "320"]) == .tablet)
    #expect(DeviceKind.from(config: ["hw.sensor.hinge": "yes", "hw.lcd.width": "2208", "hw.lcd.height": "1840", "hw.lcd.density": "420"]) == .foldable)
    #expect(DeviceKind.from(config: ["hw.sensor.hinge": "yes", "hw.resizable.configs": resizeConfig]) == .resizable)
    #expect(DeviceKind.from(config: ["tag.id": "android-tv"]) == .tv)
    #expect(DeviceKind.from(config: ["tag.id": "android-wear"]) == .watch)
    #expect(DeviceKind.from(config: ["tag.id": "android-automotive"]) == .automotive)
}

@Test func resizablePresetsRequireConfigurationAndRuntimeSupport() {
    let presets = DisplayPreset.available(config: resizeConfig, console: resizeUsage)
    #expect(presets.map(\.factor) == [.phone, .foldable, .tablet])
    #expect(presets.map(\.id) == [0, 1, 2])
    // A regular phone advertises exactly the same usage text as a Resizable AVD.
    #expect(DisplayPreset.available(config: "", console: resizeUsage).isEmpty)
    #expect(DisplayPreset.available(config: resizeConfig, console: "KO: unknown command").isEmpty)
    #expect(DisplayPreset.available(config: resizeConfig, console: "KO: device offline").isEmpty)
    #expect(DisplayPreset.available(config: resizeConfig, console: "usage: resize-display 0: phone 2: tablet").map(\.factor) == [.phone, .tablet])
    #expect(DisplayPreset.available(config: "tablet-2-1000-800-200", console: resizeUsage).map(\.factor) == [.tablet])
}

@Test func resizablePresetsValidateDimensionsAndMatchRotation() throws {
    let presets = DisplayPreset.parse(resizeConfig)
    let phone = try #require(presets.first { $0.factor == .phone })
    #expect(phone.matches(CGSize(width: 1080, height: 2400)))
    #expect(phone.matches(CGSize(width: 2400, height: 1080)))
    #expect(!phone.matches(CGSize(width: 2208, height: 1840)))
    #expect(DisplayPreset.parse("phone-0-0-2400-420, tablet-2-1920-1200-0, invalid, unknown-8-1-1-100").isEmpty)
    #expect(DisplayPreset.parse("unfolded-1-2208-1840-420").first?.factor == .foldable)
    #expect(DisplayPreset.parse("phone-0-1080-2400-420, phone-0-1080-2400-420").count == 1)
}

@Test func resizableEmulatorsKeepWindowAgentLoadedWithoutShowingAWindow() {
    let regular = Hub.bootArguments(avd: "Phone", config: [:])
    #expect(regular == ["-avd", "Phone", "-no-window", "-no-boot-anim"])
    let resizable = Hub.bootArguments(avd: "Resizable", config: ["hw.resizable.configs": resizeConfig])
    #expect(resizable == ["-avd", "Resizable", "-qt-hide-window", "-no-boot-anim"])
    #expect(!resizable.contains("-no-window"))
}

@Test func displayStateUsesEffectiveSizeAndDensity() throws {
    let state = try #require(DisplayState.parse(size: "Physical size: 1080x2400\nOverride size: 1920x1200\n",
                                              density: "Physical density: 420\nOverride density: 240\n"))
    let tablet = try #require(DisplayPreset.parse(resizeConfig).first { $0.factor == .tablet })
    #expect(state.matches(tablet))
    let wrongDensity = try #require(DisplayState.parse(size: "Physical size: 1920x1200\n", density: "Physical density: 420\n"))
    #expect(!wrongDensity.matches(tablet))
    #expect(DisplayState.parse(size: "device offline", density: "") == nil)
}

private actor ActionRecorder {
    var calls: [[String]] = []
    var results: [ToolResult]

    init(_ results: [ToolResult] = []) { self.results = results }

    func run(_ args: [String]) -> ToolResult {
        calls.append(args)
        return results.isEmpty ? ToolResult(status: 0, output: "OK\r\n") : results.removeFirst()
    }
}

private func testFiles(_ names: [String]) throws -> (URL, [URL]) {
    let directory = FileManager.default.temporaryDirectory.appending(path: "devhub-drop-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let files = names.map { directory.appending(path: $0) }
    for file in files { try Data("test".utf8).write(to: file) }
    return (directory, files)
}

@Test @MainActor func singleAPKInstallsOnCapturedSerial() async throws {
    let (directory, files) = try testFiles(["My App.APK"])
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = ActionRecorder()
    let actions = DeviceActions(run: { await recorder.run($0) })
    var progress: [String] = []
    let message = try await actions.transfer(files, serial: "emulator-5560") { progress.append($0) }
    #expect(await recorder.calls == [["-s", "emulator-5560", "install", "-r", "-t", "--user", "current", "--full", files[0].path]])
    #expect(message == "Installed My App.APK")
    #expect(progress == ["Installing My App.APK…"])
}

@Test @MainActor func multipleAPKsInstallAsOneSplitApp() async throws {
    let (directory, files) = try testFiles(["base.apk", "split_config.arm64_v8a.apk"])
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = ActionRecorder()
    let actions = DeviceActions(run: { await recorder.run($0) })
    _ = try await actions.transfer(files, serial: "phone") { _ in }
    #expect(await recorder.calls == [["-s", "phone", "install-multiple", "-r", "-t", "--user", "current", "--full"] + files.map(\.path)])
}

@Test @MainActor func otherFilesCopyToDownloadsWithoutShellInterpolation() async throws {
    let (directory, files) = try testFiles(["Photo with spaces.png", "quotes' dollar$ and `ticks`.txt"])
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = ActionRecorder()
    let actions = DeviceActions(run: { await recorder.run($0) })
    let message = try await actions.transfer(files, serial: "phone") { _ in }
    #expect(await recorder.calls == [
        ["-s", "phone", "shell", "mkdir", "-p", "/sdcard/Download"],
        ["-s", "phone", "push", files[0].path, "/sdcard/Download/Photo with spaces.png"],
        ["-s", "phone", "push", files[1].path, "/sdcard/Download/quotes' dollar$ and `ticks`.txt"],
    ])
    #expect(message == "Copied 2 files to Downloads")
}

@Test @MainActor func invalidDropsAreRejectedBeforeAnyDeviceChanges() async throws {
    let (directory, files) = try testFiles(["app.apk", "photo.png"])
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = ActionRecorder()
    let actions = DeviceActions(run: { await recorder.run($0) })
    for drop in [[], files, [directory], [files[1], directory.appending(path: "missing.txt")]] {
        await #expect(throws: (any Error).self) {
            _ = try await actions.transfer(drop, serial: "phone") { _ in }
        }
    }
    #expect(await recorder.calls.isEmpty)
}

@Test @MainActor func installErrorsAndPartialCopiesAreReported() async throws {
    let (directory, files) = try testFiles(["app.apk", "one.txt", "two.txt"])
    defer { try? FileManager.default.removeItem(at: directory) }
    let install = ActionRecorder([ToolResult(status: 1, output: "Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE]")])
    let installer = DeviceActions(run: { await install.run($0) })
    do {
        _ = try await installer.transfer([files[0]], serial: "phone") { _ in }
        Issue.record("Failed installation was reported as successful")
    } catch {
        #expect(String(describing: error).contains("INSTALL_FAILED_UPDATE_INCOMPATIBLE"))
    }
    let copy = ActionRecorder([ToolResult(status: 0, output: ""), ToolResult(status: 0, output: ""), ToolResult(status: 1, output: "device offline")])
    let copier = DeviceActions(run: { await copy.run($0) })
    do {
        _ = try await copier.transfer(Array(files.dropFirst()), serial: "phone") { _ in }
        Issue.record("Failed copy was reported as successful")
    } catch {
        #expect(String(describing: error).contains("1 of 2 files copied"))
        #expect(String(describing: error).contains("device offline"))
    }
}

@Test func resizeUsesConsolePresetIDAndDetectsKOWithZeroExitStatus() async throws {
    let preset = try #require(DisplayPreset.parse(resizeConfig).first { $0.factor == .tablet })
    let recorder = ActionRecorder([ToolResult(status: 0, output: "KO: resizable display is not enabled")])
    let actions = DeviceActions(run: { await recorder.run($0) })
    await #expect(throws: MirrorError.self) { try await actions.resize(preset, serial: "emulator-5554") }
    #expect(await recorder.calls == [["-s", "emulator-5554", "emu", "resize-display", "2"]])
}

@Test func resizeWaitsForDensityAndRepairsSnapshotMismatch() async throws {
    let tablet = try #require(DisplayPreset.parse(resizeConfig).first { $0.factor == .tablet })
    let recorder = ActionRecorder([
        ToolResult(status: 0, output: "OK"),
        ToolResult(status: 0, output: "Physical size: 1920x1200"),
        ToolResult(status: 0, output: "Physical density: 420"),
        ToolResult(status: 0, output: ""),
        ToolResult(status: 0, output: "Physical size: 1920x1200"),
        ToolResult(status: 0, output: "Physical density: 420\nOverride density: 240"),
    ])
    let actions = DeviceActions(run: { await recorder.run($0) }, pause: { _ in })
    try await actions.resize(tablet, serial: "emulator-5556")
    #expect(await recorder.calls == [
        ["-s", "emulator-5556", "emu", "resize-display", "2"],
        ["-s", "emulator-5556", "shell", "wm", "size"],
        ["-s", "emulator-5556", "shell", "wm", "density"],
        ["-s", "emulator-5556", "shell", "wm", "density", "240"],
        ["-s", "emulator-5556", "shell", "wm", "size"],
        ["-s", "emulator-5556", "shell", "wm", "density"],
    ])
}

@Test func initialStateReconcilesDensityWithActivePreset() async throws {
    let recorder = ActionRecorder([
        ToolResult(status: 0, output: "Physical size: 1080x2400"),
        ToolResult(status: 0, output: "Physical density: 420\nOverride density: 240"),
        ToolResult(status: 0, output: ""),
        ToolResult(status: 0, output: "Physical size: 1080x2400"),
        ToolResult(status: 0, output: "Physical density: 420"),
    ])
    let actions = DeviceActions(run: { await recorder.run($0) })
    let state = try await actions.synchronizeDisplay(presets: DisplayPreset.parse(resizeConfig), serial: "emulator-5556")
    let phone = try #require(DisplayPreset.parse(resizeConfig).first { $0.factor == .phone })
    #expect(state.matches(phone))
    #expect(await recorder.calls.contains(["-s", "emulator-5556", "shell", "wm", "density", "420"]))
}
