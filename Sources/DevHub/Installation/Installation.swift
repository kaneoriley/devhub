import AppKit
import BuildIdentity
import Observation

struct InstallationStatus {
    var installed = false
    var source: BuildIdentity?
    var installedIdentity: BuildIdentity?
    var error: String?

    var upgradeAvailable: Bool? {
        guard let source, let installedIdentity else { return nil }
        return source.sourceHash != installedIdentity.sourceHash
    }

    var description: String {
        if error != nil { return "Unable to check installation" }
        if source == nil { return "Source checkout unavailable" }
        if !installed { return "Not installed" }
        switch upgradeAvailable {
        case true:
            return source?.commit == installedIdentity?.commit ? "Upgrade available — local changes" : "Upgrade available — different commit"
        case false: return "Up to date"
        case nil: return "Installed build has no source hash"
        }
    }

    static func read(sourceDirectory: String?, applicationsDirectory: String) -> Self {
        let bundle = URL(fileURLWithPath: applicationsDirectory).appendingPathComponent("DevHub.app")
        var status = Self(installed: FileManager.default.isExecutableFile(atPath: bundle.appendingPathComponent("Contents/MacOS/DevHub").path))
        status.installedIdentity = try? BuildIdentity.load(from: bundle.appendingPathComponent("Contents/Resources/build-info.plist"))
        guard let sourceDirectory, FileManager.default.fileExists(atPath: URL(fileURLWithPath: sourceDirectory).appendingPathComponent("build.sh").path) else { return status }
        do { status.source = try BuildIdentity.read(source: URL(fileURLWithPath: sourceDirectory)) }
        catch { status.error = error.localizedDescription }
        return status
    }
}

@MainActor @Observable
final class Installation {
    private let defaults: UserDefaults
    private let promptThrottle: UpdatePromptThrottle
    let buildIdentity: BuildIdentity?
    var applicationsDirectory: String
    var status = InstallationStatus()
    var checking = false
    var busy = false
    var progress = ""
    var progressFraction = 0.0
    var error: String?
    private var refreshGeneration = 0
    var sourceUpdates: GitSourceUpdates?
    var fetching = false
    var showUpdatePrompt = false
    var startupUpdateMessage = ""
    var pendingCommits = PendingCommits()
    var promptsEnabled: Bool {
        didSet { defaults.set(promptsEnabled, forKey: "installation.updatePrompts") }
    }
    private var startupChecked = false
    private var automaticTask: Task<Void, Never>?
    private var lastPromptSignature: String?
    private var updateTask: Task<Void, Never>?
    var updateWindowVisible = false

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main, consumePreviousError: Bool = true) {
        self.defaults = defaults
        promptThrottle = UpdatePromptThrottle(defaults: defaults)
        promptsEnabled = defaults.object(forKey: "installation.updatePrompts") as? Bool ?? true
        buildIdentity = bundle.url(forResource: "build-info", withExtension: "plist").flatMap { try? BuildIdentity.load(from: $0) }
        applicationsDirectory = defaults.string(forKey: "installation.applicationsDirectory") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        if consumePreviousError, let text = try? String(contentsOf: Self.resultFile, encoding: .utf8) {
            error = text
            try? FileManager.default.removeItem(at: Self.resultFile)
        }
    }

    var sourceDirectory: String? { buildIdentity?.sourceDirectory }
    var canInstall: Bool { !checking && !busy && status.source != nil && !status.installed }
    var canUpgrade: Bool { !checking && !busy && status.source != nil && status.installed && status.upgradeAvailable != false }

    func setApplicationsDirectory(_ path: String) {
        guard !busy else { return }
        applicationsDirectory = URL(fileURLWithPath: path).standardizedFileURL.path
        defaults.set(applicationsDirectory, forKey: "installation.applicationsDirectory")
        refresh()
    }

    func refresh() {
        guard !busy else { return }
        Task { await readInstallation() }
    }

    private func readInstallation() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        let source = sourceDirectory, applications = applicationsDirectory
        checking = true
        let result = await Task.detached(priority: .utility) {
            InstallationStatus.read(sourceDirectory: source, applicationsDirectory: applications)
        }.value
        guard generation == refreshGeneration, !busy else { return }
        status = result
        checking = false
    }

    func checkForUpdates() async {
        if let updateTask { await updateTask.value; return }
        guard !busy else { return }
        guard let sourceDirectory else { await readInstallation(); return }
        fetching = true
        let task = Task {
            let fetch = Task.detached(priority: .utility) {
                GitSourceUpdates.check(source: URL(fileURLWithPath: sourceDirectory))
            }
            await readInstallation()
            sourceUpdates = await fetch.value
            if let installedCommit = buildIdentity?.commit {
                let includeUpstream: Bool
                if case .tracked? = sourceUpdates { includeUpstream = true } else { includeUpstream = false }
                pendingCommits = await Task.detached(priority: .utility) {
                    PendingCommits.read(since: installedCommit, source: URL(fileURLWithPath: sourceDirectory), includeUpstream: includeUpstream)
                }.value
            }
            fetching = false
        }
        updateTask = task
        await task.value
        updateTask = nil
    }

    func checkAtStartup() async {
        guard !startupChecked else { return }
        startupChecked = true
        await checkAutomatically()
    }

    func checkOnActivation() async {
        if !startupChecked { await checkAtStartup(); return }
        await checkAutomatically()
    }

    private func checkAutomatically() async {
        if let automaticTask { await automaticTask.value; return }
        guard promptsEnabled, !busy, promptThrottle.allowsPrompt() else { return }
        let task = Task { await performAutomaticCheck() }
        automaticTask = task
        await task.value
        automaticTask = nil
    }

    private func performAutomaticCheck() async {
        guard promptsEnabled else { return }
        await checkForUpdates()
        guard promptsEnabled, !busy, !updateWindowVisible, !showUpdatePrompt, promptThrottle.allowsPrompt() else { return }
        if let message = Self.updatePromptMessage(running: buildIdentity, source: status.source, upstream: sourceUpdates) {
            let signature = ([message, status.source?.commit ?? "", status.source?.sourceHash ?? ""] + pendingCommits.commits.map(\.id)).joined(separator: "\0")
            guard signature != lastPromptSignature else { return }
            lastPromptSignature = signature
            startupUpdateMessage = message
            promptThrottle.recordPrompt()
            showUpdatePrompt = true
        }
    }

    nonisolated static func updatePromptMessage(running: BuildIdentity?, source: BuildIdentity?, upstream: GitSourceUpdates?) -> String? {
        if let upstream, upstream.hasUpdates { return upstream.message }
        if let source, let running, source.sourceHash != running.sourceHash {
            return "Your source checkout has changed since this DevHub build. Open Check for Updates to build and install it."
        }
        return nil
    }

    func install() {
        guard canInstall || canUpgrade, let sourceDirectory else { return }
        busy = true
        progressFraction = 0
        error = nil
        refreshGeneration += 1
        Task {
            var staging: URL?
            do {
                let source = URL(fileURLWithPath: sourceDirectory)
                let applications = URL(fileURLWithPath: applicationsDirectory)
                let destination = applications.appendingPathComponent("DevHub.app")
                let build = source.appendingPathComponent("build/DevHub.app")
                guard destination.resolvingSymlinksInPath() != build.resolvingSymlinksInPath() else {
                    throw MirrorError("Choose an Applications directory outside the checkout's build folder.")
                }
                setProgress("Preparing build", fraction: 0.05)
                // Build in a separate output directory so a copy launched from build/ can update safely.
                let output = FileManager.default.temporaryDirectory.appendingPathComponent("devhub-build-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: output) }
                var environment = ProcessInfo.processInfo.environment
                environment["DEVHUB_BUILD_OUTPUT"] = output.path
                try await InstallationCommand.run("/bin/sh", [source.appendingPathComponent("build.sh").path], directory: source, environment: environment) { line in
                    guard line.hasPrefix("DEVHUB_STEP ") else { return }
                    let step = String(line.dropFirst("DEVHUB_STEP ".count))
                    Task { @MainActor in
                        let fraction: Double = step.hasPrefix("Preparing") ? 0.1 : step.hasPrefix("Building") ? 0.25 : step.hasPrefix("Packaging") ? 0.7 : 0.8
                        self.setProgress(step, fraction: fraction)
                    }
                }
                let builtApp = output.appendingPathComponent("DevHub.app")
                let identity = try BuildIdentity.load(from: builtApp.appendingPathComponent("Contents/Resources/build-info.plist"))
                let current = try await Task.detached(priority: .utility) { try BuildIdentity.read(source: source) }.value
                guard identity.sourceHash == current.sourceHash else { throw MirrorError("Source files changed during the build. Try again.") }
                setProgress("Staging installation", fraction: 0.9)
                try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
                let prepared = applications.appendingPathComponent(".devhub-install-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: false)
                staging = prepared
                let stagedApp = prepared.appendingPathComponent("DevHub.app")
                try await InstallationCommand.run("/usr/bin/ditto", [builtApp.path, stagedApp.path])
                try await InstallationCommand.run("/usr/bin/codesign", ["--verify", "--strict", stagedApp.path])
                guard FileManager.default.isExecutableFile(atPath: stagedApp.appendingPathComponent("Contents/MacOS/DevHub").path) else {
                    throw MirrorError("The built DevHub executable is missing.")
                }
                try FileManager.default.createDirectory(at: Self.resultFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                let helper = prepared.appendingPathComponent("install-update.sh")
                try FileManager.default.copyItem(at: builtApp.appendingPathComponent("Contents/Resources/install-update.sh"), to: helper)
                // Another app copy must not keep running against the destination being replaced.
                let others = NSRunningApplication.runningApplications(withBundleIdentifier: "com.kaneoriley.devhub")
                    .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
                for other in others { other.terminate() }
                for _ in 0..<50 {
                    if others.allSatisfy(\.isTerminated) { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard others.allSatisfy(\.isTerminated) else { throw MirrorError("Quit the other DevHub copy before installing.") }
                setProgress("Installing and restarting DevHub", fraction: 0.98)
                try DetachedProcess.launch("/bin/sh", arguments: [helper.path, String(ProcessInfo.processInfo.processIdentifier), prepared.path, destination.path, Self.resultFile.path])
                staging = nil // The independent helper now owns cleanup and rollback.
                busy = false // Dismiss the progress sheet before requesting normal termination.
                DispatchQueue.main.async { NSApp.terminate(nil) }
            } catch {
                if let staging { try? FileManager.default.removeItem(at: staging) }
                self.error = String(describing: error)
                busy = false
                refresh()
            }
        }
    }

    private func setProgress(_ step: String, fraction: Double) {
        guard fraction >= progressFraction else { return }
        progress = step
        progressFraction = fraction
    }

    private static var resultFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DevHub/installation-error.txt")
    }
}

enum InstallationCommand {
    static func run(_ tool: String, _ arguments: [String], directory: URL? = nil,
                    environment: [String: String]? = nil, onLine: @escaping (String) -> Void = { _ in }) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: tool)
                    process.arguments = arguments
                    process.currentDirectoryURL = directory
                    process.environment = environment
                    process.standardInput = FileHandle.nullDevice
                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = pipe
                    try process.run()
                    defer {
                        try? pipe.fileHandleForReading.close()
                        if process.isRunning { process.terminate(); process.waitUntilExit() }
                    }
                    var tail = Data(), line = Data()
                    while true {
                        // read(upToCount:) can wait to fill its buffer, hiding steps until the tool exits.
                        let chunk = pipe.fileHandleForReading.availableData
                        if chunk.isEmpty { break }
                        tail.append(chunk)
                        tail = Data(tail.suffix(16 * 1024))
                        line.append(chunk)
                        while let newline = line.firstIndex(of: 10) {
                            onLine(String(decoding: line[..<newline], as: UTF8.self))
                            line.removeSubrange(...newline)
                        }
                        if line.count > 16 * 1024 { line = Data(line.suffix(16 * 1024)) }
                    }
                    if !line.isEmpty { onLine(String(decoding: line, as: UTF8.self)) }
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else {
                        throw MirrorError("\(URL(fileURLWithPath: tool).lastPathComponent) failed (\(process.terminationStatus)).\n\(String(decoding: tail, as: UTF8.self))")
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
