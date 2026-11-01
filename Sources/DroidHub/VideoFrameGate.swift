import Foundation

/// Shared between the socket reader and main thread. Hidden streams are drained,
/// but never converted to samples or submitted to the hardware decoder.
final class VideoFrameGate: @unchecked Sendable {
    struct Frame {
        let generation: UInt64
        let resetDecoder: Bool
    }
    private let lock = NSLock()
    private var active = false
    private var generation: UInt64 = 0
    private var needsKeyframe = true

    @discardableResult func setActive(_ value: Bool) -> Bool {
        lock.withLock {
            guard active != value else { return false }
            active = value
            generation &+= 1
            needsKeyframe = true
            return true
        }
    }

    func accept(keyframe: Bool) -> Frame? {
        lock.withLock {
            guard active, !needsKeyframe || keyframe else { return nil }
            let frame = Frame(generation: generation, resetDecoder: needsKeyframe)
            needsKeyframe = false
            return frame
        }
    }

    func isCurrent(_ frame: Frame) -> Bool {
        lock.withLock { active && frame.generation == generation }
    }
}
