public struct Sky130LayoutExtractionProfileFactory: Sendable {
    public init() {}

    public func makeProfile(from deck: LayoutExtractionDeck) -> LayoutExtractionProcessProfile {
        let nmos = preferredRule(
            in: deck,
            model: "sky130_fd_pr__nfet_01v8",
            fallbackSelector: "nsdm"
        )
        let pmos = preferredRule(
            in: deck,
            model: "sky130_fd_pr__pfet_01v8",
            fallbackSelector: "psdm"
        )
        let pmosHVT = preferredRule(
            in: deck,
            model: "sky130_fd_pr__pfet_01v8_hvt",
            fallbackSelector: "pfethvt"
        )
        let supported = nmos != nil && pmos != nil && pmosHVT != nil
        let audit = LayoutExtractionDeckAuditor().audit(deck, requiredFamilies: ["mosfet"])
        return LayoutExtractionProcessProfile(
            processID: deck.processID,
            processProfileID: deck.processProfileID,
            extractionDeckDigest: deck.sourceDigest,
            productionEligible: supported && audit.productionEligibility.isEligible,
            parameterValueConvention: .micronScalar,
            conductorLayers: LayoutExtractionLayerReference(names: [
                "diff", "tap", "nwell", "poly", "li1", "met1", "met2", "met3", "met4", "met5",
            ]),
            connectionRules: [
                LayoutExtractionConnectionRule(
                    cutLayers: LayoutExtractionLayerReference(names: ["licon1"]),
                    lowerLayers: LayoutExtractionLayerReference(names: ["diff", "tap", "poly"]),
                    upperLayers: LayoutExtractionLayerReference(names: ["li1"])
                ),
                connectionRule(cut: "mcon", lower: "li1", upper: "met1"),
                connectionRule(cut: "via", lower: "met1", upper: "met2"),
                connectionRule(cut: "via2", lower: "met2", upper: "met3"),
                connectionRule(cut: "via3", lower: "met3", upper: "met4"),
                connectionRule(cut: "via4", lower: "met4", upper: "met5"),
            ],
            mosRules: [
                makeMOSRule(
                    compiled: nmos,
                    fallbackID: "sky130-nfet-01v8",
                    fallbackModel: "sky130_fd_pr__nfet_01v8",
                    selector: "nsdm",
                    exclusionLayers: [],
                    bulkLayers: ["pwell"],
                    bulkTapSelector: "psdm",
                    bulkPorts: ["VNB", "VGND", "VSS", "GND", "0"]
                ),
            ] + (pmosHVT.map { compiled in [makeMOSRule(
                    compiled: compiled,
                    fallbackID: "sky130-pfet-01v8-hvt",
                    fallbackModel: "sky130_fd_pr__pfet_01v8_hvt",
                    selector: "hvtp",
                    exclusionLayers: [],
                    bulkLayers: ["nwell"],
                    bulkTapSelector: "nsdm",
                    bulkPorts: ["VPB", "VPWR", "VDD", "POWER"]
                )] } ?? []) + [
                makeMOSRule(
                    compiled: pmos,
                    fallbackID: "sky130-pfet-01v8",
                    fallbackModel: "sky130_fd_pr__pfet_01v8",
                    selector: "psdm",
                    exclusionLayers: ["hvtp"],
                    bulkLayers: ["nwell"],
                    bulkTapSelector: "nsdm",
                    bulkPorts: ["VPB", "VPWR", "VDD", "POWER"]
                ),
            ]
        )
    }

    private func preferredRule(
        in deck: LayoutExtractionDeck,
        model: String,
        fallbackSelector: String
    ) -> LayoutExtractionDeviceRule? {
        deck.deviceRules.first { $0.family == "mosfet" && $0.model == model }
            ?? deck.deviceRules.first {
                $0.family == "mosfet"
                    && $0.recognitionExpressions.contains { $0.lowercased().contains(fallbackSelector) }
            }
    }

    private func makeMOSRule(
        compiled: LayoutExtractionDeviceRule?,
        fallbackID: String,
        fallbackModel: String,
        selector: String,
        exclusionLayers: Set<String>,
        bulkLayers: Set<String>,
        bulkTapSelector: String,
        bulkPorts: [String]
    ) -> LayoutExtractionMOSRule {
        LayoutExtractionMOSRule(
            ruleID: compiled?.ruleID ?? fallbackID,
            model: compiled?.model ?? fallbackModel,
            gateLayers: LayoutExtractionLayerReference(names: ["poly"]),
            diffusionLayers: LayoutExtractionLayerReference(names: ["diff"]),
            selectorLayers: LayoutExtractionLayerReference(names: [selector]),
            exclusionLayers: LayoutExtractionLayerReference(names: exclusionLayers),
            bulkLayers: LayoutExtractionLayerReference(names: bulkLayers),
            bulkTapLayers: LayoutExtractionLayerReference(names: ["tap"]),
            bulkTapSelectorLayers: LayoutExtractionLayerReference(names: [bulkTapSelector]),
            bulkPortCandidates: bulkPorts,
            preferNamedBulkPort: true,
            sourceLocation: compiled?.sourceLocation
        )
    }

    private static func connectionRule(
        cut: String,
        lower: String,
        upper: String
    ) -> LayoutExtractionConnectionRule {
        LayoutExtractionConnectionRule(
            cutLayers: LayoutExtractionLayerReference(names: [cut]),
            lowerLayers: LayoutExtractionLayerReference(names: [lower]),
            upperLayers: LayoutExtractionLayerReference(names: [upper])
        )
    }

    private func connectionRule(
        cut: String,
        lower: String,
        upper: String
    ) -> LayoutExtractionConnectionRule {
        Self.connectionRule(cut: cut, lower: lower, upper: upper)
    }
}
