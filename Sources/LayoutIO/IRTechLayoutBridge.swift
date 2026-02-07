import Foundation
import LayoutCore
import LayoutTech
import TechIR

/// Converts between `IRTechLibrary` (format-agnostic IR) and `LayoutTechDatabase` (editor model).
public struct IRTechLayoutBridge: Sendable {

    public init() {}

    // MARK: - Import: IRTechLibrary → LayoutTechDatabase

    public func importTechLibrary(_ lib: IRTechLibrary) -> LayoutTechDatabase {
        let layers = lib.layers.map { convertLayer($0) }
        let vias = lib.vias.compactMap { convertVia($0) }
        let layerRules = buildLayerRules(from: lib)
        let antennaRules = lib.antennaRules.map { convertAntennaRule($0) }
        let enclosureRules = lib.enclosureRules.map { convertEnclosureRule($0) }

        return LayoutTechDatabase(
            units: LayoutUnits(dbuPerMicron: lib.dbuPerMicron),
            grid: 1.0 / lib.dbuPerMicron,
            layers: layers,
            vias: vias,
            layerRules: layerRules,
            antennaRules: antennaRules,
            enclosureRules: enclosureRules
        )
    }

    // MARK: - Export: LayoutTechDatabase → IRTechLibrary

    public func exportTechLibrary(_ tech: LayoutTechDatabase, name: String = "") -> IRTechLibrary {
        let layers = tech.layers.map { exportLayer($0, tech: tech) }
        let vias = tech.vias.map { exportVia($0) }
        let designRules = tech.layerRules.map { exportDesignRule($0) }
        let antennaRules = tech.antennaRules.map { exportAntennaRule($0) }
        let enclosureRules = tech.enclosureRules.map { exportEnclosureRule($0) }

        return IRTechLibrary(
            name: name,
            dbuPerMicron: tech.units.dbuPerMicron,
            layers: layers,
            vias: vias,
            designRules: designRules,
            enclosureRules: enclosureRules,
            antennaRules: antennaRules
        )
    }

    // MARK: - Import Helpers

    private func convertLayer(_ ir: IRTechLayerDef) -> LayoutLayerDefinition {
        let purpose = inferPurpose(from: ir)
        let layerID = LayoutLayerID(name: ir.name, purpose: purpose)

        let color: LayoutColor
        if let c = ir.color {
            color = LayoutColor(red: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
        } else {
            color = fallbackColor(for: ir.gdsLayer ?? 0)
        }

        let fillPattern: LayoutFillPattern
        if let p = ir.fillPattern {
            fillPattern = convertFillPattern(p)
        } else {
            fillPattern = .solid
        }

        let direction: LayoutPreferredDirection
        switch ir.direction {
        case .horizontal: direction = .horizontal
        case .vertical:   direction = .vertical
        case nil:         direction = .none
        }

        return LayoutLayerDefinition(
            id: layerID,
            displayName: ir.name,
            gdsLayer: ir.gdsLayer ?? 0,
            gdsDatatype: ir.gdsDatatype ?? 0,
            color: color,
            fillPattern: fillPattern,
            preferredDirection: direction,
            visibleByDefault: ir.visibleByDefault ?? true
        )
    }

    private func convertVia(_ ir: IRTechViaDef) -> LayoutViaDefinition? {
        guard !ir.cutLayerName.isEmpty else { return nil }

        let cutLayer = LayoutLayerID(name: ir.cutLayerName, purpose: "cut")
        let topLayer = LayoutLayerID(name: ir.topLayerName, purpose: "drawing")
        let bottomLayer = LayoutLayerID(name: ir.bottomLayerName, purpose: "drawing")

        let cutSize: LayoutSize
        if let w = ir.cutWidth, let h = ir.cutHeight {
            cutSize = LayoutSize(width: w, height: h)
        } else {
            cutSize = LayoutSize(width: 0.1, height: 0.1)
        }

        let enclosure: LayoutViaEnclosure
        if let enc = ir.enclosure {
            enclosure = LayoutViaEnclosure(top: enc.overhang1, bottom: enc.overhang2)
        } else {
            enclosure = LayoutViaEnclosure(top: 0, bottom: 0)
        }

        return LayoutViaDefinition(
            id: ir.name,
            cutLayer: cutLayer,
            topLayer: topLayer,
            bottomLayer: bottomLayer,
            cutSize: cutSize,
            enclosure: enclosure,
            cutSpacing: ir.spacing ?? 0
        )
    }

    private func buildLayerRules(from lib: IRTechLibrary) -> [LayoutLayerRuleSet] {
        lib.designRules.map { rule in
            let purpose = inferPurposeFromName(rule.layerName, layers: lib.layers)
            let layerID = LayoutLayerID(name: rule.layerName, purpose: purpose)
            return LayoutLayerRuleSet(
                layerID: layerID,
                minWidth: rule.minWidth ?? 0,
                minSpacing: rule.minSpacing ?? 0,
                minArea: rule.minArea ?? 0,
                minDensity: rule.minDensity ?? 0,
                maxDensity: rule.maxDensity ?? 1
            )
        }
    }

    private func convertAntennaRule(_ ir: IRTechAntennaRule) -> LayoutAntennaRule {
        let layerID = LayoutLayerID(name: ir.layerName, purpose: "drawing")
        return LayoutAntennaRule(layerID: layerID, maxRatio: ir.maxRatio)
    }

    private func convertEnclosureRule(_ ir: IRTechEnclosureRule) -> LayoutEnclosureRule {
        let outer = LayoutLayerID(name: ir.outerLayerName, purpose: "drawing")
        let inner = LayoutLayerID(name: ir.innerLayerName, purpose: "drawing")
        return LayoutEnclosureRule(outerLayer: outer, innerLayer: inner, minEnclosure: ir.minEnclosure)
    }

    private func convertFillPattern(_ ir: IRTechFillPattern) -> LayoutFillPattern {
        switch ir {
        case .solid:            return .solid
        case .forwardDiagonal:  return .forwardDiagonal
        case .backwardDiagonal: return .backwardDiagonal
        case .crosshatch:       return .crosshatch
        case .horizontal:       return .horizontal
        case .vertical:         return .vertical
        case .grid:             return .grid
        case .dots:             return .dots
        }
    }

    private func inferPurpose(from layer: IRTechLayerDef) -> String {
        if layer.type == .cut { return "cut" }
        return "drawing"
    }

    private func inferPurposeFromName(_ name: String, layers: [IRTechLayerDef]) -> String {
        if let layer = layers.first(where: { $0.name == name }) {
            return inferPurpose(from: layer)
        }
        let n = name.lowercased()
        if n.contains("via") || n.contains("contact") || n.contains("cut") {
            return "cut"
        }
        return "drawing"
    }

    private func fallbackColor(for layer: Int) -> LayoutColor {
        let hue = Double((layer * 37) % 360) / 360
        let i = Int(hue * 6)
        let f = hue * 6 - Double(i)
        let s = 0.55
        let v = 0.92
        let p = v * (1 - s)
        let q = v * (1 - f * s)
        let t = v * (1 - (1 - f) * s)

        let (r, g, b): (Double, Double, Double)
        switch i % 6 {
        case 0: (r, g, b) = (v, t, p)
        case 1: (r, g, b) = (q, v, p)
        case 2: (r, g, b) = (p, v, t)
        case 3: (r, g, b) = (p, q, v)
        case 4: (r, g, b) = (t, p, v)
        default: (r, g, b) = (v, p, q)
        }
        return LayoutColor(red: r, green: g, blue: b)
    }

    // MARK: - Export Helpers

    private func exportLayer(_ layout: LayoutLayerDefinition, tech: LayoutTechDatabase) -> IRTechLayerDef {
        let type: IRTechLayerType = layout.id.purpose == "cut" ? .cut : .routing

        let direction: IRTechLayerDirection?
        switch layout.preferredDirection {
        case .horizontal: direction = .horizontal
        case .vertical:   direction = .vertical
        case .none:       direction = nil
        }

        let rule = tech.ruleSet(for: layout.id)

        return IRTechLayerDef(
            name: layout.id.name,
            type: type,
            gdsLayer: layout.gdsLayer,
            gdsDatatype: layout.gdsDatatype,
            direction: direction,
            spacing: rule?.minSpacing,
            color: IRTechColor(red: layout.color.red, green: layout.color.green, blue: layout.color.blue, alpha: layout.color.alpha),
            fillPattern: exportFillPattern(layout.fillPattern),
            visibleByDefault: layout.visibleByDefault,
            minArea: rule?.minArea
        )
    }

    private func exportVia(_ layout: LayoutViaDefinition) -> IRTechViaDef {
        IRTechViaDef(
            name: layout.id,
            cutLayerName: layout.cutLayer.name,
            topLayerName: layout.topLayer.name,
            bottomLayerName: layout.bottomLayer.name,
            cutWidth: layout.cutSize.width,
            cutHeight: layout.cutSize.height,
            enclosure: IRTechEnclosureValues(overhang1: layout.enclosure.top, overhang2: layout.enclosure.bottom),
            spacing: layout.cutSpacing
        )
    }

    private func exportDesignRule(_ rule: LayoutLayerRuleSet) -> IRTechDesignRule {
        IRTechDesignRule(
            layerName: rule.layerID.name,
            minWidth: rule.minWidth,
            minSpacing: rule.minSpacing,
            minArea: rule.minArea,
            minDensity: rule.minDensity,
            maxDensity: rule.maxDensity
        )
    }

    private func exportAntennaRule(_ rule: LayoutAntennaRule) -> IRTechAntennaRule {
        IRTechAntennaRule(layerName: rule.layerID.name, maxRatio: rule.maxRatio)
    }

    private func exportEnclosureRule(_ rule: LayoutEnclosureRule) -> IRTechEnclosureRule {
        IRTechEnclosureRule(
            outerLayerName: rule.outerLayer.name,
            innerLayerName: rule.innerLayer.name,
            minEnclosure: rule.minEnclosure
        )
    }

    private func exportFillPattern(_ layout: LayoutFillPattern) -> IRTechFillPattern {
        switch layout {
        case .solid:            return .solid
        case .forwardDiagonal:  return .forwardDiagonal
        case .backwardDiagonal: return .backwardDiagonal
        case .crosshatch:       return .crosshatch
        case .horizontal:       return .horizontal
        case .vertical:         return .vertical
        case .grid:             return .grid
        case .dots:             return .dots
        }
    }
}
