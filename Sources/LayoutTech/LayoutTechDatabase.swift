import Foundation
import LayoutCore

public struct LayoutTechDatabase: Hashable, Sendable, Codable {
    public var units: LayoutUnits
    public var grid: Double
    public var layers: [LayoutLayerDefinition]
    public var vias: [LayoutViaDefinition]
    public var layerRules: [LayoutLayerRuleSet]
    public var derivedLayerRules: [LayoutDerivedLayerRule]
    public var spacingRules: [LayoutSpacingRule]
    public var antennaRules: [LayoutAntennaRule]
    public var enclosureRules: [LayoutEnclosureRule]
    public var extensionRules: [LayoutExtensionRule]
    public var minimumCutRules: [LayoutMinimumCutRule]
    public var exactOverlapRules: [LayoutExactOverlapRule]
    public var forbiddenLayerRules: [LayoutForbiddenLayerRule]
    public var contacts: [LayoutContactDefinition]

    public init(
        units: LayoutUnits = .defaultUnits,
        grid: Double = 1,
        layers: [LayoutLayerDefinition],
        vias: [LayoutViaDefinition],
        layerRules: [LayoutLayerRuleSet],
        derivedLayerRules: [LayoutDerivedLayerRule] = [],
        spacingRules: [LayoutSpacingRule] = [],
        antennaRules: [LayoutAntennaRule] = [],
        enclosureRules: [LayoutEnclosureRule] = [],
        extensionRules: [LayoutExtensionRule] = [],
        minimumCutRules: [LayoutMinimumCutRule] = [],
        exactOverlapRules: [LayoutExactOverlapRule] = [],
        forbiddenLayerRules: [LayoutForbiddenLayerRule] = [],
        contacts: [LayoutContactDefinition] = []
    ) {
        self.units = units
        self.grid = grid
        self.layers = layers
        self.vias = vias
        self.layerRules = layerRules
        self.derivedLayerRules = derivedLayerRules
        self.spacingRules = spacingRules
        self.antennaRules = antennaRules
        self.enclosureRules = enclosureRules
        self.extensionRules = extensionRules
        self.minimumCutRules = minimumCutRules
        self.exactOverlapRules = exactOverlapRules
        self.forbiddenLayerRules = forbiddenLayerRules
        self.contacts = contacts
    }

    private enum CodingKeys: String, CodingKey {
        case units
        case grid
        case layers
        case vias
        case layerRules
        case derivedLayerRules
        case spacingRules
        case antennaRules
        case enclosureRules
        case extensionRules
        case minimumCutRules
        case exactOverlapRules
        case forbiddenLayerRules
        case contacts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.units = try container.decodeIfPresent(LayoutUnits.self, forKey: .units) ?? .defaultUnits
        self.grid = try container.decode(Double.self, forKey: .grid)
        self.layers = try container.decode([LayoutLayerDefinition].self, forKey: .layers)
        self.vias = try container.decode([LayoutViaDefinition].self, forKey: .vias)
        self.layerRules = try container.decode([LayoutLayerRuleSet].self, forKey: .layerRules)
        self.derivedLayerRules = try container.decodeIfPresent(
            [LayoutDerivedLayerRule].self,
            forKey: .derivedLayerRules
        ) ?? []
        self.spacingRules = try container.decodeIfPresent([LayoutSpacingRule].self, forKey: .spacingRules) ?? []
        self.antennaRules = try container.decodeIfPresent([LayoutAntennaRule].self, forKey: .antennaRules) ?? []
        self.enclosureRules = try container.decodeIfPresent([LayoutEnclosureRule].self, forKey: .enclosureRules) ?? []
        self.extensionRules = try container.decodeIfPresent([LayoutExtensionRule].self, forKey: .extensionRules) ?? []
        self.minimumCutRules = try container.decodeIfPresent([LayoutMinimumCutRule].self, forKey: .minimumCutRules) ?? []
        self.exactOverlapRules = try container.decodeIfPresent([LayoutExactOverlapRule].self, forKey: .exactOverlapRules) ?? []
        self.forbiddenLayerRules = try container.decodeIfPresent(
            [LayoutForbiddenLayerRule].self,
            forKey: .forbiddenLayerRules
        ) ?? []
        self.contacts = try container.decodeIfPresent([LayoutContactDefinition].self, forKey: .contacts) ?? []
    }

    public func layerDefinition(for id: LayoutLayerID) -> LayoutLayerDefinition? {
        layers.first { $0.id == id }
    }

    public func viaDefinition(for id: String) -> LayoutViaDefinition? {
        if let via = vias.first(where: { $0.id == id }) {
            return via
        }
        guard let contact = contactDefinition(for: id) else {
            return nil
        }
        return LayoutViaDefinition(
            id: contact.id,
            cutLayer: contact.cutLayer,
            topLayer: contact.topLayer,
            bottomLayer: contact.bottomLayer,
            cutSize: contact.cutSize,
            enclosure: contact.enclosure,
            cutSpacing: contact.cutSpacing
        )
    }

    public func ruleSet(for id: LayoutLayerID) -> LayoutLayerRuleSet? {
        layerRules.first { $0.layerID == id }
    }

    public func antennaRule(for id: LayoutLayerID) -> LayoutAntennaRule? {
        antennaRules.first { $0.layerID == id }
    }

    public func contactDefinition(for id: String) -> LayoutContactDefinition? {
        contacts.first { $0.id == id }
    }

    public func minimumCutRule(for id: String) -> LayoutMinimumCutRule? {
        minimumCutRules.first { $0.id == id }
    }

    public func exactOverlapRule(for id: String) -> LayoutExactOverlapRule? {
        exactOverlapRules.first { $0.id == id }
    }

    public func forbiddenLayerRule(for id: String) -> LayoutForbiddenLayerRule? {
        forbiddenLayerRules.first { $0.id == id }
    }

    public func enclosureRule(outer: LayoutLayerID, inner: LayoutLayerID) -> LayoutEnclosureRule? {
        enclosureRules.first { $0.outerLayer == outer && $0.innerLayer == inner }
    }

    public func extensionRule(
        extending: LayoutLayerID,
        enclosed: LayoutLayerID,
        direction: LayoutExtensionRule.Direction
    ) -> LayoutExtensionRule? {
        extensionRules.first {
            $0.extendingLayer == extending
                && $0.enclosedLayer == enclosed
                && $0.direction == direction
        }
    }

    // MARK: - Standard (M1/M2/VIA1 only)

    public static func standard() -> LayoutTechDatabase {
        let m1 = LayoutLayerDefinition(
            id: LayoutLayerID(name: "M1", purpose: "drawing"),
            displayName: "Metal1",
            gdsLayer: 1,
            gdsDatatype: 0,
            color: LayoutColor(red: 0.3, green: 0.5, blue: 0.9),
            fillPattern: .forwardDiagonal,
            preferredDirection: .horizontal
        )
        let m2 = LayoutLayerDefinition(
            id: LayoutLayerID(name: "M2", purpose: "drawing"),
            displayName: "Metal2",
            gdsLayer: 2,
            gdsDatatype: 0,
            color: LayoutColor(red: 0.9, green: 0.5, blue: 0.3),
            fillPattern: .backwardDiagonal,
            preferredDirection: .vertical
        )
        let via1 = LayoutLayerDefinition(
            id: LayoutLayerID(name: "VIA1", purpose: "cut"),
            displayName: "Via1",
            gdsLayer: 3,
            gdsDatatype: 0,
            color: LayoutColor(red: 0.8, green: 0.8, blue: 0.2),
            fillPattern: .crosshatch
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
        let rulesVia1 = LayoutLayerRuleSet(
            layerID: via1.id,
            minWidth: 0.05,
            minSpacing: 0.05,
            minArea: 0.0,
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
        // Typical foundry plasma-damage limit: each metal may collect at
        // most 400x the connected gate area at its own etch stage.
        let antennaRules = [
            LayoutAntennaRule(layerID: m1.id, maxRatio: 400),
            LayoutAntennaRule(layerID: m2.id, maxRatio: 400),
        ]
        return LayoutTechDatabase(
            units: .defaultUnits,
            grid: 0.01,
            layers: [m1, m2, via1],
            vias: [viaDef],
            layerRules: [rulesM1, rulesM2, rulesVia1],
            antennaRules: antennaRules
        )
    }

    // MARK: - Sample Process (Full device layer stack)

    /// Educational ~180nm-class process with device layers for auto-layout generation.
    public static func sampleProcess() -> LayoutTechDatabase {
        // Layer IDs
        let nwellID  = LayoutLayerID(name: "NWELL", purpose: "drawing")
        let activeID = LayoutLayerID(name: "ACTIVE", purpose: "drawing")
        let polyID   = LayoutLayerID(name: "POLY", purpose: "drawing")
        let nimpID   = LayoutLayerID(name: "NIMP", purpose: "drawing")
        let pimpID   = LayoutLayerID(name: "PIMP", purpose: "drawing")
        let contID   = LayoutLayerID(name: "CONTACT", purpose: "cut")
        let m1ID     = LayoutLayerID(name: "M1", purpose: "drawing")
        let m2ID     = LayoutLayerID(name: "M2", purpose: "drawing")
        let via1ID   = LayoutLayerID(name: "VIA1", purpose: "cut")
        let resiID   = LayoutLayerID(name: "RESI", purpose: "drawing")

        // Layer definitions
        let layers: [LayoutLayerDefinition] = [
            LayoutLayerDefinition(
                id: nwellID, displayName: "NWell", gdsLayer: 10, gdsDatatype: 0,
                color: LayoutColor(red: 0.85, green: 0.85, blue: 0.55, alpha: 0.4),
                fillPattern: .horizontal
            ),
            LayoutLayerDefinition(
                id: activeID, displayName: "Active", gdsLayer: 20, gdsDatatype: 0,
                color: LayoutColor(red: 0.3, green: 0.8, blue: 0.3),
                fillPattern: .solid
            ),
            LayoutLayerDefinition(
                id: polyID, displayName: "Poly", gdsLayer: 30, gdsDatatype: 0,
                color: LayoutColor(red: 0.9, green: 0.2, blue: 0.2),
                fillPattern: .solid
            ),
            LayoutLayerDefinition(
                id: nimpID, displayName: "N-Implant", gdsLayer: 40, gdsDatatype: 0,
                color: LayoutColor(red: 0.3, green: 0.3, blue: 0.9, alpha: 0.3),
                fillPattern: .dots
            ),
            LayoutLayerDefinition(
                id: pimpID, displayName: "P-Implant", gdsLayer: 41, gdsDatatype: 0,
                color: LayoutColor(red: 0.9, green: 0.3, blue: 0.6, alpha: 0.3),
                fillPattern: .dots
            ),
            LayoutLayerDefinition(
                id: contID, displayName: "Contact", gdsLayer: 50, gdsDatatype: 0,
                color: LayoutColor(red: 0.5, green: 0.5, blue: 0.5),
                fillPattern: .crosshatch
            ),
            LayoutLayerDefinition(
                id: m1ID, displayName: "Metal1", gdsLayer: 1, gdsDatatype: 0,
                color: LayoutColor(red: 0.3, green: 0.5, blue: 0.9),
                fillPattern: .forwardDiagonal,
                preferredDirection: .horizontal
            ),
            LayoutLayerDefinition(
                id: m2ID, displayName: "Metal2", gdsLayer: 2, gdsDatatype: 0,
                color: LayoutColor(red: 0.9, green: 0.5, blue: 0.3),
                fillPattern: .backwardDiagonal,
                preferredDirection: .vertical
            ),
            LayoutLayerDefinition(
                id: via1ID, displayName: "Via1", gdsLayer: 3, gdsDatatype: 0,
                color: LayoutColor(red: 0.8, green: 0.8, blue: 0.2),
                fillPattern: .crosshatch
            ),
            LayoutLayerDefinition(
                id: resiID, displayName: "Resistor ID", gdsLayer: 60, gdsDatatype: 0,
                color: LayoutColor(red: 0.6, green: 0.4, blue: 0.2, alpha: 0.4),
                fillPattern: .horizontal
            ),
        ]

        // Layer design rules (dimensions in µm)
        let layerRules: [LayoutLayerRuleSet] = [
            LayoutLayerRuleSet(
                layerID: nwellID, minWidth: 0.86, minSpacing: 1.40,
                minArea: 0.0, minDensity: 0.0, maxDensity: 1.0
            ),
            LayoutLayerRuleSet(
                layerID: activeID, minWidth: 0.22, minSpacing: 0.28,
                minArea: 0.0, minDensity: 0.0, maxDensity: 1.0
            ),
            LayoutLayerRuleSet(
                layerID: polyID, minWidth: 0.18, minSpacing: 0.28,
                minArea: 0.0, minDensity: 0.0, maxDensity: 1.0
            ),
            LayoutLayerRuleSet(
                layerID: nimpID, minWidth: 0.40, minSpacing: 0.40,
                minArea: 0.0, minDensity: 0.0, maxDensity: 1.0
            ),
            LayoutLayerRuleSet(
                layerID: pimpID, minWidth: 0.40, minSpacing: 0.40,
                minArea: 0.0, minDensity: 0.0, maxDensity: 1.0
            ),
            LayoutLayerRuleSet(
                layerID: contID, minWidth: 0.22, minSpacing: 0.25,
                minArea: 0.0, minDensity: 0.0, maxDensity: 1.0
            ),
            LayoutLayerRuleSet(
                layerID: m1ID, minWidth: 0.23, minSpacing: 0.23,
                minArea: 0.01, minDensity: 0.0, maxDensity: 1.0
            ),
            LayoutLayerRuleSet(
                layerID: m2ID, minWidth: 0.28, minSpacing: 0.28,
                minArea: 0.01, minDensity: 0.0, maxDensity: 1.0
            ),
            LayoutLayerRuleSet(
                layerID: via1ID, minWidth: 0.22, minSpacing: 0.25,
                minArea: 0.0, minDensity: 0.0, maxDensity: 1.0
            ),
            LayoutLayerRuleSet(
                layerID: resiID, minWidth: 0.44, minSpacing: 0.44,
                minArea: 0.0, minDensity: 0.0, maxDensity: 1.0
            ),
        ]

        // Via definitions
        let via1 = LayoutViaDefinition(
            id: "VIA1",
            cutLayer: via1ID,
            topLayer: m2ID,
            bottomLayer: m1ID,
            cutSize: LayoutSize(width: 0.22, height: 0.22),
            enclosure: LayoutViaEnclosure(top: 0.05, bottom: 0.05),
            cutSpacing: 0.25
        )

        // Enclosure rules
        let enclosureRules: [LayoutEnclosureRule] = [
            LayoutEnclosureRule(outerLayer: nwellID, innerLayer: activeID, minEnclosure: 0.18),
            LayoutEnclosureRule(outerLayer: nimpID, innerLayer: activeID, minEnclosure: 0.14),
            LayoutEnclosureRule(outerLayer: pimpID, innerLayer: activeID, minEnclosure: 0.14),
            // Resistor poly passes through the RESI marker to reach its
            // terminals, so only the covered body must keep the margin.
            LayoutEnclosureRule(outerLayer: resiID, innerLayer: polyID, minEnclosure: 0.10, allowsPassThrough: true),
        ]

        // Contact definitions
        let contacts: [LayoutContactDefinition] = [
            LayoutContactDefinition(
                id: "CONT_ACTIVE",
                cutLayer: contID,
                bottomLayer: activeID,
                topLayer: m1ID,
                cutSize: LayoutSize(width: 0.22, height: 0.22),
                enclosure: LayoutViaEnclosure(top: 0.06, bottom: 0.06),
                cutSpacing: 0.25
            ),
            LayoutContactDefinition(
                id: "CONT_POLY",
                cutLayer: contID,
                bottomLayer: polyID,
                topLayer: m1ID,
                cutSize: LayoutSize(width: 0.22, height: 0.22),
                enclosure: LayoutViaEnclosure(top: 0.06, bottom: 0.08),
                cutSpacing: 0.25
            ),
        ]

        // Typical foundry plasma-damage limit: each metal may collect at
        // most 400x the connected gate area at its own etch stage. Gates in
        // this process connect into the stack at M1 (via the poly contact),
        // so only the metal stages are evaluated.
        let antennaRules = [
            LayoutAntennaRule(layerID: m1ID, maxRatio: 400),
            LayoutAntennaRule(layerID: m2ID, maxRatio: 400),
        ]

        return LayoutTechDatabase(
            units: .defaultUnits,
            grid: 0.01,
            layers: layers,
            vias: [via1],
            layerRules: layerRules,
            antennaRules: antennaRules,
            enclosureRules: enclosureRules,
            contacts: contacts
        )
    }
}
