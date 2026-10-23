import Synchronization

/// Fixed-capacity ring buffer holding the four FOA channels in ACN order (W, Y, Z, X).
///
/// Writes come from the AVCaptureAudioDataOutput delegate queue (not a real-time
/// audio thread), so a mutex is fine here.
public final class FOARingBuffer: Sendable {
    public static let channelCount = 4

    public let capacity: Int
    private let state: Mutex<State>

    private struct State {
        var channels: [[Float]]
        var writeIndex = 0
        var filled = 0
        /// Total frames ever written; lets readers line windows up with timestamps.
        var totalFrames: Int64 = 0
    }

    public init(capacity: Int) {
        self.capacity = capacity
        state = Mutex(State(channels: Array(repeating: Array(repeating: 0, count: capacity),
                                            count: Self.channelCount)))
    }

    /// Appends `frameCount` frames. `channel(c)` returns a pointer to channel `c`'s samples.
    public func write(frameCount: Int, channel: (Int) -> UnsafePointer<Float>) {
        state.withLock { s in
            for c in 0..<Self.channelCount {
                let src = channel(c)
                var idx = s.writeIndex
                s.channels[c].withUnsafeMutableBufferPointer { dst in
                    for i in 0..<frameCount {
                        dst[idx] = src[i]
                        idx += 1
                        if idx == capacity { idx = 0 }
                    }
                }
            }
            s.writeIndex = (s.writeIndex + frameCount) % capacity
            s.filled = min(capacity, s.filled + frameCount)
            s.totalFrames += Int64(frameCount)
        }
    }

    /// Copies the most recent `frameCount` frames, oldest first. Returns nil until enough audio exists.
    public func latest(frameCount: Int) -> FOAWindow? {
        state.withLock { s in
            guard frameCount <= s.filled else { return nil }
            var start = s.writeIndex - frameCount
            if start < 0 { start += capacity }
            var out: [[Float]] = []
            out.reserveCapacity(Self.channelCount)
            for c in 0..<Self.channelCount {
                let ch = s.channels[c]
                if start + frameCount <= capacity {
                    out.append(Array(ch[start..<(start + frameCount)]))
                } else {
                    out.append(Array(ch[start...] + ch[..<(start + frameCount - capacity)]))
                }
            }
            return FOAWindow(w: out[0], y: out[1], z: out[2], x: out[3],
                             endFrame: s.totalFrames)
        }
    }
}

/// A contiguous block of FOA audio.
public struct FOAWindow: Sendable {
    public var w: [Float]
    public var y: [Float]
    public var z: [Float]
    public var x: [Float]
    /// Absolute index (since capture start) of the frame just after the window.
    public var endFrame: Int64

    public init(w: [Float], y: [Float], z: [Float], x: [Float], endFrame: Int64 = 0) {
        self.w = w; self.y = y; self.z = z; self.x = x; self.endFrame = endFrame
    }

    public var frameCount: Int { w.count }
}
