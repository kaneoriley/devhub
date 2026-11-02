import Foundation

struct PendingCommit: Identifiable, Equatable {
    let id: String
    let subject: String
}

struct PendingCommits {
    var commits: [PendingCommit] = []
    var hasMore = false
    var unavailable = false

    static func read(since installed: String, source: URL, includeUpstream: Bool) -> Self {
        do {
            func git(_ args: [String]) throws -> String {
                let result = try GitUpdateCommand.run(args, directory: source, outputLimit: 1024 * 1024)
                guard result.status == 0 else { throw MirrorError("Commit history unavailable") }
                return result.output
            }
            // Resolve to object IDs before using a revision supplied by the app's metadata.
            let installedID = try git(["rev-parse", "--verify", "--end-of-options", "\(installed)^{commit}"])
            var revisions = [try git(["rev-parse", "--verify", "HEAD^{commit}"])]
            if includeUpstream { revisions.append(try git(["rev-parse", "--verify", "@{upstream}^{commit}"])) }
            let output = try git(["log", "--topo-order", "--max-count=101", "--format=%H%x00%s%x00"] + revisions + ["^\(installedID)", "--"])
            let fields = output.components(separatedBy: "\0")
            var commits: [PendingCommit] = []
            for index in stride(from: 0, to: fields.count - 1, by: 2) where index + 1 < fields.count {
                let id = fields[index].trimmingCharacters(in: .whitespacesAndNewlines)
                guard (id.count == 40 || id.count == 64), id.allSatisfy(\.isHexDigit) else { throw MirrorError("Unreadable commit history") }
                commits.append(PendingCommit(id: id, subject: fields[index + 1]))
            }
            return Self(commits: Array(commits.prefix(100)), hasMore: commits.count > 100)
        } catch { return Self(unavailable: true) }
    }
}
