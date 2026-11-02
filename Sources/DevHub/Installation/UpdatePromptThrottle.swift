import Foundation

/// Persist the last presentation so relaunching or installing another build
/// cannot restart the automatic-prompt allowance. Manual checks bypass this.
struct UpdatePromptThrottle {
    let defaults: UserDefaults
    private let key = "installation.lastAutomaticUpdatePrompt"

    func allowsPrompt(at now: Date = Date()) -> Bool {
        guard let last = defaults.object(forKey: key) as? Date else { return true }
        return now.timeIntervalSince(last) >= 3600
    }

    func recordPrompt(at now: Date = Date()) { defaults.set(now, forKey: key) }
}
