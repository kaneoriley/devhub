import SwiftUI

enum Links {
    static let repo = URL(string: "https://github.com/kaneoriley/droidhub")!
    static let original = URL(string: "https://github.com/eduardoborges/droidhub")!
    static let scrcpy = URL(string: "https://github.com/Genymobile/scrcpy")!
    static let robot = URL(string: "https://creativecommons.org/licenses/by/3.0/")!
}

/// Project link, used by the wizard's last step and the About window.
struct ProjectLink: View {
    var body: some View {
        HStack(spacing: 10) {
            Link(destination: Links.repo) { Label("View on GitHub", systemImage: "chevron.left.forwardslash.chevron.right") }
        }
        .buttonStyle(.glass)
        .controlSize(.large)
    }
}

struct AboutView: View {
    @Environment(Hub.self) private var hub

    var body: some View {
        @Bindable var hub = hub
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 128, height: 128)
            Text("DevHub").font(.system(size: 28, weight: .bold, design: .rounded))
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Text("Forked from")
                    Link("DroidHub", destination: Links.original)
                }
                .font(.title3.weight(.semibold))
                Text("Original project by Eduardo Borges")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            Text("Android emulators and phones, iOS simulators, and connected iPhones and iPads in one window.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)  // a Window sizes Text to one line otherwise
                .padding(.top, 4)
            ProjectLink().padding(.vertical, 12)
            VStack(spacing: 6) {
                Toggle("Demo Mode", isOn: $hub.demoMode)
                    .toggleStyle(.switch)
                    .fixedSize()
                Text("Show model names instead of custom device names.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 12)
            VStack(spacing: 4) {
                Text("MIT License")
                Text("Android mirroring uses the [scrcpy](\(Links.scrcpy)) server by Genymobile, Apache 2.0.")
                Text("Apple devices use frameworks from the selected Xcode installation.")
                Text("The bugdroid is based on the [Android robot](\(Links.robot)) by Google, CC BY 3.0.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .tint(.secondary)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
        .frame(width: 440)
        .fixedSize()
    }
}

/// First-launch wizard, also under Help. Seen once means seen: closing it early doesn't bring it back.
struct WelcomeView: View {
    @AppStorage("welcomed") private var welcomed = false
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var step = 0
    private static let keys = [
        ("Click, drag, scroll", "Touch and scroll the device"),
        ("Hold ⌘, then click and drag", "Two-finger gesture around the pointer"),
        ("Right click or Esc", "Back on Android"),
        ("⇧⌘H", "Home"),
        ("⌘S", "Screenshot to the Desktop and clipboard"),
        ("⌘→", "Rotate"),
        ("⌘V", "Paste the Mac clipboard"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Group {
                switch step {
                case 0: welcome
                case 1: sdk
                case 2: controls
                default: ready
                }
            }
            .frame(maxWidth: 440)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            .id(step)
            Spacer()
            HStack(spacing: 8) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule().fill(i == step ? Color.primary : Color.secondary.opacity(0.3)).frame(width: i == step ? 24 : 8, height: 8)
                }
            }
            .padding(.bottom, 28)
        }
        .padding(.horizontal, 40)
        .frame(width: 560, height: 460)
        .animation(.spring(duration: 0.45), value: step)
        .onAppear { welcomed = true }
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 112, height: 112)
            Text("Welcome to DevHub").font(.system(size: 32, weight: .bold, design: .rounded))
            Text("Android emulators and phones, iOS simulators, and connected iPhones and iPads in one window. Boot virtual devices, interact with their screens and manage device settings. Physical Apple screen sharing requires iOS/iPadOS 27 or newer; older devices still appear in the list.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            next("Get Started")
        }
    }

    private var sdk: some View {
        VStack(spacing: 16) {
            Image(systemName: "shippingbox").font(.system(size: 48)).foregroundStyle(.tint)
            Text("Device Setup").font(.system(size: 28, weight: .bold, design: .rounded))
            Text("Android uses your SDK in ~/Library/Android/sdk or ANDROID_HOME. Device profiles are bundled; Android Studio is optional. Enable USB debugging for physical Android devices. Apple simulators and physical iPhones and iPads use the selected full Xcode installation. Connect your Apple device and follow any trust or unlock prompts.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 6) {
                check("adb (platform-tools)", SDK.adb)
                check("emulator", SDK.emulator)
                Text(SDK.root.path).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            .padding(.vertical, 4)
            next("Continue")
        }
    }

    private func check(_ title: String, _ path: String) -> some View {
        let ok = FileManager.default.fileExists(atPath: path)
        return Label(title, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(ok ? .green : .red)
    }

    private var controls: some View {
        VStack(spacing: 16) {
            Image(systemName: "keyboard").font(.system(size: 48)).foregroundStyle(.tint)
            Text("Mouse and Keyboard").font(.system(size: 28, weight: .bold, design: .rounded))
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 5) {
                ForEach(Self.keys, id: \.0) { key, action in
                    GridRow {
                        Text(key).fontWeight(.medium).gridColumnAlignment(.trailing)
                        Text(action).foregroundStyle(.secondary)
                    }
                }
            }
            Text("For Android devices and iOS simulators. Physical Apple devices use Xcode’s screen-sharing controls.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            next("Continue")
        }
    }

    private var ready: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(.tint)
            Text("All set!").font(.system(size: 28, weight: .bold, design: .rounded))
            Text("DevHub is free and open source. Find the source, report issues, or contribute on GitHub.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            ProjectLink()
            Button("Open DevHub") { dismissWindow(id: "welcome") }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 8)
        }
    }

    private func next(_ title: String) -> some View {
        Button(title) { step += 1 }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 8)
    }
}
