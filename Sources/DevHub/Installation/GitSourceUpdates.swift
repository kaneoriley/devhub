import Foundation
import Darwin

enum GitSourceUpdates: Equatable {
    case tracked(branch: String, upstream: String, ahead: Int, behind: Int)
    case noUpstream(branch: String)
    case detached
    case failed(String)

    var hasUpdates: Bool {
        if case .tracked(_, _, _, let behind) = self { return behind > 0 }
        return false
    }

    var title: String {
        switch self {
        case .tracked(_, _, _, let behind) where behind > 0: return "Update your Git branch"
        case .tracked: return "Git branch checked"
        case .noUpstream: return "No upstream branch configured"
        case .detached: return "Checkout is at a detached commit"
        case .failed: return "Couldn’t check upstream changes"
        }
    }

    var message: String {
        switch self {
        case let .tracked(branch, upstream, ahead, behind):
            if behind > 0 {
                let behindText = "\(branch) is \(behind) \(behind == 1 ? "commit" : "commits") behind \(upstream)."
                if ahead > 0 {
                    return "\(behindText) It also has \(ahead) local \(ahead == 1 ? "commit" : "commits"). Reconcile the branches using Git, then upgrade DevHub."
                }
                return "\(behindText) Update the checkout using Git, then upgrade DevHub to include the latest changes."
            }
            if ahead > 0 { return "\(branch) is \(ahead) \(ahead == 1 ? "commit" : "commits") ahead of \(upstream)." }
            return "\(branch) is up to date with \(upstream)."
        case .noUpstream(let branch): return "Configure an upstream for \(branch) using Git to check for new commits."
        case .detached: return "Switch to a branch with an upstream to check for new commits."
        case .failed(let detail): return detail
        }
    }

    static func check(source: URL) -> Self {
        do {
            func run(_ args: [String]) throws -> ToolResult { try GitUpdateCommand.run(args, directory: source) }
            func checked(_ args: [String]) throws -> String {
                let result = try run(args)
                guard result.status == 0 else { throw MirrorError(result.output.isEmpty ? "Git could not check this checkout." : result.output) }
                return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let head = try run(["symbolic-ref", "--quiet", "HEAD"])
            if head.status == 1 { return .detached }
            guard head.status == 0 else { throw MirrorError("Cannot read the checkout's current branch.") }
            let branchRef = head.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let branch = String(branchRef.dropFirst("refs/heads/".count))
            let trackingArguments = ["for-each-ref", "--format=%(upstream)%00%(upstream:short)%00%(upstream:remotename)%00%(upstream:remoteref)", branchRef]
            let tracking = try checked(trackingArguments)
            let fields = tracking.components(separatedBy: "\0")
            guard fields.count == 4, !fields[0].isEmpty, !fields[2].isEmpty else { return .noUpstream(branch: branch) }
            let upstream = fields[0], upstreamName = fields[1], remote = fields[2], remoteRef = fields[3]
            if remote != "." {
                // Explicitly update only the tracking ref, independent of configured fetch refspecs.
                guard upstream.hasPrefix("refs/remotes/"), remoteRef.hasPrefix("refs/heads/") else {
                    throw MirrorError("The branch does not track a remote branch. Check its Git configuration.")
                }
                _ = try checked(["fetch", "--quiet", "--no-tags", "--no-recurse-submodules", "--no-auto-maintenance", "--no-write-fetch-head", "--refmap=", "--", remote, "+\(remoteRef):\(upstream)"])
            }
            guard try checked(["symbolic-ref", "--quiet", "HEAD"]) == branchRef,
                  try checked(trackingArguments) == tracking else {
                throw MirrorError("The checked-out branch changed during the fetch. Check again.")
            }
            let counts = try checked(["rev-list", "--left-right", "--count", "HEAD...\(upstream)", "--"])
                .split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
            guard counts.count == 2 else { throw MirrorError("Git returned an unreadable branch comparison.") }
            return .tracked(branch: branch, upstream: upstreamName, ahead: counts[0], behind: counts[1])
        } catch { return .failed(String(describing: error)) }
    }
}

/// Noninteractive and bounded, including when a remote is offline or credentials are unavailable.
enum GitUpdateCommand {
    static func run(_ arguments: [String], directory: URL, timeout: TimeInterval = 30,
                    executable: String = "/usr/bin/git", outputLimit: UInt64 = 8192) throws -> ToolResult {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("devhub-git-\(UUID())")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: log) }
        let output = try FileHandle(forUpdating: log)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_ASKPASS"] = "/usr/bin/false"
        environment["SSH_ASKPASS"] = "/usr/bin/false"
        environment["GCM_INTERACTIVE"] = "Never"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        let timedOut = finished.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        if timedOut { throw MirrorError("Git fetch timed out. Check your network and Git credentials, then try again.") }
        let length = try output.seekToEnd()
        try output.seek(toOffset: length > outputLimit ? length - outputLimit : 0)
        let text = String(decoding: try output.readToEnd() ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return ToolResult(status: process.terminationStatus, output: text)
    }
}
