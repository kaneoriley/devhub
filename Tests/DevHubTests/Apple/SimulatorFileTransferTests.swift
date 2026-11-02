import Foundation
import Testing
@testable import DevHub

private struct SimulatorTransferFixture {
    let root: URL
    let storage: URL
    let files: [URL]
    var downloads: URL { storage.appending(path: "File Provider Storage/Downloads") }
    init(_ names: [String]) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "devhub-sim-transfer-\(UUID().uuidString)")
        storage = root.appending(path: "Files shared group")
        let inputs = root.appending(path: "inputs")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        files = names.map { inputs.appending(path: $0) }
        for file in files { try Data("contents of \(file.lastPathComponent)".utf8).write(to: file) }
    }
    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

private actor SimulatorTransferRecorder {
    var calls: [[String]] = []
    let storage: URL?
    var failMedia: Bool
    init(storage: URL? = nil, failMedia: Bool = false) { self.storage = storage; self.failMedia = failMedia }
    func run(_ args: [String]) -> ToolResult {
        calls.append(args)
        if args.first == "get_app_container" {
            guard let storage else { return ToolResult(status: 1, output: "Files is not installed") }
            return ToolResult(status: 0, output: "other.group\t/unused\ngroup.com.apple.FileProvider.LocalStorage\t\(storage.path)\n")
        }
        return ToolResult(status: args.first == "addmedia" && failMedia ? 1 : 0, output: "Media import failed")
    }
}

@Test func arbitrarySimulatorFilesCopyToTheFilesAppWithTheirContentsAndNames() async throws {
    let fixture = try SimulatorTransferFixture(["route.gpx", "archive.zip", "quotes' dollar$ and `ticks`.txt"])
    defer { fixture.cleanUp() }
    let recorder = SimulatorTransferRecorder(storage: fixture.storage)
    let transfer = SimulatorFileTransfer(run: { await recorder.run($0) })
    let message = try await transfer.transfer(fixture.files, udid: "selected-simulator")
    #expect(message == "Copied 3 files to Files → Downloads")
    #expect(await recorder.calls == [["get_app_container", "selected-simulator", "com.apple.DocumentsApp", "groups"]])
    for file in fixture.files {
        #expect(try Data(contentsOf: fixture.downloads.appending(path: file.lastPathComponent)) == Data(contentsOf: file))
    }
}

@Test func simulatorUploadsPreserveExistingFilesAndNumberDuplicateNames() async throws {
    let fixture = try SimulatorTransferFixture(["route.gpx"])
    defer { fixture.cleanUp() }
    try FileManager.default.createDirectory(at: fixture.downloads, withIntermediateDirectories: true)
    let original = fixture.downloads.appending(path: "route.gpx")
    try Data("existing route".utf8).write(to: original)
    let recorder = SimulatorTransferRecorder(storage: fixture.storage)
    let transfer = SimulatorFileTransfer(run: { await recorder.run($0) })
    _ = try await transfer.transfer(fixture.files + fixture.files, udid: "simulator")
    #expect(try String(contentsOf: original, encoding: .utf8) == "existing route")
    for name in ["route (2).gpx", "route (3).gpx"] {
        #expect(try Data(contentsOf: fixture.downloads.appending(path: name)) == Data(contentsOf: fixture.files[0]))
    }
}

@Test func simulatorMediaIsAvailableInFilesAndStillImportedIntoPhotosAndContacts() async throws {
    let fixture = try SimulatorTransferFixture(["aircraft profile.PNG", "route.gpx", "contact.vcf"])
    defer { fixture.cleanUp() }
    let recorder = SimulatorTransferRecorder(storage: fixture.storage)
    let transfer = SimulatorFileTransfer(run: { await recorder.run($0) })
    _ = try await transfer.transfer(fixture.files, udid: "simulator")
    #expect(await recorder.calls == [
        ["get_app_container", "simulator", "com.apple.DocumentsApp", "groups"],
        ["addmedia", "simulator", fixture.files[0].path, fixture.files[2].path],
    ])
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.downloads.path).sorted() == fixture.files.map(\.lastPathComponent).sorted())
}

@Test func simulatorAppInstallationDoesNotRequireFiles() async throws {
    let fixture = try SimulatorTransferFixture([])
    defer { fixture.cleanUp() }
    let app = fixture.root.appending(path: "Example.app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    let recorder = SimulatorTransferRecorder()
    let transfer = SimulatorFileTransfer(run: { await recorder.run($0) })
    #expect(try await transfer.transfer([app], udid: "simulator") == "Installed Example.app")
    #expect(await recorder.calls == [["install", "simulator", app.path]])
}

@Test func invalidSimulatorDropsAreRejectedBeforeAnyCommandsOrCopies() async throws {
    let fixture = try SimulatorTransferFixture(["route.gpx"])
    defer { fixture.cleanUp() }
    let app = fixture.root.appending(path: "Example.app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    let recorder = SimulatorTransferRecorder(storage: fixture.storage)
    let transfer = SimulatorFileTransfer(run: { await recorder.run($0) })
    for files in [[], [app, fixture.files[0]], [fixture.root], [fixture.files[0], fixture.root.appending(path: "missing.txt")], [URL(string: "https://example.com/file")!]] {
        await #expect(throws: (any Error).self) { _ = try await transfer.transfer(files, udid: "simulator") }
    }
    #expect(await recorder.calls.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fixture.downloads.path))
}

@Test func missingSimulatorFilesAppExplainsTheRequirement() async throws {
    let fixture = try SimulatorTransferFixture(["route.gpx"])
    defer { fixture.cleanUp() }
    let recorder = SimulatorTransferRecorder()
    let transfer = SimulatorFileTransfer(run: { await recorder.run($0) })
    do {
        _ = try await transfer.transfer(fixture.files, udid: "simulator")
        Issue.record("A missing Files app was reported as a successful copy")
    } catch { #expect(String(describing: error).contains("compatible simulator Files.app")) }
    #expect(!FileManager.default.fileExists(atPath: fixture.downloads.path))
}

@Test func mediaImportFailureReportsThatTheFilesCopySucceeded() async throws {
    let fixture = try SimulatorTransferFixture(["profile.png"])
    defer { fixture.cleanUp() }
    let recorder = SimulatorTransferRecorder(storage: fixture.storage, failMedia: true)
    let transfer = SimulatorFileTransfer(run: { await recorder.run($0) })
    do {
        _ = try await transfer.transfer(fixture.files, udid: "simulator")
        Issue.record("Failed media import was not reported")
    } catch {
        #expect(String(describing: error).contains("Copied profile.png to Files → Downloads"))
    }
    #expect(try Data(contentsOf: fixture.downloads.appending(path: "profile.png")) == Data(contentsOf: fixture.files[0]))
}

/// Opt in to exercise the real Files app container on a selected simulator.
@Test func simulatorFilesUploadRoundTrip() async throws {
    guard let udid = ProcessInfo.processInfo.environment["DEVHUB_TEST_FILE_SIMULATOR"] else { return }
    let fixture = try SimulatorTransferFixture(["DevHub upload test \(UUID().uuidString).txt"])
    defer { fixture.cleanUp() }
    let result = try await Simctl.run(["get_app_container", udid, "com.apple.DocumentsApp", "groups"])
    try result.checked()
    let storage = try #require(SimulatorFileTransfer.localStorage(result.output))
    let destination = storage.appending(path: "File Provider Storage/Downloads/\(fixture.files[0].lastPathComponent)")
    defer { try? FileManager.default.removeItem(at: destination) }
    let message = try await Simctl.transfer(fixture.files, udid: udid)
    #expect(message.contains("Files → Downloads"))
    #expect(try Data(contentsOf: destination) == Data(contentsOf: fixture.files[0]))
}
