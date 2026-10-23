import CoreML
import MMTCore

enum BirdClassifierError: Error, LocalizedError {
    case missingModel

    var errorDescription: String? {
        "BirdNET model missing from the app bundle. Run tools/setup_birdnet.sh and rebuild."
    }
}

/// Runs BirdNET v2.4 (Core ML) on 3 s of 48 kHz mono audio.
actor BirdClassifier {
    static let sampleRate = 48_000.0
    static let windowSamples = 144_000

    nonisolated let species: [BirdSpecies]
    private let model: MLModel
    private let input: MLMultiArray

    init() throws {
        guard let modelURL = Bundle.main.url(forResource: "BirdNET", withExtension: "mlmodelc"),
              let labelsURL = Bundle.main.url(forResource: "BirdNET_Labels", withExtension: "txt")
        else { throw BirdClassifierError.missingModel }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        model = try MLModel(contentsOf: modelURL, configuration: config)
        species = BirdSpecies.parseLabels(try String(contentsOf: labelsURL, encoding: .utf8))
        input = try MLMultiArray(shape: [1, NSNumber(value: Self.windowSamples)], dataType: .float32)
    }

    /// Returns one probability per class.
    func classify(_ samples: [Float]) throws -> [Float] {
        precondition(samples.count == Self.windowSamples)
        input.withUnsafeMutableBufferPointer(ofType: Float.self) { dst, _ in
            _ = dst.initialize(from: samples)
        }
        let features = try MLDictionaryFeatureProvider(dictionary: ["inputs": input])
        let output = try model.prediction(from: features)
        guard let logits = output.featureValue(for: "Identity")?.multiArrayValue else { return [] }
        // On device the output buffer can be padded for the Neural Engine, so read it
        // through the class axis' stride rather than as one contiguous run.
        let classes = logits.shape.last!.intValue
        let stride = logits.strides.last!.intValue
        switch logits.dataType {
        case .float16:
            return logits.withUnsafeBufferPointer(ofType: Float16.self) { p in
                (0..<classes).map { sigmoid(Float(p[$0 * stride])) }
            }
        default:
            return logits.withUnsafeBufferPointer(ofType: Float.self) { p in
                (0..<classes).map { sigmoid(p[$0 * stride]) }
            }
        }
    }
}
