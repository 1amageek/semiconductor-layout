import Foundation
import CircuiteFoundation
import LayoutCore
import LayoutTech
import TechIR

/// Converts between `IRTechLibrary` (format-agnostic IR) and `LayoutTechDatabase` (editor model).
public struct IRTechLayoutConverter: Sendable {

    public init() {}

    // MARK: - Import: IRTechLibrary → LayoutTechDatabase

    public func importTechLibrary(_ lib: IRTechLibrary) throws -> LayoutTechDatabase {
        let scale = try DatabaseUnitScale(databaseUnitsPerMicrometer: lib.dbuPerMicron)
        let layers = lib.layers.map { convertLayer($0) }
        let vias = lib.vias.compactMap { convertVia($0) }
        let layerRules = buildLayerRules(from: lib)
        let antennaRules = lib.antennaRules.map { convertAntennaRule($0) }
        let enclosureRules = lib.enclosureRules.map { convertEnclosureRule($0) }
        let extensionRules = lib.extensionRules.map { convertExtensionRule($0) }
        let minimumCutRules = lib.minimumCutRules.map { convertMinimumCutRule($0) }

        return LayoutTechDatabase(
            units: LayoutUnits(scale: scale),
            grid: 1.0 / scale.databaseUnitsPerMicrometer,
            layers: layers,
            vias: vias,
            layerRules: layerRules,
            antennaRules: antennaRules,
            enclosureRules: enclosureRules,
            extensionRules: extensionRules,
            minimumCutRules: minimumCutRules
        )
    }

    // MARK: - Export: LayoutTechDatabase → IRTechLibrary

    public func exportTechLibrary(_ tech: LayoutTechDatabase, name: String = "") -> IRTechLibrary {
        let layers = tech.layers.map { exportLayer($0, tech: tech) }
        let vias = tech.vias.map { exportVia($0) }
        let designRules = tech.layerRules.map { exportDesignRule($0) }
        let antennaRules = tech.antennaRules.map { exportAntennaRule($0) }
        let enclosureRules = tech.enclosureRules.map { exportEnclosureRule($0) }
        let extensionRules = tech.extensionRules.map { exportExtensionRule($0) }
        let minimumCutRules = tech.minimumCutRules.map { exportMinimumCutRule($0) }

        return IRTechLibrary(
            name: name,
            dbuPerMicron: tech.units.scale.databaseUnitsPerMicrometer,
            layers: layers,
            vias: vias,
            designRules: designRules,
            enclosureRules: enclosureRules,
            extensionRules: extensionRules,
            minimumCutRules: minimumCutRules,
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
            cutSpacing: ir.spacing ?? 0,
            layerGeometries: ir.layers.map { convertViaLayerGeometry($0, via: ir) }
        )
    }

    private func convertViaLayerGeometry(
        _ geometry: IRTechViaLayerGeometry,
        via: IRTechViaDef
    ) -> LayoutViaLayerGeometry {
        LayoutViaLayerGeometry(
            layer: viaLayerID(named: geometry.layerName, via: via),
            rects: geometry.rects.map(convertRect)
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
                maxDensity: rule.maxDensity ?? 1,
                minEnclosedArea: rule.minEnclosedArea,
                requiresRectangular: rule.requiresRectangular ?? false,
                allowedAngleStepDegrees: rule.allowedAngleStepDegrees
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

    private func convertExtensionRule(_ ir: IRTechExtensionRule) -> LayoutExtensionRule {
        let extending = LayoutLayerID(name: ir.extendingLayerName, purpose: "drawing")
        let enclosed = LayoutLayerID(name: ir.enclosedLayerName, purpose: "drawing")
        let direction: LayoutExtensionRule.Direction
        switch ir.direction {
        case .horizontal:
            direction = .horizontal
        case .vertical:
            direction = .vertical
        }
        return LayoutExtensionRule(
            extendingLayer: extending,
            enclosedLayer: enclosed,
            minExtension: ir.minExtension,
            direction: direction
        )
    }

    private func convertMinimumCutRule(_ ir: IRTechMinimumCutRule) -> LayoutMinimumCutRule {
        LayoutMinimumCutRule(
            id: ir.name,
            cutLayer: LayoutLayerID(name: ir.cutLayerName, purpose: "cut"),
            bottomLayer: LayoutLayerID(name: ir.bottomLayerName, purpose: "drawing"),
            topLayer: LayoutLayerID(name: ir.topLayerName, purpose: "drawing"),
            minimumCount: ir.minimumCount
        )
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

    private func viaLayerID(named layerName: String, via: IRTechViaDef) -> LayoutLayerID {
        if layerName == via.cutLayerName {
            return LayoutLayerID(name: layerName, purpose: "cut")
        }
        return LayoutLayerID(name: layerName, purpose: "drawing")
    }

    private func convertRect(_ rect: IRTechRect) -> LayoutRect {
        let minX = min(rect.x1, rect.x2)
        let minY = min(rect.y1, rect.y2)
        let maxX = max(rect.x1, rect.x2)
        let maxY = max(rect.y1, rect.y2)
        return LayoutRect(
            origin: LayoutPoint(x: minX, y: minY),
            size: LayoutSize(width: maxX - minX, height: maxY - minY)
        )
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
            spacing: layout.cutSpacing,
            layers: layout.layerGeometries.map(exportViaLayerGeometry)
        )
    }

    private func exportViaLayerGeometry(_ geometry: LayoutViaLayerGeometry) -> IRTechViaLayerGeometry {
        IRTechViaLayerGeometry(
            layerName: geometry.layer.name,
            rects: geometry.rects.map(exportRect)
        )
    }

    private func exportRect(_ rect: LayoutRect) -> IRTechRect {
        IRTechRect(
            x1: rect.minX,
            y1: rect.minY,
            x2: rect.maxX,
            y2: rect.maxY
        )
    }

    private func exportDesignRule(_ rule: LayoutLayerRuleSet) -> IRTechDesignRule {
        IRTechDesignRule(
            layerName: rule.layerID.name,
            minWidth: rule.minWidth,
            minSpacing: rule.minSpacing,
            minArea: rule.minArea,
            minEnclosedArea: rule.minEnclosedArea,
            minDensity: rule.minDensity,
            maxDensity: rule.maxDensity,
            requiresRectangular: rule.requiresRectangular ? true : nil,
            allowedAngleStepDegrees: rule.allowedAngleStepDegrees
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

    private func exportExtensionRule(_ rule: LayoutExtensionRule) -> IRTechExtensionRule {
        let direction: IRTechExtensionRule.Direction
        switch rule.direction {
        case .horizontal:
            direction = .horizontal
        case .vertical:
            direction = .vertical
        }
        return IRTechExtensionRule(
            extendingLayerName: rule.extendingLayer.name,
            enclosedLayerName: rule.enclosedLayer.name,
            minExtension: rule.minExtension,
            direction: direction
        )
    }

    private func exportMinimumCutRule(_ rule: LayoutMinimumCutRule) -> IRTechMinimumCutRule {
        IRTechMinimumCutRule(
            name: rule.id,
            cutLayerName: rule.cutLayer.name,
            bottomLayerName: rule.bottomLayer.name,
            topLayerName: rule.topLayer.name,
            minimumCount: rule.minimumCount
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
