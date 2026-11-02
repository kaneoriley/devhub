import Foundation

enum SDK {
    static let root: URL = {
        let env = ProcessInfo.processInfo.environment
        if let path = env["ANDROID_HOME"] ?? env["ANDROID_SDK_ROOT"] { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Android/sdk")
    }()
    static let adb = root.appending(path: "platform-tools/adb").path
    static let emulator = root.appending(path: "emulator/emulator").path
    // Metadata files locate each AVD's actual directory through their path= entry.
    static let avdHome = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".android/avd")

    static func avdDirectory(_ id: String) -> URL {
        if let path = Hub.ini(avdHome.appending(path: "\(id).ini"))["path"] { return URL(fileURLWithPath: path) }
        return avdHome.appending(path: "\(id).avd")
    }
}

@discardableResult
func adb(_ args: String...) async -> String {
    String(decoding: await exec(SDK.adb, args), as: UTF8.self)
}

func runADB(_ args: [String]) async throws -> ToolResult {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: SDK.adb)
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: ToolResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self)))
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
