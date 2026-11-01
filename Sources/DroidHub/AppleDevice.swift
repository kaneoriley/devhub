import Foundation

struct AppleDevice: Hashable {
    let identifier: String
    let udid: String
    let platform: String
    let version: String
    let connection: String
    let pairing: String
    var isConnected: Bool { connection == "connected" }

    enum Requirement: Equatable {
        case connect, trust, unlock, update, unknownVersion
    }

    func requirement(passcodeRequired: Bool = false, unlockedSinceBoot: Bool = true) -> Requirement? {
        guard isConnected else { return .connect }
        guard pairing == "paired" else { return .trust }
        guard !passcodeRequired, unlockedSinceBoot else { return .unlock }
        guard let major = version.split(separator: ".").first.flatMap({ Int($0) }) else { return .unknownVersion }
        return major < 27 ? .update : nil
    }

    struct LockState: Decodable {
        let passcodeRequired: Bool
        let unlockedSinceBoot: Bool
        static func parse(_ data: Data) throws -> Self {
            struct Response: Decodable { let result: LockState }
            return try JSONDecoder().decode(Response.self, from: data).result
        }
    }

    static func parse(_ data: Data) throws -> [Device] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any], let devices = result["devices"] as? [[String: Any]] else {
            throw MirrorError("Couldn't read Apple's device inventory.")
        }
        return devices.compactMap { entry -> Device? in
            let properties = entry["properties"] as? [String: Any] ?? [:]
            let hardware = properties["hardware"] as? [String: Any] ?? entry["hardwareProperties"] as? [String: Any] ?? [:]
            let software = properties["software"] as? [String: Any] ?? entry["deviceProperties"] as? [String: Any] ?? [:]
            let state = properties["state"] as? [String: Any] ?? entry["deviceProperties"] as? [String: Any] ?? [:]
            let connection = properties["connection"] as? [String: Any] ?? entry["connectionProperties"] as? [String: Any] ?? [:]
            guard hardware["reality"] as? String == "physical",
                  let family = hardware["deviceType"] as? String, ["iPhone", "iPad", "iPodTouch"].contains(family),
                  let identifier = entry["identifier"] as? String else { return nil }
            let version = (software["osVersionNumber"] as? [String: Any])?["stringValue"] as? String ?? software["osVersionNumber"] as? String ?? ""
            let model = hardware["marketingName"] as? String ?? family
            let apple = AppleDevice(identifier: identifier, udid: hardware["udid"] as? String ?? identifier,
                                    platform: hardware["platform"] as? String ?? "iOS", version: version,
                                    connection: connection["state"] as? String ?? connection["tunnelState"] as? String ?? "disconnected",
                                    pairing: connection["pairingState"] as? String ?? "unknown")
            return Device(id: "apple:\(identifier)", name: state["name"] as? String ?? model, detail: model,
                          model: model, release: version, api: version, kind: family == "iPad" ? .tablet : .phone, appleDevice: apple)
        }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    static func inventory() async -> Data? {
        guard let result = try? await Simctl.runTool("devicectl", ["list", "devices", "--quiet", "--json-output", "-", "--timeout", "5"]), result.status == 0 else { return nil }
        return Data(result.output.utf8)
    }
}
