import BuildIdentity
import Darwin
import Foundation
import Testing
@testable import DevHub

private func git(_ args: [String], in directory: URL) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = args
    p.currentDirectoryURL = directory
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
    #expect(p.terminationStatus == 0)
}

private func checkout() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("devhub-source-test-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try git(["init", "-q"], in: root)
    try Data("build/\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
    try Data("echo build\n".utf8).write(to: root.appendingPathComponent("build.sh"))
    try git(["add", "."], in: root)
    try git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "initial"], in: root)
    return root
}

@Test func sourceFingerprintIncludesEditsNewFilesAndDeletionsButIgnoresBuildOutput() throws {
    let root = try checkout()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = try BuildIdentity.read(source: root)
    #expect(original.dirty == false)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("build"), withIntermediateDirectories: true)
    try Data("artifact".utf8).write(to: root.appendingPathComponent("build/ignored"))
    #expect(try BuildIdentity.read(source: root) == original)
    let file = root.appendingPathComponent("build.sh")
    try Data("edited".utf8).write(to: file)
    let edited = try BuildIdentity.read(source: root)
    #expect(edited.commit == original.commit)
    #expect(edited.dirty == true)
    #expect(edited.commitLabel.hasSuffix(" (modified)"))
    #expect(edited.sourceHash != original.sourceHash)
    try git(["add", "build.sh"], in: root)
    #expect(try BuildIdentity.read(source: root) == edited)
    try Data("new".utf8).write(to: root.appendingPathComponent("new file"))
    #expect(try BuildIdentity.read(source: root).sourceHash != edited.sourceHash)
    try FileManager.default.removeItem(at: root.appendingPathComponent("new file"))
    #expect(try BuildIdentity.read(source: root) == edited)
    try FileManager.default.removeItem(at: file)
    #expect(try BuildIdentity.read(source: root).sourceHash != edited.sourceHash)
}

@Test func installationDistinguishesMissingCurrentStaleAndLegacyBuilds() throws {
    let root = try checkout()
    defer { try? FileManager.default.removeItem(at: root) }
    let applications = root.appendingPathComponent("build/Applications")
    let resources = applications.appendingPathComponent("DevHub.app/Contents/Resources")
    var state = InstallationStatus.read(sourceDirectory: root.path, applicationsDirectory: applications.path)
    #expect(!state.installed && state.source != nil && state.upgradeAvailable == nil)
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    let executable = applications.appendingPathComponent("DevHub.app/Contents/MacOS/DevHub")
    try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
    state = InstallationStatus.read(sourceDirectory: root.path, applicationsDirectory: applications.path)
    #expect(state.installed && state.upgradeAvailable == nil)
    try BuildIdentity.read(source: root).write(to: resources.appendingPathComponent("build-info.plist"))
    state = InstallationStatus.read(sourceDirectory: root.path, applicationsDirectory: applications.path)
    #expect(state.upgradeAvailable == false)
    try git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-qm", "new revision"], in: root)
    state = InstallationStatus.read(sourceDirectory: root.path, applicationsDirectory: applications.path)
    #expect(state.upgradeAvailable == false)
    #expect(state.description == "Up to date")
    try BuildIdentity.read(source: root).write(to: resources.appendingPathComponent("build-info.plist"))
    try Data("changed".utf8).write(to: root.appendingPathComponent("build.sh"))
    state = InstallationStatus.read(sourceDirectory: root.path, applicationsDirectory: applications.path)
    #expect(state.upgradeAvailable == true)
    #expect(state.description.contains("local changes"))
    // Installing dirty source and then committing those exact files needs no rebuild.
    let installedDirty = try BuildIdentity.read(source: root)
    #expect(installedDirty.dirty == true)
    try installedDirty.write(to: resources.appendingPathComponent("build-info.plist"))
    try git(["add", "build.sh"], in: root)
    try git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "commit installed work"], in: root)
    state = InstallationStatus.read(sourceDirectory: root.path, applicationsDirectory: applications.path)
    #expect(state.source?.sourceHash == installedDirty.sourceHash)
    #expect(state.source?.commit != installedDirty.commit)
    #expect(state.source?.dirty == false)
    #expect(state.upgradeAvailable == false)
    #expect(state.description == "Up to date")
    #expect(Installation.updatePromptMessage(running: installedDirty, source: state.source, upstream: nil) == nil)
    state = InstallationStatus.read(sourceDirectory: root.appendingPathComponent("missing").path, applicationsDirectory: applications.path)
    #expect(state.installed && state.source == nil && state.upgradeAvailable == nil)
}

@Test func legacyBuildIdentityWithoutDirtyFlagRemainsReadable() throws {
    let data = try PropertyListSerialization.data(fromPropertyList: ["sourceDirectory": "/source", "commit": "1234567890abcdef", "sourceHash": "hash"], format: .xml, options: 0)
    let identity = try PropertyListDecoder().decode(BuildIdentity.self, from: data)
    #expect(identity.dirty == nil)
    #expect(identity.commitLabel == "1234567890ab")
}

@Test func installationCommandStreamsStepsAndReportsFailureOutput() async throws {
    let output = FileManager.default.temporaryDirectory.appendingPathComponent("devhub-command-\(UUID())")
    defer { try? FileManager.default.removeItem(at: output) }
    try await InstallationCommand.run("/bin/sh", ["-c", "printf '%s' \"$1\" > \"$2\"", "test", "space;$(literal)", output.path])
    #expect(try String(contentsOf: output, encoding: .utf8) == "space;$(literal)")
    do {
        try await InstallationCommand.run("/bin/sh", ["-c", "printf 'build failed\\n' >&2; exit 42"])
        Issue.record("Expected command failure")
    } catch {
        #expect(String(describing: error).contains("42"))
        #expect(String(describing: error).contains("build failed"))
    }
}

@Test func detachedProcessStartsInItsOwnSessionAndIsReaped() async throws {
    let status: Int32 = try await withCheckedThrowingContinuation { continuation in
        do {
            let pid = try DetachedProcess.launch("/bin/sleep", arguments: ["30"]) { continuation.resume(returning: $0) }
            #expect(getpgid(pid) == pid)
            #expect(getsid(pid) == pid)
            kill(pid, SIGTERM)
        } catch { continuation.resume(throwing: error) }
    }
    #expect(status == SIGTERM)
}

@Test func installationStepsAreDeliveredWhileTheToolIsStillRunning() async throws {
    let marker = FileManager.default.temporaryDirectory.appendingPathComponent("devhub-stream-\(UUID())")
    defer { try? FileManager.default.removeItem(at: marker) }
    // The command cannot finish successfully until its progress callback runs.
    try await InstallationCommand.run("/bin/sh", ["-c", "printf 'DEVHUB_STEP Starting\\n'; i=0; while [ ! -f \"$1\" ]; do i=$((i + 1)); [ \"$i\" -lt 100 ] || exit 42; sleep 0.02; done", "test", marker.path]) { line in
        if line == "DEVHUB_STEP Starting" { try? Data().write(to: marker) }
    }
}

@Test func detachedProcessReportsLaunchFailure() {
    #expect(throws: (any Error).self) { try DetachedProcess.launch("/devhub-missing-executable", arguments: []) }
}
