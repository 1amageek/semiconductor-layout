import Foundation
import LayoutCore

public struct LayoutTechDatabase: Hashable, Sendable, Codable {
    public var units: LayoutUnits
    public var grid: Double
    public var layers: [LayoutLayerDefinition]
    public var vias: [LayoutViaDefinition]
    public var layerRules: [LayoutLayerRuleSet]
    public var antennaRules: [LayoutAntennaRule]

    public init(
        units: LayoutUnits = .defaultUnits,
        grid: Double = 1,
        layers: [LayoutLayerDefinition],
        vias: [LayoutViaDefinition],
        layerRules: [LayoutLayerRuleSet],
        antennaRules: [LayoutAntennaRule] = []
    ) {
        self.units = units
        self.grid = grid
        self.layers = layers
        self.vias = vias
        self.layerRules = layerRules
        self.antennaRules = antennaRules
    }

    public func layerDefinition(for id: LayoutLayerID) -> LayoutLayerDefinition? {
        layers.first { $0.id == id }
    }

    public func viaDefinition(for id: String) -> LayoutViaDefinition? {
        vias.first { $0.id == id }
    }

    public func ruleSet(for id: LayoutLayerID) -> LayoutLayerRuleSet? {
        layerRules.first { $0.layerID == id }
    }

    public func antennaRule(for id: LayoutLayerID) -> LayoutAntennaRule? {
        antennaRules.first { $0.layerID == id }
    }

    public static func standard() -> LayoutTechDatabase {
        let m1 = LayoutLayerDefinition(
            id: LayoutLayerID(name: "M1", purpose: "drawing"),
            displayName: "Metal1",
            gdsLayer: 1,
            gdsDatatype: 0,
            color: LayoutColor(red: 0.3, green: 0.5, blue: 0.9),
            preferredDirection: .horizontal
        )
        let m2 = LayoutLayerDefinition(
            id: LayoutLayerID(name: "M2", purpose: "drawing"),
            displayName: "Metal2",
            gdsLayer: 2,
            gdsDatatype: 0,
            color: LayoutColor(red: 0.9, green: 0.5, blue: 0.3),
            preferredDirection: .vertical
        )
        let via1 = LayoutLayerDefinition(
            id: LayoutLayerID(name: "VIA1", purpose: "cut"),
            displayName: "Via1",
            gdsLayer: 3,
            gdsDatatype: 0,
            color: LayoutColor(red: 0.8, green: 0.8, blue: 0.2)
        )
        let rulesM1 = LayoutLayerRuleSet(
            layerID: m1.id,
            minWidth: 0.05,
            minSpacing: 0.05,
            minArea: 0.01,
            minDensity: 0.0,
            maxDensity: 1.0
        )
        let rulesM2 = LayoutLayerRuleSet(
            layerID: m2.id,
            minWidth: 0.05,
            minSpacing: 0.05,
            minArea: 0.01,
            minDensity: 0.0,
            maxDensity: 1.0
        )
        let viaDef = LayoutViaDefinition(
            id: "VIA1",
            cutLayer: via1.id,
            topLayer: m2.id,
            bottomLayer: m1.id,
            cutSize: LayoutSize(width: 0.05, height: 0.05),
            enclosure: LayoutViaEnclosure(top: 0.01, bottom: 0.01),
            cutSpacing: 0.05
        )
        return LayoutTechDatabase(
            units: .defaultUnits,
            grid: 0.01,
            layers: [m1, m2, via1],
            vias: [viaDef],
            layerRules: [rulesM1, rulesM2]
        )
    }
}
