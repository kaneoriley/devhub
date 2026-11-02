import Foundation

enum AndroidAPI {
    static func imageVersion(path: String, properties: [String: String] = [:]) -> String? {
        if let version = properties["AndroidVersion.ApiLevel"], version.range(of: #"^\d+(?:\.\d+)?$"#, options: .regularExpression) != nil {
            return version
        }
        guard let match = path.range(of: #"android-\d+(?:\.\d+)?"#, options: .regularExpression) else { return nil }
        return String(path[match].dropFirst(8))
    }

    static func label(properties: [String: String], avdVersion: String? = nil) -> String? {
        // Studio identifies AVDs by their system image. ro.build.version.sdk only
        // reports the major level and must not replace an image's minor version.
        if let avdVersion, !avdVersion.isEmpty { return "API \(avdVersion)" }
        guard let major = properties["ro.build.version.sdk"], !major.isEmpty else { return nil }
        if let full = properties["ro.build.version.sdk_full"], full.range(of: #"^\d+\.\d+$"#, options: .regularExpression) != nil {
            return "API \(full)"
        }
        if let minor = properties["ro.build.version.sdk_minor"].flatMap(Int.init), minor > 0 { return "API \(major).\(minor)" }
        if let full = properties["ro.build.version.sdk_full"].flatMap(Int.init), full >= 100_000 {
            let minor = full % 100_000
            if minor > 0 { return "API \(full / 100_000).\(minor)" }
        }
        return "API \(major)"
    }
}
