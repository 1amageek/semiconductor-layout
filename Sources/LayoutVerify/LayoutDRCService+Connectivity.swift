import Foundation
import LayoutCore
import LayoutTech
import LayoutIR
import MaskGeometry

extension LayoutDRCService {
    func viaCutRects(for via: LayoutVia, tech: LayoutTechDatabase) -> [LayoutRect] {
        guard let def = tech.viaDefinition(for: via.viaDefinitionID) else {
            return [fallbackViaCutRect(for: via)]
        }

        let explicitRects = def.layerGeometries
            .filter { $0.layer == def.cutLayer }
            .flatMap(\.rects)
            .filter { $0.size.width > 0 && $0.size.height > 0 }
        guard !explicitRects.isEmpty else {
            return [defaultViaCutRect(for: via, definition: def)]
        }
        return explicitRects.map { LayoutGeometryAnalysis.boundingBox(for: via.geometry(forLocalRect: $0)) }
    }

    func viaLayerRects(for via: LayoutVia, layer: LayoutLayerID, tech: LayoutTechDatabase) -> [LayoutRect] {
        guard let def = tech.viaDefinition(for: via.viaDefinitionID) else {
            return []
        }
        let explicitRects = explicitViaLayerRects(for: via, layer: layer, tech: tech)
        if !explicitRects.isEmpty {
            return explicitRects
        }
        if layer == def.cutLayer || layer == def.topLayer || layer == def.bottomLayer {
            return viaCutRects(for: via, tech: tech)
        }
        return []
    }

    func explicitViaLayerRects(
        for via: LayoutVia,
        layer: LayoutLayerID,
        tech: LayoutTechDatabase
    ) -> [LayoutRect] {
        guard let def = tech.viaDefinition(for: via.viaDefinitionID) else {
            return []
        }
        return def.layerGeometries
            .filter { $0.layer == layer }
            .flatMap(\.rects)
            .filter { $0.size.width > 0 && $0.size.height > 0 }
            .map { LayoutGeometryAnalysis.boundingBox(for: via.geometry(forLocalRect: $0)) }
    }

    func viaConductorRects(for via: LayoutVia, tech: LayoutTechDatabase) -> [LayoutRect] {
        guard let def = tech.viaDefinition(for: via.viaDefinitionID) else {
            return [fallbackViaCutRect(for: via)]
        }
        let explicitRects = def.layerGeometries
            .flatMap(\.rects)
            .filter { $0.size.width > 0 && $0.size.height > 0 }
        if !explicitRects.isEmpty {
            return explicitRects.map { LayoutGeometryAnalysis.boundingBox(for: via.geometry(forLocalRect: $0)) }
        }
        return viaCutRects(for: via, tech: tech)
    }

    func viaContactRectsByLayer(
        for via: LayoutVia,
        tech: LayoutTechDatabase
    ) -> [LayoutLayerID: [LayoutRect]] {
        guard let def = tech.viaDefinition(for: via.viaDefinitionID) else {
            return [:]
        }
        var result: [LayoutLayerID: [LayoutRect]] = [:]
        for layer in Set([def.topLayer, def.bottomLayer]) {
            result[layer] = viaLayerRects(for: via, layer: layer, tech: tech)
        }
        return result
    }

    func viaCutBoundingBox(for via: LayoutVia, tech: LayoutTechDatabase) -> LayoutRect {
        union(rects: viaCutRects(for: via, tech: tech)) ?? fallbackViaCutRect(for: via)
    }

    func viaCutRect(for via: LayoutVia, tech: LayoutTechDatabase) -> LayoutRect {
        viaCutBoundingBox(for: via, tech: tech)
    }

    func unknownViaDefinitionViolation(for via: LayoutVia) -> LayoutViolation {
        LayoutViolation(
            kind: .ruleCoverage,
            ruleID: "via.\(via.viaDefinitionID).definition",
            message: "Via \(via.viaDefinitionID) is used but has no technology definition.",
            region: fallbackViaCutRect(for: via),
            measured: 1,
            required: 0,
            unit: "missing-definition",
            viaIDs: [via.id],
            netIDs: via.netID.map { [$0] } ?? [],
            suggestedFix: "Add the via/contact definition to the technology database or replace the via with a defined stack element."
        )
    }

    func union(rects: [LayoutRect]) -> LayoutRect? {
        guard var result = rects.first else { return nil }
        for rect in rects.dropFirst() {
            result = result.union(rect)
        }
        return result
    }

    private func defaultViaCutRect(for via: LayoutVia, definition: LayoutViaDefinition) -> LayoutRect {
        LayoutGeometryAnalysis.boundingBox(for: via.geometry(forLocalRect: LayoutRect(
            origin: LayoutPoint(x: -definition.cutSize.width / 2, y: -definition.cutSize.height / 2),
            size: definition.cutSize
        )))
    }

    private func fallbackViaCutRect(for via: LayoutVia) -> LayoutRect {
        LayoutGeometryAnalysis.boundingBox(for: via.geometry(forLocalRect: LayoutRect(
            origin: LayoutPoint(x: -0.5, y: -0.5),
            size: LayoutSize(width: 1, height: 1)
        )))
    }

}
