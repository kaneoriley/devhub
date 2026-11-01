import Foundation
import Testing
@testable import DroidHub

private func simulator(_ id: String, name: String = "Phone", version: String = "27.1", state: String = "Shutdown") -> Device {
    Device(id: id, name: name, detail: "Simulator", release: version,
           simulator: AppleSimulator(udid: id, state: state, runtime: "iOS \(version)", version: version, type: "iPhone", family: "iPhone"))
}

@Test func deviceFiltersIncludeBothVirtualPlatformsAndSeparatePhysicalDevices() {
    let devices = [simulator("ios"), Device(id: "avd", name: "Pixel", detail: "Emulator", avd: "Pixel"),
                   Device(id: "usb", name: "Phone", detail: "Physical", serial: "usb")]
    #expect(DeviceList(filter: .virtual).groups(devices).flatMap(\.devices).map(\.id) == ["ios", "avd"])
    #expect(DeviceList(filter: .physical).groups(devices).flatMap(\.devices).map(\.id) == ["usb"])
    #expect(DeviceList().groups(devices).flatMap(\.devices).count == 3)
    #expect(DeviceFilter(rawValue: "simulators") == .virtual)
    #expect(DeviceFilter.virtual.title == "Virtual Devices")
}

@Test func formFactorSortGroupsPhysicalAndVirtualDevicesTogetherByTheirGeometry() {
    var ipad = simulator("ipad", name: "iPad")
    ipad.kind = .tablet
    let devices = [Device(id: "fold", name: "Pixel Fold", detail: "Emulator", kind: .foldable, avd: "Fold"),
                   Device(id: "tablet", name: "Pixel Tablet", detail: "Emulator", kind: .tablet, avd: "Tablet"),
                   Device(id: "adaptive", name: "Resizable", detail: "Emulator", kind: .resizable, avd: "Resizable"),
                   Device(id: "phone", name: "Android Phone", detail: "Physical", serial: "usb"), ipad,
                   simulator("iphone", name: "iPhone")]
    let listing = DeviceList(sort: .formFactor)
    let groups = listing.groups(devices)
    #expect(groups.map(\.title) == ["Phones", "Tablets", "Foldables", "Resizables"])
    #expect(groups[0].devices.map(\.id) == ["phone", "iphone"])
    #expect(groups[1].devices.map(\.id) == ["ipad", "tablet"])
    #expect(DeviceList(sort: .formFactor, showGroups: false).groups(devices).first?.devices.map(\.id) == ["phone", "iphone", "ipad", "tablet", "fold", "adaptive"])
}

@Test func availabilityKeepsStoppedVirtualDevicesAvailableButFlagsMissingImages() {
    let devices = [Device(id: "missing", name: "Missing", detail: "Emulator", avd: "Missing", hasSystemImage: false),
                   simulator("stopped"), simulator("booting", state: "Booting"), simulator("running", state: "Booted"),
                   Device(id: "offline", name: "Offline", detail: "Physical")]
    let groups = DeviceList().groups(devices)
    #expect(groups.map(\.title) == ["Available", "Unavailable"])
    #expect(groups[0].devices.map(\.id) == ["running", "booting", "stopped"])
    #expect(groups[1].devices.map(\.id) == ["missing", "offline"])
}

@Test func deviceSortsUseNaturalNamesNumericVersionsAndDeterministicTies() {
    let devices = [simulator("b", name: "Phone 10", version: "27.2"), simulator("a", name: "Phone 2", version: "27.10"),
                   simulator("c", name: "Phone 2", version: "26.6.2")]
    let names = DeviceList(sort: .name, showGroups: false).groups(devices)
    #expect(names.count == 1 && names[0].title == nil)
    #expect(names[0].devices.map(\.id) == ["a", "c", "b"])
    let systems = DeviceList(sort: .operatingSystem).groups(devices)
    #expect(systems.map(\.title) == ["iOS 27.10", "iOS 27.2", "iOS 26.6.2"])
    let avd = Device(id: "avd", name: "Pixel", detail: "Emulator", api: "API 37.2", avd: "Pixel")
    #expect(avd.operatingSystem == "Android API 37.2")
    #expect(DeviceList(query: "37.2").groups([avd]).first?.devices.map(\.id) == ["avd"])
    #expect(DeviceList(sort: .platform).groups([devices[0], avd]).map(\.title) == ["Android", "iOS"])
    #expect(DeviceList(sort: .fidelity).groups([devices[0], avd, Device(id: "usb", name: "USB", detail: "Physical")]).map(\.title) == ["Physical Devices", "Virtual Devices"])
}

@Test func recentSortCombinesLocalSelectionsWithSystemHistoryAndHandlesUnknownDates() throws {
    let now = try #require(DeviceList.systemDate("2026-11-01T12:00:00Z"))
    var older = simulator("older")
    older.lastUsedAt = now.addingTimeInterval(-86400)
    var recent = simulator("recent")
    recent.lastUsedAt = now.addingTimeInterval(-3600)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    var listing = DeviceList(sort: .recent, recentSelections: ["older": now.timeIntervalSince1970], now: now, calendar: calendar)
    #expect(listing.groups([older, recent, simulator("unknown")]).map(\.title) == ["Today", "No Recent Activity"])
    #expect(listing.groups([older, recent]).flatMap(\.devices).map(\.id) == ["older", "recent"])
    listing.recentSelections = [:]
    #expect(listing.groups([older, recent]).map(\.title) == ["Today", "Yesterday"])
    #expect(DeviceList.systemDate("2026-11-01T12:00:00.123Z") != nil)
    #expect(DeviceList.systemDate(nil) == nil)
    #expect(DeviceList.systemDate("invalid") == nil)
}
