import Foundation

struct SimulatorFileTransfer {
    var run: ([String]) async throws -> ADBResult = { try await Simctl.run($0) }

    func transfer(_ urls: [URL], udid: String) async throws -> String {
        guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { throw MirrorError("Drop files or simulator .app bundles.") }
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        let apps = urls.filter { $0.pathExtension.lowercased() == "app" }
        guard apps.isEmpty || apps.count == urls.count else { throw MirrorError("Install apps and copy files in separate drops.") }
        let manager = FileManager.default
        for url in urls {
            let values = try url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            guard apps.isEmpty ? values.isRegularFile == true : values.isDirectory == true else {
                throw MirrorError("Drop regular files or simulator .app bundles. \(url.lastPathComponent) isn't supported.")
            }
        }
        if !apps.isEmpty {
            for app in apps { try await run(["install", udid, app.path]).checked() }
            return apps.count == 1 ? "Installed \(apps[0].lastPathComponent)" : "Installed \(apps.count) apps"
        }

        let result = try await run(["get_app_container", udid, "com.apple.DocumentsApp", "groups"])
        guard result.status == 0, let storage = Self.localStorage(result.output),
              (try? storage.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw MirrorError("Copying files requires Apple's Files app on this simulator. Install a compatible simulator Files.app bundle, then drop the files again.")
        }
        let downloads = storage.appending(path: "File Provider Storage/Downloads", directoryHint: .isDirectory)
        let staging = storage.appending(path: ".DroidHubTransfers/\(UUID().uuidString)", directoryHint: .isDirectory)
        try manager.createDirectory(at: downloads, withIntermediateDirectories: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        var copied = 0
        for url in urls {
            do {
                let temporary = staging.appending(path: UUID().uuidString)
                try manager.copyItem(at: url.resolvingSymlinksInPath(), to: temporary)
                try manager.moveItem(at: temporary, to: Self.availableDestination(for: url.lastPathComponent, in: downloads))
                copied += 1
            } catch {
                throw MirrorError("Copied \(copied) of \(urls.count) files to Files → Downloads. Couldn't copy \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        let message = urls.count == 1 ? "Copied \(urls[0].lastPathComponent) to Files → Downloads" : "Copied \(urls.count) files to Files → Downloads"
        let media = Set(["png", "jpg", "jpeg", "heic", "gif", "mov", "mp4", "m4v", "vcf"])
        let imports = urls.filter { media.contains($0.pathExtension.lowercased()) }
        if !imports.isEmpty {
            do { try await run(["addmedia", udid] + imports.map(\.path)).checked() }
            catch { throw MirrorError("\(message), but the additional Photos/Contacts import failed: \(error)") }
        }
        return message
    }

    static func localStorage(_ output: String) -> URL? {
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", maxSplits: 1).map(String.init)
            if fields.count == 2, fields[0] == "group.com.apple.FileProvider.LocalStorage", fields[1].hasPrefix("/") {
                return URL(fileURLWithPath: fields[1], isDirectory: true)
            }
        }
        return nil
    }

    private static func availableDestination(for name: String, in directory: URL) -> URL {
        let original = directory.appending(path: name)
        let suffix = original.pathExtension
        let stem = suffix.isEmpty ? name : original.deletingPathExtension().lastPathComponent
        var candidate = original, number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appending(path: "\(stem) (\(number))" + (suffix.isEmpty ? "" : ".\(suffix)"))
            number += 1
        }
        return candidate
    }
}
