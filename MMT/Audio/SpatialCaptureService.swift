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

/// A camera lens the user can switch to, as a zoom factor on the virtual multi-camera.
struct CameraLens: Identifiable, Hashable, Sendable {
    /// What the Camera app shows, e.g. "0.5×".
    var label: String
    var zoomFactor: CGFloat

    var id: CGFloat { zoomFactor }
}

/// Captures 4-channel First Order Ambisonics (ACN/SN3D: W, Y, Z, X) from the built-in
/// mic array and keeps the most recent audio in a ring buffer. The same session also
/// drives the camera preview, so camera and spatial audio never compete.
final class SpatialCaptureService: NSObject, @unchecked Sendable {
    /// ~10 s of audio at 48 kHz.
    let buffer = FOARingBuffer(capacity: 48_000 * 10)
    private(set) var sampleRate: Double = 48_000
    /// For the camera preview layer.
    let session = AVCaptureSession()
    /// Lenses on this phone, widest first. Empty if there's no camera or access was denied.
    private(set) var lenses: [CameraLens] = []

    private var camera: AVCaptureDevice?
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

        let cameraInput = await makeCameraInput()

        session.beginConfiguration()
        if let cameraInput, session.canAddInput(cameraInput) { session.addInput(cameraInput) }
        if session.canAddInput(input) { session.addInput(input) }
        input.multichannelAudioMode = .firstOrderAmbisonics
        // iOS 26: ask this data output for the FOA stream rather than the stereo one.
        output.spatialAudioChannelLayoutTag = kAudioChannelLayoutTag_HOA_ACN_SN3D | 4
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()

        queue.async { self.session.startRunning() }
    }

    func stop() {
        queue.async { self.session.stopRunning() }
    }

    /// Switches lens. On the virtual multi-camera, zoom factor 1 is the widest lens and
    /// iOS swaps physical cameras at the switch-over factors.
    func select(_ lens: CameraLens) {
        guard let camera else { return }
        queue.async {
            do {
                try camera.lockForConfiguration()
                camera.videoZoomFactor = min(max(lens.zoomFactor, camera.minAvailableVideoZoomFactor),
                                             camera.maxAvailableVideoZoomFactor)
                camera.unlockForConfiguration()
            } catch {}
        }
    }

    private func makeCameraInput() async -> AVCaptureDeviceInput? {
        guard await AVCaptureDevice.requestAccess(for: .video) else { return nil }
        let types: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera,
                                                   .builtInDualCamera, .builtInWideAngleCamera]
        guard let device = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video,
                                                            position: .back).devices.first,
              let input = try? AVCaptureDeviceInput(device: device) else { return nil }
        camera = device
        lenses = Self.lenses(for: device)
        // Start on the widest lens.
        if let widest = lenses.first { select(widest) }
        return input
    }

    /// The physical lenses of a (virtual) camera as zoom factors, labelled like the Camera
    /// app: the main wide lens is "1×", so the ultra-wide is "0.5×" and so on.
    private static func lenses(for device: AVCaptureDevice) -> [CameraLens] {
        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        let factors = [CGFloat(1)] + switchOvers
        let hasUltraWide = device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        // Zoom factor of the main wide camera, which the Camera app calls 1×.
        let main = hasUltraWide ? (switchOvers.first ?? 1) : 1
        return factors.map { factor in
            let shown = factor / main
            let label = shown < 1 ? String(format: "%.1f×", shown) : String(format: "%.0f×", shown)
            return CameraLens(label: label, zoomFactor: factor)
        }
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
