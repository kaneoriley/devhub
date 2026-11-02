import Darwin
import Foundation

/// Long-lived VMs and the replacement helper must survive DevHub, including Force Quit.
enum DetachedProcess {
    @discardableResult
    static func launch(_ executable: String, arguments: [String], onExit: @escaping (Int32) -> Void = { _ in }) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        func check(_ status: Int32) throws {
            if status != 0 { throw MirrorError("Cannot start \(URL(fileURLWithPath: executable).lastPathComponent): \(String(cString: strerror(status)))") }
        }
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)))
        var mask = sigset_t()
        sigemptyset(&mask)
        try check(posix_spawnattr_setsigmask(&attributes, &mask))
        sigfillset(&mask)
        try check(posix_spawnattr_setsigdefault(&attributes, &mask))
        // libSystem SPI also used by Chromium/LLDB: don't attribute the child to this app.
        typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else {
            throw MirrorError("This macOS version cannot start independent device processes.")
        }
        try check(unsafeBitCast(symbol, to: Disclaim.self)(&attributes, 1))
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            try check(posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", descriptor == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0))
        }
        let strings = ([executable] + arguments).map { strdup($0)! }
        defer { strings.forEach { free($0) } }
        var argv = strings.map { Optional($0) } + [nil]
        let environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)")! }
        defer { environment.forEach { free($0) } }
        var envp = environment.map { Optional($0) } + [nil]
        var pid: pid_t = 0
        try check(posix_spawn(&pid, executable, &actions, &attributes, &argv, &envp))
        let child = pid
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            var result: pid_t
            repeat { result = waitpid(child, &status, 0) } while result == -1 && errno == EINTR
            onExit(result == -1 ? -1 : status)
        }
        return pid
    }
}
