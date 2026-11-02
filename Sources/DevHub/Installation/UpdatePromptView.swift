import SwiftUI

struct UpdatePromptView: View {
    let installation: Installation
    let openUpdates: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("DevHub Update Available", systemImage: "arrow.down.app")
                .font(.title3.weight(.semibold))
            Text(installation.startupUpdateMessage).fixedSize(horizontal: false, vertical: true)
            if !installation.pendingCommits.commits.isEmpty {
                Text("Commits not in this build").font(.subheadline.weight(.medium))
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(installation.pendingCommits.commits) { commit in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(commit.subject).lineLimit(2).help(commit.subject)
                                Text(String(commit.id.prefix(12))).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            if commit.id != installation.pendingCommits.commits.last?.id { Divider().padding(.horizontal, 10) }
                        }
                    }
                }
                .frame(height: min(CGFloat(installation.pendingCommits.commits.count) * 58, 220))
                .scrollBounceBehavior(.basedOnSize)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                if installation.pendingCommits.hasMore {
                    Text("Showing the latest 100 commits.").font(.caption).foregroundStyle(.secondary)
                }
            } else if installation.pendingCommits.unavailable {
                Text("Commit history is unavailable for this build’s revision.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No new commits; this update contains local working-tree changes.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Later", role: .cancel) { installation.showUpdatePrompt = false }
                    .keyboardShortcut(.cancelAction)
                Button("Check for Updates…") {
                    installation.showUpdatePrompt = false
                    openUpdates()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}
