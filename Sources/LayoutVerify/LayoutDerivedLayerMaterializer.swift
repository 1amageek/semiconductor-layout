import Foundation
import CryptoKit
import LayoutCore
import LayoutTech

public struct LayoutDerivedLayerMaterializer: Sendable {
    private struct DerivedLayerCandidate {
        var rect: LayoutRect
        var sourceShapeIDs: [UUID]
        var netID: UUID?
    }

    private struct CloseGridCell: Hashable {
        var xIndex: Int
        var yIndex: Int
    }

    private static let geometryTolerance = 0.000000001

    public init() {}

    public static func materialize(
        document: LayoutDocument,
        tech: LayoutTechDatabase
    ) -> LayoutDocument {
        Self().materialize(document: document, tech: tech)
    }

    public func materialize(
        document: LayoutDocument,
        tech: LayoutTechDatabase
    ) -> LayoutDocument {
        guard !tech.derivedLayerRules.isEmpty else { return document }
        var updated = document
        for index in updated.cells.indices {
            updated.cells[index].shapes.removeAll { $0.properties["derivedLayerRuleID"] != nil }
            for rule in tech.derivedLayerRules {
                updated.cells[index].shapes.append(
                    contentsOf: materializedShapes(for: rule, in: updated.cells[index])
                )
            }
        }
        return updated
    }

    /// Returns blocking diagnostics for source geometry that this materializer
    /// cannot represent without losing layout semantics.
    public func unsupportedGeometryDiagnostics(
        document: LayoutDocument,
        tech: LayoutTechDatabase,
        cellID: UUID? = nil
    ) -> [LayoutDRCDiagnostic] {
        guard !tech.derivedLayerRules.isEmpty else { return [] }
        let targetCells = reachableCells(in: document, from: cellID)
        var diagnostics: [LayoutDRCDiagnostic] = []
        for cell in targetCells {
            for rule in tech.derivedLayerRules {
                let sourceLayers = Set(rule.sourceLayers)
                for shape in cell.shapes where sourceLayers.contains(shape.layer)
                    && shape.properties["derivedLayerRuleID"] == nil {
                    guard let geometryKind = unsupportedGeometryKind(for: shape.geometry) else {
                        continue
                    }
                    diagnostics.append(LayoutDRCDiagnostic(
                        code: "drc.unsupported_derived_geometry",
                        severity: .error,
                        message: "Derived rule '\(rule.id)' cannot safely materialize \(geometryKind) geometry on layer '\(shape.layer.name):\(shape.layer.purpose)'.",
                        cellID: cell.id,
                        suggestedActions: [
                            "convert_geometry_to_exact_supported_polygon",
                            "run_with_exact_geometry_kernel",
                            "inspect_derived_layer_rule"
                        ]
                    ))
                }
            }
        }
        return diagnostics
    }

    private func reachableCells(in document: LayoutDocument, from cellID: UUID?) -> [LayoutCell] {
        guard let cellID else { return document.cells }
        var pending = [cellID]
        var visited: Set<UUID> = []
        while let currentID = pending.popLast() {
            guard visited.insert(currentID).inserted,
                  let cell = document.cells.first(where: { $0.id == currentID }) else {
                continue
            }
            pending.append(contentsOf: cell.instances.map(\.cellID))
        }
        return document.cells.filter { visited.contains($0.id) }
    }

    public func materializedShapes(
        for rule: LayoutDerivedLayerRule,
        in cell: LayoutCell
    ) -> [LayoutShape] {
        switch rule.operation {
        case .intersection:
            return materializedIntersectionShapes(for: rule, in: cell)
        case .union:
            return materializedUnionShapes(for: rule, in: cell)
        case .difference:
            return materializedDifferenceShapes(for: rule, in: cell)
        case .xor:
            return materializedXORShapes(for: rule, in: cell)
        case .grow:
            return materializedOffsetShapes(for: rule, in: cell, distanceSign: 1)
        case .growMin:
            return materializedGrowMinShapes(for: rule, in: cell)
        case .shrink:
            return materializedOffsetShapes(for: rule, in: cell, distanceSign: -1)
        case .bridge:
            return materializedBridgeShapes(for: rule, in: cell)
        case .close:
            return materializedCloseShapes(for: rule, in: cell)
        case .bloatAll:
            return materializedBloatAllShapes(for: rule, in: cell)
        case .cellBoundary:
            return materializedCellBoundaryShapes(for: rule, in: cell)
        }
    }

    private func materializedIntersectionShapes(
        for rule: LayoutDerivedLayerRule,
        in cell: LayoutCell
    ) -> [LayoutShape] {
        guard let firstLayer = rule.sourceLayers.first,
              rule.sourceLayers.count >= 2 else {
            return []
        }
        let grouped = Dictionary(grouping: cell.shapes, by: \.layer)
        guard let firstShapes = grouped[firstLayer], !firstShapes.isEmpty else {
            return []
        }
        var candidates = firstShapes.flatMap(Self.rectCandidates)
        guard !candidates.isEmpty else { return [] }

        for layer in rule.sourceLayers.dropFirst() {
            guard let layerShapes = grouped[layer], !layerShapes.isEmpty else {
                return []
            }
            var nextCandidates: [DerivedLayerCandidate] = []
            for candidate in candidates {
                for shape in layerShapes {
                    for sourceCandidate in Self.rectCandidates(for: shape) {
                        guard let rect = Self.intersection(candidate.rect, sourceCandidate.rect) else {
                            continue
                        }
                        nextCandidates.append(DerivedLayerCandidate(
                            rect: rect,
                            sourceShapeIDs: Self.uniqueShapeIDs(candidate.sourceShapeIDs + sourceCandidate.sourceShapeIDs),
                            netID: Self.mergedNetID(candidate.netID, sourceCandidate.netID)
                        ))
                    }
                }
            }
            candidates = nextCandidates
            if candidates.isEmpty { return [] }
        }

        return candidates.map { candidate in
            Self.derivedShape(rule: rule, candidate: candidate)
        }
    }

    private func materializedUnionShapes(
        for rule: LayoutDerivedLayerRule,
        in cell: LayoutCell
    ) -> [LayoutShape] {
        let grouped = Dictionary(grouping: cell.shapes, by: \.layer)
        return rule.sourceLayers.flatMap { layer -> [LayoutShape] in
            (grouped[layer] ?? []).flatMap { shape in
                Self.rectCandidates(for: shape).map { candidate in
                    Self.derivedShape(rule: rule, candidate: candidate)
                }
            }
        }
    }

    private func materializedDifferenceShapes(
        for rule: LayoutDerivedLayerRule,
        in cell: LayoutCell
    ) -> [LayoutShape] {
        guard let firstLayer = rule.sourceLayers.first,
              rule.sourceLayers.count >= 2 else {
            return []
        }
        let grouped = Dictionary(grouping: cell.shapes, by: \.layer)
        guard let baseShapes = grouped[firstLayer], !baseShapes.isEmpty else {
            return []
        }
        let cutterShapes = rule.sourceLayers.dropFirst().flatMap { grouped[$0] ?? [] }
        guard !cutterShapes.isEmpty else {
            return baseShapes.flatMap { shape in
                Self.rectCandidates(for: shape).map { candidate in
                    Self.derivedShape(rule: rule, candidate: candidate)
                }
            }
        }

        var materialized: [LayoutShape] = []
        for baseShape in baseShapes {
            var candidates = Self.rectCandidates(for: baseShape)
            for cutterShape in cutterShapes {
                let cutterCandidates = Self.rectCandidates(for: cutterShape)
                guard !cutterCandidates.isEmpty else { continue }
                var nextCandidates: [DerivedLayerCandidate] = []
                for candidate in candidates {
                    var pieces = [candidate]
                    for cutterCandidate in cutterCandidates {
                        pieces = pieces.flatMap { pieceCandidate in
                            Self.subtract(cutterCandidate.rect, from: pieceCandidate.rect).map { piece in
                                DerivedLayerCandidate(
                                    rect: piece,
                                    sourceShapeIDs: Self.uniqueShapeIDs(
                                        pieceCandidate.sourceShapeIDs + cutterCandidate.sourceShapeIDs
                                    ),
                                    netID: pieceCandidate.netID
                                )
                            }
                        }
                        if pieces.isEmpty { break }
                    }
                    nextCandidates.append(contentsOf: pieces)
                }
                candidates = nextCandidates
                if candidates.isEmpty { break }
            }
            materialized.append(contentsOf: candidates.map { Self.derivedShape(rule: rule, candidate: $0) })
        }
        return materialized
    }

    private func materializedXORShapes(
        for rule: LayoutDerivedLayerRule,
        in cell: LayoutCell
    ) -> [LayoutShape] {
        guard rule.sourceLayers.count >= 2 else { return [] }
        let grouped = Dictionary(grouping: cell.shapes, by: \.layer)
        let firstLayer = rule.sourceLayers[0]
        let secondLayer = rule.sourceLayers[1]
        let firstShapes = grouped[firstLayer] ?? []
        let secondShapes = grouped[secondLayer] ?? []
        return materializedExclusiveShapes(
            baseShapes: firstShapes,
            cutterShapes: secondShapes,
            rule: rule
        ) + materializedExclusiveShapes(
            baseShapes: secondShapes,
            cutterShapes: firstShapes,
            rule: rule
        )
    }

    private func materializedExclusiveShapes(
        baseShapes: [LayoutShape],
        cutterShapes: [LayoutShape],
        rule: LayoutDerivedLayerRule
    ) -> [LayoutShape] {
        guard !baseShapes.isEmpty else { return [] }
        var materialized: [LayoutShape] = []
        for baseShape in baseShapes {
            var candidates = Self.rectCandidates(for: baseShape)
            for cutterShape in cutterShapes {
                let cutterCandidates = Self.rectCandidates(for: cutterShape)
                guard !cutterCandidates.isEmpty else { continue }
                for cutterCandidate in cutterCandidates {
                    candidates = candidates.flatMap { candidate in
                        Self.subtract(cutterCandidate.rect, from: candidate.rect).map { piece in
                            DerivedLayerCandidate(
                                rect: piece,
                                sourceShapeIDs: Self.uniqueShapeIDs(candidate.sourceShapeIDs + cutterCandidate.sourceShapeIDs),
                                netID: candidate.netID
                            )
                        }
                    }
                    if candidates.isEmpty { break }
                }
                if candidates.isEmpty { break }
            }
            materialized.append(contentsOf: candidates.map { Self.derivedShape(rule: rule, candidate: $0) })
        }
        return materialized
    }

    private func materializedOffsetShapes(
        for rule: LayoutDerivedLayerRule,
        in cell: LayoutCell,
        distanceSign: Double
    ) -> [LayoutShape] {
        guard let distance = rule.operationDistance,
              distance.isFinite,
              distance >= 0 else {
            return []
        }
        let grouped = Dictionary(grouping: cell.shapes, by: \.layer)
        return rule.sourceLayers.flatMap { layer -> [LayoutShape] in
            (grouped[layer] ?? []).flatMap { shape in
                Self.rectCandidates(for: shape).compactMap { candidate in
                    guard let offsetRect = Self.offset(candidate.rect, by: distance * distanceSign) else {
                        return nil
                    }
                    return Self.derivedShape(
                        rule: rule,
                        candidate: DerivedLayerCandidate(
                            rect: offsetRect,
                            sourceShapeIDs: candidate.sourceShapeIDs,
                            netID: candidate.netID
                        )
                    )
                }
            }
        }
    }

    private func materializedGrowMinShapes(
        for rule: LayoutDerivedLayerRule,
        in cell: LayoutCell
    ) -> [LayoutShape] {
        guard let minimumSize = rule.operationDistance,
              minimumSize.isFinite,
              minimumSize >= 0 else {
            return []
        }
        let grouped = Dictionary(grouping: cell.shapes, by: \.layer)
        return rule.sourceLayers.flatMap { layer -> [LayoutShape] in
            (grouped[layer] ?? []).flatMap { shape in
                Self.rectCandidates(for: shape).compactMap { candidate in
                    guard let grownRect = Self.growMin(candidate.rect, minimumSize: minimumSize) else {
                        return nil
                    }
                    return Self.derivedShape(
                        rule: rule,
                        candidate: DerivedLayerCandidate(
                            rect: grownRect,
                            sourceShapeIDs: candidate.sourceShapeIDs,
                            netID: candidate.netID
                        )
                    )
                }
            }
        }
    }

    private func materializedBridgeShapes(
        for rule: LayoutDerivedLayerRule,
        in cell: LayoutCell
    ) -> [LayoutShape] {
        guard let maxDistance = rule.operationDistance,
              maxDistance.isFinite,
              maxDistance > 0,
              let width = rule.operationWidth ?? rule.operationDistance,
              width.isFinite,
              width > 0 else {
            return []
        }

        let baseCandidates = sourceCandidates(for: rule, in: cell)
        guard !baseCandidates.isEmpty else { return [] }

        var candidates = baseCandidates
        guard baseCandidates.count > 1 else {
            return candidates.map { Self.derivedShape(rule: rule, candidate: $0) }
        }

        for leftIndex in 0..<(baseCandidates.count - 1) {
            for rightIndex in (leftIndex + 1)..<baseCandidates.count {
                let left = baseCandidates[leftIndex]
                let right = baseCandidates[rightIndex]
                guard let rect = Self.bridgeRect(
                    between: left.rect,
                    and: right.rect,
                    maxDistance: maxDistance,
                    width: width
                ) else {
                    continue
                }
                candidates.append(DerivedLayerCandidate(
                    rect: rect,
                    sourceShapeIDs: Self.uniqueShapeIDs(left.sourceShapeIDs + right.sourceShapeIDs),
                    netID: Self.mergedNetID(left.netID, right.netID)
                ))
            }
        }

        return candidates.map { Self.derivedShape(rule: rule, candidate: $0) }
    }

    private func materializedCloseShapes(
        for rule: LayoutDerivedLayerRule,
        in cell: LayoutCell
    ) -> [LayoutShape] {
        let areaThreshold = rule.operationDistance ?? 0
        guard areaThreshold.isFinite,
              areaThreshold >= 0 else {
            return []
        }

        let baseCandidates = sourceCandidates(for: rule, in: cell)
        guard !baseCandidates.isEmpty else { return [] }

        let sourceShapeIDs = Self.uniqueShapeIDs(baseCandidates.flatMap(\.sourceShapeIDs))
        let fillCandidates = Self.closeFillRects(
            from: baseCandidates.map(\.rect),
            areaThreshold: areaThreshold
        ).map { rect in
            DerivedLayerCandidate(
                rect: rect,
                sourceShapeIDs: sourceShapeIDs,
                netID: nil
            )
        }

        return (baseCandidates + fillCandidates).map { Self.derivedShape(rule: rule, candidate: $0) }
    }

    private func materializedBloatAllShapes(
        for rule: LayoutDerivedLayerRule,
        in cell: LayoutCell
    ) -> [LayoutShape] {
        guard let primarySourceLayerCount = rule.primarySourceLayerCount,
              primarySourceLayerCount > 0,
              primarySourceLayerCount < rule.sourceLayers.count else {
            return []
        }

        let grouped = Dictionary(grouping: cell.shapes, by: \.layer)
        let seedLayers = rule.sourceLayers.prefix(primarySourceLayerCount)
        let guideLayers = rule.sourceLayers.dropFirst(primarySourceLayerCount)
        let seedShapes = seedLayers.flatMap { grouped[$0] ?? [] }
        let guideShapes = guideLayers.flatMap { grouped[$0] ?? [] }
        let seedCandidates = seedShapes.flatMap(Self.rectCandidates)
        let guideCandidates = guideShapes.flatMap(Self.rectCandidates)
        guard !seedCandidates.isEmpty, !guideCandidates.isEmpty else {
            return []
        }

        var selected = Array(repeating: false, count: guideCandidates.count)
        var selectedSourceShapeIDs = guideCandidates.map(\.sourceShapeIDs)
        var queue: [Int] = []
        for index in guideCandidates.indices {
            let touchingSeedIDs = seedCandidates
                .filter { Self.touchesOrOverlaps($0.rect, guideCandidates[index].rect) }
                .flatMap(\.sourceShapeIDs)
            guard !touchingSeedIDs.isEmpty else { continue }
            selected[index] = true
            selectedSourceShapeIDs[index] = Self.uniqueShapeIDs(guideCandidates[index].sourceShapeIDs + touchingSeedIDs)
            queue.append(index)
        }

        var cursor = 0
        while cursor < queue.count {
            let selectedIndex = queue[cursor]
            cursor += 1
            for candidateIndex in guideCandidates.indices where !selected[candidateIndex] {
                guard Self.touchesOrOverlaps(
                    guideCandidates[selectedIndex].rect,
                    guideCandidates[candidateIndex].rect
                ) else {
                    continue
                }
                selected[candidateIndex] = true
                selectedSourceShapeIDs[candidateIndex] = Self.uniqueShapeIDs(
                    guideCandidates[candidateIndex].sourceShapeIDs + selectedSourceShapeIDs[selectedIndex]
                )
                queue.append(candidateIndex)
            }
        }

        return guideCandidates.indices
            .filter { selected[$0] }
            .map { index in
                var candidate = guideCandidates[index]
                candidate.sourceShapeIDs = selectedSourceShapeIDs[index]
                return Self.derivedShape(rule: rule, candidate: candidate)
            }
    }

    private func materializedCellBoundaryShapes(
        for rule: LayoutDerivedLayerRule,
        in cell: LayoutCell
    ) -> [LayoutShape] {
        guard rule.sourceLayers.isEmpty,
              let rect = Self.fixedBoundaryRect(in: cell) else {
            return []
        }
        return [
            Self.derivedShape(
                rule: rule,
                candidate: DerivedLayerCandidate(
                    rect: rect,
                    sourceShapeIDs: [],
                    netID: nil
                )
            )
        ]
    }

    private func sourceCandidates(
        for rule: LayoutDerivedLayerRule,
        in cell: LayoutCell
    ) -> [DerivedLayerCandidate] {
        let grouped = Dictionary(grouping: cell.shapes, by: \.layer)
        return rule.sourceLayers.flatMap { layer -> [DerivedLayerCandidate] in
            (grouped[layer] ?? []).flatMap(Self.rectCandidates)
        }
    }

    private static func derivedShape(
        rule: LayoutDerivedLayerRule,
        candidate: DerivedLayerCandidate
    ) -> LayoutShape {
        LayoutShape(
            id: deterministicDerivedShapeID(rule: rule, candidate: candidate),
            layer: rule.targetLayer,
            netID: candidate.netID,
            geometry: .rect(candidate.rect),
            properties: [
                "derivedLayerRuleID": rule.id,
                "derivedSourceShapeIDs": candidate.sourceShapeIDs.map(\.uuidString).joined(separator: ","),
            ]
        )
    }

    private static func deterministicDerivedShapeID(
        rule: LayoutDerivedLayerRule,
        candidate: DerivedLayerCandidate
    ) -> UUID {
        let rect = candidate.rect
        let sourceIDs = candidate.sourceShapeIDs.map(\.uuidString).sorted().joined(separator: ",")
        let payload = [
            "derived-shape-v1",
            rule.id,
            Self.format(rect.minX),
            Self.format(rect.minY),
            Self.format(rect.maxX),
            Self.format(rect.maxY),
            sourceIDs
        ].joined(separator: "|")
        var bytes = Array(SHA256.hash(data: Data(payload.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func format(_ value: Double) -> String {
        let normalized = value == 0 ? 0 : value
        return String(
            format: "%.12f",
            locale: Locale(identifier: "en_US_POSIX"),
            normalized
        )
    }

    private static func subtract(_ cutter: LayoutRect, from base: LayoutRect) -> [LayoutRect] {
        guard let overlap = intersection(base, cutter) else {
            return [base]
        }
        var pieces: [LayoutRect] = []
        appendRect(minX: base.minX, minY: base.minY, maxX: overlap.minX, maxY: base.maxY, to: &pieces)
        appendRect(minX: overlap.maxX, minY: base.minY, maxX: base.maxX, maxY: base.maxY, to: &pieces)
        appendRect(minX: overlap.minX, minY: base.minY, maxX: overlap.maxX, maxY: overlap.minY, to: &pieces)
        appendRect(minX: overlap.minX, minY: overlap.maxY, maxX: overlap.maxX, maxY: base.maxY, to: &pieces)
        return pieces
    }

    private static func appendRect(
        minX: Double,
        minY: Double,
        maxX: Double,
        maxY: Double,
        to pieces: inout [LayoutRect]
    ) {
        guard maxX - minX > geometryTolerance, maxY - minY > geometryTolerance else {
            return
        }
        pieces.append(LayoutRect(
            origin: LayoutPoint(x: minX, y: minY),
            size: LayoutSize(width: maxX - minX, height: maxY - minY)
        ))
    }

    private static func offset(_ rect: LayoutRect, by distance: Double) -> LayoutRect? {
        let offsetRect: LayoutRect
        if distance >= 0 {
            offsetRect = rect.expanded(by: distance, distance)
        } else {
            offsetRect = rect.inset(by: -distance, -distance)
        }
        guard offsetRect.size.width > geometryTolerance,
              offsetRect.size.height > geometryTolerance else {
            return nil
        }
        return offsetRect
    }

    private static func growMin(_ rect: LayoutRect, minimumSize: Double) -> LayoutRect? {
        let widthDelta = max(0, minimumSize - rect.size.width) / 2
        let heightDelta = max(0, minimumSize - rect.size.height) / 2
        let grownRect = LayoutRect(
            origin: LayoutPoint(
                x: rect.origin.x - widthDelta,
                y: rect.origin.y - heightDelta
            ),
            size: LayoutSize(
                width: rect.size.width + widthDelta * 2,
                height: rect.size.height + heightDelta * 2
            )
        )
        guard grownRect.size.width > geometryTolerance,
              grownRect.size.height > geometryTolerance else {
            return nil
        }
        return grownRect
    }

    private static func bridgeRect(
        between first: LayoutRect,
        and second: LayoutRect,
        maxDistance: Double,
        width: Double
    ) -> LayoutRect? {
        if let overlap = intersection(first, second) {
            guard overlap.size.width + geometryTolerance < width
                    || overlap.size.height + geometryTolerance < width else {
                return nil
            }
            return growMin(overlap, minimumSize: width)
        }

        let horizontalGap: (min: Double, max: Double, distance: Double)?
        if first.maxX <= second.minX + geometryTolerance {
            horizontalGap = (first.maxX, second.minX, max(0, second.minX - first.maxX))
        } else if second.maxX <= first.minX + geometryTolerance {
            horizontalGap = (second.maxX, first.minX, max(0, first.minX - second.maxX))
        } else {
            horizontalGap = nil
        }

        let verticalGap: (min: Double, max: Double, distance: Double)?
        if first.maxY <= second.minY + geometryTolerance {
            verticalGap = (first.maxY, second.minY, max(0, second.minY - first.maxY))
        } else if second.maxY <= first.minY + geometryTolerance {
            verticalGap = (second.maxY, first.minY, max(0, first.minY - second.maxY))
        } else {
            verticalGap = nil
        }

        guard let horizontalGap,
              let verticalGap,
              horizontalGap.distance <= maxDistance + geometryTolerance,
              verticalGap.distance <= maxDistance + geometryTolerance else {
            return nil
        }

        let gapRect = LayoutRect(
            origin: LayoutPoint(x: horizontalGap.min, y: verticalGap.min),
            size: LayoutSize(
                width: horizontalGap.max - horizontalGap.min,
                height: verticalGap.max - verticalGap.min
            )
        )
        return growMin(gapRect, minimumSize: width)
    }

    private static func closeFillRects(
        from sourceRects: [LayoutRect],
        areaThreshold: Double
    ) -> [LayoutRect] {
        let xValues = sortedUniqueCoordinates(sourceRects.flatMap { [$0.minX, $0.maxX] })
        let yValues = sortedUniqueCoordinates(sourceRects.flatMap { [$0.minY, $0.maxY] })
        guard xValues.count >= 2, yValues.count >= 2 else { return [] }

        let xCellCount = xValues.count - 1
        let yCellCount = yValues.count - 1
        var emptyCells: Set<CloseGridCell> = []

        for xIndex in 0..<xCellCount {
            for yIndex in 0..<yCellCount {
                let cell = closeCellRect(xIndex: xIndex, yIndex: yIndex, xValues: xValues, yValues: yValues)
                guard cell.size.width > geometryTolerance,
                      cell.size.height > geometryTolerance else {
                    continue
                }
                let covered = sourceRects.contains { rect in
                    rect.contains(cell.center)
                }
                if !covered {
                    emptyCells.insert(CloseGridCell(xIndex: xIndex, yIndex: yIndex))
                }
            }
        }

        var remaining = emptyCells
        var fillRects: [LayoutRect] = []
        while let start = remaining.first {
            var queue = [start]
            var cursor = 0
            var component: [CloseGridCell] = []
            var touchesBoundary = false
            var area = 0.0
            remaining.remove(start)

            while cursor < queue.count {
                let cell = queue[cursor]
                cursor += 1
                component.append(cell)
                touchesBoundary = touchesBoundary
                    || cell.xIndex == 0
                    || cell.xIndex == xCellCount - 1
                    || cell.yIndex == 0
                    || cell.yIndex == yCellCount - 1
                let rect = closeCellRect(xIndex: cell.xIndex, yIndex: cell.yIndex, xValues: xValues, yValues: yValues)
                area += rect.size.width * rect.size.height

                for neighbor in closeNeighbors(of: cell, xCellCount: xCellCount, yCellCount: yCellCount) {
                    guard remaining.remove(neighbor) != nil else { continue }
                    queue.append(neighbor)
                }
            }

            guard !touchesBoundary,
                  areaThreshold == 0 || area < areaThreshold + geometryTolerance else {
                continue
            }
            fillRects.append(contentsOf: mergedCloseFillRects(component, xValues: xValues, yValues: yValues))
        }

        return fillRects
    }

    private static func sortedUniqueCoordinates(_ values: [Double]) -> [Double] {
        values
            .filter(\.isFinite)
            .sorted()
            .reduce(into: [Double]()) { unique, value in
                guard let last = unique.last,
                      abs(last - value) <= geometryTolerance else {
                    unique.append(value)
                    return
                }
            }
    }

    private static func closeCellRect(
        xIndex: Int,
        yIndex: Int,
        xValues: [Double],
        yValues: [Double]
    ) -> LayoutRect {
        LayoutRect(
            origin: LayoutPoint(x: xValues[xIndex], y: yValues[yIndex]),
            size: LayoutSize(
                width: xValues[xIndex + 1] - xValues[xIndex],
                height: yValues[yIndex + 1] - yValues[yIndex]
            )
        )
    }

    private static func closeNeighbors(
        of cell: CloseGridCell,
        xCellCount: Int,
        yCellCount: Int
    ) -> [CloseGridCell] {
        [
            CloseGridCell(xIndex: cell.xIndex - 1, yIndex: cell.yIndex),
            CloseGridCell(xIndex: cell.xIndex + 1, yIndex: cell.yIndex),
            CloseGridCell(xIndex: cell.xIndex, yIndex: cell.yIndex - 1),
            CloseGridCell(xIndex: cell.xIndex, yIndex: cell.yIndex + 1),
        ].filter { neighbor in
            neighbor.xIndex >= 0
                && neighbor.xIndex < xCellCount
                && neighbor.yIndex >= 0
                && neighbor.yIndex < yCellCount
        }
    }

    private static func mergedCloseFillRects(
        _ component: [CloseGridCell],
        xValues: [Double],
        yValues: [Double]
    ) -> [LayoutRect] {
        let rows = Dictionary(grouping: component, by: \.yIndex)
        return rows.keys.sorted().flatMap { yIndex -> [LayoutRect] in
            let xIndices = (rows[yIndex] ?? []).map(\.xIndex).sorted()
            guard !xIndices.isEmpty else { return [] }
            var spans: [(start: Int, end: Int)] = []
            var start = xIndices[0]
            var end = xIndices[0]
            for xIndex in xIndices.dropFirst() {
                if xIndex == end + 1 {
                    end = xIndex
                } else {
                    spans.append((start, end))
                    start = xIndex
                    end = xIndex
                }
            }
            spans.append((start, end))
            return spans.map { span in
                LayoutRect(
                    origin: LayoutPoint(x: xValues[span.start], y: yValues[yIndex]),
                    size: LayoutSize(
                        width: xValues[span.end + 1] - xValues[span.start],
                        height: yValues[yIndex + 1] - yValues[yIndex]
                    )
                )
            }
        }
    }

    private static func rectCandidates(for shape: LayoutShape) -> [DerivedLayerCandidate] {
        rects(for: shape.geometry).map { rect in
            DerivedLayerCandidate(
                rect: rect,
                sourceShapeIDs: [shape.id],
                netID: shape.netID
            )
        }
    }

    private static func rects(for geometry: LayoutGeometry) -> [LayoutRect] {
        switch geometry {
        case .rect(let rect):
            return [rect]
        case .polygon(let polygon):
            if let rect = axisAlignedRect(for: polygon) {
                return [rect]
            }
            return rectilinearRects(for: polygon)
        case .path:
            return []
        }
    }

    private func unsupportedGeometryKind(for geometry: LayoutGeometry) -> String? {
        switch geometry {
        case .rect:
            return nil
        case .path:
            return "path"
        case .polygon(let polygon):
            var points = polygon.points
            if let first = points.first, points.last == first {
                points.removeLast()
            }
            return Self.polygonEdgesAreRectilinear(points) ? nil : "non-rectilinear polygon"
        }
    }

    private static func axisAlignedRect(for polygon: LayoutPolygon) -> LayoutRect? {
        var points = polygon.points
        if let first = points.first, points.last == first {
            points.removeLast()
        }
        guard points.count == 4 else { return nil }
        let bounds = LayoutGeometryAnalysis.boundingBox(for: polygon)
        let corners = [
            LayoutPoint(x: bounds.minX, y: bounds.minY),
            LayoutPoint(x: bounds.maxX, y: bounds.minY),
            LayoutPoint(x: bounds.maxX, y: bounds.maxY),
            LayoutPoint(x: bounds.minX, y: bounds.maxY),
        ]
        guard corners.allSatisfy({ corner in
            points.contains { point in
                abs(point.x - corner.x) < geometryTolerance &&
                    abs(point.y - corner.y) < geometryTolerance
            }
        }) else {
            return nil
        }
        return bounds
    }

    private static func rectilinearRects(for polygon: LayoutPolygon) -> [LayoutRect] {
        var points = polygon.points
        if let first = points.first, points.last == first {
            points.removeLast()
        }
        guard points.count >= 4,
              polygonEdgesAreRectilinear(points) else {
            return []
        }
        let xValues = sortedUniqueCoordinates(points.map(\.x))
        let yValues = sortedUniqueCoordinates(points.map(\.y))
        guard xValues.count >= 2, yValues.count >= 2 else { return [] }

        var cellsByRow: [Int: [Int]] = [:]
        for yIndex in 0..<(yValues.count - 1) {
            for xIndex in 0..<(xValues.count - 1) {
                let cell = LayoutRect(
                    origin: LayoutPoint(x: xValues[xIndex], y: yValues[yIndex]),
                    size: LayoutSize(
                        width: xValues[xIndex + 1] - xValues[xIndex],
                        height: yValues[yIndex + 1] - yValues[yIndex]
                    )
                )
                guard cell.size.width > geometryTolerance,
                      cell.size.height > geometryTolerance,
                      point(cell.center, isInside: points) else {
                    continue
                }
                cellsByRow[yIndex, default: []].append(xIndex)
            }
        }

        return cellsByRow.keys.sorted().flatMap { yIndex -> [LayoutRect] in
            let xIndices = (cellsByRow[yIndex] ?? []).sorted()
            guard !xIndices.isEmpty else { return [] }
            var spans: [(start: Int, end: Int)] = []
            var start = xIndices[0]
            var end = xIndices[0]
            for xIndex in xIndices.dropFirst() {
                if xIndex == end + 1 {
                    end = xIndex
                } else {
                    spans.append((start, end))
                    start = xIndex
                    end = xIndex
                }
            }
            spans.append((start, end))
            return spans.map { span in
                LayoutRect(
                    origin: LayoutPoint(x: xValues[span.start], y: yValues[yIndex]),
                    size: LayoutSize(
                        width: xValues[span.end + 1] - xValues[span.start],
                        height: yValues[yIndex + 1] - yValues[yIndex]
                    )
                )
            }
        }
    }

    private static func polygonEdgesAreRectilinear(_ points: [LayoutPoint]) -> Bool {
        guard points.count >= 4 else { return false }
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            let current = points[index]
            let horizontal = abs(current.y - next.y) <= geometryTolerance
            let vertical = abs(current.x - next.x) <= geometryTolerance
            guard horizontal != vertical else {
                return false
            }
        }
        return true
    }

    private static func point(_ point: LayoutPoint, isInside polygon: [LayoutPoint]) -> Bool {
        var inside = false
        var previousIndex = polygon.count - 1
        for index in polygon.indices {
            let current = polygon[index]
            let previous = polygon[previousIndex]
            let crossesRay = (current.y > point.y) != (previous.y > point.y)
            if crossesRay {
                let intersectX = (previous.x - current.x)
                    * (point.y - current.y)
                    / (previous.y - current.y)
                    + current.x
                if point.x < intersectX {
                    inside.toggle()
                }
            }
            previousIndex = index
        }
        return inside
    }

    private static func intersection(_ first: LayoutRect, _ second: LayoutRect) -> LayoutRect? {
        let minX = max(first.minX, second.minX)
        let minY = max(first.minY, second.minY)
        let maxX = min(first.maxX, second.maxX)
        let maxY = min(first.maxY, second.maxY)
        guard minX < maxX, minY < maxY else { return nil }
        return LayoutRect(
            origin: LayoutPoint(x: minX, y: minY),
            size: LayoutSize(width: maxX - minX, height: maxY - minY)
        )
    }

    private static func touchesOrOverlaps(_ first: LayoutRect, _ second: LayoutRect) -> Bool {
        !(second.maxX < first.minX
            || second.minX > first.maxX
            || second.maxY < first.minY
            || second.minY > first.maxY)
    }

    private static func uniqueShapeIDs(_ ids: [UUID]) -> [UUID] {
        var seen: Set<UUID> = []
        var unique: [UUID] = []
        for id in ids where seen.insert(id).inserted {
            unique.append(id)
        }
        return unique
    }

    private static func mergedNetID(_ first: UUID?, _ second: UUID?) -> UUID? {
        switch (first, second) {
        case (.none, .none):
            return nil
        case (.some(let id), .none), (.none, .some(let id)):
            return id
        case (.some(let lhs), .some(let rhs)):
            return lhs == rhs ? lhs : nil
        }
    }

    private static func fixedBoundaryRect(in cell: LayoutCell) -> LayoutRect? {
        let keys = [
            "FIXED_BBOX",
            "fixed_bbox",
            "fixedBBox",
            "fixedBoundingBox",
            "lsi.fixedBBox",
        ]
        for key in keys {
            guard let rawValue = cell.properties[key],
                  let rect = rect(fromFixedBoundaryValue: rawValue) else {
                continue
            }
            return rect
        }
        return nil
    }

    private static func rect(fromFixedBoundaryValue rawValue: String) -> LayoutRect? {
        let normalized = rawValue.map { character -> Character in
            character.isNumber || character == "." || character == "-" || character == "+" || character == "e" || character == "E"
                ? character
                : " "
        }
        let values = String(normalized)
            .split(separator: " ")
            .compactMap { Double($0) }
        guard values.count == 4,
              values.allSatisfy({ $0.isFinite }) else {
            return nil
        }
        let x = values[0]
        let y = values[1]
        let third = values[2]
        let fourth = values[3]
        if third > x, fourth > y {
            return LayoutRect(
                origin: LayoutPoint(x: x, y: y),
                size: LayoutSize(width: third - x, height: fourth - y)
            )
        }
        guard third > 0, fourth > 0 else {
            return nil
        }
        return LayoutRect(
            origin: LayoutPoint(x: x, y: y),
            size: LayoutSize(width: third, height: fourth)
        )
    }
}
