import AVFoundation
import AppKit

struct MirrorError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Client for the scrcpy server: pushes it to the device, decodes its H.264 stream
/// into `layer` and sends input back. Protocol: scrcpy doc/develop.md, "Protocol".
final class Mirror {
    let serial: String
    let layer = AVSampleBufferDisplayLayer()
    var onSize: ((CGSize) -> Void)?
    var onClose: (() -> Void)?
    /// Current video size in device pixels. Main thread only.
    private(set) var size = CGSize.zero

    private var server: Process?
    private var video: Socket?
    private var control: Socket?
    private var port = ""
    private var closed = false
    private var log: Pipe?
    /// Screen density in dpi, read from the device on start. Main thread only.
    private var density = 420.0
    private let writes = DispatchQueue(label: "droidhub.control")

    init(serial: String) {
        self.serial = serial
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = .black
    }

    func start() async throws {
        guard let jar = Bundle.main.url(forResource: "scrcpy-server", withExtension: nil),
              let version = Bundle.main.object(forInfoDictionaryKey: "ScrcpyVersion") as? String
        else { throw MirrorError("scrcpy-server is missing from the bundle, run ./build.sh") }

        let scid = String(format: "%08x", UInt32.random(in: 0..<0x7fff_ffff))
        let remote = "/data/local/tmp/droidhub-server.jar"
        await adb("-s", serial, "push", jar.path, remote)
        port = await adb("-s", serial, "forward", "tcp:0", "localabstract:scrcpy_\(scid)").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let localPort = UInt16(port) else { throw MirrorError("adb forward failed") }
        await refreshDensity()

        let server = Process()
        server.executableURL = URL(fileURLWithPath: SDK.adb)
        server.arguments = ["-s", serial, "shell", "CLASSPATH=\(remote)", "app_process", "/", "com.genymobile.scrcpy.Server", version,
                            "scid=\(scid)", "tunnel_forward=true", "audio=false", "video_codec=h264", "max_fps=60", "stay_awake=true",
                            "capture_orientation=\(serial.hasPrefix("emulator-") ? "@0" : "0")"]
        let log = Pipe()
        server.standardOutput = log
        server.standardError = log
        try server.run()
        self.server = server

        let video: Socket, control: Socket
        do {
            (video, control) = try await Task.detached {
                let video = try Mirror.connect(port: localPort)
                return (video, try Socket.connect(port: localPort))
            }.value
        } catch {
            server.terminate()
            let out = await Task.detached { String(decoding: log.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) }.value
            throw MirrorError(out.split(separator: "\n").last { $0.contains("ERROR") }.map(String.init) ?? "scrcpy server didn't start")
        }
        // Keep draining the server log, or it blocks once the pipe fills up. At EOF the
        // handler fires nonstop with empty reads and pins a core, so it removes itself.
        log.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { FileHandle.standardError.write(data) }
        }
        self.log = log

        self.video = video
        self.control = control
        Thread { self.readVideo(video) }.start()
        Thread { self.readControl(control) }.start()
    }

    func stop() {
        closed = true
        log?.fileHandleForReading.readabilityHandler = nil
        video?.shutdown()
        control?.shutdown()
        server?.terminate()
        let args = ["-s", serial, "forward", "--remove", "tcp:\(port)"]
        Task.detached { _ = await exec(SDK.adb, args) }
    }

    @MainActor func screenshot(rotation: QuarterTurn = .zero) throws -> Data {
        guard let buffer = layer.sampleBufferRenderer.displayedPixelBuffer() else {
            throw MirrorError("No video frame is available yet. Wait for the device screen and try again.")
        }
        return try Screenshot.png(from: buffer, rotation: rotation)
    }

    // MARK: Input (main thread). Points are normalized to 0...1.

    func touch(_ action: UInt8, at point: CGPoint) {
        guard let (x, y, w, h) = pixels(point) else { return }
        send(Control.touch(action, x: x, y: y, width: w, height: h))
    }

    func scroll(at point: CGPoint, dx: Float, dy: Float) {
        guard let (x, y, w, h) = pixels(point) else { return }
        send(Control.scroll(x: x, y: y, width: w, height: h, dx: dx, dy: dy))
    }

    func key(_ code: UInt32, meta: UInt32 = 0) {
        send(Control.key(0, code, meta: meta))
        send(Control.key(1, code, meta: meta))
    }

    func type(_ text: String) {
        guard !text.isEmpty else { return }
        // The server can only inject characters present in the device key map, so
        // anything non-ASCII (ç, ã, emoji) goes through the clipboard instead.
        send(text.unicodeScalars.allSatisfy(\.isASCII) ? Control.text(text) : Control.setClipboard(text, paste: true))
    }

    func paste(_ text: String) { send(Control.setClipboard(text, paste: true)) }

    /// Screen points that one wheel notch covers at the current zoom.
    func pointsPerNotch(viewWidth: CGFloat) -> CGFloat {
        size.width > 0 ? Self.pointsPerNotch(density: density, viewWidth: viewWidth, videoWidth: size.width) : 25
    }

    /// Android scrolls 64dp per notch (config_verticalScrollFactor).
    static func pointsPerNotch(density: Double, viewWidth: Double, videoWidth: Double) -> Double {
        64 * density / 160 * viewWidth / videoWidth
    }

    /// Last number in `wm density` output, which is the override when there is one.
    static func density(from output: String) -> Double? {
        output.split(whereSeparator: \.isNewline).last.flatMap { $0.split(separator: " ").last }.flatMap { Double($0) }
    }

    private func pixels(_ p: CGPoint) -> (Int32, Int32, UInt16, UInt16)? {
        guard size.width >= 1, size.height >= 1 else { return nil }
        let x = min(max(p.x, 0), 1) * (size.width - 1)
        let y = min(max(p.y, 0), 1) * (size.height - 1)
        return (Int32(x.rounded()), Int32(y.rounded()), UInt16(size.width), UInt16(size.height))
    }

    private func send(_ data: Data) {
        writes.async { [control] in control?.write(data) }
    }

    // MARK: Sockets

    /// On a forward tunnel adb accepts the connection even before the server listens,
    /// so the server's dummy byte is what proves it's really there.
    private static func connect(port: UInt16) throws -> Socket {
        for _ in 0..<100 {
            if let s = try? Socket.connect(port: port), s.read(1) != nil { return s }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw MirrorError("scrcpy server didn't start")
    }

    @MainActor func refreshDensity() async {
        density = Self.density(from: await adb("-s", serial, "shell", "wm", "density")) ?? density
    }

    private func readVideo(_ s: Socket) {
        defer { DispatchQueue.main.async { if !self.closed { self.onClose?() } } }
        // 64-byte device name, then the codec id.
        guard s.read(64) != nil, let codec = s.read(4), codec.int(0) as UInt32 == 0x6832_3634 else { return }
        var format: CMVideoFormatDescription?
        var pendingSize: CGSize?
        while let header = s.read(12) {
            if header[0] & 0x80 != 0 {  // session packet: new capture size (e.g. after rotating)
                pendingSize = CGSize(width: Int(header.int(4) as UInt32), height: Int(header.int(8) as UInt32))
                format = nil
                continue
            }
            let flags: UInt64 = header.int(0)
            guard let packet = s.read(Int(header.int(8) as UInt32)) else { return }
            if flags & (1 << 62) != 0 {
                format = H264.format(config: packet)
                continue
            }
            guard let format, let sample = H264.sample(packet, format: format) else { continue }
            let newSize = pendingSize
            pendingSize = nil
            // Keep frame and geometry updates in order, and reset the decoder at a new
            // capture session instead of reusing reference frames from the previous size.
            DispatchQueue.main.async {
                guard !self.closed else { return }
                let renderer = self.layer.sampleBufferRenderer
                if let newSize {
                    renderer.flush()
                    self.size = newSize
                    self.onSize?(newSize)
                } else if renderer.status == .failed { renderer.flush() }
                renderer.enqueue(sample)
            }
        }
    }

    /// Device messages. Only the clipboard matters: copying on the device lands on the Mac.
    private func readControl(_ s: Socket) {
        while let type = s.read(1)?.first {
            switch type {
            case 0:
                guard let len = s.read(4), let text = s.read(Int(len.int(0) as UInt32)) else { return }
                let string = String(decoding: text, as: UTF8.self)
                DispatchQueue.main.async {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(string, forType: .string)
                }
            case 1: _ = s.read(8)  // clipboard ack
            case 2:  // uhid output
                guard let h = s.read(4) else { return }
                _ = s.read(Int(h.int(2) as UInt16))
            default: return
            }
        }
    }
}

enum Control {
    static func key(_ action: UInt8, _ code: UInt32, meta: UInt32 = 0) -> Data {
        var d = Data([0, action])
        d.append(be: code)
        d.append(be: UInt32(0))  // repeat
        d.append(be: meta)
        return d
    }

    static func text(_ text: String) -> Data {
        var d = Data([1])
        d.append(string: text)
        return d
    }

    static func touch(_ action: UInt8, x: Int32, y: Int32, width: UInt16, height: UInt16) -> Data {
        var d = Data([2, action])
        d.append(be: UInt64(bitPattern: -2))  // generic finger, so apps see a touchscreen
        d.append(position(x, y, width, height))
        d.append(be: action == 1 ? UInt16(0) : 0xffff)  // pressure
        d.append(be: UInt32(0))  // action button
        d.append(be: UInt32(0))  // buttons
        return d
    }

    /// dx/dy in wheel notches, clamped to ±16.
    static func scroll(x: Int32, y: Int32, width: UInt16, height: UInt16, dx: Float, dy: Float) -> Data {
        var d = Data([3])
        d.append(position(x, y, width, height))
        d.append(be: fixed(dx / 16))
        d.append(be: fixed(dy / 16))
        d.append(be: UInt32(0))
        return d
    }

    static func setClipboard(_ text: String, paste: Bool) -> Data {
        var d = Data([9])
        d.append(be: UInt64(0))  // sequence 0: no ack wanted
        d.append(paste ? 1 : 0)
        d.append(string: text)
        return d
    }

    private static func position(_ x: Int32, _ y: Int32, _ w: UInt16, _ h: UInt16) -> Data {
        var d = Data()
        d.append(be: x)
        d.append(be: y)
        d.append(be: w)
        d.append(be: h)
        return d
    }

    private static func fixed(_ f: Float) -> Int16 {
        let c = min(max(f, -1), 1)
        return c >= 1 ? .max : Int16(c * 0x8000)
    }
}

enum H264 {
    /// Splits an Annex B byte stream into NAL units, start codes removed.
    static func nalUnits(_ data: Data) -> [Data] {
        let b = [UInt8](data)
        var units: [Data] = []
        var start = -1
        var i = 0
        func flush(_ end: Int) {
            guard start >= 0 else { return }
            var end = end
            while end > start, b[end - 1] == 0 { end -= 1 }  // a NAL never ends in 0x00
            if end > start { units.append(Data(b[start..<end])) }
        }
        while i + 2 < b.count {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 {
                flush(i)
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        flush(b.count)
        return units
    }

    /// Annex B to AVCC: 4-byte big-endian length before each NAL unit.
    static func avcc(_ data: Data) -> Data {
        var out = Data()
        for nal in nalUnits(data) {
            out.append(be: UInt32(nal.count))
            out.append(nal)
        }
        return out
    }

    static func format(config: Data) -> CMVideoFormatDescription? {
        let nals = nalUnits(config)
        guard let sps = nals.first(where: { $0[0] & 0x1f == 7 }), let pps = nals.first(where: { $0[0] & 0x1f == 8 }) else { return nil }
        var format: CMVideoFormatDescription?
        sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                let pointers = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: pointers,
                                                                    parameterSetSizes: [sps.count, pps.count], nalUnitHeaderLength: 4,
                                                                    formatDescriptionOut: &format)
            }
        }
        return format
    }

    static func sample(_ packet: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        let data = avcc(packet)
        guard !data.isEmpty else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: data.count,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block,
              data.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) }) == noErr
        else { return nil }
        var sample: CMSampleBuffer?
        var size = data.count
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample
        else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        return sample
    }
}

final class Socket {
    private let fd: Int32
    private init(fd: Int32) { self.fd = fd }
    deinit { close(fd) }

    static func connect(port: UInt16, timeout: Int? = nil) throws -> Socket {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MirrorError("socket() failed") }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else {
            close(fd)
            throw MirrorError("connect() failed")
        }
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        if let timeout {
            var value = timeval(tv_sec: timeout, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        }
        return Socket(fd: fd)
    }

    /// Reads exactly `count` bytes, nil on EOF or error.
    func read(_ count: Int) -> Data? {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        var got = 0
        while got < count {
            let n = data.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + got, count - got, 0) }
            if n <= 0 { return nil }
            got += n
        }
        return data
    }

    func write(_ data: Data) {
        data.withUnsafeBytes { buf in
            var sent = 0
            while sent < data.count {
                let n = send(fd, buf.baseAddress! + sent, data.count - sent, 0)
                if n <= 0 { return }
                sent += n
            }
        }
    }

    func shutdown() { Darwin.shutdown(fd, SHUT_RDWR) }
}

extension Data {
    /// Big-endian integer at `offset`.
    func int<T: FixedWidthInteger>(_ offset: Int) -> T {
        self[(startIndex + offset)..<(startIndex + offset + MemoryLayout<T>.size)].reduce(0) { $0 << 8 | T($1) }
    }

    mutating func append<T: FixedWidthInteger>(be value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func append(string: String) {
        let bytes = Data(string.utf8)
        append(be: UInt32(bytes.count))
        append(bytes)
    }
}
