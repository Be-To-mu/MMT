import simd

/// Frames used here:
/// - FOA frame: X front, Y left, Z up (as delivered by iOS spatial audio capture).
/// - Device frame (CoreMotion): x right edge, y top edge, z out of the screen.
/// - World frame (CMAttitudeReferenceFrame.xTrueNorthZVertical): x true north, y west, z up.
public enum SpatialGeometry {
    /// Maps FOA axes into the device frame. Initial guess, assuming a portrait phone
    /// recording "video" through the back camera: front = -z (camera direction),
    /// left = -x, up = +y. Confirm with the clap test and adjust if the arrow is mirrored.
    public static let foaToDevice = simd_double3x3(columns: (
        SIMD3(0, 0, -1),   // FOA X →
        SIMD3(-1, 0, 0),   // FOA Y →
        SIMD3(0, 1, 0)     // FOA Z →
    ))

    /// Converts a direction in the FOA frame to a unit vector in the world frame.
    public static func worldVector(foa: SIMD3<Double>,
                                   deviceToWorld: simd_double3x3) -> SIMD3<Double> {
        simd_normalize(deviceToWorld * (foaToDevice * foa))
    }

    /// Compass bearing of a world vector: degrees clockwise from true north, [0, 360).
    public static func compassBearing(_ world: SIMD3<Double>) -> Double {
        // y points west, so east is -y.
        let deg = atan2(-world.y, world.x) * 180 / .pi
        return deg < 0 ? deg + 360 : deg
    }

    /// Elevation of a world vector in degrees.
    public static func elevation(_ world: SIMD3<Double>) -> Double {
        atan2(world.z, (world.x * world.x + world.y * world.y).squareRoot()) * 180 / .pi
    }

    /// Angle for an on-screen arrow pointing at `world`, in degrees clockwise from the
    /// top of the screen. Works whether the phone is held flat or upright: the target
    /// is moved into the device frame and projected onto the screen plane.
    /// Returns nil when the target is (almost) straight out of or behind the screen.
    public static func arrowAngle(towards world: SIMD3<Double>,
                                  deviceToWorld: simd_double3x3) -> Double? {
        let d = deviceToWorld.transpose * world
        guard (d.x * d.x + d.y * d.y).squareRoot() > 0.05 else { return nil }
        return atan2(d.x, d.y) * 180 / .pi
    }

}
