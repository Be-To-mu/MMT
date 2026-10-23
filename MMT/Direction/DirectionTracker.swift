import Accelerate
import Observation
import MMTCore

/// Listens to the FOA stream and keeps the world direction of the most recent loud sound.
/// Shared by the AR view and the debug view.
@MainActor @Observable
final class DirectionTracker {
    let heading = HeadingService()
    private(set) var levels: [Float] = [0, 0, 0, 0]
    private(set) var lastEstimate: DirectionEstimate?
    /// Unit vector in the world frame (x north, y west, z up).
    private(set) var targetWorld: SIMD3<Double>?
    private(set) var error: String?

    private let capture = SpatialCaptureService()
    private let estimator = DOAEstimator()

    var targetBearing: Double? { targetWorld.map(SpatialGeometry.compassBearing) }
    var targetElevation: Double? { targetWorld.map(SpatialGeometry.elevation) }

    /// Runs until the calling task is cancelled.
    func run() async {
        heading.start()
        do {
            try await capture.start()
        } catch {
            self.error = error.localizedDescription
            heading.stop()
            return
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            let frames = Int(capture.sampleRate / 2)
            guard let window = capture.buffer.latest(frameCount: frames) else { continue }
            levels = [window.w, window.y, window.z, window.x].map { vDSP.rootMeanSquare($0) }
            // Only re-aim on clearly loud events.
            guard levels[0] > 0.02 else { continue }
            let estimator = estimator
            let est = await Task.detached { estimator.estimate(window, band: 300...12_000) }.value
            guard let est, est.confidence > 0.3 else { continue }
            lastEstimate = est
            targetWorld = SpatialGeometry.worldVector(foa: est.vector,
                                                      deviceToWorld: heading.deviceToWorld)
        }
        capture.stop()
        heading.stop()
    }
}
