import BuildIdentity
import Foundation
import Testing
@testable import DevHub

private func runGit(_ args: [String], at root: URL) throws -> String {
    let result = try GitUpdateCommand.run(["-c", "user.name=Test", "-c", "user.email=test@example.invalid"] + args, directory: root)
    guard result.status == 0 else { throw MirrorError(result.output) }
    return result.output
}

private struct UpdateFixture {
    let root: URL
    let remote: URL
    let publisher: URL
    let checkout: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("devhub-git-updates-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        remote = root.appendingPathComponent("remote.git")
        publisher = root.appendingPathComponent("publisher")
        checkout = root.appendingPathComponent("checkout")
        _ = try runGit(["init", "--bare", "--initial-branch=main", remote.path], at: root)
        _ = try runGit(["clone", remote.path, publisher.path], at: root)
        _ = try runGit(["commit", "--allow-empty", "-m", "initial"], at: publisher)
        _ = try runGit(["push", "-u", "origin", "main"], at: publisher)
        _ = try runGit(["clone", remote.path, checkout.path], at: root)
    }

    func publish() throws {
        _ = try runGit(["commit", "--allow-empty", "-m", "upstream change"], at: publisher)
        _ = try runGit(["push"], at: publisher)
    }
}

@Test func fetchingFindsNewCommitsWithoutChangingHEADIndexOrDirtyFiles() throws {
    let f = try UpdateFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try Data("local file".utf8).write(to: f.checkout.appendingPathComponent("local.txt"))
    _ = try runGit(["add", "local.txt"], at: f.checkout)
    try Data("uncommitted edit".utf8).write(to: f.checkout.appendingPathComponent("local.txt"))
    let head = try runGit(["rev-parse", "HEAD"], at: f.checkout)
    let diff = try runGit(["diff", "HEAD"], at: f.checkout)
    let index = try Data(contentsOf: f.checkout.appendingPathComponent(".git/index"))
    #expect(GitSourceUpdates.check(source: f.checkout) == .tracked(branch: "main", upstream: "origin/main", ahead: 0, behind: 0))
    try f.publish()
    let state = GitSourceUpdates.check(source: f.checkout)
    #expect(state == .tracked(branch: "main", upstream: "origin/main", ahead: 0, behind: 1))
    #expect(state.hasUpdates)
    #expect(state.message.contains("1 commit behind"))
    #expect(try runGit(["rev-parse", "HEAD"], at: f.checkout) == head)
    #expect(try runGit(["diff", "HEAD"], at: f.checkout) == diff)
    #expect(try Data(contentsOf: f.checkout.appendingPathComponent(".git/index")) == index)
}

@Test func upstreamCheckUsesConfiguredRemoteAndReportsDivergence() throws {
    let f = try UpdateFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    _ = try runGit(["remote", "rename", "origin", "source"], at: f.checkout)
    _ = try runGit(["commit", "--allow-empty", "-m", "local change"], at: f.checkout)
    #expect(GitSourceUpdates.check(source: f.checkout) == .tracked(branch: "main", upstream: "source/main", ahead: 1, behind: 0))
    try f.publish()
    let state = GitSourceUpdates.check(source: f.checkout)
    #expect(state == .tracked(branch: "main", upstream: "source/main", ahead: 1, behind: 1))
    #expect(state.message.contains("Reconcile"))
}

@Test func upstreamCheckHandlesMissingTrackingDetachedHEADAndFetchFailures() throws {
    let f = try UpdateFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    _ = try runGit(["branch", "--unset-upstream"], at: f.checkout)
    #expect(GitSourceUpdates.check(source: f.checkout) == .noUpstream(branch: "main"))
    _ = try runGit(["checkout", "--detach"], at: f.checkout)
    #expect(GitSourceUpdates.check(source: f.checkout) == .detached)
    _ = try runGit(["checkout", "main"], at: f.checkout)
    _ = try runGit(["branch", "--set-upstream-to=origin/main"], at: f.checkout)
    _ = try runGit(["remote", "set-url", "origin", f.root.appendingPathComponent("missing.git").path], at: f.checkout)
    let failed = GitSourceUpdates.check(source: f.checkout)
    if case .failed = failed {} else { Issue.record("Failed fetch was treated as a successful check") }
    #expect(!failed.hasUpdates)
}

@Test func aRemovedRemoteBranchIsNotReportedAsUpToDate() throws {
    let f = try UpdateFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    _ = try runGit(["--git-dir", f.remote.path, "update-ref", "-d", "refs/heads/main"], at: f.root)
    if case .failed = GitSourceUpdates.check(source: f.checkout) {} else { Issue.record("Missing remote branch was treated as current") }
}

@Test func aLocalTrackingBranchDoesNotRequireNetworkFetch() throws {
    let f = try UpdateFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    _ = try runGit(["branch", "local-upstream"], at: f.checkout)
    _ = try runGit(["branch", "--set-upstream-to=local-upstream"], at: f.checkout)
    #expect(GitSourceUpdates.check(source: f.checkout) == .tracked(branch: "main", upstream: "local-upstream", ahead: 0, behind: 0))
}

@Test func gitUpdateCommandsTimeOutWithoutWaitingForPrompts() throws {
    let started = Date()
    #expect(throws: (any Error).self) {
        try GitUpdateCommand.run(["10"], directory: FileManager.default.temporaryDirectory, timeout: 0.05, executable: "/bin/sleep")
    }
    #expect(Date().timeIntervalSince(started) < 3)
}

@Test func startupNoticeDistinguishesUpstreamUpdatesAndLocalBuildChanges() throws {
    let f = try UpdateFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let running = try BuildIdentity.read(source: f.checkout)
    #expect(Installation.updatePromptMessage(running: running, source: running, upstream: nil) == nil)
    #expect(Installation.updatePromptMessage(running: running, source: running, upstream: .failed("offline")) == nil)
    _ = try runGit(["commit", "--allow-empty", "-m", "metadata-only revision"], at: f.checkout)
    let sameSource = try BuildIdentity.read(source: f.checkout)
    #expect(sameSource.commit != running.commit)
    #expect(sameSource.sourceHash == running.sourceHash)
    #expect(Installation.updatePromptMessage(running: running, source: sameSource, upstream: nil) == nil)
    let upstream = GitSourceUpdates.tracked(branch: "main", upstream: "origin/main", ahead: 0, behind: 2)
    #expect(Installation.updatePromptMessage(running: running, source: running, upstream: upstream)?.contains("2 commits behind") == true)
    try Data("local changes".utf8).write(to: f.checkout.appendingPathComponent("edited"))
    let changed = try BuildIdentity.read(source: f.checkout)
    #expect(Installation.updatePromptMessage(running: running, source: changed, upstream: nil)?.contains("checkout has changed") == true)
    #expect(Installation.updatePromptMessage(running: nil, source: changed, upstream: nil) == nil)
}

@Test @MainActor func disablingStartupPromptsPersistsAndSkipsAutomaticChecks() async throws {
    let suite = "devhub-update-prompts-test-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let initial = Installation(defaults: defaults, consumePreviousError: false)
    #expect(initial.promptsEnabled)
    initial.promptsEnabled = false
    let nextLaunch = Installation(defaults: defaults, consumePreviousError: false)
    #expect(!nextLaunch.promptsEnabled)
    await nextLaunch.checkAtStartup()
    #expect(!nextLaunch.checking && !nextLaunch.fetching && !nextLaunch.showUpdatePrompt)
    #expect(nextLaunch.sourceUpdates == nil)
    nextLaunch.promptsEnabled = true
    await nextLaunch.checkAtStartup() // Only once per launch, even if the option changes later.
    #expect(nextLaunch.sourceUpdates == nil)
    #expect(defaults.bool(forKey: "installation.updatePrompts"))
}

@Test @MainActor func startupCheckPromptsOnceAndManualChecksWorkWithPromptsDisabled() async throws {
    let f = try UpdateFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try Data("echo build".utf8).write(to: f.checkout.appendingPathComponent("build.sh"))
    let app = f.root.appendingPathComponent("DevHub.app")
    let resources = app.appendingPathComponent("Contents/Resources")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    let info = ["CFBundleIdentifier": "devhub.test.\(UUID())", "CFBundlePackageType": "APPL", "CFBundleExecutable": "DevHub"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: app.appendingPathComponent("Contents/Info.plist"))
    try BuildIdentity.read(source: f.checkout).write(to: resources.appendingPathComponent("build-info.plist"))
    let bundle = try #require(Bundle(url: app))
    let suite = "devhub-startup-test-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(f.root.appendingPathComponent("Applications").path, forKey: "installation.applicationsDirectory")
    let installation = Installation(defaults: defaults, bundle: bundle, consumePreviousError: false)
    #expect(installation.buildIdentity != nil)
    try f.publish()
    await installation.checkAtStartup()
    #expect(installation.showUpdatePrompt)
    #expect(installation.startupUpdateMessage.contains("1 commit behind"))
    #expect(installation.pendingCommits.commits.map(\.subject) == ["upstream change"])
    installation.showUpdatePrompt = false
    await installation.checkAtStartup()
    #expect(!installation.showUpdatePrompt)
    await installation.checkOnActivation()
    #expect(!installation.showUpdatePrompt) // Don't repeat a dismissed notice for the same source.
    try f.publish()
    await installation.checkOnActivation()
    #expect(!installation.showUpdatePrompt) // New commits still respect the hourly cap.
    let nextLaunch = Installation(defaults: defaults, bundle: bundle, consumePreviousError: false)
    await nextLaunch.checkAtStartup()
    #expect(!nextLaunch.showUpdatePrompt && nextLaunch.sourceUpdates == nil)
    UpdatePromptThrottle(defaults: defaults).recordPrompt(at: Date().addingTimeInterval(-3601))
    await installation.checkOnActivation()
    #expect(installation.showUpdatePrompt)
    #expect(installation.startupUpdateMessage.contains("2 commits behind"))
    #expect(installation.pendingCommits.commits.count == 2)
    installation.showUpdatePrompt = false
    installation.promptsEnabled = false
    installation.sourceUpdates = nil
    await installation.checkOnActivation()
    #expect(installation.sourceUpdates == nil)
    await installation.checkForUpdates()
    #expect(installation.sourceUpdates?.hasUpdates == true)
    #expect(!installation.showUpdatePrompt)
    let openWindow = Installation(defaults: defaults, bundle: bundle, consumePreviousError: false)
    openWindow.promptsEnabled = true
    openWindow.updateWindowVisible = true
    UpdatePromptThrottle(defaults: defaults).recordPrompt(at: Date().addingTimeInterval(-3601))
    await openWindow.checkAtStartup()
    #expect(openWindow.sourceUpdates?.hasUpdates == true)
    #expect(!openWindow.showUpdatePrompt)
}

@Test func automaticUpdatePromptAllowanceIsHourlyAndPersistsAcrossLaunches() throws {
    let suite = "devhub-prompt-throttle-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let now = Date(timeIntervalSince1970: 100_000)
    let throttle = UpdatePromptThrottle(defaults: defaults)
    #expect(throttle.allowsPrompt(at: now))
    throttle.recordPrompt(at: now)
    let relaunched = UpdatePromptThrottle(defaults: defaults)
    #expect(!relaunched.allowsPrompt(at: now))
    #expect(!relaunched.allowsPrompt(at: now.addingTimeInterval(3599)))
    #expect(relaunched.allowsPrompt(at: now.addingTimeInterval(3600)))
    relaunched.recordPrompt(at: now.addingTimeInterval(3600))
    #expect(!throttle.allowsPrompt(at: now.addingTimeInterval(3601)))
}

@Test func pendingCommitsExcludeInstalledHistoryAndIncludeFetchedAndLocalCommits() throws {
    let f = try UpdateFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let installed = try runGit(["rev-parse", "HEAD"], at: f.checkout)
    #expect(PendingCommits.read(since: installed, source: f.checkout, includeUpstream: false).commits.isEmpty)
    try f.publish()
    try f.publish()
    _ = try runGit(["commit", "--allow-empty", "-m", "Local improvement 📱"], at: f.checkout)
    _ = GitSourceUpdates.check(source: f.checkout)
    let history = PendingCommits.read(since: installed, source: f.checkout, includeUpstream: true)
    #expect(!history.unavailable && !history.hasMore)
    #expect(history.commits.count == 3)
    #expect(history.commits.filter { $0.subject == "upstream change" }.count == 2)
    #expect(history.commits.contains { $0.subject == "Local improvement 📱" })
    #expect(!history.commits.contains { $0.id == installed })
    #expect(Set(history.commits.map(\.id)).count == 3)
    let localOnly = PendingCommits.read(since: installed, source: f.checkout, includeUpstream: false)
    #expect(localOnly.commits.map(\.subject) == ["Local improvement 📱"])
    #expect(PendingCommits.read(since: String(repeating: "a", count: 40), source: f.checkout, includeUpstream: false).unavailable)
}

@Test func pendingCommitHistoryCapsLongListsAndSignalsMore() throws {
    let f = try UpdateFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let installed = try runGit(["rev-parse", "HEAD"], at: f.checkout)
    for index in 0..<102 {
        _ = try runGit(["commit", "--allow-empty", "-m", "Improvement \(index)"], at: f.checkout)
    }
    let history = PendingCommits.read(since: installed, source: f.checkout, includeUpstream: false)
    #expect(!history.unavailable && history.hasMore)
    #expect(history.commits.count == 100)
    #expect(history.commits.first?.subject == "Improvement 101")
}
