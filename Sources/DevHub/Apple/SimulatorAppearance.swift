import Foundation

struct SimulatorAppearance {
    enum ColorFilter: String, CaseIterable {
        case none, grayscale, protanopia, deuteranopia, tritanopia, unknown
        static let choices: [Self] = [.none, .grayscale, .protanopia, .deuteranopia, .tritanopia]
        var title: String {
            switch self {
            case .none: return "None"
            case .grayscale: return "Grayscale"
            case .protanopia: return "Protanopia (red-green)"
            case .deuteranopia: return "Deuteranopia (green-red)"
            case .tritanopia: return "Tritanopia (blue-yellow)"
            case .unknown: return "Other"
            }
        }
    }
    static let defaultLiquidGlassOpacity = 0.5
    static let textSizes = ["extra-small", "small", "medium", "large", "extra-large", "extra-extra-large", "extra-extra-extra-large",
                            "accessibility-medium", "accessibility-large", "accessibility-extra-large", "accessibility-extra-extra-large", "accessibility-extra-extra-extra-large"]
    var dark: Bool?
    var textSize: String?
    var borders: Bool?
    var colorFilter: ColorFilter?
    var liquidGlassOpacity: Double?
    // Older runtimes report a placeholder colorFilter even though setters reject it.
    var modernCustomizationSupported: Bool? = true
    var native = true
    var supportsColorFilter: Bool { native && modernCustomizationSupported == true && colorFilter != nil }
    var supportsLiquidGlass: Bool { native && modernCustomizationSupported == true && liquidGlassOpacity != nil }

    static func customizationSupport(_ data: Data) -> Bool? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let capabilities = result["capabilities"] as? [[String: Any]] else { return nil }
        return capabilities.contains { $0["featureIdentifier"] as? String == "com.apple.coredevice.feature.customizeliquidglass" }
    }

    static func parse(_ data: Data) throws -> Self {
        struct Response: Decodable {
            struct Result: Decodable {
                struct Enabled: Decodable { let enabled: Bool }
                struct Filter: Decodable {
                    struct Kind: Decodable { let name: String? }
                    let enabled: Bool
                    let filterType: Kind?
                }
                let userInterfaceStyle: String?
                let textSize: String?
                let showBorders: Enabled?
                let colorFilter: Filter?
                let liquidGlassOpacity: Double?
            }
            let result: Result
        }
        let result = try JSONDecoder().decode(Response.self, from: data).result
        let size = result.textSize?.lowercased().replacingOccurrences(of: " ", with: "-")
        let filter: ColorFilter? = result.colorFilter.map {
            $0.enabled ? ColorFilter(rawValue: $0.filterType?.name?.lowercased() ?? "") ?? .unknown : ColorFilter.none
        }
        let opacity = result.liquidGlassOpacity.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
        return Self(dark: result.userInterfaceStyle == "dark" ? true : result.userInterfaceStyle == "light" ? false : nil,
                    textSize: size.flatMap { textSizes.contains($0) ? $0 : nil }, borders: result.showBorders?.enabled,
                    colorFilter: filter, liquidGlassOpacity: opacity, modernCustomizationSupported: nil)
    }

    static func load(_ id: String, run: (String, [String]) async throws -> ToolResult = { try await Simctl.runTool($0, $1) }) async throws -> Self {
        async let details = try? run("devicectl", ["device", "info", "details", "--device", id, "--quiet", "--json-output", "-", "--timeout", "10"])
        let result = try await run("devicectl", ["device", "info", "appearance", "--device", id, "--quiet", "--json-output", "-", "--timeout", "10"])
        if result.status == 0 {
            var value = try parse(Data(result.output.utf8))
            let capability = await details
            value.modernCustomizationSupported = capability.flatMap { $0.status == 0 ? customizationSupport(Data($0.output.utf8)) : nil }
            if value.modernCustomizationSupported == false { value.colorFilter = nil; value.liquidGlassOpacity = nil }
            return value
        }
        // Earlier Xcodes expose appearance and Dynamic Type through simctl.
        let appearance = try await run("simctl", ["ui", id, "appearance"])
        try appearance.checked()
        let size = try await run("simctl", ["ui", id, "content_size"])
        try size.checked()
        let value = size.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let mode = appearance.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(dark: mode == "dark" ? true : mode == "light" ? false : nil,
                    textSize: textSizes.contains(value) ? value : nil, borders: nil, modernCustomizationSupported: false, native: false)
    }

    enum Change: Equatable { case appearance(Bool), textSize(Int), borders(Bool), colorFilter(ColorFilter), liquidGlassOpacity(Double) }

    func command(_ change: Change, id: String) throws -> (String, [String]) {
        var options: [String]
        switch change {
        case .appearance(let dark):
            if !native { return ("simctl", ["ui", id, "appearance", dark ? "dark" : "light"]) }
            options = ["--mode", dark ? "dark" : "light"]
        case .textSize(let index):
            guard Self.textSizes.indices.contains(index) else { throw MirrorError("Choose a valid text size.") }
            let size = Self.textSizes[index]
            if !native { return ("simctl", ["ui", id, "content_size", size]) }
            options = ["--text-size", size]
            if index >= 7 { options += ["--larger-accessibility-sizes", "on"] }
        case .borders(let enabled):
            guard native, borders != nil else { throw MirrorError("This simulator doesn't support Show Borders.") }
            options = ["--show-borders", enabled ? "on" : "off"]
        case .colorFilter(let filter):
            guard supportsColorFilter, filter != .unknown else { throw MirrorError("This device doesn't support the selected Color Filter.") }
            options = filter == .none ? ["--color-filter", "off"] : ["--color-filter", "on", "--color-filter-type", filter.rawValue]
        case .liquidGlassOpacity(let opacity):
            guard supportsLiquidGlass, opacity.isFinite, (0...1).contains(opacity) else {
                throw MirrorError("Choose a supported Liquid Glass opacity between 0% and 100%.")
            }
            options = ["--liquid-glass-opacity", String(opacity)]
        }
        return ("devicectl", ["device", "settings", "appearance", "--device", id] + options + ["--quiet", "--timeout", "10"])
    }

    func apply(_ change: Change, id: String, run: (String, [String]) async throws -> ToolResult = { try await Simctl.runTool($0, $1) }) async throws {
        let (tool, args) = try command(change, id: id)
        try await run(tool, args).checked()
    }
}

extension SimulatorAppearance {
    func reset(id: String, run: (String, [String]) async throws -> ToolResult = { try await Simctl.runTool($0, $1) }) async throws {
        if !native {
            if dark != nil { try await apply(.appearance(false), id: id, run: run) }
            if textSize != nil { try await apply(.textSize(3), id: id, run: run) }
            return
        }
        var options: [String] = []
        if dark != nil { options += ["--mode", "light"] }
        if textSize != nil { options += ["--text-size", "large", "--larger-accessibility-sizes", "off"] }
        if borders != nil { options += ["--show-borders", "off"] }
        if supportsColorFilter { options += ["--color-filter", "off"] }
        if supportsLiquidGlass { options += ["--liquid-glass-opacity", String(Self.defaultLiquidGlassOpacity)] }
        guard !options.isEmpty else { return }
        try await run("devicectl", ["device", "settings", "appearance", "--device", id] + options + ["--quiet", "--timeout", "10"]).checked()
    }
}
