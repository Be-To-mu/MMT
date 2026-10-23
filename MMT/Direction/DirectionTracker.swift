import Accelerate
import AVFoundation
import Observation
import MMTCore

/// A species heard during this session and where it was last heard.
struct BirdSighting: Identifiable, Sendable {
    var species: BirdSpecies
    var bestScore: Float
    var lastScore: Float
    var lastHeard: Date
    /// Unit vector in the world frame (x north, y west, z up); nil if no clear direction.
    var worldVector: SIMD3<Double>?
    var spread: Double?

    var id: Int { species.index }
}

/// Owns the FOA capture and heading. Runs two loops: one for the loudest sound
/// (debug / clap test), and one that identifies birds with BirdNET and records
/// where each species was heard.
@MainActor @Observable
final class DirectionTracker {
    let heading = HeadingService()
    private(set) var levels: [Float] = [0, 0, 0, 0]
    private(set) var lastEstimate: DirectionEstimate?
    /// Unit vector in the world frame (x north, y west, z up) of the last loud sound.
    private(set) var targetWorld: SIMD3<Double>?
    private(set) var error: String?

    /// Most recently heard first.
    private(set) var sightings: [BirdSighting] = []
    var selectedSpeciesIndex: Int?

    private(set) var lenses: [CameraLens] = []
    private(set) var currentLens: CameraLens?
    /// Shared with the camera preview; the same session captures the spatial audio.
    var captureSession: AVCaptureSession { capture.session }

    private let capture = SpatialCaptureService()
    private let estimator = DOAEstimator()
    private var classifier: BirdClassifier?
    private var aggregator = DetectionAggregator()

    var targetBearing: Double? { targetWorld.map(SpatialGeometry.compassBearing) }
    var targetElevation: Double? { targetWorld.map(SpatialGeometry.elevation) }

    var selectedSighting: BirdSighting? {
        sightings.first { $0.id == selectedSpeciesIndex }
    }

    func select(_ lens: CameraLens) {
        capture.select(lens)
        currentLens = lens
    }

    /// Runs until the calling task is cancelled.
    func run() async {
        heading.start()
        do {
            try await capture.start()
            lenses = capture.lenses
            currentLens = lenses.first
        } catch {
            self.error = error.localizedDescription
            heading.stop()
            return
        }
        do {
            classifier = try BirdClassifier()
        } catch {
            self.error = error.localizedDescription
        }
        async let loud: Void = trackLoudestSound()
        async let birds: Void = identifyBirds()
        _ = await (loud, birds)
        capture.stop()
        heading.stop()
    }

    private func trackLoudestSound() async {
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
    }

    private func identifyBirds() async {
        guard let classifier else { return }
        let species = classifier.species
        let start = Date()
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(1500))
            let rate = capture.sampleRate
            let frames = Int(rate * 3)
            guard let window = capture.buffer.latest(frameCount: frames) else { continue }
            let deviceToWorld = heading.deviceToWorld

            let mono = resample(window.w, from: rate, to: BirdClassifier.sampleRate,
                                count: BirdClassifier.windowSamples)
            guard let scores = try? await classifier.classify(mono),
                  scores.count == species.count else { continue }
            let confirmed = aggregator.add(scores: scores, at: Date().timeIntervalSince(start),
                                           allowed: { species[$0].isBird })
            guard !confirmed.isEmpty else { continue }

            let estimator = estimator
            let est = await Task.detached { estimator.estimate(window, band: 1_000...10_000) }.value
            let world = est.map { SpatialGeometry.worldVector(foa: $0.vector, deviceToWorld: deviceToWorld) }

            for hit in confirmed {
                record(species[hit.index], score: hit.score, world: world, spread: est?.spread)
            }
            if sightings.count == 1 { selectedSpeciesIndex = sightings[0].id }
        }
    }

    private func record(_ species: BirdSpecies, score: Float, world: SIMD3<Double>?, spread: Double?) {
        var sighting = sightings.first { $0.id == species.index }
            ?? BirdSighting(species: species, bestScore: 0, lastScore: 0, lastHeard: .now)
        sighting.bestScore = max(sighting.bestScore, score)
        sighting.lastScore = score
        sighting.lastHeard = .now
        if let world {
            sighting.worldVector = world
            sighting.spread = spread
        }
        sightings.removeAll { $0.id == species.index }
        sightings.insert(sighting, at: 0)
    }

    /// Linear resampling; a no-op when the capture already runs at 48 kHz.
    private func resample(_ samples: [Float], from rate: Double, to target: Double, count: Int) -> [Float] {
        if rate == target, samples.count >= count { return Array(samples.suffix(count)) }
        let step = rate / target
        return (0..<count).map { i in
            let pos = Double(i) * step
            let j = min(Int(pos), samples.count - 2)
            let frac = Float(pos - Double(j))
            return samples[j] * (1 - frac) + samples[j + 1] * frac
        }
    }
}
