import Foundation

/// One BirdNET class, parsed from a "Scientific name_Common name" label line.
public struct BirdSpecies: Sendable, Hashable, Identifiable {
    public var index: Int
    public var scientificName: String
    public var commonName: String

    public var id: Int { index }

    /// BirdNET's non-event classes (Dog, Engine, Human vocal, Noise, Siren, ...) and a
    /// couple of crickets use the same text for both names. None of them are birds.
    public var isBird: Bool { scientificName != commonName }

    public init(index: Int, scientificName: String, commonName: String) {
        self.index = index
        self.scientificName = scientificName
        self.commonName = commonName
    }

    /// Parses the contents of BirdNET_GLOBAL_6K_V2.4_Labels.txt.
    public static func parseLabels(_ text: String) -> [BirdSpecies] {
        text.split(whereSeparator: \.isNewline).enumerated().map { i, line in
            let parts = line.split(separator: "_", maxSplits: 1).map(String.init)
            return BirdSpecies(index: i, scientificName: parts[0],
                               commonName: parts.count > 1 ? parts[1] : parts[0])
        }
    }
}

/// Logistic sigmoid, as BirdNET applies to its logits (sensitivity 1).
public func sigmoid(_ x: Float) -> Float { 1 / (1 + exp(-x)) }

/// Turns per-window BirdNET scores into confirmed species.
///
/// A species is confirmed when one window scores at least `strongThreshold`, or when
/// at least two windows within `memory` seconds score at least `weakThreshold`.
/// Requiring repeats cuts down one-off false positives, since there is no
/// location filter yet.
public struct DetectionAggregator: Sendable {
    public var strongThreshold: Float = 0.7
    public var weakThreshold: Float = 0.35
    public var memory: TimeInterval = 8

    private var hits: [Int: [(time: TimeInterval, score: Float)]] = [:]

    public init() {}

    /// Feeds one window's scores (probabilities, indexed by class) and returns the classes
    /// confirmed by this window, with the window's score, strongest first.
    public mutating func add(scores: [Float], at time: TimeInterval,
                             allowed: (Int) -> Bool = { _ in true }) -> [(index: Int, score: Float)] {
        for key in hits.keys {
            hits[key]!.removeAll { time - $0.time > memory }
            if hits[key]!.isEmpty { hits[key] = nil }
        }
        var confirmed: [(index: Int, score: Float)] = []
        for (i, score) in scores.enumerated() where score >= weakThreshold && allowed(i) {
            hits[i, default: []].append((time, score))
            if score >= strongThreshold || hits[i]!.count >= 2 {
                confirmed.append((i, score))
            }
        }
        return confirmed.sorted { $0.score > $1.score }
    }
}
