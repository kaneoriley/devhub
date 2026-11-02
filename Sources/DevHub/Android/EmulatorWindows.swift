import AppKit

@MainActor enum EmulatorWindows {
    static func observe() {
        // Emulators started elsewhere (Android Studio or command-line tools) bring their
        // own window. Hiding that app leaves the screen to DevHub. Qt activates and unhides
        // the emulator about a second after launch, so those are hidden again too, but only in
        // the first 10 s: a later unhide is the user clicking the Dock icon to get the window back.
        NSWorkspace.shared.runningApplications.forEach(Self.hideEmulator)
        let launch = NSWorkspace.didLaunchApplicationNotification
        for name in [launch, NSWorkspace.didActivateApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) {
                guard let app = $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                if name == launch { Self.launched[app.processIdentifier] = .now }
                if Date.now.timeIntervalSince(Self.launched[app.processIdentifier] ?? .distantPast) < 10 { Self.hideEmulator(app) }
            }
        }
    }

    // Main queue only. NSRunningApplication.launchDate is nil for the emulator, hence the bookkeeping.
    nonisolated(unsafe) private static var launched: [pid_t: Date] = [:]

    nonisolated private static func hideEmulator(_ app: NSRunningApplication) {
        if app.executableURL?.lastPathComponent.hasPrefix("qemu-system") == true { app.hide() }
    }
}
