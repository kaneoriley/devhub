import Foundation

enum DeviceFilter: String, CaseIterable, Identifiable {
    // Keep the stored value so existing filter preferences survive the label change.
    case all, virtual = "simulators", physical
    var id: Self { self }
    var title: String {
        switch self { case .all: "All Devices"; case .virtual: "Virtual Devices"; case .physical: "Physical Devices" }
    }
    func includes(_ device: Device) -> Bool {
        switch self { case .all: true; case .virtual: device.isVirtual; case .physical: !device.isVirtual }
    }
}

enum DeviceSort: String, CaseIterable, Identifiable {
    case availability, recent, name, formFactor, fidelity, platform, operatingSystem
    var id: Self { self }
    var title: String {
        switch self {
        case .availability: "Availability"
        case .recent: "Recent"
        case .name: "Name"
        case .formFactor: "Form Factor"
        case .fidelity: "Fidelity"
        case .platform: "Platform"
        case .operatingSystem: "Operating System"
        }
    }
}

extension Device {
    var isVirtual: Bool { isEmulator || simulator != nil }
    // A shut-down virtual device is still available to boot. Missing system images
    // and disconnected physical devices belong in Unavailable.
    var isAvailable: Bool { isRunning || simulator != nil || (isEmulator && hasSystemImage) }
    var platform: String {
        if let appleDevice { return appleDevice.platform }
        guard let simulator else { return "Android" }
        return simulator.runtime.split(separator: " ").first.map(String.init) ?? "iOS"
    }
    var osVersion: String {
        if simulator != nil || appleDevice != nil { return release }
        // SDK image versions remain available for stopped AVDs and preserve minor
        // API levels, unlike ro.build.version.release's marketing version.
        return api.hasPrefix("API ") ? String(api.dropFirst(4)) : release
    }
    var operatingSystem: String {
        if simulator != nil || appleDevice != nil { return [platform, osVersion].filter { !$0.isEmpty }.joined(separator: " ") }
        return osVersion.isEmpty ? platform : "Android API \(osVersion)"
    }
}

private extension DeviceKind {
    var listRank: Int {
        switch self {
        case .phone: 0; case .tablet: 1; case .foldable: 2; case .resizable: 3
        case .watch: 4; case .tv: 5; case .automotive: 6; case .desktop: 7
        }
    }
    var listTitle: String {
        switch self {
        case .phone: "Phones"; case .tablet: "Tablets"; case .foldable: "Foldables"; case .resizable: "Resizables"
        case .watch: "Watches"; case .tv: "TVs"; case .automotive: "Automotive"; case .desktop: "Desktops"
        }
    }
}

struct DeviceListGroup: Identifiable {
    let id: String
    let title: String?
    var devices: [Device]
}

struct DeviceList {
    var filter: DeviceFilter = .all
    var sort: DeviceSort = .availability
    var showGroups = true
    var query = ""
    var recentSelections: [String: Double] = [:]
    var booting: Set<String> = []
    var now = Date.now
    var calendar = Calendar.current

    func groups(_ devices: [Device]) -> [DeviceListGroup] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = devices.filter { device in
            filter.includes(device) && (query.isEmpty || [device.name, device.model, device.platform, device.operatingSystem]
                .contains { $0.localizedCaseInsensitiveContains(query) })
        }.sorted(by: precedes)
        guard !rows.isEmpty else { return [] }
        guard showGroups else { return [DeviceListGroup(id: "all", title: nil, devices: rows)] }
        var result: [DeviceListGroup] = []
        var indices: [String: Int] = [:]
        for device in rows {
            let title = groupTitle(device)
            if let index = indices[title] { result[index].devices.append(device) }
            else { indices[title] = result.count; result.append(DeviceListGroup(id: title, title: title, devices: [device])) }
        }
        return result
    }

    private func lastUsed(_ device: Device) -> Date? {
        let viewed = recentSelections[device.id].map { Date(timeIntervalSince1970: $0) }
        return [viewed, device.lastUsedAt].compactMap { $0 }.max()
    }

    private func precedes(_ a: Device, _ b: Device) -> Bool {
        switch sort {
        case .availability:
            if a.isAvailable != b.isAvailable { return a.isAvailable }
            func rank(_ device: Device) -> Int {
                if device.isRunning { return 0 }
                return booting.contains(device.id) || device.simulator?.state == "Booting" ? 1 : 2
            }
            if rank(a) != rank(b) { return rank(a) < rank(b) }
        case .recent:
            let x = lastUsed(a) ?? .distantPast, y = lastUsed(b) ?? .distantPast
            if x != y { return x > y }
        case .name: break
        case .formFactor:
            if a.kind != b.kind { return a.kind.listRank < b.kind.listRank }
        case .fidelity:
            if a.isVirtual != b.isVirtual { return !a.isVirtual }
        case .platform:
            if a.platform != b.platform { return a.platform.localizedStandardCompare(b.platform) == .orderedAscending }
        case .operatingSystem:
            if a.platform != b.platform { return a.platform.localizedStandardCompare(b.platform) == .orderedAscending }
            let comparison = a.osVersion.compare(b.osVersion, options: .numeric)
            if comparison != .orderedSame { return comparison == .orderedDescending }
        }
        let names = a.name.localizedStandardCompare(b.name)
        return names == .orderedSame ? a.id < b.id : names == .orderedAscending
    }

    private func groupTitle(_ device: Device) -> String {
        switch sort {
        case .availability: return device.isAvailable ? "Available" : "Unavailable"
        case .fidelity: return device.isVirtual ? "Virtual Devices" : "Physical Devices"
        case .formFactor: return device.kind.listTitle
        case .platform: return device.platform
        case .operatingSystem: return device.operatingSystem
        case .name:
            guard let first = device.name.first, first.isLetter else { return "#" }
            return String(first).uppercased()
        case .recent:
            guard let used = lastUsed(device) else { return "No Recent Activity" }
            if calendar.isDate(used, inSameDayAs: now) { return "Today" }
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(used, inSameDayAs: yesterday) { return "Yesterday" }
            if let week = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: now)), used >= week { return "Previous 7 Days" }
            return "Earlier"
        }
    }

    static func systemDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        return (try? Date(text, strategy: .iso8601)) ?? (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    }
}
