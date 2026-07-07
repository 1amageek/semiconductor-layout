import DEF
import Foundation
import LayoutCore
import LayoutTech

struct DEFViaDefinitionTechAugmentor: Sendable {
    func augmenting(
        _ tech: LayoutTechDatabase,
        with viaDefs: [DEFViaDef],
        dbuPerMicron: Double
    ) -> LayoutTechDatabase {
        guard !viaDefs.isEmpty else { return tech }

        var augmented = tech
        for viaDef in viaDefs {
            guard let layoutVia = layoutViaDefinition(from: viaDef, tech: augmented, dbuPerMicron: dbuPerMicron) else {
                continue
            }
            if let existingIndex = augmented.vias.firstIndex(where: { $0.id == layoutVia.id }) {
                augmented.vias[existingIndex] = layoutVia
            } else {
                augmented.vias.append(layoutVia)
            }
        }
        return augmented
    }

    private func layoutViaDefinition(
        from viaDef: DEFViaDef,
        tech: LayoutTechDatabase,
        dbuPerMicron: Double
    ) -> LayoutViaDefinition? {
        let layerIDsByName = defLayerIDsByName(in: tech)
        let mappedLayers = viaDef.layers.compactMap { layer -> MappedViaLayer? in
            guard let id = layerIDsByName[normalizedDEFName(layer.layerName)] else { return nil }
            return MappedViaLayer(defLayer: layer, layerID: id)
        }
        guard let stack = viaStack(from: mappedLayers) else { return nil }
        guard let cutSize = cutSize(from: viaDef, cutLayer: stack.cut, dbuPerMicron: dbuPerMicron),
              cutSize.width > 0,
              cutSize.height > 0 else {
            return nil
        }

        let cutRect = firstRect(on: stack.cut, dbuPerMicron: dbuPerMicron)
        let bottomEnclosure = enclosure(
            explicit: viaDef.botEnclosure,
            conductorLayer: stack.bottom,
            cutRect: cutRect,
            dbuPerMicron: dbuPerMicron
        )
        let topEnclosure = enclosure(
            explicit: viaDef.topEnclosure,
            conductorLayer: stack.top,
            cutRect: cutRect,
            dbuPerMicron: dbuPerMicron
        )

        return LayoutViaDefinition(
            id: viaDef.name,
            cutLayer: stack.cut.layerID,
            topLayer: stack.top.layerID,
            bottomLayer: stack.bottom.layerID,
            cutSize: cutSize,
            enclosure: LayoutViaEnclosure(top: topEnclosure, bottom: bottomEnclosure),
            cutSpacing: cutSpacing(from: viaDef, cutLayer: stack.cut, dbuPerMicron: dbuPerMicron),
            layerGeometries: viaGeometries(from: mappedLayers, dbuPerMicron: dbuPerMicron)
        )
    }

    private func defLayerIDsByName(in tech: LayoutTechDatabase) -> [String: LayoutLayerID] {
        var result: [String: LayoutLayerID] = [:]
        for layer in tech.layers {
            result[normalizedDEFName(layer.id.name)] = layer.id
            result[normalizedDEFName(layer.displayName)] = layer.id
        }
        return result
    }

    private func viaStack(from layers: [MappedViaLayer]) -> ViaStack? {
        guard layers.count >= 3 else { return nil }
        let cutIndex = layers.firstIndex(where: isCutLayer) ?? 1
        guard layers.indices.contains(cutIndex) else { return nil }

        let layersAfterCut: ArraySlice<MappedViaLayer>
        if cutIndex + 1 < layers.endIndex {
            layersAfterCut = layers[(cutIndex + 1)..<layers.endIndex]
        } else {
            layersAfterCut = []
        }
        let bottom = layers[..<cutIndex].last(where: { !isCutLayer($0) })
            ?? layers.first(where: { !isCutLayer($0) && $0.layerID != layers[cutIndex].layerID })
        let top = layersAfterCut.first(where: { !isCutLayer($0) })
            ?? layers.reversed().first(where: { !isCutLayer($0) && $0.layerID != bottom?.layerID })

        guard let bottom, let top else { return nil }
        return ViaStack(bottom: bottom, cut: layers[cutIndex], top: top)
    }

    private func isCutLayer(_ layer: MappedViaLayer) -> Bool {
        if layer.layerID.purpose.lowercased() == "cut" {
            return true
        }
        let normalizedName = normalizedDEFName(layer.defLayer.layerName)
        return normalizedName.contains("via")
            || normalizedName.contains("cut")
            || normalizedName.contains("contact")
    }

    private func cutSize(
        from viaDef: DEFViaDef,
        cutLayer: MappedViaLayer,
        dbuPerMicron: Double
    ) -> LayoutSize? {
        if let cutSize = viaDef.cutSize {
            return LayoutSize(
                width: Double(cutSize.width) / dbuPerMicron,
                height: Double(cutSize.height) / dbuPerMicron
            )
        }
        guard let rect = firstRect(on: cutLayer, dbuPerMicron: dbuPerMicron) else {
            return nil
        }
        return rect.size
    }

    private func cutSpacing(
        from viaDef: DEFViaDef,
        cutLayer: MappedViaLayer,
        dbuPerMicron: Double
    ) -> Double {
        if let cutSpacing = viaDef.cutSpacing {
            return max(Double(cutSpacing.x), Double(cutSpacing.y)) / dbuPerMicron
        }
        return inferredSpacing(from: cutLayer.defLayer.rects, dbuPerMicron: dbuPerMicron) ?? 0
    }

    private func enclosure(
        explicit: (x: Int32, y: Int32)?,
        conductorLayer: MappedViaLayer,
        cutRect: LayoutRect?,
        dbuPerMicron: Double
    ) -> Double {
        if let explicit {
            return min(Double(explicit.x), Double(explicit.y)) / dbuPerMicron
        }
        guard let cutRect,
              let conductorRect = firstRect(on: conductorLayer, dbuPerMicron: dbuPerMicron) else {
            return 0
        }
        return max(
            0,
            [
                cutRect.minX - conductorRect.minX,
                conductorRect.maxX - cutRect.maxX,
                cutRect.minY - conductorRect.minY,
                conductorRect.maxY - cutRect.maxY,
            ].min() ?? 0
        )
    }

    private func viaGeometries(
        from layers: [MappedViaLayer],
        dbuPerMicron: Double
    ) -> [LayoutViaLayerGeometry] {
        layers.map { layer in
            LayoutViaLayerGeometry(
                layer: layer.layerID,
                rects: layer.defLayer.rects.map { layoutRect(from: $0, dbuPerMicron: dbuPerMicron) }
            )
        }
    }

    private func firstRect(on layer: MappedViaLayer, dbuPerMicron: Double) -> LayoutRect? {
        layer.defLayer.rects.first.map { layoutRect(from: $0, dbuPerMicron: dbuPerMicron) }
    }

    private func layoutRect(from rect: DEFRect, dbuPerMicron: Double) -> LayoutRect {
        let minX = Double(min(rect.x1, rect.x2)) / dbuPerMicron
        let minY = Double(min(rect.y1, rect.y2)) / dbuPerMicron
        let maxX = Double(max(rect.x1, rect.x2)) / dbuPerMicron
        let maxY = Double(max(rect.y1, rect.y2)) / dbuPerMicron
        return LayoutRect(
            origin: LayoutPoint(x: minX, y: minY),
            size: LayoutSize(width: maxX - minX, height: maxY - minY)
        )
    }

    private func inferredSpacing(from rects: [DEFRect], dbuPerMicron: Double) -> Double? {
        guard rects.count >= 2 else { return nil }
        var gaps: [Double] = []
        for firstIndex in rects.indices {
            for secondIndex in rects.index(after: firstIndex)..<rects.endIndex {
                let first = layoutRect(from: rects[firstIndex], dbuPerMicron: dbuPerMicron)
                let second = layoutRect(from: rects[secondIndex], dbuPerMicron: dbuPerMicron)
                if first.maxX <= second.minX || second.maxX <= first.minX {
                    gaps.append(max(second.minX - first.maxX, first.minX - second.maxX))
                }
                if first.maxY <= second.minY || second.maxY <= first.minY {
                    gaps.append(max(second.minY - first.maxY, first.minY - second.maxY))
                }
            }
        }
        return gaps.filter { $0 >= 0 }.min()
    }

    private func normalizedDEFName(_ value: String) -> String {
        value
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private struct MappedViaLayer {
        var defLayer: DEFViaLayer
        var layerID: LayoutLayerID
    }

    private struct ViaStack {
        var bottom: MappedViaLayer
        var cut: MappedViaLayer
        var top: MappedViaLayer
    }
}
