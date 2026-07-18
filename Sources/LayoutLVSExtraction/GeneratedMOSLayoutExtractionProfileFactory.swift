public struct GeneratedMOSLayoutExtractionProfileFactory: Sendable {
    public init() {}

    public func makeProfile(from deck: LayoutExtractionDeck = GeneratedMOSFixtureDeck().makeDeck()) -> LayoutExtractionProcessProfile {
        let nmos = deck.deviceRules.first { $0.model.lowercased() == "nmos" }
        let pmos = deck.deviceRules.first { $0.model.lowercased() == "pmos" }
        return LayoutExtractionProcessProfile(
            processID: deck.processID,
            processProfileID: deck.processProfileID,
            extractionDeckDigest: deck.sourceDigest,
            deckUseScope: deck.useScope,
            conductorLayers: LayoutExtractionLayerReference(names: [
                "ACTIVE", "POLY", "M1", "M2", "M3", "M4", "M5",
            ]),
            connectionRules: [],
            mosRules: [
                LayoutExtractionMOSRule(
                    ruleID: nmos?.ruleID ?? "fixture.generated-mos.nmos",
                    model: nmos?.model ?? "nmos",
                    gateLayers: LayoutExtractionLayerReference(names: ["POLY"]),
                    diffusionLayers: LayoutExtractionLayerReference(names: ["ACTIVE"]),
                    selectorLayers: LayoutExtractionLayerReference(names: ["NIMP"]),
                    bulkLayers: LayoutExtractionLayerReference(names: []),
                    bulkTapLayers: LayoutExtractionLayerReference(names: ["ACTIVE"]),
                    bulkTapSelectorLayers: LayoutExtractionLayerReference(names: ["PIMP"]),
                    bulkPortCandidates: ["B", "BULK", "VSS", "VGND", "GND", "0"],
                    sourceLocation: nmos?.sourceLocation
                ),
                LayoutExtractionMOSRule(
                    ruleID: pmos?.ruleID ?? "fixture.generated-mos.pmos",
                    model: pmos?.model ?? "pmos",
                    gateLayers: LayoutExtractionLayerReference(names: ["POLY"]),
                    diffusionLayers: LayoutExtractionLayerReference(names: ["ACTIVE"]),
                    selectorLayers: LayoutExtractionLayerReference(names: ["PIMP"]),
                    bulkLayers: LayoutExtractionLayerReference(names: []),
                    bulkTapLayers: LayoutExtractionLayerReference(names: ["ACTIVE"]),
                    bulkTapSelectorLayers: LayoutExtractionLayerReference(names: ["NIMP"]),
                    bulkPortCandidates: ["B", "BULK", "VDD", "VPWR", "POWER"],
                    sourceLocation: pmos?.sourceLocation
                ),
            ]
        )
    }
}
