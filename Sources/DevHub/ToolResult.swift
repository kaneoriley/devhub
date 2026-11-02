import Foundation

/// Unlike the polling helpers, user actions need exit status and stderr to report failures.
struct ToolResult {
    let status: Int32
    let output: String

    func checked() throws {
        // The emulator console can report KO even when adb itself exits successfully.
        let rejected = output.split(whereSeparator: \.isNewline).contains {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("KO")
        }
        guard status == 0, !rejected else {
            throw MirrorError(output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              ? "ADB failed (exit \(status))." : output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
