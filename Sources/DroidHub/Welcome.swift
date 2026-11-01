import SwiftUI

enum Links {
    static let repo = URL(string: "https://github.com/eduardoborges/droidhub")!
    static let sponsor = URL(string: "https://github.com/sponsors/eduardoborges")!
    static let donate = URL(string: "https://github.com/sponsors/eduardoborges?frequency=one-time")!
    static let scrcpy = URL(string: "https://github.com/Genymobile/scrcpy")!
    static let robot = URL(string: "https://creativecommons.org/licenses/by/3.0/")!
}

/// Star, sponsor and donate, used by the wizard's last step and the About window.
struct SupportButtons: View {
    var body: some View {
        HStack(spacing: 10) {
            Link(destination: Links.repo) { Label("Star on GitHub", systemImage: "star") }
            Link(destination: Links.sponsor) { Label("Sponsor", systemImage: "heart") }
            Link(destination: Links.donate) { Label("Donate", systemImage: "cup.and.saucer") }
        }
        .buttonStyle(.glass)
        .controlSize(.large)
    }
}

struct AboutView: View {
    private let info = Bundle.main.infoDictionary ?? [:]

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 128, height: 128)
            Text("DroidHub").font(.system(size: 28, weight: .bold, design: .rounded))
            Text("Version \(info["CFBundleShortVersionString"] ?? "dev") · scrcpy \(info["ScrcpyVersion"] ?? "?")")
                .foregroundStyle(.secondary)
            Text("Android emulators, phones, and Apple simulators in one window, with the screen live and clickable.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)  // a Window sizes Text to one line otherwise
                .padding(.top, 4)
            SupportButtons().padding(.vertical, 12)
            VStack(spacing: 4) {
                Text("Made by [Eduardo Borges](https://github.com/eduardoborges) · MIT License")
                Text("Built on the [scrcpy](\(Links.scrcpy)) server by Genymobile, Apache 2.0.")
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
        ("Right click or Esc", "Back"),
        ("⇧⌘H", "Home"),
        ("⌘S", "Screenshot to the Desktop and clipboard"),
        ("⌘→", "Rotate"),
        ("⌘V", "Paste the Mac clipboard"),
        ("⌘M", "Menu key, the React Native dev menu"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Group {
                switch step {
                case 0: welcome
                case 1: sdk
                case 2: controls
                default: support
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
            Text("Welcome to DroidHub").font(.system(size: 32, weight: .bold, design: .rounded))
            Text("Android devices and Apple simulators in one window, with the screen live and clickable. Boot virtual devices, type on the screen, share the clipboard and follow Android logs.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            next("Get Started")
        }
    }

    private var sdk: some View {
        VStack(spacing: 16) {
            Image(systemName: "shippingbox").font(.system(size: 48)).foregroundStyle(.tint)
            Text("Android SDK").font(.system(size: 28, weight: .bold, design: .rounded))
            Text("DroidHub uses your Android SDK, in ~/Library/Android/sdk or wherever ANDROID_HOME points. Android Studio is optional: device profiles are bundled, and SDK tools and system images can be installed separately. Apple simulators use the selected Xcode installation. Phones show up when USB debugging is on.")
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
            next("Continue")
        }
    }

    private var support: some View {
        VStack(spacing: 16) {
            Image(systemName: "heart.fill").font(.system(size: 48)).foregroundStyle(.pink).symbolEffect(.pulse)
            Text("All set!").font(.system(size: 28, weight: .bold, design: .rounded))
            Text("DroidHub is free and open source. If it saves you time, a star or a sponsorship keeps it going.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            SupportButtons()
            Button("Open DroidHub") { dismissWindow(id: "welcome") }
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
