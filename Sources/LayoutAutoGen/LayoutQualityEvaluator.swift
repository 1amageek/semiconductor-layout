import Foundation
import LayoutCore
import LayoutTech

/// Computes layout quality metrics from a generated layout document.
public struct LayoutQualityEvaluator: Sendable {

    public init() {}

    /// Evaluates quality metrics for a layout document.
    ///
    /// - Parameters:
    ///   - document: The layout document to evaluate.
    ///   - tech: Technology database for DRC evaluation.
    ///   - routingResult: Routing output (for completion rate).
    ///   - placementNets: Nets used during placement (for HPWL).
    ///   - placements: Instance placement transforms.
    ///   - instances: Placed device instances.
    ///   - constraints: Layout constraints to evaluate satisfaction rate.
    public func evaluate(
        document: LayoutDocument,
        tech: LayoutTechDatabase,
        routingResult: RoutingResult?,
        placementNets: [PlacementNet],
        placements: [UUID: LayoutTransform],
        instances: [PlacementInstance],
        constraints: [LayoutConstraint] = []
    ) -> LayoutQualityMetrics {
        var metrics = LayoutQualityMetrics()

        // 1. Total wirelength — sum lengths of routed shapes only (excludes power rails)
        let metalLayerNames: Set<String> = ["M1", "M2", "M3", "M4"]
        if let routing = routingResult {
            let routedShapes = routing.routes.flatMap(\.shapes)
            metrics.totalWirelength = computeWirelength(
                shapes: routedShapes,
                metalLayerNames: metalLayerNames
            )
        }

        // 2. Via count
        if let topCellID = document.topCellID,
           let topCell = document.cell(withID: topCellID) {
            metrics.viaCount = topCell.vias.count
        }

        // 3. Bounding box and area
        metrics.boundingBox = computeBoundingBox(document: document)
        metrics.totalArea = metrics.boundingBox.size.width * metrics.boundingBox.size.height

        // 4. HPWL from placement
        metrics.hpwl = computeHPWL(
            nets: placementNets,
            placements: placements,
            instances: instances
        )

        // 5. Routing completion
        if let routing = routingResult {
            let total = routing.routes.count + routing.unroutedNets.count
            metrics.totalNetCount = total
            metrics.routedNetCount = routing.routes.count
            metrics.routingCompletionRate = total > 0
                ? Double(routing.routes.count) / Double(total)
                : 1.0
            metrics.unroutedNets = routing.unroutedNets
        }

        // 6. DRC is not run here to avoid circular dependency on LayoutVerify.
        //    Callers should run DRC separately and inject results via `injectDRC`.

        // 7. Constraint satisfaction
        if !constraints.isEmpty {
            metrics.constraintSatisfactionRate = computeConstraintSatisfaction(
                constraints: constraints,
                placements: placements,
                instances: instances,
                grid: tech.grid
            )
        }

        // 8. White space utilization and aspect ratio
        metrics.whiteSpaceUtilization = computeWhiteSpaceUtilization(
            instances: instances,
            placements: placements
        )
        if metrics.boundingBox.size.height > 0 {
            metrics.aspectRatio = metrics.boundingBox.size.width / metrics.boundingBox.size.height
        }

        return metrics
    }

    /// Injects DRC results into existing metrics.
    public func injectDRC(
        violations: [DRCViolationInfo],
        into metrics: inout LayoutQualityMetrics
    ) {
        metrics.drcViolationCount = violations.count
        var byKind: [String: Int] = [:]
        for v in violations {
            byKind[v.kind, default: 0] += 1
        }
        metrics.drcViolationsByKind = byKind
    }

    /// Injects congestion metrics into existing metrics.
    public func injectCongestionMetrics(
        peakCongestion: Double,
        overcongestedCellCount: Int,
        into metrics: inout LayoutQualityMetrics
    ) {
        metrics.peakCongestion = peakCongestion
        metrics.overcongestedCellCount = overcongestedCellCount
    }

    /// Compares two sets of metrics and returns improvement ratios.
    ///
    /// Positive values indicate the `improved` metrics are better.
    public func compare(
        baseline: LayoutQualityMetrics,
        improved: LayoutQualityMetrics
    ) -> MetricsComparison {
        MetricsComparison(
            wirelengthImprovement: relativeReduction(
                baseline: baseline.totalWirelength,
                improved: improved.totalWirelength
            ),
            areaImprovement: relativeReduction(
                baseline: baseline.totalArea,
                improved: improved.totalArea
            ),
            viaCountImprovement: relativeReduction(
                baseline: Double(baseline.viaCount),
                improved: Double(improved.viaCount)
            ),
            drcImprovement: relativeReduction(
                baseline: Double(baseline.drcViolationCount),
                improved: Double(improved.drcViolationCount)
            ),
            routingCompletionImprovement: improved.routingCompletionRate - baseline.routingCompletionRate
        )
    }

    // MARK: - Private

    private func computeWirelength(
        shapes: [LayoutShape],
        metalLayerNames: Set<String>
    ) -> Double {
        var total = 0.0
        for shape in shapes {
            guard metalLayerNames.contains(shape.layer.name) else { continue }
            switch shape.geometry {
            case .rect(let rect):
                // Wire segment: length = longer dimension
                total += max(rect.size.width, rect.size.height)
            case .path(let path):
                total += LayoutGeometryUtils.pathLength(path)
            case .polygon:
                // Polygons are not typical routing shapes; skip
                break
            }
        }
        return total
    }

    private func computeBoundingBox(document: LayoutDocument) -> LayoutRect {
        guard let topCellID = document.topCellID,
              let topCell = document.cell(withID: topCellID) else {
            return .zero
        }
        var bbox: LayoutRect?
        for shape in topCell.shapes {
            let shapeBBox = LayoutGeometryUtils.boundingBox(for: shape.geometry)
            bbox = bbox.map { $0.union(shapeBBox) } ?? shapeBBox
        }
        for instance in topCell.instances {
            guard let cell = document.cell(withID: instance.cellID) else { continue }
            let cellBBox = cellBoundingBox(cell)
            let transformedBBox = transformRect(cellBBox, by: instance.transform)
            bbox = bbox.map { $0.union(transformedBBox) } ?? transformedBBox
        }
        return bbox ?? .zero
    }

    private func cellBoundingBox(_ cell: LayoutCell) -> LayoutRect {
        var bbox: LayoutRect?
        for shape in cell.shapes {
            let shapeBBox = LayoutGeometryUtils.boundingBox(for: shape.geometry)
            bbox = bbox.map { $0.union(shapeBBox) } ?? shapeBBox
        }
        return bbox ?? .zero
    }

    private func transformRect(_ rect: LayoutRect, by transform: LayoutTransform) -> LayoutRect {
        let corners = [
            LayoutPoint(x: rect.minX, y: rect.minY),
            LayoutPoint(x: rect.maxX, y: rect.minY),
            LayoutPoint(x: rect.maxX, y: rect.maxY),
            LayoutPoint(x: rect.minX, y: rect.maxY),
        ]
        let transformed = corners.map { transform.apply(to: $0) }
        guard let first = transformed.first else { return .zero }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in transformed.dropFirst() {
            minX = min(minX, p.x)
            minY = min(minY, p.y)
            maxX = max(maxX, p.x)
            maxY = max(maxY, p.y)
        }
        return LayoutRect(
            origin: LayoutPoint(x: minX, y: minY),
            size: LayoutSize(width: maxX - minX, height: maxY - minY)
        )
    }

    private func computeHPWL(
        nets: [PlacementNet],
        placements: [UUID: LayoutTransform],
        instances: [PlacementInstance]
    ) -> Double {
        let instanceMap = Dictionary(uniqueKeysWithValues: instances.map { ($0.id, $0) })
        var totalHPWL = 0.0

        for net in nets {
            var minX = Double.greatestFiniteMagnitude
            var minY = Double.greatestFiniteMagnitude
            var maxX = -Double.greatestFiniteMagnitude
            var maxY = -Double.greatestFiniteMagnitude
            var pinCount = 0

            for conn in net.pinConnections {
                guard let inst = instanceMap[conn.instanceID],
                      let transform = placements[conn.instanceID] else { continue }
                let pin = inst.cell.pins.first { $0.name == conn.pinName }
                guard let cellPin = pin else { continue }
                let absPos = transform.apply(to: cellPin.position)
                minX = min(minX, absPos.x)
                minY = min(minY, absPos.y)
                maxX = max(maxX, absPos.x)
                maxY = max(maxY, absPos.y)
                pinCount += 1
            }

            if pinCount >= 2 {
                totalHPWL += (maxX - minX) + (maxY - minY)
            }
        }
        return totalHPWL
    }

    private func relativeReduction(baseline: Double, improved: Double) -> Double {
        guard baseline > 0 else { return 0 }
        return (baseline - improved) / baseline
    }

    // MARK: - Constraint Satisfaction

    private func computeConstraintSatisfaction(
        constraints: [LayoutConstraint],
        placements: [UUID: LayoutTransform],
        instances: [PlacementInstance],
        grid: Double
    ) -> Double {
        guard !constraints.isEmpty else { return 1.0 }
        let tolerance = grid * 10

        var satisfied = 0
        var total = 0

        for constraint in constraints {
            switch constraint {
            case .symmetry(let sym):
                total += 1
                if isSymmetrySatisfied(sym, placements: placements, tolerance: tolerance) {
                    satisfied += 1
                }
            case .matching(let match):
                total += 1
                if isMatchingSatisfied(match, placements: placements, instances: instances, tolerance: tolerance) {
                    satisfied += 1
                }
            case .commonCentroid(let cc):
                total += 1
                if isCommonCentroidSatisfied(cc, placements: placements, tolerance: tolerance) {
                    satisfied += 1
                }
            case .interdigitated(let idg):
                total += 1
                if isInterdigitatedSatisfied(idg, placements: placements) {
                    satisfied += 1
                }
            }
        }
        return total > 0 ? Double(satisfied) / Double(total) : 1.0
    }

    private func isSymmetrySatisfied(
        _ sym: LayoutSymmetryConstraint,
        placements: [UUID: LayoutTransform],
        tolerance: Double
    ) -> Bool {
        // Use fixed axis position if available, otherwise compute from members
        let axisPos: Double
        if let fixed = sym.axisPosition {
            axisPos = fixed
        } else {
            let members = sym.members
            guard members.count >= 2 else { return true }
            var positions: [LayoutPoint] = []
            for id in members {
                guard let t = placements[id] else { return false }
                positions.append(t.translation)
            }
            let sumX: Double = positions.map(\.x).reduce(0, +)
            let sumY: Double = positions.map(\.y).reduce(0, +)
            let count = Double(positions.count)
            axisPos = sym.axis == .vertical ? sumX / count : sumY / count
        }

        // Check self-symmetric members: must sit on the axis
        for selfID in sym.selfSymmetricMembers {
            guard let t = placements[selfID] else { return false }
            let pos = sym.axis == .vertical ? t.translation.x : t.translation.y
            if abs(pos - axisPos) > tolerance { return false }
        }

        // Check pairs: for vertical axis, members[i] and members[i+1] should be symmetric about axis
        let members = sym.members
        guard members.count >= 2 else { return true }
        for i in stride(from: 0, to: members.count - 1, by: 2) {
            guard let ta = placements[members[i]],
                  let tb = placements[members[i + 1]] else { return false }
            if sym.axis == .vertical {
                let devA = abs(ta.translation.x - axisPos) - abs(tb.translation.x - axisPos)
                let devY = abs(ta.translation.y - tb.translation.y)
                if abs(devA) > tolerance || devY > tolerance { return false }
            } else {
                let devA = abs(ta.translation.y - axisPos) - abs(tb.translation.y - axisPos)
                let devX = abs(ta.translation.x - tb.translation.x)
                if abs(devA) > tolerance || devX > tolerance { return false }
            }
        }
        return true
    }

    private func isMatchingSatisfied(
        _ match: LayoutMatchingConstraint,
        placements: [UUID: LayoutTransform],
        instances: [PlacementInstance],
        tolerance: Double
    ) -> Bool {
        guard match.members.count >= 2 else { return true }

        // Check rotation and mirror match
        guard let firstTransform = placements[match.members[0]] else { return false }
        for id in match.members.dropFirst() {
            guard let t = placements[id] else { return false }
            if !rotationDegreesEqual(t.rotationDegrees, firstTransform.rotationDegrees) || t.mirrorX != firstTransform.mirrorX {
                return false
            }
        }

        // Check Y-coordinate alignment (matched devices should be on same row)
        for id in match.members.dropFirst() {
            guard let t = placements[id] else { return false }
            if abs(t.translation.y - firstTransform.translation.y) > tolerance {
                return false
            }
        }
        return true
    }

    private func isCommonCentroidSatisfied(
        _ cc: LayoutCommonCentroidConstraint,
        placements: [UUID: LayoutTransform],
        tolerance: Double
    ) -> Bool {
        guard cc.members.count >= 2 else { return true }

        // All members should have the same centroid
        var positions: [LayoutPoint] = []
        for id in cc.members {
            guard let t = placements[id] else { return false }
            positions.append(t.translation)
        }
        let cx = positions.map(\.x).reduce(0, +) / Double(positions.count)
        let cy = positions.map(\.y).reduce(0, +) / Double(positions.count)

        // Group by pattern index, check each subgroup's centroid matches common centroid
        let uniquePatterns = Set(cc.pattern)
        for patIdx in uniquePatterns {
            let indices = cc.pattern.enumerated().compactMap { $0.element == patIdx ? $0.offset : nil }
            guard !indices.isEmpty else { continue }
            let subPositions = indices.compactMap { idx -> LayoutPoint? in
                guard idx < cc.members.count else { return nil }
                return placements[cc.members[idx]]?.translation
            }
            guard !subPositions.isEmpty else { continue }
            let subCx = subPositions.map(\.x).reduce(0, +) / Double(subPositions.count)
            let subCy = subPositions.map(\.y).reduce(0, +) / Double(subPositions.count)
            if abs(subCx - cx) > tolerance || abs(subCy - cy) > tolerance {
                return false
            }
        }
        return true
    }

    private func isInterdigitatedSatisfied(
        _ idg: LayoutInterdigitatedConstraint,
        placements: [UUID: LayoutTransform]
    ) -> Bool {
        guard idg.members.count >= 2, !idg.pattern.isEmpty else { return true }

        // Sort members by X position
        let sorted = idg.members.compactMap { id -> (UUID, Double)? in
            guard let t = placements[id] else { return nil }
            return (id, t.translation.x)
        }.sorted { $0.1 < $1.1 }

        guard sorted.count == idg.members.count else { return false }

        // Check that the X-sorted order matches the expected pattern
        let memberToPatternIdx = Dictionary(uniqueKeysWithValues:
            zip(idg.members, idg.pattern).map { ($0, $1) }
        )
        let actualPattern = sorted.compactMap { memberToPatternIdx[$0.0] }

        // Pattern should alternate (e.g. [0,1,0,1] or match the specified pattern)
        return actualPattern == idg.pattern
    }

    private func rotationDegreesEqual(_ lhs: Double, _ rhs: Double) -> Bool {
        let delta = abs(((lhs - rhs + 180).truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360) - 180)
        return delta < 1e-9
    }

    // MARK: - White Space Utilization

    private func computeWhiteSpaceUtilization(
        instances: [PlacementInstance],
        placements: [UUID: LayoutTransform]
    ) -> Double {
        var deviceArea = 0.0
        var bbMinX = Double.greatestFiniteMagnitude
        var bbMinY = Double.greatestFiniteMagnitude
        var bbMaxX = -Double.greatestFiniteMagnitude
        var bbMaxY = -Double.greatestFiniteMagnitude
        var hasPlacement = false

        for inst in instances {
            guard let transform = placements[inst.id] else { continue }
            let cellBB = cellBoundingBox(inst.cell)
            let transformedBB = transformRect(cellBB, by: transform)
            deviceArea += transformedBB.size.width * transformedBB.size.height
            bbMinX = min(bbMinX, transformedBB.minX)
            bbMinY = min(bbMinY, transformedBB.minY)
            bbMaxX = max(bbMaxX, transformedBB.maxX)
            bbMaxY = max(bbMaxY, transformedBB.maxY)
            hasPlacement = true
        }

        guard hasPlacement else { return 0 }
        let totalArea = (bbMaxX - bbMinX) * (bbMaxY - bbMinY)
        guard totalArea > 0 else { return 0 }
        return min(deviceArea / totalArea, 1.0)
    }
}

/// Lightweight DRC violation info to avoid direct LayoutVerify dependency.
public struct DRCViolationInfo: Sendable {
    public let kind: String
    public let message: String

    public init(kind: String, message: String) {
        self.kind = kind
        self.message = message
    }
}
