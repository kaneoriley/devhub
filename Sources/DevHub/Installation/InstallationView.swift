import SwiftUI

struct InstallationView: View {
    @Bindable var installation: Installation
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            InstallationSection("Location") {
                LabeledContent("Source directory") {
                    Text(installation.sourceDirectory ?? "Not embedded — rebuild with build.sh")
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .help(installation.sourceDirectory ?? "Build with build.sh to embed the source directory.")
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .contain)
                .padding(.vertical, 10)
                Divider()
                LabeledContent("Applications directory") {
                    HStack {
                        Text(installation.applicationsDirectory).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).help(installation.applicationsDirectory).textSelection(.enabled)
                        Button("Choose…") { chooseApplications() }
                    }
                }
                .accessibilityElement(children: .contain)
                .padding(.vertical, 10)
            }
            InstallationSection("Actions") {
                LabeledContent("Status") {
                    Group {
                        if installation.checking {
                            HStack { ProgressView().controlSize(.small); Text("Checking…").foregroundStyle(.secondary) }
                        } else {
                            Text(installation.status.description).foregroundStyle(.secondary)
                                .lineLimit(1).help(installation.status.description)
                        }
                    }
                    .frame(height: 18, alignment: .trailing)
                }
                .padding(.vertical, 10)
                Divider()
                InstallationIdentityRow("Installed source commit", value: installation.status.installedIdentity?.commitLabel,
                                        detail: installation.status.installedIdentity?.commit)
                Divider()
                InstallationIdentityRow("Installed source hash", value: installation.status.installedIdentity.map { String($0.sourceHash.prefix(12)) },
                                        detail: installation.status.installedIdentity?.sourceHash)
                Divider()
                InstallationIdentityRow("Checkout source commit", value: installation.status.source?.commitLabel,
                                        detail: installation.status.source?.commit)
                Divider()
                InstallationIdentityRow("Checkout source hash", value: installation.status.source.map { String($0.sourceHash.prefix(12)) },
                                        detail: installation.status.source?.sourceHash)
                Divider()
                LabeledContent {
                    InstallationActionButton(installation.status.installed ? "Installed" : "Install", enabled: installation.canInstall) { installation.install() }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Install")
                        Text("Build and install DevHub in the Applications directory.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 10)
                Divider()
                LabeledContent {
                    InstallationActionButton(installation.status.installed && installation.status.upgradeAvailable == false ? "Up to date" : "Upgrade",
                                             enabled: installation.canUpgrade) { installation.install() }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Upgrade")
                        Text("Rebuild from this checkout, install, and restart DevHub.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 10)
            }
            ZStack(alignment: .topLeading) {
                Color.clear
                if let error = installation.status.error {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(4).help(error).textSelection(.enabled)
                } else if installation.fetching {
                    HStack { ProgressView().controlSize(.small); Text("Fetching upstream changes…").foregroundStyle(.secondary) }
                } else if let updates = installation.sourceUpdates {
                    VStack(alignment: .leading, spacing: 5) {
                        Label(updates.title, systemImage: updates.hasUpdates ? "arrow.down.circle" : "arrow.triangle.branch")
                            .font(.subheadline.weight(.medium))
                        Text(updates.message).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(4).help(updates.message).textSelection(.enabled)
                    }
                }
            }
            .frame(height: 76)
            Toggle("Show update prompts", isOn: $installation.promptsEnabled)
                .toggleStyle(.switch)
                .help("Check at startup and when DevHub returns from the background.")
            Text("Fetches the branch’s configured upstream to check for new commits. Update your checkout using Git before upgrading; Upgrade builds the current local source, including uncommitted changes.")
                .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Check Again") { Task { await installation.checkForUpdates() } }.disabled(installation.checking || installation.fetching) }
        }
        .labeledContentStyle(InstallationRowStyle())
        .padding(20)
        .disabled(installation.busy)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .task { await installation.checkForUpdates() }
        .onAppear { installation.updateWindowVisible = true; installation.showUpdatePrompt = false }
        .onDisappear { installation.updateWindowVisible = false }
        .onChange(of: activeState) { _, state in if state != .inactive { installation.refresh() } }
        .sheet(isPresented: Binding(get: { installation.busy }, set: { _ in })) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Installing DevHub").font(.headline)
                ProgressView(value: installation.progressFraction)
                Text(installation.progress).foregroundStyle(.secondary)
                Text("DevHub will restart when installation is ready. Your virtual devices will keep running.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24).frame(width: 400)
            .interactiveDismissDisabled()
        }
        .alert("Installation Failed", isPresented: Binding(get: { installation.error != nil }, set: { if !$0 { installation.error = nil } })) {
            Button("OK", role: .cancel) { installation.error = nil }
        } message: { Text(installation.error ?? "") }
    }

    private func chooseApplications() {
        let panel = NSOpenPanel()
        panel.title = "Choose Applications Directory"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: installation.applicationsDirectory)
        panel.begin { response in
            if response == .OK, let url = panel.url { installation.setApplicationsDirectory(url.path) }
        }
    }
}

private struct InstallationIdentityRow: View {
    let title: String
    let value: String?
    let detail: String?

    init(_ title: String, value: String?, detail: String?) {
        self.title = title
        self.value = value
        self.detail = detail
    }

    var body: some View {
        LabeledContent(title) {
            Text(value ?? "—").monospaced().foregroundStyle(.secondary)
                .lineLimit(1).help(detail ?? "No build identity available").textSelection(.enabled)
                .frame(height: 18, alignment: .trailing)
        }
        .padding(.vertical, 10)
    }
}

private struct InstallationActionButton: View {
    let title: String
    let enabled: Bool
    let action: () -> Void

    init(_ title: String, enabled: Bool, action: @escaping () -> Void) {
        self.title = title
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        if enabled {
            Button(title, action: action).buttonStyle(.borderedProminent).tint(.accentColor)
        } else {
            Button(title, action: action).buttonStyle(.bordered).disabled(true)
        }
    }
}

private struct InstallationRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 16) {
            configuration.label
            Spacer(minLength: 12)
            configuration.content.multilineTextAlignment(.trailing)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct InstallationSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 10)
            VStack(spacing: 0) { content }
                .padding(.horizontal, 12)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
