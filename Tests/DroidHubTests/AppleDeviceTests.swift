import Foundation
import Testing
import SimulatorBridge
@testable import DroidHub

@Test func physicalAppleDiscoveryKeepsVersionAndExcludesSimulatorsAndMacs() throws {
    let data = Data(#"""
    {"result":{"devices":[
      {"identifier":"ipad-id","properties":{"hardware":{"reality":"physical","deviceType":"iPad","marketingName":"iPad Pro (11-inch)","platform":"iOS","udid":"ipad-udid"},"software":{"osVersionNumber":{"stringValue":"26.6.2"}},"state":{"name":"My iPad"},"connection":{"state":"connected","pairingState":"paired"}}},
      {"identifier":"sim-id","properties":{"hardware":{"reality":"simulated","deviceType":"iPhone"}}},
      {"identifier":"mac-id","properties":{"hardware":{"reality":"physical","deviceType":"Mac"}}}
    ]}}
    """#.utf8)
    let devices = try AppleDevice.parse(data)
    #expect(devices.count == 1)
    let device = try #require(devices.first)
    #expect(device.id == "apple:ipad-id" && device.name == "My iPad")
    #expect(device.api == "26.6.2" && device.kind == .tablet && device.isRunning)
    #expect(device.simulator == nil && device.serial == nil && !device.isEmulator)
    #expect(device.appleDevice?.udid == "ipad-udid")
}

@Test func physicalAppleDiscoverySupportsOlderCoreDeviceJSON() throws {
    let data = Data(#"""
    {"result":{"devices":[{"identifier":"phone","hardwareProperties":{"reality":"physical","deviceType":"iPhone","platform":"iOS"},"deviceProperties":{"name":"My iPhone","osVersionNumber":"27.1"},"connectionProperties":{"tunnelState":"disconnected","pairingState":"unpaired"}}]}}
    """#.utf8)
    let device = try #require(try AppleDevice.parse(data).first)
    #expect(!device.isRunning && device.appleDevice?.pairing == "unpaired")
    #expect(device.api == "27.1" && device.kind == .phone)
}

@Test func physicalAppleConnectionChecksPrecedeScreenSharingAndRejectOlderOS() {
    func device(version: String = "27.0", connection: String = "connected", pairing: String = "paired") -> AppleDevice {
        AppleDevice(identifier: "id", udid: "udid", platform: "iOS", version: version, connection: connection, pairing: pairing)
    }
    #expect(device(version: "26.6.2").requirement() == .update)
    #expect(device(version: "26.6.2").requirement(passcodeRequired: true) == .unlock)
    #expect(device().requirement(unlockedSinceBoot: false) == .unlock)
    #expect(device(pairing: "unpaired").requirement() == .trust)
    #expect(device(connection: "disconnected").requirement() == .connect)
    #expect(device(version: "27.2").requirement() == nil)
    #expect(device(version: "").requirement() == .unknownVersion)
    let state = try? AppleDevice.LockState.parse(Data(#"{"result":{"passcodeRequired":true,"unlockedSinceBoot":false}}"#.utf8))
    #expect(state?.passcodeRequired == true && state?.unlockedSinceBoot == false)
}

/// Opt-in integration check against the selected Xcode's resilient Swift view ABI.
@Test @MainActor func nativeAppleDeviceViewLoadsWithoutCopyingItsLayout() async throws {
    guard let id = ProcessInfo.processInfo.environment["DROIDHUB_TEST_APPLE_DEVICE"], let identifier = UUID(uuidString: id) else { return }
    let directory = try await Simctl.developerDirectory()
    var error: NSError?
    let metadata = try #require(DHDeviceViewMetadata(directory, &error), "\(String(describing: error))")
    _ = try NativeAppleDeviceView.make(identifier: identifier, metadata: metadata)
}
