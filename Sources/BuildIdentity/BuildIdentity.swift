import CryptoKit
import Foundation

/// Shared by the build script and the app so their checkout comparisons cannot drift.
public struct BuildIdentity: Codable, Equatable, Sendable {
    public let sourceDirectory: String
    public let commit: String
    public let sourceHash: String
    /// Optional so apps built before working-tree metadata was added remain readable.
    public let dirty: Bool?

    public static func read(source: URL) throws -> Self {
        let paths = try git(["ls-files", "--cached", "--others", "--exclude-standard", "-z"], in: source)
        var fingerprint = SHA256()
        for path in Set(paths.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }).sorted() {
            fingerprint.update(data: Data(path.utf8))
            fingerprint.update(data: Data([0]))
            var content = SHA256()
            let file = source.appendingPathComponent(path)
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: file.path, isDirectory: &directory), !directory.boolValue {
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty { content.update(data: chunk) }
            }
            fingerprint.update(data: Data(content.finalize()))
        }
        let commit = String(decoding: try git(["rev-parse", "HEAD"], in: source), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let dirty = !(try git(["status", "--porcelain=v1", "--untracked-files=normal"], in: source)).isEmpty
        return Self(sourceDirectory: source.standardizedFileURL.path, commit: commit,
                    sourceHash: fingerprint.finalize().map { String(format: "%02x", $0) }.joined(), dirty: dirty)
    }

    public var commitLabel: String {
        String(commit.prefix(12)) + (dirty == true ? " (modified)" : "")
    }

    public static func load(from url: URL) throws -> Self {
        try PropertyListDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    private static func git(_ arguments: [String], in source: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = source
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw IdentityError("Cannot read the Git checkout at \(source.path).") }
        return data
    }
}

private struct IdentityError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
