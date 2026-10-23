import CoreMotion
import Observation
import simd

/// Publishes the phone's orientation relative to true north at 30 Hz.
@MainActor @Observable
final class HeadingService {
    /// Rotates device-frame vectors into the world frame (x north, y west, z up).
    private(set) var deviceToWorld = matrix_identity_double3x3

    private let motion = CMMotionManager()

    func start() {
        guard motion.isDeviceMotionAvailable,
              CMMotionManager.availableAttitudeReferenceFrames().contains(.xTrueNorthZVertical)
        else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.startDeviceMotionUpdates(using: .xTrueNorthZVertical, to: .main) { [weak self] data, _ in
            guard let m = data?.attitude.rotationMatrix else { return }
            // CMAttitude.rotationMatrix maps reference-frame vectors into the device frame,
            // so its transpose maps device → world. Check with the clap test.
            let referenceToDevice = simd_double3x3(rows: [
                SIMD3(m.m11, m.m12, m.m13),
                SIMD3(m.m21, m.m22, m.m23),
                SIMD3(m.m31, m.m32, m.m33),
            ])
            self?.deviceToWorld = referenceToDevice.transpose
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
    }
}
