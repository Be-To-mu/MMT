import Testing
import simd
@testable import MMTCore

/// Encodes a mono signal as an FOA (ACN/SN3D) plane wave from the given direction.
func planeWave(azimuth: Double, elevation: Double, noise: Float = 0.05,
               frames: Int = 48_000 * 3, sampleRate: Double = 48_000) -> FOAWindow {
    var rng = SystemRandomNumberGenerator()
    let az = azimuth * .pi / 180, el = elevation * .pi / 180
    let gx = Float(cos(az) * cos(el)), gy = Float(sin(az) * cos(el)), gz = Float(sin(el))
    var w = [Float](), x = [Float](), y = [Float](), z = [Float]()
    for i in 0..<frames {
        let t = Double(i) / sampleRate
        // Chirpy "bird" between 2 and 5 kHz.
        let s = Float(sin(2 * .pi * (2_000 + 1_500 * sin(2 * .pi * 3 * t)) * t))
        func n() -> Float { Float.random(in: -noise...noise, using: &rng) }
        w.append(s + n()); x.append(s * gx + n()); y.append(s * gy + n()); z.append(s * gz + n())
    }
    return FOAWindow(w: w, y: y, z: z, x: x)
}

@Suite struct DOAEstimatorTests {
    let estimator = DOAEstimator()

    @Test(arguments: [0.0, 45, 90, 135, 180, -135, -90, -30])
    func recoversAzimuth(azimuth: Double) throws {
        let est = try #require(estimator.estimate(planeWave(azimuth: azimuth, elevation: 0)))
        #expect(angularDistance(est.azimuth, azimuth) < 5)
        #expect(abs(est.elevation) < 5)
        #expect(est.spread < 15)
    }

    @Test(arguments: [30.0, -40, 60])
    func recoversElevation(elevation: Double) throws {
        let est = try #require(estimator.estimate(planeWave(azimuth: 70, elevation: elevation)))
        #expect(angularDistance(est.azimuth, 70) < 5)
        #expect(abs(est.elevation - elevation) < 5)
    }

    @Test func louderSourceWins() throws {
        let a = planeWave(azimuth: 100, elevation: 0, noise: 0)
        let b = planeWave(azimuth: -60, elevation: 0, noise: 0)
        func mix(_ p: [Float], _ q: [Float]) -> [Float] { zip(p, q).map { $0 + 0.3 * $1 } }
        let window = FOAWindow(w: mix(a.w, b.w), y: mix(a.y, b.y), z: mix(a.z, b.z), x: mix(a.x, b.x))
        let est = try #require(estimator.estimate(window))
        #expect(angularDistance(est.azimuth, 100) < 10)
    }

    @Test func silenceGivesNil() {
        let zeros = [Float](repeating: 0, count: 48_000)
        #expect(estimator.estimate(FOAWindow(w: zeros, y: zeros, z: zeros, x: zeros)) == nil)
    }
}

@Suite struct GeometryTests {
    @Test func normalizeWraps() {
        #expect(normalizeSigned(190) == -170)
        #expect(normalizeSigned(-180) == 180)
        #expect(angularDistance(350, 10) == 20)
    }

    @Test func compassBearings() {
        #expect(abs(SpatialGeometry.compassBearing(SIMD3(1, 0, 0)) - 0) < 1e-9)   // north
        #expect(abs(SpatialGeometry.compassBearing(SIMD3(0, -1, 0)) - 90) < 1e-9) // east
        #expect(abs(SpatialGeometry.compassBearing(SIMD3(0, 1, 0)) - 270) < 1e-9) // west
    }

    @Test func arrowFollowsPhoneRotation() throws {
        // Phone lying flat, screen up, top edge pointing north: device frame x=east, y=north, z=up.
        let flatNorth = simd_double3x3(columns: (SIMD3(0, -1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)))
        let east = SIMD3<Double>(0, -1, 0)
        #expect(abs(try #require(SpatialGeometry.arrowAngle(towards: east, deviceToWorld: flatNorth)) - 90) < 1e-9)

        // Turn the phone to face east: the arrow should now point straight up the screen.
        let flatEast = simd_double3x3(columns: (SIMD3(-1, 0, 0), SIMD3(0, -1, 0), SIMD3(0, 0, 1)))
        #expect(abs(try #require(SpatialGeometry.arrowAngle(towards: east, deviceToWorld: flatEast))) < 1e-9)
    }
}

@Suite struct RingBufferTests {
    @Test func wrapsAndReturnsLatest() throws {
        let rb = FOARingBuffer(capacity: 8)
        #expect(rb.latest(frameCount: 4) == nil)
        for block in 0..<3 {
            let data = (0..<4).map { Float(block * 4 + $0) }
            data.withUnsafeBufferPointer { p in rb.write(frameCount: 4) { _ in p.baseAddress! } }
        }
        let win = try #require(rb.latest(frameCount: 6))
        #expect(win.w == [6, 7, 8, 9, 10, 11])
        #expect(win.x == win.w)
        #expect(win.endFrame == 12)
    }
}
