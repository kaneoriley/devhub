import Foundation

extension DeviceKind {
    static func from(config: [String: String]) -> DeviceKind {
        let name = (config["hw.device.name"] ?? "").lowercased()
        let tags = (config["tag.ids"] ?? config["tag.id"] ?? "").lowercased()
        if !DisplayPreset.parse(config["hw.resizable.configs"] ?? "").isEmpty { return .resizable }
        if ["yes", "true"].contains(config["hw.sensor.hinge"]?.lowercased() ?? "") { return .foldable }
        if tags.contains("android-tv") || tags.contains("google-tv") || name.contains("tv") { return .tv }
        if tags.contains("android-wear") || name.contains("wear") || name.contains("watch") { return .watch }
        if tags.contains("automotive") || name.contains("automotive") { return .automotive }
        if tags.contains("desktop") || name.contains("desktop") { return .desktop }
        if name.contains("tablet") { return .tablet }
        if let width = Double(config["hw.lcd.width"] ?? ""), let height = Double(config["hw.lcd.height"] ?? ""),
           let density = Double(config["hw.lcd.density"] ?? ""), density > 0, min(width, height) * 160 / density >= 600 {
            return .tablet
        }
        return .phone
    }
}
