import Testing
@testable import MMTCore

@Suite struct BirdSpeciesTests {
    @Test func parsesLabelsAndFlagsNonBirds() {
        let labels = BirdSpecies.parseLabels("""
        Turdus merula_Eurasian Blackbird
        Dog_Dog
        Human vocal_Human vocal
        Erithacus rubecula_European Robin
        """)
        #expect(labels.count == 4)
        #expect(labels[0] == BirdSpecies(index: 0, scientificName: "Turdus merula", commonName: "Eurasian Blackbird"))
        #expect(labels[3].index == 3)
        #expect(labels.map(\.isBird) == [true, false, false, true])
    }
}

@Suite struct DetectionAggregatorTests {
    @Test func strongSingleWindowConfirms() {
        var agg = DetectionAggregator()
        let confirmed = agg.add(scores: [0.9, 0.1, 0.5], at: 0)
        #expect(confirmed.map(\.index) == [0])
    }

    @Test func weakNeedsTwoWindowsWithinMemory() {
        var agg = DetectionAggregator()
        #expect(agg.add(scores: [0.5], at: 0).isEmpty)
        #expect(agg.add(scores: [0.5], at: 1.5).map(\.index) == [0])
    }

    @Test func oldHitsExpire() {
        var agg = DetectionAggregator()
        #expect(agg.add(scores: [0.5], at: 0).isEmpty)
        #expect(agg.add(scores: [0.5], at: 20).isEmpty)
    }

    @Test func respectsAllowedFilterAndSortsByScore() {
        var agg = DetectionAggregator()
        let confirmed = agg.add(scores: [0.75, 0.95, 0.8], at: 0, allowed: { $0 != 1 })
        #expect(confirmed.map(\.index) == [2, 0])
    }

    @Test func sigmoidMatchesBirdNET() {
        #expect(sigmoid(0) == 0.5)
        #expect(abs(sigmoid(-3.0338628) - 0.0459) < 0.001)
    }
}
