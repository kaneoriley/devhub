import SwiftUI
import SimulatorBridge

struct AppleDeviceView: View {
    let device: Device
    let apple: AppleDevice
    @State private var native: AnyView?
    @State private var failure: String?
    @State private var requirement: AppleDevice.Requirement?
    @State private var attempt = 0

    var body: some View {
        ZStack {
            if let requirement { requirementView(requirement) }
            else if let native { native.transition(.opacity) }
            else if let failure {
                ContentUnavailableView {
                    Label("Couldn't Open Device", systemImage: "exclamationmark.triangle")
                } description: { Text(failure) } actions: { Button("Retry") { attempt += 1 } }
            } else { ProgressView("Connecting to \(device.name)…") }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.18), value: native != nil)
        .navigationTitle(device.name)
        .navigationSubtitle("\(apple.platform) \(apple.version)")
        .task(id: "\(apple.identifier)#\(apple.connection)#\(apple.pairing)#\(apple.version)#\(attempt)") {
            native = nil; failure = nil; requirement = nil
            do {
                guard let identifier = UUID(uuidString: apple.identifier) else { throw MirrorError("Apple reported an invalid device identifier.") }
                // DeviceKit's standalone view can keep retrying unavailable media
                // providers. Resolve known connection requirements before opening it.
                if let initial = apple.requirement(), [.connect, .trust].contains(initial) { requirement = initial; return }
                while !Task.isCancelled {
                    let lock = try? await Simctl.runTool("devicectl", ["device", "info", "lockState", "--device", apple.identifier, "--quiet", "--json-output", "-", "--timeout", "5"])
                    guard !Task.isCancelled else { return }
                    let state = lock.flatMap { $0.status == 0 ? try? AppleDevice.LockState.parse(Data($0.output.utf8)) : nil }
                    requirement = apple.requirement(passcodeRequired: state?.passcodeRequired ?? false, unlockedSinceBoot: state?.unlockedSinceBoot ?? true)
                    if requirement == .unlock {
                        try await Task.sleep(for: .seconds(2))
                        continue
                    }
                    if requirement != nil { return }
                    guard lock?.status == 0 else { throw MirrorError("Couldn't check \(device.name)'s connection. Unlock the device, confirm that it trusts this Mac, and retry.") }
                    break
                }
                guard !Task.isCancelled else { return }
                let directory = try await Simctl.developerDirectory()
                let metadata = try await Task.detached {
                    var error: NSError?
                    guard let metadata = DHDeviceViewMetadata(directory, &error) else { throw error ?? MirrorError("Couldn't load Xcode's Apple device view.") }
                    return NativeAppleDeviceView.Metadata(pointer: metadata)
                }.value
                guard !Task.isCancelled else { return }
                native = try NativeAppleDeviceView.make(identifier: identifier, metadata: metadata.pointer)
            } catch is CancellationError {} catch {
                failure = (error as? MirrorError)?.description ?? (error as NSError).localizedDescription
            }
        }
    }

    private func requirementView(_ requirement: AppleDevice.Requirement) -> some View {
        let text: (String, String) = switch requirement {
        case .connect: ("Device Disconnected", "Connect \(device.name) to this Mac to view its screen.")
        case .trust: ("Trust This Mac", "Unlock \(device.name) and confirm the Trust prompt on the device.")
        case .unlock: ("Unlock \(device.name)", "Unlock the device to continue. DroidHub will reconnect automatically.")
        case .update: ("Screen Sharing Unavailable", "\(device.name) must be running iOS 27.0 or above to screen share with this Mac.")
        case .unknownVersion: ("Couldn't Check Compatibility", "The device hasn't reported its OS version. Reconnect it and retry.")
        }
        return VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.black)
                    .overlay { RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.3), lineWidth: 1) }
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(colors: [Color(red: 0.2, green: 0.56, blue: 0.8), Color(red: 0.32, green: 0.69, blue: 0.93)], startPoint: .top, endPoint: .bottom))
                    .padding(7)
            }
            .frame(width: device.kind == .tablet ? 140 : 96, height: 196)
            .shadow(color: .black.opacity(0.3), radius: 2, y: 2)
            VStack(spacing: 5) {
                Text(text.0).font(.headline)
                Text(text.1).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            }
            if requirement == .unknownVersion { Button("Retry") { attempt += 1 } }
        }
        .padding(32)
    }
}

/// Type-erase Xcode's own SwiftUI device view without linking or bundling DeviceKit.
/// Its runtime metadata supplies allocation, ARC, and View conformance; its layout
/// and implementation stay entirely owned by the selected Xcode installation.
@MainActor enum NativeAppleDeviceView {
    // Runtime type metadata is immutable and the framework stays loaded.
    struct Metadata: @unchecked Sendable { let pointer: UnsafeRawPointer }
    static func make(identifier: UUID, metadata: UnsafeRawPointer) throws -> AnyView {
        var identifier = identifier
        let type = unsafeBitCast(metadata, to: Any.Type.self)
        func create<T>(_ type: T.Type) -> Any {
            let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
            defer { value.deallocate() }
            withUnsafePointer(to: &identifier) { DHInitializeDeviceView(value, $0) }
            return value.move()
        }
        let value = _openExistential(type, do: create)
        guard let view = value as? any View else { throw MirrorError("Xcode's Apple device view has an unsupported interface.") }
        return AnyView(view)
    }
}
