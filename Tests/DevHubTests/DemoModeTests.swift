import Foundation
import Testing
@testable import DevHub

@Test func demoModePresentsModelNamesWithoutChangingDeviceIdentity() {
    let devices = [
        Device(id: "avd:custom", name: "private Android name", detail: "Emulator",
               model: "sdk_gphone64_arm64", modelName: "Pixel 9 Pro XL", avd: "custom", serial: "emulator-5554"),
        Device(id: "simulator:custom", name: "private simulator name", detail: "Simulator", model: "iPhone 17 Pro Max"),
        Device(id: "apple:custom", name: "private iPad name", detail: "iPad Pro", model: "iPad Pro (11-inch)"),
        Device(id: "usb", name: "private phone name", detail: "Android", model: "Pixel 10", serial: "usb"),
    ]
    for (device, expected) in zip(devices, ["Pixel 9 Pro XL", "iPhone 17 Pro Max", "iPad Pro (11-inch)", "Pixel 10"]) {
        let shown = device.presented(demoMode: true)
        #expect(shown.name == expected)
        #expect(shown.id == device.id && shown.avd == device.avd && shown.serial == device.serial)
        #expect(shown.model == device.model)
        #expect(device.name.hasPrefix("private"))
        #expect(device.presented(demoMode: false) == device)
    }
}

@Test func demoModeNeverFallsBackToCustomNamesWhenModelMetadataIsMissing() {
    let unknown = Device(id: "unknown", name: "private custom name", detail: "Emulator", model: " ", kind: .tablet)
    #expect(unknown.presented(demoMode: true).name == "Tablet")
    let simulator = AppleSimulator(udid: "sim", state: "Shutdown", runtime: "iOS 27", version: "27",
                                   type: "iPhone 17", family: "iPhone")
    let device = Device(id: "sim", name: "private custom name", detail: "Simulator", simulator: simulator)
    #expect(device.presented(demoMode: true).name == "iPhone 17")
}

@Test func demoModeSortsGroupsAndSearchesUsingThePresentedNames() {
    let devices = [Device(id: "android", name: "AAA private name", detail: "Emulator", model: "Pixel 9 Pro XL", avd: "custom"),
                   Device(id: "apple", name: "ZZZ private name", detail: "Simulator", model: "iPhone 17")]
    #expect(DeviceList(sort: .name, showGroups: false).groups(devices).flatMap(\.devices).map(\.id) == ["android", "apple"])
    let shown = devices.map { $0.presented(demoMode: true) }
    let groups = DeviceList(sort: .name).groups(shown)
    #expect(groups.map(\.title) == ["I", "P"])
    #expect(groups.flatMap(\.devices).map(\.id) == ["apple", "android"])
    #expect(DeviceList(query: "iPhone").groups(shown).flatMap(\.devices).map(\.id) == ["apple"])
    #expect(DeviceList(query: "private").groups(shown).isEmpty)
}
