import Foundation

struct SimulatorAppearance {
    static let textSizes = ["extra-small", "small", "medium", "large", "extra-large", "extra-extra-large", "extra-extra-extra-large",
                            "accessibility-medium", "accessibility-large", "accessibility-extra-large", "accessibility-extra-extra-large", "accessibility-extra-extra-extra-large"]
    var dark: Bool?
    var textSize: String?
    var borders: Bool?
    var native = true

    static func parse(_ data: Data) throws -> Self {
        struct Response: Decodable {
            struct Result: Decodable {
                struct Enabled: Decodable { let enabled: Bool }
                let userInterfaceStyle: String?
                let textSize: String?
                let showBorders: Enabled?
            }
            let result: Result
        }
        let result = try JSONDecoder().decode(Response.self, from: data).result
        let size = result.textSize?.lowercased().replacingOccurrences(of: " ", with: "-")
        return Self(dark: result.userInterfaceStyle == "dark" ? true : result.userInterfaceStyle == "light" ? false : nil,
                    textSize: size.flatMap { textSizes.contains($0) ? $0 : nil }, borders: result.showBorders?.enabled)
    }

    static func load(_ id: String, run: (String, [String]) async throws -> ToolResult = { try await Simctl.runTool($0, $1) }) async throws -> Self {
        let result = try await run("devicectl", ["device", "info", "appearance", "--device", id, "--quiet", "--json-output", "-", "--timeout", "10"])
        if result.status == 0 { return try parse(Data(result.output.utf8)) }
        // Earlier Xcodes expose appearance and Dynamic Type through simctl.
        let appearance = try await run("simctl", ["ui", id, "appearance"])
        try appearance.checked()
        let size = try await run("simctl", ["ui", id, "content_size"])
        try size.checked()
        let value = size.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let mode = appearance.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(dark: mode == "dark" ? true : mode == "light" ? false : nil,
                    textSize: textSizes.contains(value) ? value : nil, borders: nil, native: false)
    }

    enum Change: Equatable { case appearance(Bool), textSize(Int), borders(Bool) }

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
        guard !options.isEmpty else { return }
        try await run("devicectl", ["device", "settings", "appearance", "--device", id] + options + ["--quiet", "--timeout", "10"]).checked()
    }
}
