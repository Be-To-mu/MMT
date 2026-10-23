import AVFoundation
import MMTCore

enum SpatialCaptureError: Error, LocalizedError {
    case noMicrophone
    case ambisonicsUnsupported
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .noMicrophone: "No built-in microphone found."
        case .ambisonicsUnsupported: "This iPhone can't capture Spatial Audio (needs iPhone 16 or later on the built-in mic)."
        case .permissionDenied: "Microphone access was denied."
        }
    }
}

/// Captures 4-channel First Order Ambisonics (ACN/SN3D: W, Y, Z, X) from the built-in
/// mic array and keeps the most recent audio in a ring buffer.
final class SpatialCaptureService: NSObject, @unchecked Sendable {
    /// ~10 s of audio at 48 kHz.
    let buffer = FOARingBuffer(capacity: 48_000 * 10)
    private(set) var sampleRate: Double = 48_000

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "mmt.capture", qos: .userInitiated)
    private var scratch: [[Float]] = Array(repeating: [], count: FOARingBuffer.channelCount)

    func start() async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw SpatialCaptureError.permissionDenied
        }
        guard let mic = AVCaptureDevice.default(for: .audio) else {
            throw SpatialCaptureError.noMicrophone
        }
        let input = try AVCaptureDeviceInput(device: mic)
        guard input.isMultichannelAudioModeSupported(.firstOrderAmbisonics) else {
            throw SpatialCaptureError.ambisonicsUnsupported
        }

        session.beginConfiguration()
        if session.canAddInput(input) { session.addInput(input) }
        input.multichannelAudioMode = .firstOrderAmbisonics
        // iOS 26: ask this data output for the FOA stream rather than the stereo one.
        output.spatialAudioChannelLayoutTag = kAudioChannelLayoutTag_HOA_ACN_SN3D | 4
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()

        queue.async { [session] in session.startRunning() }
    }

    func stop() {
        queue.async { [session] in session.stopRunning() }
    }
}

extension SpatialCaptureService: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let format = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              Int(format.mChannelsPerFrame) == FOARingBuffer.channelCount else { return }
        sampleRate = format.mSampleRate

        let frames = sampleBuffer.numSamples
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let channels = FOARingBuffer.channelCount

        try? sampleBuffer.withAudioBufferList { list, _ in
            for c in 0..<channels {
                if scratch[c].count < frames { scratch[c] = [Float](repeating: 0, count: frames) }
            }
            // The iOS capture output picks the sample format, so handle Float32 and Int16,
            // interleaved or not, and convert to deinterleaved Float.
            for c in 0..<channels {
                let buf = interleaved ? list[0] : list[c]
                guard let data = buf.mData else { return }
                let stride = interleaved ? channels : 1
                let offset = interleaved ? c : 0
                scratch[c].withUnsafeMutableBufferPointer { dst in
                    if isFloat {
                        let src = data.assumingMemoryBound(to: Float.self)
                        for i in 0..<frames { dst[i] = src[i * stride + offset] }
                    } else {
                        let src = data.assumingMemoryBound(to: Int16.self)
                        for i in 0..<frames { dst[i] = Float(src[i * stride + offset]) / 32_768 }
                    }
                }
            }
            buffer.write(frameCount: frames) { c in
                scratch[c].withUnsafeBufferPointer { $0.baseAddress! }
            }
        }
    }
}
