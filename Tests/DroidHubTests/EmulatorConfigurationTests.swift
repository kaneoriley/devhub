import Foundation
import Testing
@testable import DroidHub

private func configurationDirectory(_ config: String = "") throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "DroidHubConfigurationTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try config.write(to: url.appending(path: "config.ini"), atomically: true, encoding: .utf8)
    return url
}
private let basicAVD = """
# Keep custom settings
hw.device.name=custom_phone
hw.camera.front=webcam2
hw.camera.back=virtualscene
hw.initialOrientation=landscape
hw.ramSize=2048
vm.heapSize=288
disk.dataPartition.size=10G
runtime.network.speed=123:456
custom.option=leave me alone
fastboot.forceChosenSnapshotBoot=yes
fastboot.chosenSnapshotFile=my-snapshot
""" + "\n"

@Test func emulatorCapacityParsesSDKUnitsWithoutOverflow() {
    #expect(EmulatorCapacity(ini: "10G", defaultBytes: 0).bytes == 10 << 30)
    #expect(EmulatorCapacity(ini: "10737418240", defaultBytes: 0).bytes == 10 << 30)
    #expect(EmulatorCapacity(ini: "2048", defaultBytes: 0, unsuffixedUnit: .mb).bytes == 2 << 30)
    var huge = EmulatorCapacity(Int64.max, .tb)
    #expect(huge.bytes == nil)
    huge.amount = "-1"
    #expect(huge.bytes == nil)
}

@Test func emulatorConfigPreservesLegacySettingsAndClearsSnapshotSelection() throws {
    let directory = try configurationDirectory(basicAVD)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = try EmulatorConfigurationFile(directory: directory)
    var value = file.original
    value.boot = "cold"
    let text = EmulatorINI.updating(file.configText, with: value.configChanges(from: file.original))
    #expect(text.contains("hw.camera.front=webcam2\n"))
    #expect(text.contains("runtime.network.speed=123:456\n"))
    #expect(text.contains("# Keep custom settings\n"))
    #expect(text.contains("custom.option=leave me alone\n"))
    #expect(text.contains("fastboot.forceColdBoot=yes\n"))
    #expect(text.contains("fastboot.forceFastBoot=no\n"))
    #expect(text.contains("fastboot.forceChosenSnapshotBoot=no\n"))
    #expect(text.contains("fastboot.chosenSnapshotFile=\n"))
    #expect(file.original.configChanges(from: file.original).isEmpty)
}

@Test func emulatorCompatibilityUsesProfileAndAllImageABIs() async throws {
    let directory = try configurationDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try """
    <localPackage><type-details><abi>x86_64</abi><abis>x86_64</abis><abis>x86</abis><translatedAbi>arm64-v8a</translatedAbi><translatedAbis>armeabi-v7a</translatedAbis></type-details></localPackage>
    """.write(to: directory.appending(path: "package.xml"), atomically: true, encoding: .utf8)
    let profiles = await DeviceProfile.load()
    let phone = try #require(profiles.first { $0.id == "pixel_10" })
    let compatible = EmulatorCompatibility(profile: phone, config: [:], imageDirectory: directory)
    #expect(compatible.frontCamera && compatible.rearCamera)
    #expect(compatible.orientations == ["portrait", "landscape"])
    #expect(compatible.abis == ["x86_64", "x86", "arm64-v8a", "armeabi-v7a"])
    let wearable = EmulatorCompatibility(profile: nil, config: ["tag.id": "android-wear"], imageDirectory: nil)
    #expect(!wearable.expandedStorage)
    #expect(!wearable.frontCamera && !wearable.rearCamera)
}

@Test func emulatorConfigValidatesChangedValuesAndKeepsLegacyCapacities() throws {
    let compatible = EmulatorCompatibility(profile: nil, config: ["abi.type": "arm64-v8a"], imageDirectory: nil)
    var old = EmulatorConfiguration()
    old.storage = EmulatorCapacity(1, .gb)
    old.cores = 64
    var value = old
    value.latency = "edge"
    try value.validate(compatibility: compatible, original: old)
    value.storage = EmulatorCapacity(2, .gb)
    #expect(throws: MirrorError.self) { try value.validate(compatibility: compatible, original: old) }
    value = old; value.preferredABI = "x86_64"
    #expect(throws: MirrorError.self) { try value.validate(compatibility: compatible, original: old) }
    value = old; value.expanded = "custom"; value.sdSize = EmulatorCapacity(4, .mb)
    #expect(throws: MirrorError.self) { try value.validate(compatibility: compatible, original: old) }
}

@Test func offlineEmulatorConfigSavesAndPreservesUnrelatedUserSettings() async throws {
    let directory = try configurationDirectory(basicAVD)
    defer { try? FileManager.default.removeItem(at: directory) }
    try "window.zoom=2\nabi.type.preferred=arm64-v8a\n".write(to: directory.appending(path: "user-settings.ini"), atomically: true, encoding: .utf8)
    let file = try EmulatorConfigurationFile(directory: directory)
    var value = file.original
    value.speed = "lte"; value.ram = EmulatorCapacity(4, .gb); value.heap = EmulatorCapacity(512, .mb); value.preferredABI = ""
    try await file.save(value, compatibility: EmulatorCompatibility(profile: nil, config: file.config, imageDirectory: nil), isRunning: { false })
    let config = Hub.ini(directory.appending(path: "config.ini"))
    #expect(config["hw.ramSize"] == "4096")
    #expect(config["vm.heapSize"] == "512")
    #expect(config["runtime.network.speed"] == "lte")
    #expect(config["custom.option"] == "leave me alone")
    let user = Hub.ini(directory.appending(path: "user-settings.ini"))
    #expect(user["window.zoom"] == "2")
    #expect(user["abi.type.preferred"] == nil)
}

@Test func emulatorConfigRejectsRunningDeviceAndExternalChanges() async throws {
    let directory = try configurationDirectory(basicAVD)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = try EmulatorConfigurationFile(directory: directory)
    let compatible = EmulatorCompatibility(profile: nil, config: file.config, imageDirectory: nil)
    var value = file.original; value.speed = "edge"
    await #expect(throws: MirrorError.self) { try await file.save(value, compatibility: compatible, isRunning: { true }) }
    #expect(try String(contentsOf: directory.appending(path: "config.ini"), encoding: .utf8) == basicAVD)
    try "external.change=yes\n".write(to: directory.appending(path: "config.ini"), atomically: true, encoding: .utf8)
    await #expect(throws: MirrorError.self) { try await file.save(value, compatibility: compatible, isRunning: { false }) }
    #expect(Hub.ini(directory.appending(path: "config.ini"))["external.change"] == "yes")
}

@Test func emulatorCardCreationFailureLeavesConfigurationAndCardUntouched() async throws {
    let directory = try configurationDirectory(basicAVD + "sdcard.size=10M\nhw.sdCard=yes\n")
    defer { try? FileManager.default.removeItem(at: directory) }
    let previous = Data("existing card contents".utf8)
    try previous.write(to: directory.appending(path: "sdcard.img"))
    let file = try EmulatorConfigurationFile(directory: directory)
    var value = file.original; value.sdSize = EmulatorCapacity(20, .mb)
    #expect(file.replacesCard(value))
    await #expect(throws: MirrorError.self) {
        try await file.save(value, compatibility: EmulatorCompatibility(profile: nil, config: file.config, imageDirectory: nil), isRunning: { false }, createCard: { _, _ in throw MirrorError("disk full") })
    }
    #expect(try Data(contentsOf: directory.appending(path: "sdcard.img")) == previous)
    #expect(try String(contentsOf: directory.appending(path: "config.ini"), encoding: .utf8) == file.configText)
}

@Test func emulatorRechecksStateAfterCardGenerationAndRetainsExistingCard() async throws {
    let directory = try configurationDirectory(basicAVD)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = try EmulatorConfigurationFile(directory: directory)
    var value = file.original; value.expanded = "custom"; value.sdSize = EmulatorCapacity(10, .mb)
    var started = false
    await #expect(throws: MirrorError.self) {
        try await file.save(value, compatibility: EmulatorCompatibility(profile: nil, config: file.config, imageDirectory: nil), isRunning: { started }, createCard: { _, destination in
            try Data("new card".utf8).write(to: destination); started = true
        })
    }
    #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "sdcard.img").path))
    #expect(try String(contentsOf: directory.appending(path: "config.ini"), encoding: .utf8) == file.configText)
}

@Test func emulatorCreatesRealSDCardWithSDKTool() async throws {
    guard ProcessInfo.processInfo.environment["DROIDHUB_TEST_AVD_SDCARD"] == "1" else { return }
    let directory = try configurationDirectory(basicAVD)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = try EmulatorConfigurationFile(directory: directory)
    let compatible = EmulatorCompatibility(profile: nil, config: file.config, imageDirectory: nil)
    var value = file.original; value.expanded = "custom"; value.sdSize = EmulatorCapacity(10, .mb)
    try await file.save(value, compatibility: compatible, isRunning: { false })
    #expect(Hub.ini(directory.appending(path: "config.ini"))["sdcard.size"] == "10240K")
    let card = directory.appending(path: "sdcard.img")
    #expect(try card.resourceValues(forKeys: [.fileSizeKey]).fileSize == 10 << 20)
    let handle = try FileHandle(forReadingFrom: card)
    let header = try #require(try handle.read(upToCount: 512)); try handle.close()
    #expect(header[510] == 0x55 && header[511] == 0xaa)
    let reloaded = try EmulatorConfigurationFile(directory: directory)
    #expect(!reloaded.cardNeedsCreation(value))
    var networkOnly = reloaded.original; networkOnly.speed = "gprs"
    try await reloaded.save(networkOnly, compatibility: compatible, isRunning: { false }, createCard: { _, _ in Issue.record("An unchanged SD card should be preserved") })
    #expect(try Data(contentsOf: card).prefix(512) == header)
}

@Test func emulatorSaveRollsBackWhenAConfigurationFileCannotBeWritten() async throws {
    let directory = try configurationDirectory(basicAVD)
    defer { try? FileManager.default.removeItem(at: directory) }
    // A directory occupying user-settings.ini forces the second write to fail.
    try FileManager.default.createDirectory(at: directory.appending(path: "user-settings.ini"), withIntermediateDirectories: false)
    let previous = Data("existing SD card".utf8)
    try previous.write(to: directory.appending(path: "sdcard.img"))
    let file = try EmulatorConfigurationFile(directory: directory)
    var value = file.original
    value.speed = "edge"; value.preferredABI = "arm64-v8a"; value.expanded = "custom"; value.sdSize = EmulatorCapacity(10, .mb)
    await #expect(throws: (any Error).self) {
        try await file.save(value, compatibility: EmulatorCompatibility(profile: nil, config: ["abi.type": "arm64-v8a"], imageDirectory: nil), isRunning: { false }, createCard: { _, destination in
            try Data("new SD card".utf8).write(to: destination)
        })
    }
    #expect(try String(contentsOf: directory.appending(path: "config.ini"), encoding: .utf8) == basicAVD)
    #expect(try Data(contentsOf: directory.appending(path: "sdcard.img")) == previous)
}

@Test func newEmulatorDefaultsFollowProfileAndSDKMemoryRecommendations() async throws {
    let profile = try #require(await DeviceProfile.load().first { $0.id == "pixel_10" })
    let defaults = EmulatorConfiguration.defaults(profile: profile, base: "hw.ramSize=4096\n")
    #expect(defaults.ram.bytes == 2 << 30)
    #expect(defaults.heap.bytes == 112 << 20)
    #expect(defaults.frontCamera == "emulated" && defaults.rearCamera == "virtualscene")
    #expect(defaults.graphics == "auto")
}
